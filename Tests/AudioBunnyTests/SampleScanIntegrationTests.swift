import XCTest
import AVFoundation
@testable import AudioBunny

@MainActor
final class SampleScanIntegrationTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "AudioBunnyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioBunnyScan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeTone(to: folder.appendingPathComponent("Trap Kick.wav"))
        try writeTone(to: folder.appendingPathComponent("Closed HiHat.wav"))
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
        try super.tearDownWithError()
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func testScanPopulatesSamplesAndAvailableTags() async {
        let m = SampleManager(userDefaults: defaults, autoRescanOnLaunch: false)
        m.addFolder(folder)

        await waitUntil { m.folders.first?.samples.count == 2 }
        XCTAssertEqual(m.folders.first?.samples.count, 2)

        // Auto-tag index is built from the filenames.
        XCTAssertEqual(Set(m.availableTags), ["Kick", "HiHat"])
    }

    func testScanHydratesManualTagsFromExistingFinderTags() async throws {
        // "Glitch" isn't derivable from either filename — simulates a tag set
        // by hand in Finder, or synced in from another Mac, before this scan.
        let kickURL = folder.appendingPathComponent("Trap Kick.wav")
        try (kickURL as NSURL).setResourceValue(["Glitch"], forKey: .tagNamesKey)

        let m = SampleManager(userDefaults: defaults, autoRescanOnLaunch: false)
        m.addFolder(folder)
        await waitUntil { m.folders.first?.samples.count == 2 }

        let sample = try XCTUnwrap(m.folders.first!.samples.first { $0.name == "Trap Kick" })
        XCTAssertEqual(Set(m.tags(for: sample)), ["Kick", "Glitch"])
    }

    func testScanWritesAutoTagsBackToFinderTags() async throws {
        let kickURL = folder.appendingPathComponent("Trap Kick.wav")
        let m = SampleManager(userDefaults: defaults, autoRescanOnLaunch: false)
        m.addFolder(folder)
        await waitUntil { m.folders.first?.samples.count == 2 }

        await waitUntil(5) { vocabularyFinderTags(at: kickURL).contains("Kick") }
        XCTAssertEqual(vocabularyFinderTags(at: kickURL), ["Kick"])
    }

    func testToggleTagWritesThroughToFinderTags() async throws {
        let hihatURL = folder.appendingPathComponent("Closed HiHat.wav")
        let m = SampleManager(userDefaults: defaults, autoRescanOnLaunch: false)
        m.addFolder(folder)
        await waitUntil { m.folders.first?.samples.count == 2 }
        let sample = try XCTUnwrap(m.folders.first!.samples.first { $0.name == "Closed HiHat" })

        m.toggleTag("Glitch", for: sample)

        await waitUntil(5) { vocabularyFinderTags(at: hihatURL).contains("Glitch") }
        XCTAssertEqual(vocabularyFinderTags(at: hihatURL), ["Glitch", "HiHat"])
    }

    func testPrewarmFillsWaveformsInTheBackground() async {
        let m = SampleManager(userDefaults: defaults, autoRescanOnLaunch: false)
        m.addFolder(folder)
        await waitUntil { m.folders.first?.samples.count == 2 }

        let sample = m.folders.first!.samples.first!
        await waitUntil(8) { m.waveform(for: sample) != nil }
        XCTAssertNotNil(m.waveform(for: sample), "background pre-warm should produce a waveform")
    }

    private func writeTone(to url: URL) throws {
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(0.3 * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let ch = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = 0.5 * sinf(2 * .pi * 220 * Float(i) / Float(sampleRate))
        }
        try file.write(from: buffer)
    }
}
