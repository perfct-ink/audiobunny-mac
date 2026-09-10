import Foundation
import AVFoundation
import SwiftUI

// MARK: - Model

/// A waveform overview in the BBC `audiowaveform` sense: signed min/max sample
/// pairs, one pair per horizontal pixel. Held as 8-bit values (that's what the
/// on-disk cache stores — see `WaveformCache`); exposed as −1…1 floats for
/// drawing.
struct Waveform: Equatable {
    var sampleRate: Int
    var samplesPerPixel: Int
    /// Interleaved signed 8-bit min/max, two entries per pixel:
    /// `[min₀, max₀, min₁, max₁, …]`.
    var samples: [Int8]

    var pixelCount: Int { samples.count / 2 }

    /// The (min, max) for pixel `i`, each in −1…1.
    func minMax(at i: Int) -> (min: Float, max: Float) {
        (Float(samples[2 * i]) / 127, Float(samples[2 * i + 1]) / 127)
    }
}

// MARK: - Extraction

/// Reads `url` once in ~1M-frame chunks and reduces it to ≈`targetPixels`
/// min/max pairs — the data behind the waveform display, matching the BBC
/// `audiowaveform` tool's output. All channels are folded into one. Returns nil
/// if the file can't be opened. Honours `Task.isCancelled`.
func computeWaveform(url: URL, targetPixels: Int = 480) -> Waveform? {
    guard targetPixels > 0, let file = try? AVAudioFile(forReading: url) else { return nil }
    let format = file.processingFormat
    let totalFrames = file.length
    guard totalFrames > 0, format.channelCount > 0 else { return nil }

    let samplesPerPixel = max(1, Int(totalFrames) / targetPixels)
    let spp = AVAudioFramePosition(samplesPerPixel)
    let pixelCount = Int((totalFrames + spp - 1) / spp)
    guard pixelCount > 0 else { return nil }

    var mins = [Float](repeating: .greatestFiniteMagnitude, count: pixelCount)
    var maxs = [Float](repeating: -.greatestFiniteMagnitude, count: pixelCount)

    let chunkCapacity: AVAudioFrameCount = 1 << 20
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCapacity) else { return nil }
    var framesRead: AVAudioFramePosition = 0

    while framesRead < totalFrames {
        if Task.isCancelled { return nil }
        guard (try? file.read(into: buffer)) != nil,
              buffer.frameLength > 0,
              let channels = buffer.floatChannelData else { break }
        let n = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        for i in 0..<n {
            var lo: Float = .greatestFiniteMagnitude
            var hi: Float = -.greatestFiniteMagnitude
            for ch in 0..<channelCount {
                let v = channels[ch][i]
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
            let pixel = min(pixelCount - 1, Int((framesRead + AVAudioFramePosition(i)) / spp))
            if lo < mins[pixel] { mins[pixel] = lo }
            if hi > maxs[pixel] { maxs[pixel] = hi }
        }
        framesRead += AVAudioFramePosition(n)
    }

    var samples = [Int8](repeating: 0, count: pixelCount * 2)
    for p in 0..<pixelCount {
        samples[2 * p]     = int8Sample(mins[p])
        samples[2 * p + 1] = int8Sample(maxs[p])
    }
    return Waveform(sampleRate: Int(format.sampleRate),
                    samplesPerPixel: samplesPerPixel,
                    samples: samples)
}

/// −1…1 float → signed 8-bit, clamped to −127…127 (kept symmetric).
private func int8Sample(_ v: Float) -> Int8 {
    guard v.isFinite else { return 0 }
    return Int8(max(-127, min(127, (v * 127).rounded())))
}

// MARK: - View

struct WaveformView: View {
    let waveform: Waveform?
    /// Playback position 0…1, or nil to hide the playhead.
    var playhead: Double? = nil
    /// Called with a 0…1 position while the user scrubs across the waveform.
    var onScrub: ((Double) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Canvas { ctx, size in
                    guard let wf = waveform, wf.pixelCount > 0 else {
                        ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: size.height / 2))
                                          $0.addLine(to: CGPoint(x: size.width, y: size.height / 2)) },
                                   with: .color(.secondary.opacity(0.4)))
                        return
                    }
                    let mid = size.height / 2
                    let half = max(1, mid - 1)
                    let count = wf.pixelCount
                    let colWidth = size.width / CGFloat(count)
                    let playedX = (playhead.map { CGFloat($0) } ?? 0) * size.width
                    for p in 0..<count {
                        let (lo, hi) = wf.minMax(at: p)
                        let x = CGFloat(p) * colWidth
                        let top = mid - CGFloat(hi) * half
                        let bottom = mid - CGFloat(lo) * half
                        let rect = CGRect(x: x, y: min(top, bottom),
                                          width: max(0.75, colWidth - 0.5),
                                          height: max(1, abs(bottom - top)))
                        let played = playhead != nil && x < playedX
                        ctx.fill(Path(rect), with: .color(played ? .accentColor : .secondary.opacity(0.55)))
                    }
                }
                if let playhead {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 1.5)
                        .offset(x: CGFloat(playhead) * width - 0.75)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard width > 0 else { return }
                        onScrub?(Double(min(max(value.location.x, 0), width) / width))
                    }
            )
        }
    }
}
