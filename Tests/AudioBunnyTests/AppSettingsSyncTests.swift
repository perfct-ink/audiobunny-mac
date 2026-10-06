import XCTest
@testable import AudioBunny

/// Runs under a disposable fake "home" inside the real home folder —
/// `isSafeSyncDirectory` refuses anything outside the real one by design.
final class AppSettingsSyncTests: XCTestCase {
    private var home: URL!
    private var syncRoot: URL!

    override func setUp() {
        super.setUp()
        home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AudioBunnyTests-\(UUID().uuidString)")
        syncRoot = home.appendingPathComponent("CloudRoot/AudioBunny/App Settings")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        home = nil
        syncRoot = nil
        super.tearDown()
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func contents(of url: URL) throws -> String {
        String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
    }

    private func isSymlink(_ url: URL) throws -> Bool {
        try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeSymbolicLink
    }

    // MARK: Providers

    func testICloudDriveDetectedOnlyWhenItsFolderExists() throws {
        XCTAssertNil(CloudSyncProvider.iCloudDrive.rootFolder(home: home))
        let docs = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        XCTAssertEqual(CloudSyncProvider.iCloudDrive.rootFolder(home: home)?.path, docs.path)
    }

    func testDropboxPrefersPathFromInfoJSON() throws {
        let custom = home.appendingPathComponent("Elsewhere/My Dropbox")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Dropbox"), withIntermediateDirectories: true)
        try write(#"{"personal": {"path": "\#(custom.path)"}}"#, to: home.appendingPathComponent(".dropbox/info.json"))

        XCTAssertEqual(CloudSyncProvider.dropbox.rootFolder(home: home)?.path, custom.path)
    }

    func testDropboxFallsBackToCloudStorageThenLegacyFolder() throws {
        XCTAssertNil(CloudSyncProvider.dropbox.rootFolder(home: home))

        let legacy = home.appendingPathComponent("Dropbox")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        XCTAssertEqual(CloudSyncProvider.dropbox.rootFolder(home: home)?.path, legacy.path)

        let fileProvider = home.appendingPathComponent("Library/CloudStorage/Dropbox")
        try FileManager.default.createDirectory(at: fileProvider, withIntermediateDirectories: true)
        XCTAssertEqual(CloudSyncProvider.dropbox.rootFolder(home: home)?.path, fileProvider.path)
    }

    // MARK: Validation

    func testValidationRejectsUnsyncablePaths() {
        func error(_ relative: String) -> AppSettingsSyncError? {
            do {
                try validateAppSettingsPath(home.appendingPathComponent(relative), syncRoot: syncRoot, home: home)
                return nil
            } catch {
                return error as? AppSettingsSyncError
            }
        }
        XCTAssertEqual(error("Library"), .tooBroad)
        XCTAssertEqual(error("Documents"), .tooBroad)
        XCTAssertEqual(error("Library/Preferences/com.ableton.live.plist"), .managedByMacOS)
        XCTAssertEqual(error("Library/Containers/com.example.app/Data"), .managedByMacOS)
        XCTAssertEqual(error("Library/Mobile Documents/com~apple~CloudDocs/x"), .insideCloudFolder)
        XCTAssertEqual(error("CloudRoot"), .overlapsSyncFolder)
        XCTAssertNil(error("Library/Application Support/REAPER"))
        XCTAssertNil(error("Library/Preferences/Ableton"))

        XCTAssertThrowsError(try validateAppSettingsPath(URL(fileURLWithPath: "/tmp/x"), syncRoot: syncRoot, home: home)) {
            XCTAssertEqual($0 as? AppSettingsSyncError, .unsafePath)
        }
    }

    // MARK: Discovery

    func testVendorFolderMatchingIgnoresCorporateNoise() {
        XCTAssertTrue(vendorFolderMatches(folderName: "Xfer", manufacturer: "Xfer Records"))
        XCTAssertTrue(vendorFolderMatches(folderName: "Native Instruments", manufacturer: "Native Instruments GmbH"))
        XCTAssertTrue(vendorFolderMatches(folderName: "u-he", manufacturer: "u-he"))
        XCTAssertTrue(vendorFolderMatches(folderName: "Spitfire Audio", manufacturer: "Spitfire"))
        XCTAssertFalse(vendorFolderMatches(folderName: "Apple", manufacturer: "Apple"))
        XCTAssertFalse(vendorFolderMatches(folderName: "Audio", manufacturer: "Audio Inc"))
        XCTAssertFalse(vendorFolderMatches(folderName: "FabFilter", manufacturer: "Xfer Records"))
    }

    func testDiscoveryFindsInstalledAppsAndPluginVendorsOnly() throws {
        let fm = FileManager.default
        for path in ["Music/Ableton/User Library", "Library/Application Support/FabFilter",
                     "Library/Application Support/Some Other App", "Documents/Xfer",
                     "Library/Preferences/Cubase 13"] {
            try fm.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        // Synced from another Mac, nothing local yet.
        try fm.createDirectory(at: syncRoot.appendingPathComponent("Documents/Bitwig Studio"),
                               withIntermediateDirectories: true)

        let items = discoverAppSettingsItems(home: home, syncRoot: syncRoot,
                                             pluginManufacturers: ["FabFilter", "Xfer Records", "FabFilter"])
        let ids = items.map(\.relativePath)

        XCTAssertTrue(ids.contains("Music/Ableton/User Library"))
        XCTAssertTrue(ids.contains("Documents/Bitwig Studio"))
        XCTAssertTrue(ids.contains("Library/Preferences/Cubase 13"))
        XCTAssertTrue(ids.contains("Library/Application Support/FabFilter"))
        XCTAssertTrue(ids.contains("Documents/Xfer"))
        XCTAssertFalse(ids.contains("Library/Application Support/Some Other App"))
        XCTAssertFalse(ids.contains("Library/Application Support/REAPER"))
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(items.first { $0.relativePath == "Documents/Xfer" }?.source, .pluginVendor)
    }

    // MARK: Link / unlink

    func testFirstMacMovesFolderIntoSyncFolderAndLinksBack() throws {
        let item = AppSettingsItem.custom(relativePath: "Library/Application Support/REAPER")
        let local = item.localURL(home: home)
        let remote = item.remoteURL(syncRoot: syncRoot)
        try write("[reaper]", to: local.appendingPathComponent("reaper.ini"))

        try linkAppSettings(local: local, toSynced: remote, syncRoot: syncRoot, home: home)

        XCTAssertTrue(try isSymlink(local))
        XCTAssertEqual(try contents(of: local.appendingPathComponent("reaper.ini")), "[reaper]")
        XCTAssertEqual(try contents(of: remote.appendingPathComponent("reaper.ini")), "[reaper]")
        XCTAssertEqual(appSettingsStatus(local: local, remote: remote), .synced)
    }

    func testSingleFileIsSyncedToo() throws {
        let local = home.appendingPathComponent("Library/Preferences/Ableton/Options.txt")
        let remote = syncRoot.appendingPathComponent("Library/Preferences/Ableton/Options.txt")
        try write("-NoAutoArm", to: local)

        try linkAppSettings(local: local, toSynced: remote, syncRoot: syncRoot, home: home)

        XCTAssertTrue(try isSymlink(local))
        XCTAssertEqual(try contents(of: local), "-NoAutoArm")
    }

    func testSecondMacUsesSyncedCopyAndBacksUpItsOwn() throws {
        let local = home.appendingPathComponent("Documents/Bitwig Studio")
        let remote = syncRoot.appendingPathComponent("Documents/Bitwig Studio")
        try write("from other mac", to: remote.appendingPathComponent("prefs"))
        try write("this mac", to: local.appendingPathComponent("prefs"))
        XCTAssertEqual(appSettingsStatus(local: local, remote: remote), .notSynced(inCloud: true))

        try linkAppSettings(local: local, toSynced: remote, syncRoot: syncRoot, home: home)

        XCTAssertEqual(try contents(of: local.appendingPathComponent("prefs")), "from other mac")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: local.deletingLastPathComponent().path)
        let backup = try XCTUnwrap(siblings.first { $0.hasPrefix("Bitwig Studio (pre-sync backup") })
        XCTAssertEqual(try contents(of: local.deletingLastPathComponent()
            .appendingPathComponent(backup).appendingPathComponent("prefs")), "this mac")
    }

    func testSecondMacWithNothingLocalJustLinks() throws {
        let local = home.appendingPathComponent("Music/Audio Music Apps")
        let remote = syncRoot.appendingPathComponent("Music/Audio Music Apps")
        try write("cmd", to: remote.appendingPathComponent("Key Commands/Mine.logikcs"))

        try linkAppSettings(local: local, toSynced: remote, syncRoot: syncRoot, home: home)

        XCTAssertEqual(try contents(of: local.appendingPathComponent("Key Commands/Mine.logikcs")), "cmd")
    }

    func testLinkThrowsWhenNothingExistsAnywhere() {
        let local = home.appendingPathComponent("Music/Ableton/User Library")
        XCTAssertEqual(appSettingsStatus(local: local, remote: syncRoot.appendingPathComponent("x")), .notFound)
        XCTAssertThrowsError(try linkAppSettings(local: local, toSynced: syncRoot.appendingPathComponent("x"),
                                                 syncRoot: syncRoot, home: home)) {
            XCTAssertEqual($0 as? AppSettingsSyncError, .nothingToSync)
        }
    }

    func testLinkRefusesFileVersusFolderMismatch() throws {
        let local = home.appendingPathComponent("Library/Application Support/Thing")
        let remote = syncRoot.appendingPathComponent("Library/Application Support/Thing")
        try write("file", to: local)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)

        XCTAssertThrowsError(try linkAppSettings(local: local, toSynced: remote, syncRoot: syncRoot, home: home)) {
            XCTAssertEqual($0 as? AppSettingsSyncError, .kindMismatch)
        }
        XCTAssertFalse(try isSymlink(local))
    }

    func testLinkIsIdempotentAndRefusesOtherLinks() throws {
        let local = home.appendingPathComponent("Library/Application Support/REAPER")
        let remote = syncRoot.appendingPathComponent("Library/Application Support/REAPER")
        try write("x", to: local.appendingPathComponent("reaper.ini"))
        try linkAppSettings(local: local, toSynced: remote, syncRoot: syncRoot, home: home)

        XCTAssertNoThrow(try linkAppSettings(local: local, toSynced: remote, syncRoot: syncRoot, home: home))
        XCTAssertThrowsError(try linkAppSettings(local: local, toSynced: home.appendingPathComponent("Other"),
                                                 syncRoot: syncRoot, home: home)) { error in
            guard case AppSettingsSyncError.alreadyLinkedElsewhere = error else {
                return XCTFail("expected alreadyLinkedElsewhere, got \(error)")
            }
        }
    }

    func testLinkRefusesFolderAlreadyContainingALink() throws {
        let local = home.appendingPathComponent("Documents/Xfer")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: local.appendingPathComponent("Serum Presets"),
                                                   withDestinationURL: home.appendingPathComponent("elsewhere"))

        XCTAssertThrowsError(try linkAppSettings(local: local, toSynced: syncRoot.appendingPathComponent("Documents/Xfer"),
                                                 syncRoot: syncRoot, home: home)) {
            XCTAssertEqual($0 as? AppSettingsSyncError, .containsLinks)
        }
    }

