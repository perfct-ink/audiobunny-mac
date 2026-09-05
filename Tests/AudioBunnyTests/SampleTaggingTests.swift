import XCTest
@testable import AudioBunny

final class SampleTaggingTests: XCTestCase {

    // MARK: autoTags

    func testTagFromFilename() {
        XCTAssertEqual(autoTags(forFileName: "Trap_Kick_01", parentFolderName: "Oneshots"), ["Kick"])
    }

    func testTagFromParentFolder() {
        XCTAssertEqual(autoTags(forFileName: "SP1200_17", parentFolderName: "Snare"), ["Snare"])
    }

    func testSeparatorAndCaseInsensitiveMatch() {
        XCTAssertTrue(autoTags(forFileName: "closed-HI_HAT-loop", parentFolderName: "x").contains("HiHat"))
    }

    func testAliasesMapToCanonicalTags() {
        XCTAssertTrue(autoTags(forFileName: "lead vox dry", parentFolderName: "x").contains("Vocal"))
        XCTAssertTrue(autoTags(forFileName: "perc_fill", parentFolderName: "x").contains("Percussion"))
    }

    func testMultipleTags() {
        let tags = autoTags(forFileName: "Bass Stab C#", parentFolderName: "Synth")
        XCTAssertEqual(tags, ["Bass", "Stabs", "Synth"])
    }

    func testNoFalsePositiveFromSubstring() {
        // "brass" must not trip "Bass" / "Ride" must not trip on "pride" etc.
        XCTAssertFalse(autoTags(forFileName: "pride_anthem", parentFolderName: "x").contains("Ride"))
        XCTAssertEqual(autoTags(forFileName: "Brass Section", parentFolderName: "x"), ["Brass"])
    }

    // MARK: formatSampleDuration

    func testDurationFormatting() {
        XCTAssertEqual(formatSampleDuration(0.8), "0.8s")
        XCTAssertEqual(formatSampleDuration(4.28), "4.3s")
        XCTAssertEqual(formatSampleDuration(12), "0:12")
        XCTAssertEqual(formatSampleDuration(95), "1:35")
        XCTAssertEqual(formatSampleDuration(-1), "—")
    }
}

@MainActor
final class SampleManagerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

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

    private func manager(withSamples names: [String]) -> SampleManager {
        let m = SampleManager(userDefaults: defaults, autoRescanOnLaunch: false)
        let samples = names.map { SoundFile(url: URL(fileURLWithPath: "/lib/Pack/\($0).wav")) }
        m.folders = [SampleFolder(url: URL(fileURLWithPath: "/lib/Pack"), samples: samples)]
        return m
    }

    func testSelectNextAndPreviousClampAtEnds() {
        let m = manager(withSamples: ["a", "b", "c"])
        let ids = m.folders[0].samples.map(\.id)

        m.selectPrevious()                       // nothing selected → first
        XCTAssertEqual(m.selectedID, ids[0])
        m.selectNext(); m.selectNext()
        XCTAssertEqual(m.selectedID, ids[2])
        m.selectNext()                           // clamped at the end
        XCTAssertEqual(m.selectedID, ids[2])
        m.selectPrevious()
        XCTAssertEqual(m.selectedID, ids[1])
    }

    func testTagFilterMatchesAllActiveTags() {
        let m = manager(withSamples: ["Kick 808", "Snare tight", "Kick + Bass loop"])
        XCTAssertEqual(m.visibleSamples(in: m.folders[0]).count, 3)

        m.toggleTagFilter("Kick")
        XCTAssertEqual(Set(m.visibleSamples(in: m.folders[0]).map(\.name)), ["Kick 808", "Kick + Bass loop"])

        m.toggleTagFilter("Bass")               // AND: must have Kick *and* Bass
        XCTAssertEqual(m.visibleSamples(in: m.folders[0]).map(\.name), ["Kick + Bass loop"])
    }

    func testManualTagsPersistAndAugmentAutoTags() {
        let m = manager(withSamples: ["mystery_01"])
        let sample = m.folders[0].samples[0]
        XCTAssertTrue(m.tags(for: sample).isEmpty)

        m.toggleTag("Glitch", for: sample)
        XCTAssertEqual(m.tags(for: sample), ["Glitch"])

        // Reload from the same defaults — the manual tag survives.
        let reloaded = SampleManager(userDefaults: defaults, autoRescanOnLaunch: false)
        reloaded.folders = m.folders
        XCTAssertEqual(reloaded.tags(for: sample), ["Glitch"])
    }

    func testAutoTagsCannotBeToggledOff() {
        let m = manager(withSamples: ["Big Kick"])
        let sample = m.folders[0].samples[0]
        XCTAssertEqual(m.tags(for: sample), ["Kick"])

        m.toggleTag("Kick", for: sample)        // no-op-ish: auto tag stays
        XCTAssertEqual(m.tags(for: sample), ["Kick"])
    }

    func testLoopFlagAppliesToFuturePlayback() {
        let m = manager(withSamples: ["a"])
        XCTAssertFalse(m.isLooping)
        m.isLooping = true
        XCTAssertTrue(m.isLooping)               // didSet on the player is a no-op with no player
    }
}
