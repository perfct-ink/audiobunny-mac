import XCTest
@testable import AudioBunny

final class PresetFolderLocatorTests: XCTestCase {
    private var home: URL!

    override func setUp() {
        super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioBunnyLocatorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        home = nil
        super.tearDown()
    }

    private func makeDir(_ relative: String) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func paths(_ urls: [URL]) -> [String] {
        urls.map { $0.standardizedFileURL.path }
    }

    func testFindsKnownSerumLayout() throws {
        let presets = try makeDir("Documents/Xfer/Serum Presets/Presets")
        XCTAssertEqual(paths(locatePluginFolders(pluginName: "Serum", manufacturer: "Xfer Records", home: home)),
                       paths([presets]))
    }

    func testFindsNativeInstrumentsProductFolderByName() throws {
        let kontakt = try makeDir("Documents/Native Instruments/Kontakt 7")
        XCTAssertEqual(paths(locatePluginFolders(pluginName: "Kontakt 7", manufacturer: "Native Instruments", home: home)),
                       paths([kontakt]))
    }

    func testFindsUnknownPluginFolderByName() throws {
        let presets = try makeDir("Documents/Pro-Q 3 Presets")
        _ = try makeDir("Documents/Something Else")
        XCTAssertEqual(paths(locatePluginFolders(pluginName: "Pro-Q 3", manufacturer: "FabFilter", home: home)),
                       paths([presets]))
    }

    func testFindsPluginFolderUnderManufacturerFolder() throws {
        let presets = try makeDir("Music/FabFilter/Pro-Q 3")
        XCTAssertEqual(paths(locatePluginFolders(pluginName: "Pro-Q 3", manufacturer: "FabFilter", home: home)),
                       paths([presets]))
    }

    func testSkipsConflictedCopies() throws {
        _ = try makeDir("Documents/Pro-Q 3 (conflicted copy 2019)")
        XCTAssertTrue(locatePluginFolders(pluginName: "Pro-Q 3", manufacturer: "FabFilter", home: home).isEmpty)
    }

    func testIgnoresNamesTooShortToMatchSafely() throws {
        _ = try makeDir("Documents/OTTER stuff")
        XCTAssertTrue(locatePluginFolders(pluginName: "O", manufacturer: "X", home: home).isEmpty)
    }

    func testRemoteNameStripsSlashes() {
        let target = SyncTarget(owner: "A/B", localURL: home.appendingPathComponent("x/Presets"))
        XCTAssertEqual(target.remoteName, "A-B — Presets")
    }

    func testAbletonUserLibraryFoldersExcludeProjectInfo() throws {
        let presets = try makeDir("Music/Ableton/User Library/Presets")
        let samples = try makeDir("Music/Ableton/User Library/Samples")
        _ = try makeDir("Music/Ableton/User Library/Ableton Project Info")
        XCTAssertEqual(paths(abletonUserLibraryFolders(home: home)), paths([presets, samples]))
    }

    func testSyncTargetsGroupsByPluginWithManualFolders() throws {
        let serum = try makeDir("Documents/Xfer/Serum Presets/Presets")
        let manual = try makeDir("Somewhere/Serum Extra")
        let targets = syncTargets(plugins: [(name: "Serum", manufacturer: "Xfer"),
                                            (name: "serum", manufacturer: "Xfer")],
                                  manualFolders: ["Serum": [manual]],
                                  home: home)
        let foundPaths: Set<String> = Set(targets.map { $0.localURL.standardizedFileURL.path })
        let expectedPaths: Set<String> = [serum.standardizedFileURL.path, manual.standardizedFileURL.path]
        XCTAssertEqual(Set(targets.map(\.owner)), ["Serum"])
        XCTAssertEqual(foundPaths, expectedPaths)
    }

    func testSyncTargetRemoteNameIsOwnerAndLabel() {
        let target = SyncTarget(owner: "Ableton Live", localURL: home.appendingPathComponent("Music/Ableton/User Library/Presets"))
        XCTAssertEqual(target.remoteName, "Ableton Live — Presets")
    }

}

final class PresetSyncPureLogicTests: XCTestCase {

    func testIsSafeSyncDirectoryRejectsOutsideOrEqualToHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertFalse(isSafeSyncDirectory(home))
        XCTAssertFalse(isSafeSyncDirectory(URL(fileURLWithPath: "/tmp/whatever")))
        XCTAssertFalse(isSafeSyncDirectory(URL(fileURLWithPath: "/")))
        XCTAssertTrue(isSafeSyncDirectory(home.appendingPathComponent("Library/Audio/Presets/X/Y")))
    }
}

