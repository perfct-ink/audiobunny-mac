import XCTest
@testable import AudioBunny

/// A timed-out validation is inconclusive, not a verdict — it must never be
/// treated the same as a genuine failure.
@MainActor
final class PluginTimeoutStatusTests: XCTestCase {
    private var suiteName = ""
    private var manager: PluginManager!

    override func setUp() {
        super.setUp()
        suiteName = "AudioBunnyTests.\(UUID().uuidString)"
        manager = PluginManager(userDefaults: UserDefaults(suiteName: suiteName)!)
    }
    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        manager = nil
        super.tearDown()
    }

    private func plugin(_ name: String, status: PluginStatus) -> AudioPlugin {
        let p = AudioPlugin(name: name, manufacturer: "M", type: .vst3,
                            fileURL: URL(fileURLWithPath: "/no/such/\(name).vst3"),
                            version: "1.0")
        p.status = status
        return p
    }

    func testTimedOutStatusIsNotEqualToFailed() {
        XCTAssertNotEqual(PluginStatus.timedOut, .failed("Timed out"))
        XCTAssertEqual(PluginStatus.timedOut, .timedOut)
    }

    func testPluginCountsSeparatesTimedOutFromFailed() {
        manager.plugins = [
            plugin("A", status: .failed("boom")),
            plugin("B", status: .timedOut),
            plugin("C", status: .timedOut),
        ]
        let counts = manager.pluginCounts
        XCTAssertEqual(counts.failed, 1)
        XCTAssertEqual(counts.timedOut, 2)
        XCTAssertEqual(counts.total, 3)
    }

    func testFailedStatusFilterExcludesTimedOutPlugins() {
        manager.plugins = [plugin("A", status: .failed("boom")), plugin("B", status: .timedOut)]
        manager.filterStatus = .failed
        XCTAssertEqual(manager.filteredPlugins.map(\.name), ["A"])
    }

    func testTimedOutStatusFilterMatchesOnlyTimedOutPlugins() {
        manager.plugins = [plugin("A", status: .failed("boom")), plugin("B", status: .timedOut)]
        manager.filterStatus = .timedOut
        XCTAssertEqual(manager.filteredPlugins.map(\.name), ["B"])
    }

    func testDisableAllFailingNeverTouchesTimedOutPlugins() async {
        let timedOut = plugin("B", status: .timedOut)
        manager.plugins = [plugin("A", status: .failed("boom")), timedOut]

        manager.disableAllFailing()
        // The (fake, nonexistent-file) failed plugin's disable attempt runs and
        // resolves quickly; give it a moment, then confirm the timed-out one was
        // never even considered.
        for _ in 0..<20 where timedOut.status == .timedOut {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(timedOut.status, .timedOut, "disableAllFailing must not act on a timed-out plugin")
    }

    func testTestAllRetriesTimedOutPluginsButLeavesOthersAlone() async {
        let timedOut = plugin("TimedOut", status: .timedOut)
        let active = plugin("Active", status: .active)
        let failed = plugin("Failed", status: .failed("boom"))
        manager.plugins = [timedOut, active, failed]

        manager.testAllUntested()
        await manager.batchTestTask?.value

        XCTAssertNotEqual(timedOut.status, .timedOut, "a timed-out plugin should be retried by Test All")
        XCTAssertEqual(active.status, .active, "Test All must not re-test an already-active plugin")
        XCTAssertEqual(failed.status, .failed("boom"), "Test All must not re-test an already-failed plugin")
    }

    func testTimedOutResultIsNeverPersistedToTestHistory() {
        let p = plugin("Flaky", status: .timedOut)
        manager.recordTestResult(for: p)
        let key = manager.testHistoryKey(for: p)!
        XCTAssertNil(manager.loadTestHistory()[key], "a timeout must not be remembered as a verdict across launches")
    }
}
