import XCTest
@testable import AudioBunny

@MainActor
final class LiveProjectManagerPersistenceTests: XCTestCase {
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

    func testStartsEmptyWithNoSavedFolders() {
        let manager = LiveProjectManager(userDefaults: defaults, autoRescanOnLaunch: false)
        XCTAssertTrue(manager.folders.isEmpty)
    }

    func testAddFolderPersistsPath() {
        let manager = LiveProjectManager(userDefaults: defaults, autoRescanOnLaunch: false)
        let url = URL(fileURLWithPath: "/tmp/SomeLiveSetFolder")

        manager.addFolder(url)

        XCTAssertEqual(manager.folders.count, 1)
        XCTAssertEqual(manager.folders.first?.url.path, url.path)
        XCTAssertEqual(defaults.stringArray(forKey: "audiobunny.projectFolderPaths"), [url.path])
    }

    func testAddingSameFolderTwiceIsIgnored() {
        let manager = LiveProjectManager(userDefaults: defaults, autoRescanOnLaunch: false)
        let url = URL(fileURLWithPath: "/tmp/SomeLiveSetFolder")

        manager.addFolder(url)
        manager.addFolder(url)

        XCTAssertEqual(manager.folders.count, 1)
    }

    func testRestoresSavedFoldersOnRelaunch() {
        let first = LiveProjectManager(userDefaults: defaults, autoRescanOnLaunch: false)
        first.addFolder(URL(fileURLWithPath: "/tmp/ProjectsA"))
        first.addFolder(URL(fileURLWithPath: "/tmp/ProjectsB"))

        // Simulate relaunch: a fresh manager reading the same defaults.
        let second = LiveProjectManager(userDefaults: defaults, autoRescanOnLaunch: false)

        XCTAssertEqual(Set(second.folders.map(\.url.path)), ["/tmp/ProjectsA", "/tmp/ProjectsB"])
    }

    func testRemoveFolderPersists() {
        let manager = LiveProjectManager(userDefaults: defaults, autoRescanOnLaunch: false)
        let url = URL(fileURLWithPath: "/tmp/SomeLiveSetFolder")
        manager.addFolder(url)
        let id = manager.folders[0].id

        manager.removeFolder(id)

        XCTAssertTrue(manager.folders.isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: "audiobunny.projectFolderPaths"), [])
    }

    // MARK: - Backup-folder filtering

    func testIncludeBackupProjectsDefaultsOffAndPersists() {
        let first = LiveProjectManager(userDefaults: defaults, autoRescanOnLaunch: false)
        XCTAssertFalse(first.includeBackupProjects)

        first.includeBackupProjects = true

        let second = LiveProjectManager(userDefaults: defaults, autoRescanOnLaunch: false)
        XCTAssertTrue(second.includeBackupProjects)
    }

    func testIsBackupProjectURLMatchesOnlyBackupFolders() {
        let live = URL(fileURLWithPath: "/Music/Song Project/Song.als")
        let backup = URL(fileURLWithPath: "/Music/Song Project/Backup/Song [2024-01-02 120000].als")
        let nestedBackup = URL(fileURLWithPath: "/Music/Song Project/Backup/Older/Song.als")
        let lookalike = URL(fileURLWithPath: "/Music/Backups Archive/Song.als")

        XCTAssertFalse(isBackupProjectURL(live))
        XCTAssertTrue(isBackupProjectURL(backup))
        XCTAssertTrue(isBackupProjectURL(nestedBackup))
        XCTAssertFalse(isBackupProjectURL(lookalike))
    }

    // MARK: - Cloud placeholder detection

    func testOrdinaryLocalFileIsNotACloudPlaceholder() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioBunnyTest-\(UUID().uuidString).als")
        try Data("x".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertFalse(isCloudPlaceholder(tmp))
    }

    func testMissingFileIsNotACloudPlaceholder() {
        XCTAssertFalse(isCloudPlaceholder(URL(fileURLWithPath: "/no/such/file.als")))
    }
}