    func testLinkRefusesItemInsideALinkedFolder() throws {
        let outer = home.appendingPathComponent("Library/Application Support/Vendor")
        try write("x", to: outer.appendingPathComponent("settings.json"))
        try linkAppSettings(local: outer, toSynced: syncRoot.appendingPathComponent("Library/Application Support/Vendor"),
                            syncRoot: syncRoot, home: home)

        let inner = outer.appendingPathComponent("settings.json")
        XCTAssertThrowsError(try linkAppSettings(local: inner, toSynced: home.appendingPathComponent("Other/settings.json"),
                                                 syncRoot: syncRoot, home: home)) {
            XCTAssertEqual($0 as? AppSettingsSyncError, .insideLinkedFolder)
        }
    }

    func testUnlinkRestoresLocalCopyAndLeavesSyncedCopy() throws {
        let local = home.appendingPathComponent("Library/Application Support/REAPER")
        let remote = syncRoot.appendingPathComponent("Library/Application Support/REAPER")
        try write("x", to: local.appendingPathComponent("reaper.ini"))
        try linkAppSettings(local: local, toSynced: remote, syncRoot: syncRoot, home: home)

        try unlinkAppSettings(local: local)

        XCTAssertFalse(try isSymlink(local))
        XCTAssertEqual(try contents(of: local.appendingPathComponent("reaper.ini")), "x")
        XCTAssertEqual(try contents(of: remote.appendingPathComponent("reaper.ini")), "x")
        XCTAssertEqual(appSettingsStatus(local: local, remote: remote), .notSynced(inCloud: true))
    }

