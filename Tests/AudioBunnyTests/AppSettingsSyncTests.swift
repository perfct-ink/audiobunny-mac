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

    func testPluginNameMatching() {
        XCTAssertTrue(folderMatchesPluginName("ValhallaRoom", pluginName: "Valhalla Room"))
        XCTAssertTrue(folderMatchesPluginName("Pro-Q 3", pluginName: "Pro-Q 3"))
        XCTAssertFalse(folderMatchesPluginName("Pro-Q 2", pluginName: "Pro-Q 3"))
        XCTAssertFalse(folderMatchesPluginName("EQ", pluginName: "EQ"))
    }

    func testDiscoveryFindsAppsAndEachPluginsOwnSettingsFolder() throws {
        let fm = FileManager.default
        for path in ["Music/Ableton/User Library",
                     "Library/Application Support/FabFilter/Pro-Q 3",
                     "Library/Application Support/FabFilter/Shared",
                     "Library/Application Support/u-he",
                     "Library/Preferences/Valhalla Room",
                     "Library/Application Support/Some Other App",
                     "Library/Preferences/Cubase 13"] {
            try fm.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        // Moved into the destination from another Mac; nothing local yet.
        let manifest = ["Bitwig Studio": "Documents/Bitwig Studio"]

        let catalog = SettingsCatalog(version: 1, apps: [
            .init(name: "Ableton Live", detail: "User Library", paths: ["Music/Ableton/User Library"]),
            .init(name: "Bitwig Studio", detail: "Library", paths: ["Documents/Bitwig Studio"]),
            .init(name: "REAPER", detail: "Settings", paths: ["Library/Application Support/REAPER"]),
            .init(name: "Cubase", detail: "Cubase preferences",
                  versionedFolders: [.init(parent: "Library/Preferences", prefix: "Cubase ")]),
        ], pluginVendors: [])
        let items = discoverAppSettingsItems(home: home, manifest: manifest, plugins: [
            (name: "Pro-Q 3", manufacturer: "FabFilter"),
            (name: "Pro-L 2", manufacturer: "FabFilter"),
            (name: "Diva", manufacturer: "u-he"),
            (name: "Valhalla Room", manufacturer: "Valhalla DSP, LLC"),
            (name: "Pro-Q 3", manufacturer: "FabFilter"),
        ], catalog: catalog)
        func paths(_ owner: String) -> [String] { items.filter { $0.owner == owner }.map(\.relativePath) }

        XCTAssertEqual(paths("Ableton Live"), ["Music/Ableton/User Library"])
        XCTAssertEqual(paths("Bitwig Studio"), ["Documents/Bitwig Studio"])
        XCTAssertEqual(paths("Cubase 13"), ["Library/Preferences/Cubase 13"])
        // A plugin-named folder inside the vendor's folder wins over the whole vendor folder…
        XCTAssertEqual(paths("Pro-Q 3"), ["Library/Application Support/FabFilter/Pro-Q 3"])
        // …otherwise the vendor folder is the plugin's settings location.
        XCTAssertEqual(paths("Pro-L 2"), ["Library/Application Support/FabFilter"])
        XCTAssertEqual(paths("Diva"), ["Library/Application Support/u-he"])
        XCTAssertEqual(paths("Valhalla Room"), ["Library/Preferences/Valhalla Room"])
        XCTAssertFalse(items.contains { $0.relativePath.hasSuffix("Some Other App") })
        XCTAssertEqual(items.first { $0.owner == "Diva" }?.source, .plugin)
    }

    func testCatalogVendorLocationsWinOverSearching() throws {
        let fm = FileManager.default
        for path in ["Library/Application Support/Valhalla DSP, LLC/ValhallaRoom",
                     "Library/Preferences/ValhallaRoom",
                     "Library/Application Support/u-he"] {
            try fm.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let catalog = SettingsCatalog(version: 1, apps: [], pluginVendors: [
            .init(manufacturer: "Valhalla DSP", detail: "Valhalla settings",
                  paths: ["Library/Application Support/Valhalla DSP, LLC/{plugin}"]),
            // Listed, but nothing there: falls back to searching.
            .init(manufacturer: "u-he", paths: ["Library/Application Support/u-he/Nope"]),
        ])
        let items = discoverAppSettingsItems(home: home, manifest: [:], plugins: [
            (name: "ValhallaRoom", manufacturer: "Valhalla DSP, LLC"),
            (name: "Diva", manufacturer: "u-he"),
        ], catalog: catalog)

        XCTAssertEqual(items.filter { $0.owner == "ValhallaRoom" }.map(\.relativePath),
                       ["Library/Application Support/Valhalla DSP, LLC/ValhallaRoom"])
        XCTAssertEqual(items.first { $0.owner == "ValhallaRoom" }?.detail, "Valhalla settings")
        XCTAssertEqual(items.filter { $0.owner == "Diva" }.map(\.relativePath), ["Library/Application Support/u-he"])
    }

    func testBundledCatalogLoadsAndOnlyListsSyncablePaths() throws {
        let catalog = SettingsCatalog.bundled
        XCTAssertGreaterThan(catalog.version, 0)
        XCTAssertFalse(catalog.apps.isEmpty)
        let destination = home.appendingPathComponent("Destination")
        let paths = catalog.appItems.map(\.relativePath)
            + catalog.pluginVendors.flatMap(\.paths).map { $0.replacingOccurrences(of: "{plugin}", with: "Plugin") }
        for path in paths {
            XCTAssertFalse(path.hasPrefix("/") || path.hasPrefix("~"), "\(path) must be relative to home")
            XCTAssertNoThrow(try validateAppSettingsPath(home.appendingPathComponent(path), syncRoot: destination, home: home),
                             "\(path) can't be synced")
        }
    }

    // MARK: Destination layout

    func testNewNameIsTheFolderNameWhenFree() {
        XCTAssertEqual(newSettingsName(for: "Library/Application Support/u-he", destination: syncRoot, manifest: [:]), "u-he")
    }

    func testExistingFolderGetsASiblingInsteadOfBeingReused() throws {
        // A "u-he" folder is already in the destination but isn't recorded as
        // ours (put there by hand, say): never merge into it.
        try FileManager.default.createDirectory(at: syncRoot.appendingPathComponent("u-he"), withIntermediateDirectories: true)
        XCTAssertEqual(newSettingsName(for: "Library/Application Support/u-he", destination: syncRoot, manifest: [:]),
                       "u-he (Application Support)")

        // Same name from a different place: sibling again, then numbered.
        let manifest = ["u-he (Application Support)": "Library/Application Support/u-he"]
        try FileManager.default.createDirectory(at: syncRoot.appendingPathComponent("u-he (Application Support)"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(newSettingsName(for: "Documents/Elsewhere/u-he", destination: syncRoot, manifest: manifest),
                       "u-he (Elsewhere)")
        try FileManager.default.createDirectory(at: syncRoot.appendingPathComponent("u-he (Elsewhere)"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(newSettingsName(for: "Documents/Elsewhere/u-he", destination: syncRoot, manifest: manifest),
                       "u-he 2")
    }

    func testManifestRoundTripsAndFindsRecordedName() throws {
        try FileManager.default.createDirectory(at: syncRoot, withIntermediateDirectories: true)
        let manifest = ["u-he 2": "Library/Application Support/u-he"]
        try saveSettingsManifest(manifest, destination: syncRoot)
        XCTAssertEqual(loadSettingsManifest(destination: syncRoot), manifest)
        XCTAssertEqual(recordedSettingsName(for: "Library/Application Support/u-he", manifest: manifest), "u-he 2")
        XCTAssertNil(recordedSettingsName(for: "Library/Application Support/Other", manifest: manifest))
    }

    // MARK: Link / unlink

    func testFirstMacMovesFolderIntoSyncFolderAndLinksBack() throws {
        let local = home.appendingPathComponent("Library/Application Support/REAPER")
        let remote = syncRoot.appendingPathComponent("REAPER")
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
        XCTAssertEqual(appSettingsStatus(local: local, remote: remote), .notSynced(inDestination: true))

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
        XCTAssertEqual(appSettingsStatus(local: local, remote: remote), .notSynced(inDestination: true))
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

    func testStatusReflectsDestinationChoiceAndAvailability() throws {
        let manager = AppSettingsSyncManager(userDefaults: defaults, home: home)
        let item = SettingsCatalog.bundled.appItems[0]
        XCTAssertEqual(manager.status(for: item), .noDestination)

        manager.useProvider(.dropbox)
        XCTAssertNil(manager.destination) // Dropbox isn't set up in this fake home
        XCTAssertNotNil(manager.lastError)

        try FileManager.default.createDirectory(at: home.appendingPathComponent("Dropbox"), withIntermediateDirectories: true)
        manager.useProvider(.dropbox)
        XCTAssertEqual(manager.destination?.path, home.appendingPathComponent("Dropbox/AudioBunny Settings").path)
        XCTAssertEqual(manager.status(for: item), .notFound)

        try FileManager.default.removeItem(at: home.appendingPathComponent("Dropbox"))
        XCTAssertEqual(manager.status(for: item), .destinationMissing)
    }

    func testDestinationAndCustomItemsPersist() {
        let destination = home.appendingPathComponent("Settings Destination")
        let first = AppSettingsSyncManager(userDefaults: defaults, home: home)
        first.chooseDestination(destination)
        XCTAssertTrue(first.addCustomItem(at: home.appendingPathComponent("Library/Application Support/Serum"), owner: "Serum"))
        XCTAssertFalse(first.addCustomItem(at: URL(fileURLWithPath: "/etc/hosts")))

        let second = AppSettingsSyncManager(userDefaults: defaults, home: home)
        XCTAssertEqual(second.destination?.path, destination.path)
        XCTAssertEqual(second.items.filter(\.isCustom).map(\.relativePath), ["Library/Application Support/Serum"])
        XCTAssertEqual(second.items.filter(\.isCustom).map(\.owner), ["Serum"])
    }

    func testEnableAndDisableSyncRoundTripRecordsTheFolder() async throws {
        let destination = home.appendingPathComponent("Settings Destination")
        let manager = AppSettingsSyncManager(userDefaults: defaults, home: home)
        manager.chooseDestination(destination)
        // Something unrelated already called "REAPER" is in the destination.
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("REAPER"),
                                                withIntermediateDirectories: true)
        let item = AppSettingsItem.custom(owner: "REAPER", relativePath: "Library/Application Support/REAPER")
        let local = item.localURL(home: home)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: local.appendingPathComponent("reaper.ini"))

        await manager.enableSync(for: item)
        XCTAssertNil(manager.lastError)
        XCTAssertEqual(manager.status(for: item), .synced)
        XCTAssertEqual(manager.remoteURL(for: item)?.lastPathComponent, "REAPER (Application Support)")
        XCTAssertEqual(loadSettingsManifest(destination: destination),
                       ["REAPER (Application Support)": "Library/Application Support/REAPER"])
        // The folder that was already there is untouched.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent("REAPER").path), [])

        await manager.disableSync(for: item)
        XCTAssertNil(manager.lastError)
        XCTAssertEqual(manager.status(for: item), .notSynced(inDestination: true))
    }
}