/// Exercises the real filesystem operations, scoped to unique, disposable
/// directories under the real home folder — `isSafeSyncDirectory` refuses
/// anything outside it by design, so that's what a real caller (and this test)
/// must use.
final class PresetSyncFileOperationTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AudioBunnyTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    private func write(_ text: String, to url: URL, modified: Date? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    private func contents(of url: URL) throws -> String {
        String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
    }

    func testLinkMovesLocalContentIntoRemoteAndSymlinks() throws {
        let local = root.appendingPathComponent("local")
        let remote = root.appendingPathComponent("remote")
        try write("bass patch", to: local.appendingPathComponent("Bass.fxp"))

        try linkPresetDirectory(local: local, toSynced: remote)

        let attrs = try FileManager.default.attributesOfItem(atPath: local.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(try contents(of: local.appendingPathComponent("Bass.fxp")), "bass patch")
        XCTAssertEqual(try contents(of: remote.appendingPathComponent("Bass.fxp")), "bass patch")

        // The original folder is preserved as a backup, not deleted.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(siblings.contains { $0.hasPrefix("local (pre-sync backup") })
    }

    func testLinkWithNoExistingLocalFolderJustSymlinks() throws {
        let local = root.appendingPathComponent("local")
        let remote = root.appendingPathComponent("remote")

        try linkPresetDirectory(local: local, toSynced: remote)

        let attrs = try FileManager.default.attributesOfItem(atPath: local.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertTrue(FileManager.default.fileExists(atPath: remote.path))
    }

    func testLinkMergesAndNewerFileWins() throws {
        let local = root.appendingPathComponent("local")
        let remote = root.appendingPathComponent("remote")
        let old = Date(timeIntervalSinceNow: -3600)
        let new = Date()

        try write("remote-only", to: remote.appendingPathComponent("Pad.fxp"))
        try write("old version", to: remote.appendingPathComponent("Lead.fxp"), modified: old)
        try write("new version", to: local.appendingPathComponent("Lead.fxp"), modified: new)

        try linkPresetDirectory(local: local, toSynced: remote)

        XCTAssertEqual(try contents(of: remote.appendingPathComponent("Pad.fxp")), "remote-only")
        XCTAssertEqual(try contents(of: remote.appendingPathComponent("Lead.fxp")), "new version")
    }

    func testLinkIsIdempotentWhenAlreadyLinkedCorrectly() throws {
        let local = root.appendingPathComponent("local")
        let remote = root.appendingPathComponent("remote")
        try linkPresetDirectory(local: local, toSynced: remote)

        XCTAssertNoThrow(try linkPresetDirectory(local: local, toSynced: remote))
    }

    func testLinkThrowsWhenAlreadyLinkedElsewhere() throws {
        let local = root.appendingPathComponent("local")
        let remoteA = root.appendingPathComponent("remoteA")
        let remoteB = root.appendingPathComponent("remoteB")
        try linkPresetDirectory(local: local, toSynced: remoteA)

        XCTAssertThrowsError(try linkPresetDirectory(local: local, toSynced: remoteB)) { error in
            guard case PresetSyncError.alreadyLinkedElsewhere = error else {
                return XCTFail("expected alreadyLinkedElsewhere, got \(error)")
            }
        }
    }

    func testLinkRejectsPathsOutsideHome() {
        let outside = URL(fileURLWithPath: "/tmp/AudioBunnyTests-\(UUID().uuidString)")
        XCTAssertThrowsError(try linkPresetDirectory(local: outside, toSynced: root.appendingPathComponent("remote"))) { error in
            XCTAssertEqual(error as? PresetSyncError, .unsafePath)
        }
    }

    func testUnlinkRestoresRealFolderFromRemote() throws {
        let local = root.appendingPathComponent("local")
        let remote = root.appendingPathComponent("remote")
        try write("kick", to: local.appendingPathComponent("Kick.fxp"))
        try linkPresetDirectory(local: local, toSynced: remote)

        try unlinkPresetDirectory(local: local)

        let attrs = try FileManager.default.attributesOfItem(atPath: local.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeDirectory)
        XCTAssertEqual(try contents(of: local.appendingPathComponent("Kick.fxp")), "kick")
        // The remote copy is untouched.
        XCTAssertEqual(try contents(of: remote.appendingPathComponent("Kick.fxp")), "kick")
    }

    func testUnlinkThrowsWhenNotCurrentlyLinked() throws {
        let local = root.appendingPathComponent("local")
        try write("x", to: local.appendingPathComponent("f.fxp"))

        XCTAssertThrowsError(try unlinkPresetDirectory(local: local)) { error in
            XCTAssertEqual(error as? PresetSyncError, .notLinked)
        }
    }
}

@MainActor
final class PresetSyncManagerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var syncFolder: URL!

    override func setUp() {
        super.setUp()
        suiteName = "AudioBunnyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        syncFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AudioBunnyTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: syncFolder)
        defaults = nil
        super.tearDown()
    }

    func testStatusIsNoSyncFolderUntilOneIsChosen() {
        let manager = PresetSyncManager(userDefaults: defaults)
        let target = SyncTarget(owner: "FabFilter Pro-Q 3", localURL: syncFolder.appendingPathComponent("Local/Presets"))
        XCTAssertEqual(manager.status(for: target), .noSyncFolder)
    }

    func testChooseSyncFolderPersists() {
        let first = PresetSyncManager(userDefaults: defaults)
        first.chooseSyncFolder(syncFolder)

        let second = PresetSyncManager(userDefaults: defaults)
        XCTAssertEqual(second.syncFolderURL?.path, syncFolder.path)
    }

    func testEnableSyncLinksAndStatusReportsSynced() async throws {
        let manager = PresetSyncManager(userDefaults: defaults)
        manager.chooseSyncFolder(syncFolder)
        let local = syncFolder.appendingPathComponent("Local/TestSynth-\(UUID().uuidString)")
        let target = SyncTarget(owner: "TestSynth", localURL: local)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)

        await manager.enableSync(for: target)

        XCTAssertNil(manager.lastError)
        XCTAssertEqual(manager.status(for: target), .synced)

        await manager.disableSync(for: target)
        XCTAssertEqual(manager.status(for: target), .notSynced)
    }

    func testManualFoldersPersistAcrossInstances() {
        let first = PresetSyncManager(userDefaults: defaults)
        let folder = syncFolder.appendingPathComponent("ManualPresets")
        first.addManualFolder(folder, owner: "Pro-Q 3")
        first.addManualFolder(folder, owner: "Pro-Q 3")

        let second = PresetSyncManager(userDefaults: defaults)
        XCTAssertEqual(second.manualFolderURLs["Pro-Q 3"]?.map(\.path), [folder.path])
    }
}
