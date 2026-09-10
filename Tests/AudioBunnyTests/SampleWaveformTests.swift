import XCTest
import AVFoundation
@testable import AudioBunny

final class SampleWaveformTests: XCTestCase {

    // MARK: - computeWaveform

    func testComputeWaveformOnARealTone() throws {
        let url = try writeSineWave(seconds: 1.0, amplitude: 0.8)
        defer { try? FileManager.default.removeItem(at: url) }

        let wf = try XCTUnwrap(computeWaveform(url: url, targetPixels: 100))
        XCTAssertEqual(wf.pixelCount, 100, accuracy: 2)   // rounding at the tail
        XCTAssertEqual(wf.sampleRate, 44_100)
        XCTAssertGreaterThan(wf.samplesPerPixel, 1)

        for p in 0..<wf.pixelCount {
            let (lo, hi) = wf.minMax(at: p)
            XCTAssertGreaterThanOrEqual(lo, -1.0001)
            XCTAssertLessThanOrEqual(hi, 1.0001)
            XCTAssertLessThanOrEqual(lo, hi)
        }
        // A steady 0.8 tone: every pixel swings roughly ±0.8.
        let peak = (0..<wf.pixelCount).map { abs(wf.minMax(at: $0).max) }.max()!
        XCTAssertEqual(peak, 0.8, accuracy: 0.1)
    }

    func testComputeWaveformReturnsNilForMissingFile() {
        XCTAssertNil(computeWaveform(url: URL(fileURLWithPath: "/no/such/sound.wav")))
    }

    // MARK: - BBC audiowaveform .dat encoding

    func testEncodeProducesAConformantV2Header() {
        let wf = Waveform(sampleRate: 44_100, samplesPerPixel: 256,
                          samples: [-40, 60, -128 + 1, 127])   // 2 pixels
        let data = AudioWaveformData.encode(wf)

        XCTAssertEqual(data.count, 24 + 4)
        XCTAssertEqual([UInt8](data[0..<4]), [2, 0, 0, 0])        // int32 version = 2, LE
        XCTAssertEqual([UInt8](data[4..<8]), [1, 0, 0, 0])        // flags: 8-bit
        XCTAssertEqual(le32(data, 8), 44_100)                     // sample_rate
        XCTAssertEqual(le32(data, 12), 256)                       // samples_per_pixel
        XCTAssertEqual(le32(data, 16), 2)                         // length (pairs)
        XCTAssertEqual(le32(data, 20), 1)                         // channels
    }

    func testEncodeDecodeRoundTrips() {
        let original = Waveform(sampleRate: 48_000, samplesPerPixel: 512,
                                samples: (0..<480).map { Int8(truncatingIfNeeded: $0 - 60) })
        let restored = AudioWaveformData.decode(AudioWaveformData.encode(original))
        XCTAssertEqual(restored, original)
    }

    func testDecodeRejectsGarbage() {
        XCTAssertNil(AudioWaveformData.decode(Data([1, 2, 3])))
        XCTAssertNil(AudioWaveformData.decode(Data(count: 24)))   // version 0
    }

    // MARK: - helpers

    private func le32(_ data: Data, _ offset: Int) -> Int {
        (0..<4).reduce(0) { $0 | (Int(data[data.startIndex + offset + $1]) << (8 * $1)) }
    }

    private func writeSineWave(seconds: Double, amplitude: Float) throws -> URL {
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioBunnyWaveTest-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let ch = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = amplitude * sinf(2 * .pi * 440 * Float(i) / Float(sampleRate))
        }
        try file.write(from: buffer)
        return url
    }
}
