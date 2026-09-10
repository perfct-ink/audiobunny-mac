import XCTest
@testable import AudioBunny

/// Note: these avoid actually starting `AVAudioPlayer` — in a headless test
/// process audio-output init blocks for ~15s. They cover the selection-side
/// behaviour of `play`/`togglePlay`, which happens before any player is touched;
/// real playback is verified by hand.
@MainActor
final class SamplePlaybackTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "AudioBunnyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }
    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func manager(_ names: [String]) -> SampleManager {
        let m = SampleManager(userDefaults: defaults, autoRescanOnLaunch: false)
        m.folders = [SampleFolder(url: URL(fileURLWithPath: "/pack"),
                                  samples: names.map { SoundFile(url: URL(fileURLWithPath: "/pack/\($0).wav")) })]
        return m
    }

    func testSampleLookupByID() {
        let m = manager(["a", "b"])
        let second = m.folders[0].samples[1]
        XCTAssertEqual(m.sample(withID: second.id)?.url, second.url)
        XCTAssertNil(m.sample(withID: nil))
        XCTAssertNil(m.sample(withID: UUID()))
    }

    func testPlaySelectsTheSample() {
        let m = manager(["a", "b"])
        let b = m.folders[0].samples[1]

        m.play(b)   // file can't actually play, but selection happens first

        XCTAssertEqual(m.selectedID, b.id)
    }

    func testTogglePlayOnAnUnplayedSampleSelectsIt() {
        let m = manager(["a", "b"])
        let a = m.folders[0].samples[0]

        m.togglePlay(a)

        XCTAssertEqual(m.selectedID, a.id)
    }

    func testPlayMarksTheSampleAsHeard() {
        let m = manager(["a", "b"])
        let a = m.folders[0].samples[0]
        let b = m.folders[0].samples[1]

        XCTAssertFalse(m.hasPlayed(a))
        m.play(a)
        XCTAssertTrue(m.hasPlayed(a))
        XCTAssertFalse(m.hasPlayed(b))
    }
}
