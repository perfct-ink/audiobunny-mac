import Foundation
import AVFoundation
import SwiftUI

// MARK: - Peak extraction (pure enough to unit-test the maths)

/// Peak magnitude (0...1) for each horizontal bucket of a sample's waveform.
/// Reads the whole file once in ~1M-frame chunks, so memory stays flat even for
/// long files. Returns nil if the file can't be opened.
func computeWaveformPeaks(url: URL, buckets: Int = 480) -> [Float]? {
    guard buckets > 0, let file = try? AVAudioFile(forReading: url) else { return nil }
    let format = file.processingFormat
    let totalFrames = file.length
    guard totalFrames > 0, format.channelCount > 0 else { return nil }

    let chunkCapacity: AVAudioFrameCount = 1 << 20
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCapacity) else { return nil }

    var peaks = [Float](repeating: 0, count: buckets)
    var framesRead: AVAudioFramePosition = 0

    while framesRead < totalFrames {
        guard (try? file.read(into: buffer)) != nil,
              buffer.frameLength > 0,
              let channels = buffer.floatChannelData else { break }
        let n = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        for i in 0..<n {
            var mag: Float = 0
            for ch in 0..<channelCount { mag = max(mag, abs(channels[ch][i])) }
            let frame = framesRead + AVAudioFramePosition(i)
            let bucket = min(buckets - 1, Int(frame * AVAudioFramePosition(buckets) / totalFrames))
            if mag > peaks[bucket] { peaks[bucket] = mag }
        }
        framesRead += AVAudioFramePosition(n)
    }
    return normalizeWaveformPeaks(peaks)
}

/// Scales peaks so the loudest bucket sits at 1.0. All-silent input is returned
/// unchanged (all zeros) rather than divided by zero.
func normalizeWaveformPeaks(_ peaks: [Float]) -> [Float] {
    guard let loudest = peaks.max(), loudest > 0 else { return peaks }
    return peaks.map { min(1, $0 / loudest) }
}

// MARK: - Waveform view

struct WaveformView: View {
    /// Normalised peaks (0...1). Empty renders a flat baseline.
    let peaks: [Float]
    /// Playback position 0...1, or nil to hide the playhead.
    var playhead: Double? = nil
    /// Called with a 0...1 position while the user scrubs across the waveform.
    var onScrub: ((Double) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Canvas { ctx, size in
                    guard !peaks.isEmpty else {
                        ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: size.height / 2))
                                          $0.addLine(to: CGPoint(x: size.width, y: size.height / 2)) },
                                   with: .color(.secondary.opacity(0.4)))
                        return
                    }
                    let mid = size.height / 2
                    let barWidth = size.width / CGFloat(peaks.count)
                    let playedX = (playhead.map { CGFloat($0) } ?? 0) * size.width
                    for (i, p) in peaks.enumerated() {
                        let x = CGFloat(i) * barWidth
                        let barHeight = max(1, CGFloat(p) * (size.height - 2))
                        let rect = CGRect(x: x, y: mid - barHeight / 2,
                                          width: max(0.75, barWidth - 0.75), height: barHeight)
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
                    .onChanged { v in
                        guard width > 0 else { return }
                        onScrub?(Double(min(max(v.location.x, 0), width) / width))
                    }
            )
        }
    }
}
