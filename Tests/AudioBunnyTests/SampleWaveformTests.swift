import XCTest
import AVFoundation
@testable import AudioBunny

final class SampleWaveformTests: XCTestCase {

    func testNormalizeScalesLoudestToOne() {
        XCTAssertEqual(normalizeWaveformPeaks([0.1, 0.25, 0.5]), [0.2, 0.5, 1.0])
    }

    func testNormalizeLeavesSilenceAlone() {
        XCTAssertEqual(normalizeWaveformPeaks([0, 0, 0]), [0, 0, 0])
    }

    func testNormalizeClampsAboveOne() {
        // Shouldn't happen from real audio, but must never exceed 1.
        XCTAssertEqual(normalizeWaveformPeaks([2, 1]).max()!, 1.0, accuracy: 0.0001)
    }

    func testComputeWaveformPeaksOnARealFile() throws {
        let url = try writeSineWave(seconds: 1.0, amplitude: 0.8)
        defer { try? FileManager.default.removeItem(at: url) }

        let peaks = try XCTUnwrap(computeWaveformPeaks(url: url, buckets: 100))
        XCTAssertEqual(peaks.count, 100)
        XCTAssertTrue(peaks.allSatisfy { $0 >= 0 && $0 <= 1 })
        // A steady tone fills every bucket; the loudest is normalised to 1.
        XCTAssertEqual(peaks.max()!, 1.0, accuracy: 0.001)
        XCTAssertGreaterThan(peaks.min()!, 0.5)
    }

    func testComputeWaveformPeaksReturnsNilForMissingFile() {
        XCTAssertNil(computeWaveformPeaks(url: URL(fileURLWithPath: "/no/such/sound.wav")))
    }

    // MARK: - helpers

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