    func testUnlinkThrowsWhenNotLinked() throws {
        let local = home.appendingPathComponent("Library/Application Support/REAPER")
        try write("x", to: local.appendingPathComponent("reaper.ini"))
        XCTAssertThrowsError(try unlinkAppSettings(local: local)) {
            XCTAssertEqual($0 as? AppSettingsSyncError, .notLinked)
        }
    }
}

@MainActor
final class AppSettingsSyncManagerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var home: URL!

    override func setUp() {
        super.setUp()
        suiteName = "AudioBunnyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AudioBunnyTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: home)
        defaults = nil
        super.tearDown()
    }

    func testStatusReflectsProviderChoiceAndAvailability() throws {
        let manager = AppSettingsSyncManager(userDefaults: defaults, home: home)
        let item = knownAppSettingsItems[0]
        XCTAssertEqual(manager.status(for: item), .noProvider)

        manager.chooseProvider(.dropbox)
        XCTAssertEqual(manager.status(for: item), .providerUnavailable)

        try FileManager.default.createDirectory(at: home.appendingPathComponent("Dropbox"), withIntermediateDirectories: true)
        manager.refreshSyncRoot()
        XCTAssertEqual(manager.syncRoot?.path, home.appendingPathComponent("Dropbox/AudioBunny/App Settings").path)
        XCTAssertEqual(manager.status(for: item), .notFound)
    }

    func testProviderAndCustomItemsPersist() {
        let first = AppSettingsSyncManager(userDefaults: defaults, home: home)
        first.chooseProvider(.iCloudDrive)
        XCTAssertTrue(first.addCustomItem(at: home.appendingPathComponent("Library/Application Support/Serum")))
        XCTAssertFalse(first.addCustomItem(at: URL(fileURLWithPath: "/etc/hosts")))

        let second = AppSettingsSyncManager(userDefaults: defaults, home: home)
        XCTAssertEqual(second.provider, .iCloudDrive)
        XCTAssertEqual(second.customItems.map(\.relativePath), ["Library/Application Support/Serum"])
    }

    func testEnableAndDisableSyncRoundTrip() async throws {
        let dropbox = home.appendingPathComponent("Dropbox")
        try FileManager.default.createDirectory(at: dropbox, withIntermediateDirectories: true)
        let manager = AppSettingsSyncManager(userDefaults: defaults, home: home)
        manager.chooseProvider(.dropbox)
        let item = AppSettingsItem.custom(relativePath: "Library/Application Support/REAPER")
        let local = item.localURL(home: home)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: local.appendingPathComponent("reaper.ini"))

        await manager.enableSync(for: item)
        XCTAssertNil(manager.lastError)
        XCTAssertEqual(manager.status(for: item), .synced)

        await manager.disableSync(for: item)
        XCTAssertNil(manager.lastError)
        XCTAssertEqual(manager.status(for: item), .notSynced(inCloud: true))
    }
}
