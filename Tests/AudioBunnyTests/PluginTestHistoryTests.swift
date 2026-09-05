import XCTest
@testable import AudioBunny

@MainActor
final class PluginTestHistoryTests: XCTestCase {
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

    private func plugin(
        name: String = "Serum", type: PluginType = .vst3, version: String? = "1.2.3"
    ) -> AudioPlugin {
        AudioPlugin(name: name, manufacturer: "M", type: type,
                    fileURL: URL(fileURLWithPath: "/tmp/\(name).\(type.fileExtension ?? "component")"),
                    version: version)
    }

    func testKeyIsNilWithoutAKnownVersion() {
        let manager = PluginManager(userDefaults: defaults)
        XCTAssertNil(manager.testHistoryKey(for: plugin(version: nil)))
    }

    func testKeyIncludesOSBuildTypeNameAndVersion() {
        let manager = PluginManager(userDefaults: defaults)
        let key = manager.testHistoryKey(for: plugin(name: "Serum", type: .vst3, version: "1.2.3"))
        // Scoped to the current macOS build so an OS update invalidates results.
        XCTAssertEqual(key, "\(currentOSBuild())|VST 3|serum|1.2.3")
        XCTAssertTrue(key!.hasSuffix("|VST 3|serum|1.2.3"))
        XCTAssertFalse(key!.hasPrefix("|"), "OS build prefix should not be empty")
    }

    func testResultsFromOtherOSBuildsAreDropped() {
        let manager = PluginManager(userDefaults: defaults)
        // A record left over from a previous macOS build.
        let staleKey = "OLDBUILD|VST 3|serum|1.2.3"
        let stale = ["OLDBUILD|VST 3|serum|1.2.3": PluginManager.TestHistoryRecord(statusKind: "active", failureMessage: nil)]
        defaults.set(try! JSONEncoder().encode(stale), forKey: "audiobunny.pluginTestHistory")

        let p = plugin(name: "Other", version: "9.9")
        p.status = .active
        manager.recordTestResult(for: p)

        XCTAssertNil(manager.loadTestHistory()[staleKey])
    }

    func testRecordingActiveResultPersists() {
        let manager = PluginManager(userDefaults: defaults)
        let p = plugin()
        p.status = .active

        manager.recordTestResult(for: p)

        let history = manager.loadTestHistory()
        XCTAssertEqual(history[manager.testHistoryKey(for: p)!]?.status, .active)
    }

    func testRecordingFailedResultPersistsMessage() {
        let manager = PluginManager(userDefaults: defaults)
        let p = plugin()
        p.status = .failed("Missing entry point")

        manager.recordTestResult(for: p)

        let history = manager.loadTestHistory()
        XCTAssertEqual(history[manager.testHistoryKey(for: p)!]?.status, .failed("Missing entry point"))
    }

    func testUntestedAndDisabledStatusesAreNotRecorded() {
        let manager = PluginManager(userDefaults: defaults)
        let untested = plugin(name: "A")
        let disabled = plugin(name: "B")
        disabled.status = .disabled

        manager.recordTestResult(for: untested)
        manager.recordTestResult(for: disabled)

        XCTAssertTrue(manager.loadTestHistory().isEmpty)
    }

    func testHistoryPersistsAcrossManagerInstances() {
        let first = PluginManager(userDefaults: defaults)
        let p = plugin(name: "Vital", version: "1.0")
        p.status = .active
        first.recordTestResult(for: p)

        // Simulate relaunch: a fresh PluginManager reading the same defaults.
        let second = PluginManager(userDefaults: defaults)
        let key = second.testHistoryKey(for: plugin(name: "Vital", version: "1.0"))!
        XCTAssertEqual(second.loadTestHistory()[key]?.status, .active)
    }

    func testDifferentVersionIsATreatedAsUntestedKey() {
        let manager = PluginManager(userDefaults: defaults)
        let old = plugin(name: "Vital", version: "1.0")
        old.status = .active
        manager.recordTestResult(for: old)

        let newVersionKey = manager.testHistoryKey(for: plugin(name: "Vital", version: "2.0"))!
        XCTAssertNil(manager.loadTestHistory()[newVersionKey])
    }
}
