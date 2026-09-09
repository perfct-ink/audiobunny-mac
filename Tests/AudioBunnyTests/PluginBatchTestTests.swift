import XCTest
@testable import AudioBunny

@MainActor
final class PluginBatchTestTests: XCTestCase {
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "AudioBunnyTests.\(UUID().uuidString)"
    }
    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func vst3(_ name: String) -> AudioPlugin {
        AudioPlugin(name: name, manufacturer: "M", type: .vst3,
                    fileURL: URL(fileURLWithPath: "/no/such/\(name).vst3"),
                    version: "1.0")
    }

    func testTestAllWithNoUntestedPluginsNeverStartsProgress() async {
        let manager = PluginManager(userDefaults: UserDefaults(suiteName: suiteName)!)
        let done = vst3("Already")
        done.status = .active
        manager.plugins = [done]

        manager.testAllUntested()
        await manager.batchTestTask?.value

        XCTAssertNil(manager.batchTestProgress)
        XCTAssertFalse(manager.isTestingAll)
        XCTAssertEqual(done.status, .active) // untouched
    }

    func testTestAllRunsEveryUntestedPluginAndClearsProgress() async {
        let manager = PluginManager(userDefaults: UserDefaults(suiteName: suiteName)!)
        let plugins = (1...5).map { vst3("P\($0)") }
        manager.plugins = plugins

        manager.testAllUntested()
        await manager.batchTestTask?.value

        XCTAssertNil(manager.batchTestProgress, "progress should clear when the run ends")
        XCTAssertFalse(manager.isTestingAll)
        // Every plugin was tested (fake paths → File not found, but no longer untested).
        for plugin in plugins {
            XCTAssertEqual(plugin.status, .failed("File not found"))
        }
    }

    func testTestAllIgnoredWhileAlreadyRunning() async {
        let manager = PluginManager(userDefaults: UserDefaults(suiteName: suiteName)!)
        manager.plugins = (1...20).map { vst3("Q\($0)") }

        manager.testAllUntested()
        let firstTask = manager.batchTestTask
        manager.testAllUntested() // must be a no-op, not a second concurrent run
        XCTAssertTrue(firstTask == manager.batchTestTask, "second call must not replace the running task")

        await manager.batchTestTask?.value
        XCTAssertNil(manager.batchTestProgress)
    }

    func testCancelBatchTestStopsEarly() async {
        let manager = PluginManager(userDefaults: UserDefaults(suiteName: suiteName)!)
        manager.plugins = (1...50).map { vst3("R\($0)") }

        manager.testAllUntested()
        manager.cancelBatchTest()
        await manager.batchTestTask?.value

        XCTAssertNil(manager.batchTestProgress)
        let stillUntested = manager.plugins.filter { $0.status == .untested }.count
        XCTAssertGreaterThan(stillUntested, 0, "cancelling should leave some plugins untested")
    }
}
