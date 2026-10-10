import Foundation

// MARK: - Cloud providers

/// A cloud-synced folder on this Mac that app settings can live in. The
/// settings are moved into the provider's folder and the original location
/// becomes a symlink to them, so every Mac that links the same item shares
/// one copy.
enum CloudSyncProvider: String, CaseIterable, Identifiable {
    case iCloudDrive
    case dropbox

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iCloudDrive: return "iCloud Drive"
        case .dropbox: return "Dropbox"
        }
    }

    /// The provider's synced root folder on this Mac, or nil if it isn't set
    /// up here (not installed, or not signed in).
    func rootFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let candidates: [URL]
        switch self {
        case .iCloudDrive:
            candidates = [home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")]
        case .dropbox:
            candidates = dropboxRootCandidates(home: home)
        }
        return candidates.first { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }
}

/// Where Dropbox might be, most authoritative first: the path Dropbox itself
/// records in `~/.dropbox/info.json`, then File Provider folders under
/// `~/Library/CloudStorage` (current Dropbox), then the legacy `~/Dropbox`.
func dropboxRootCandidates(home: URL) -> [URL] {
    var result: [URL] = []
    let info = home.appendingPathComponent(".dropbox/info.json")
    if let data = try? Data(contentsOf: info),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        for account in ["personal", "business"] {
            if let entry = json[account] as? [String: Any], let path = entry["path"] as? String {
                result.append(URL(fileURLWithPath: path))
            }
        }
    }
    let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: cloudStorage.path)) ?? [])
        .filter { $0.hasPrefix("Dropbox") }
        .sorted()
    result += names.map { cloudStorage.appendingPathComponent($0) }
    result.append(home.appendingPathComponent("Dropbox"))
    return result
}

/// Where AudioBunny suggests putting settings inside iCloud Drive / Dropbox.
func suggestedSettingsDestination(providerRoot: URL) -> URL {
    providerRoot.appendingPathComponent("AudioBunny Settings")
}

// MARK: - Items

/// One settings file or folder that can be moved into the destination folder
/// and linked back, identified by its path relative to the home folder.
struct AppSettingsItem: Identifiable, Hashable {
    enum Source: Int, Hashable {
        /// A DAW or audio app from `SettingsCatalog.json`.
        case audioApp
        /// A folder found for an installed plugin.
        case plugin
        /// Added by hand.
        case custom
    }

    /// The app or plugin this belongs to — the list groups by it. Several
    /// plugins from one vendor can share a folder, so the same path can show
    /// up under more than one owner.
    let owner: String
    let detail: String
    let relativePath: String
    var source: Source = .audioApp

    var id: String { "\(owner)|\(relativePath)" }
    var isCustom: Bool { source == .custom }

    func localURL(home: URL) -> URL {
        home.appendingPathComponent(relativePath)
    }

    /// A user-chosen path, named after its last component.
    static func custom(owner: String, relativePath: String) -> AppSettingsItem {
        AppSettingsItem(owner: owner,
                        detail: "Added by you",
                        relativePath: relativePath,
                        source: .custom)
    }
}

/// Owner used for items added by hand that don't belong to a plugin.
let otherSettingsOwner = "Other"

// MARK: - Catalog

/// Global, non-user data: where each audio app and plugin vendor keeps its
/// settings. (Each user's own choices are `SettingsSyncPrefs`.) Served by the
/// web app at GET /api/v1/settings_catalog, with a bundled fallback in
/// `SettingsCatalog.json` (checked into the repo — edit that file to add
/// an app or plugin). All paths are relative to the home folder.
struct SettingsCatalog: Codable, Equatable {
    struct App: Codable, Equatable {
        let name: String
        let detail: String
        /// Fixed locations, e.g. "Music/Ableton/User Library".
        var paths: [String]?
        /// Version-numbered folders: every child of `parent` whose name starts
        /// with `prefix` (e.g. "Library/Preferences/Cubase 13").
        var versionedFolders: [VersionedFolder]?
    }

    struct VersionedFolder: Codable, Equatable {
        let parent: String
        let prefix: String
    }

    /// Where one plugin maker keeps its plugins' settings. `{plugin}` in a
    /// path is replaced by each installed plugin's name.
    struct PluginVendor: Codable, Equatable {
        let manufacturer: String
        var detail: String?
        let paths: [String]
    }

    let version: Int
    let apps: [App]
    let pluginVendors: [PluginVendor]

    static let empty = SettingsCatalog(version: 0, apps: [], pluginVendors: [])

    /// Where the last catalog fetched from the web app is kept, so new
    /// locations survive a relaunch without network.
    static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioBunny/SettingsCatalog.json")
    }

    static func loadCached(from url: URL = cacheURL) -> SettingsCatalog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SettingsCatalog.self, from: data)
    }

    func saveCache(to url: URL = SettingsCatalog.cacheURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// The copy bundled with the app — used until the web app's copy has
    /// been fetched once, and whenever it can't be.
    static let bundled: SettingsCatalog = {
        guard let url = Bundle.module.url(forResource: "SettingsCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(SettingsCatalog.self, from: data) else {
            print("SettingsCatalog.json missing or invalid — settings discovery falls back to searching")
            return .empty
        }
        return catalog
    }()

    /// Every fixed app location as an item.
    var appItems: [AppSettingsItem] {
        apps.flatMap { app in
            (app.paths ?? []).map { AppSettingsItem(owner: app.name, detail: app.detail, relativePath: $0) }
        }
    }

    /// The catalog entry for a plugin's manufacturer, if there is one.
    func vendor(for manufacturer: String) -> PluginVendor? {
        let key = vendorMatchKey(manufacturer)
        guard !key.isEmpty else { return nil }
        return pluginVendors.first { vendorMatchKey($0.manufacturer) == key }
    }
}

/// Where plugins keep their settings. (Presets in `~/Documents` and
/// `~/Library/Audio/Presets` are Preset Sync's job.)
let pluginSettingsParents = [
    "Library/Application Support",
    "Library/Preferences",
]

/// Words that vary between how a vendor names itself in a plugin and how it
/// names its folders ("Xfer Records" → "Xfer").
private let vendorNoiseWords: Set<String> = [
    "inc", "gmbh", "ltd", "llc", "co", "corp", "ag", "bv", "sas",
    "records", "software", "audio", "music", "media", "technologies", "technology",
    "plugins", "plugin", "dsp", "labs",
]

/// Vendors whose folders are system or catch-all, never one plugin maker's settings.
private let ignoredVendorKeys: Set<String> = ["apple", "audiobunny", "unknown", "steinberg"]

func vendorMatchKey(_ name: String) -> String {
    let words = name.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty && !vendorNoiseWords.contains($0) }
    return words.joined()
}

/// Whether a folder named `folderName` belongs to `manufacturer`.
func vendorFolderMatches(folderName: String, manufacturer: String) -> Bool {
    let key = vendorMatchKey(manufacturer)
    guard key.count >= 3, !ignoredVendorKeys.contains(key) else { return false }
    return vendorMatchKey(folderName) == key
}

/// Whether a folder is named for a plugin ("Pro-Q 3" ↔ "Pro-Q 3", "Valhalla
/// Room" ↔ "ValhallaRoom").
func folderMatchesPluginName(_ folderName: String, pluginName: String) -> Bool {
    func key(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
    let pluginKey = key(pluginName)
    return pluginKey.count >= 3 && key(folderName) == pluginKey
}

/// Everything worth offering on this Mac: the catalog's audio apps and
/// versioned DAW preference folders, plus each installed plugin's settings
/// folders — the catalog's locations for its maker when present, else a
/// folder named for the plugin, or else its vendor's folder (narrowed to a
/// plugin-named folder inside it when there is one). Items another Mac
/// already moved into the destination (per `manifest`) are included even when
/// nothing is here yet. Does filesystem I/O — call off the main thread.
func discoverAppSettingsItems(home: URL, manifest: [String: String],
                              plugins: [(name: String, manufacturer: String)],
                              catalog: SettingsCatalog = .bundled) -> [AppSettingsItem] {
    let fm = FileManager.default
    let syncedPaths = Set(manifest.values)

    func isLink(_ relativePath: String) -> Bool {
        (try? fm.destinationOfSymbolicLink(atPath: home.appendingPathComponent(relativePath).path)) != nil
    }
    func present(_ relativePath: String) -> Bool {
        isLink(relativePath) || fm.fileExists(atPath: home.appendingPathComponent(relativePath).path)
            || syncedPaths.contains(relativePath)
    }
    /// Child folders of a home-relative folder, here or recorded in the manifest.
    func childFolders(of parent: String) -> [String] {
        var names = Set<String>()
        let dir = home.appendingPathComponent(parent)
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        where !name.hasPrefix(".") && !name.contains("pre-sync backup") {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir), isDir.boolValue {
                names.insert(name)
            }
        }
        for path in syncedPaths where (path as NSString).deletingLastPathComponent == parent {
            names.insert((path as NSString).lastPathComponent)
        }
        return names.sorted()
    }

    let appItems = catalog.appItems
    var result = appItems.filter { present($0.relativePath) }
    var claimed = Set(appItems.map(\.relativePath))

    for app in catalog.apps {
        for versioned in app.versionedFolders ?? [] {
            for name in childFolders(of: versioned.parent) where name.hasPrefix(versioned.prefix) {
                let relative = "\(versioned.parent)/\(name)"
                guard claimed.insert(relative).inserted else { continue }
                result.append(AppSettingsItem(owner: name, detail: app.detail, relativePath: relative))
            }
        }
    }

    let parentFolders = pluginSettingsParents.map { parent in (parent, childFolders(of: parent)) }
    var pluginsSeen = Set<String>()
    for plugin in plugins where pluginsSeen.insert(plugin.name.lowercased()).inserted {
        // The catalog's locations for this plugin's maker win when any of them is here.
        if let vendor = catalog.vendor(for: plugin.manufacturer) {
            let catalogPaths = vendor.paths
                .map { $0.replacingOccurrences(of: "{plugin}", with: plugin.name) }
                .filter { !claimed.contains($0) && present($0) }
            if !catalogPaths.isEmpty {
                for path in catalogPaths {
                    result.append(AppSettingsItem(owner: plugin.name,
                                                  detail: vendor.detail ?? "\(plugin.manufacturer) settings",
                                                  relativePath: path, source: .plugin))
                }
                continue
            }
        }
        // Otherwise search: a folder named for the plugin, or its maker's folder.
        var paths: [String] = []
        for (parent, children) in parentFolders {
            for name in children {
                let relative = "\(parent)/\(name)"
                guard !claimed.contains(relative) else { continue }
                if folderMatchesPluginName(name, pluginName: plugin.name) {
                    paths.append(relative)
                } else if vendorFolderMatches(folderName: name, manufacturer: plugin.manufacturer) {
                    // A vendor folder that's already linked is synced as a
                    // whole — don't offer pieces of it.
                    let inner: [String] = isLink(relative) ? [] : childFolders(of: relative)
                        .filter { folderMatchesPluginName($0, pluginName: plugin.name) }
                    paths += inner.isEmpty ? [relative] : inner.map { "\(relative)/\($0)" }
                }
            }
        }
        for path in paths {
            let place = path.hasPrefix("Library/Preferences") ? "Preferences" : "Application Support"
            result.append(AppSettingsItem(owner: plugin.name,
                                          detail: "\(plugin.manufacturer) · \(place)",
                                          relativePath: path, source: .plugin))
        }
    }
    return result
}

/// Bytes a file or folder takes on disk, not following symlinks (a synced item
/// is just a link here, so it counts as nothing).
func appSettingsDiskSize(_ url: URL) -> Int64 {
    let fm = FileManager.default
    if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil { return 0 }
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey]
    guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
    guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
    var total: Int64 = 0
    let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys)
    while let file = enumerator?.nextObject() as? URL {
        total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
    }
    return total
}

/// Any symlink at or below `url` (not following links). Syncing a folder that
/// already contains a link — e.g. a preset folder synced by Preset Sync —
/// would nest one sync inside another.
func containsSymlink(_ url: URL) -> Bool {
    guard let enumerator = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return false }
    while let file = enumerator.nextObject() as? URL {
        if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return true }
    }
    return false
}

/// `url`'s path relative to `home`, or nil if it isn't strictly inside it.
func homeRelativePath(of url: URL, home: URL) -> String? {
    let homePath = home.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(homePath + "/") else { return nil }
    let relative = String(path.dropFirst(homePath.count + 1))
    return relative.isEmpty ? nil : relative
}

// MARK: - Pure helpers

enum AppSettingsSyncError: LocalizedError, Equatable {
    case unsafePath
    case tooBroad
    case insideCloudFolder
    case managedByMacOS
    case overlapsSyncFolder
    case nothingToSync
    case kindMismatch
    case containsLinks
    case insideLinkedFolder
    case alreadyLinkedElsewhere(String)
    case notLinked

    var errorDescription: String? {
        switch self {
        case .unsafePath:
            return "That isn't somewhere AudioBunny will touch — pick something inside your home folder."
        case .tooBroad:
            return "That folder is too broad to sync — pick a specific app's folder inside it."
        case .insideCloudFolder:
            return "That's already inside a cloud-synced folder."
        case .managedByMacOS:
            return "macOS replaces symlinks there (preference plists and sandboxed app containers), so it can't be synced this way."
        case .overlapsSyncFolder:
            return "That overlaps the destination folder itself."
        case .nothingToSync:
            return "There's nothing there yet, on this Mac or in the destination folder."
        case .kindMismatch:
            return "One copy is a file and the other a folder — move one aside and try again."
        case .containsLinks:
            return "Something inside is already a link (maybe synced by Preset Sync) — unsync that first."
        case .insideLinkedFolder:
            return "It's inside a folder that's already linked, so it's synced along with that folder."
        case .alreadyLinkedElsewhere(let path):
            return "Already linked to \(path) — remove that link by hand first."
        case .notLinked:
            return "This isn't currently synced."
        }
    }
}

/// Folders directly under home that hold too much (or too much of other
/// apps' state) to replace with a single link.
private let tooBroadRelativePaths: Set<String> = [
    "Library", "Library/Preferences", "Library/Application Support", "Library/Caches",
    "Library/Containers", "Library/Group Containers", "Library/Audio",
    "Documents", "Desktop", "Downloads", "Music", "Movies", "Pictures", "Applications",
]

/// Everything `linkAppSettings` checks before touching the filesystem.
func validateAppSettingsPath(_ local: URL, syncRoot: URL,
                             home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
    guard isSafeSyncDirectory(local), let relative = homeRelativePath(of: local, home: home) else {
        throw AppSettingsSyncError.unsafePath
    }
    if tooBroadRelativePaths.contains(relative) { throw AppSettingsSyncError.tooBroad }
    if relative.hasPrefix("Library/Mobile Documents") || relative.hasPrefix("Library/CloudStorage") {
        throw AppSettingsSyncError.insideCloudFolder
    }
    // cfprefsd rewrites preference plists atomically, replacing a symlink with
    // a plain file, and sandboxed apps can't follow links out of their
    // container — either way the link would silently stop syncing.
    if (relative.hasPrefix("Library/Preferences/") && local.pathExtension == "plist")
        || relative.hasPrefix("Library/Containers/") || relative.hasPrefix("Library/Group Containers/") {
        throw AppSettingsSyncError.managedByMacOS
    }
    let localPath = local.standardizedFileURL.path
    let rootPath = syncRoot.standardizedFileURL.path
    if localPath == rootPath || localPath.hasPrefix(rootPath + "/") || rootPath.hasPrefix(localPath + "/") {
        throw AppSettingsSyncError.overlapsSyncFolder
    }
}

/// Makes `local` a symlink to `remote`, where `remote` sits inside `syncRoot`:
///
/// - Already linked to `remote`: no-op. Linked anywhere else: refuses, and the
///   caller must remove that link by hand.
/// - Only a local copy (first Mac): it's *moved* into the destination folder, then
///   linked back — nothing is copied or duplicated.
/// - Only a synced copy (another Mac already synced it): just links to it.
/// - Both: the synced copy wins, and this Mac's copy is renamed aside as a
///   timestamped backup — never deleted — before linking.
func linkAppSettings(local: URL, toSynced remote: URL, syncRoot: URL,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
    try validateAppSettingsPath(local, syncRoot: syncRoot, home: home)
    let fm = FileManager.default

    if let destPath = try? fm.destinationOfSymbolicLink(atPath: local.path) {
        let existing = URL(fileURLWithPath: destPath).standardizedFileURL.path
        if existing == remote.standardizedFileURL.path { return }
        throw AppSettingsSyncError.alreadyLinkedElsewhere(existing)
    }

    var localIsDir: ObjCBool = false
    let localExists = fm.fileExists(atPath: local.path, isDirectory: &localIsDir)
    var remoteIsDir: ObjCBool = false
    let remoteExists = fm.fileExists(atPath: remote.path, isDirectory: &remoteIsDir)

    let parent = local.deletingLastPathComponent()
    if parent.resolvingSymlinksInPath().path != parent.standardizedFileURL.path {
        throw AppSettingsSyncError.insideLinkedFolder
    }
    if localExists && localIsDir.boolValue && containsSymlink(local) {
        throw AppSettingsSyncError.containsLinks
    }

    switch (localExists, remoteExists) {
    case (false, false):
        throw AppSettingsSyncError.nothingToSync
    case (true, true):
        guard localIsDir.boolValue == remoteIsDir.boolValue else { throw AppSettingsSyncError.kindMismatch }
        let backup = local.deletingLastPathComponent()
            .appendingPathComponent("\(local.lastPathComponent) (pre-sync backup \(presetSyncBackupTimestamp()))")
        try fm.moveItem(at: local, to: backup)
    case (true, false):
        try fm.createDirectory(at: remote.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: local, to: remote)
    case (false, true):
        break
    }

    try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: local, withDestinationURL: remote)
}

/// Reverses `linkAppSettings`: replaces the symlink with a real local copy of
/// what it points at. The synced copy is left untouched (other Macs may still
/// use it). The copy is made beside the link first, so a failed copy never
/// leaves the app with nothing.
func unlinkAppSettings(local: URL) throws {
    let fm = FileManager.default
    guard isSafeSyncDirectory(local) else { throw AppSettingsSyncError.unsafePath }
    guard let destPath = try? fm.destinationOfSymbolicLink(atPath: local.path) else {
        throw AppSettingsSyncError.notLinked
    }
    let staging = local.deletingLastPathComponent()
        .appendingPathComponent(".\(local.lastPathComponent).audiobunny-unsync-\(UUID().uuidString)")
    try fm.copyItem(at: URL(fileURLWithPath: destPath), to: staging)
    do {
        try fm.removeItem(at: local) // removes the symlink itself, not its target
        try fm.moveItem(at: staging, to: local)
    } catch {
        try? fm.removeItem(at: staging)
        throw error
    }
}

// MARK: - Destination layout

/// Lives in the destination folder and records which home-relative path each
/// folder there came from, so every Mac links the same path to the same
/// folder — and so a folder that was already there (put there by hand, or
/// belonging to some other path with the same name) is never mistaken for
/// this one and overwritten.
let settingsManifestFileName = ".audiobunny-settings.json"

/// Folder name in the destination → home-relative path it holds.
func loadSettingsManifest(destination: URL) -> [String: String] {
    let url = destination.appendingPathComponent(settingsManifestFileName)
    guard let data = try? Data(contentsOf: url),
          let manifest = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
    return manifest
}

func saveSettingsManifest(_ manifest: [String: String], destination: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: destination.appendingPathComponent(settingsManifestFileName),
                                       options: .atomic)
}

/// The destination folder name already recorded for `relativePath`, if any.
func recordedSettingsName(for relativePath: String, manifest: [String: String]) -> String? {
    manifest.filter { $0.value == relativePath }.keys.sorted().first
}

/// A name for `relativePath` in the destination that isn't taken. It's the
/// folder's own name when free; when a folder by that name is already there,
/// the new one goes beside it as a sibling — "Name (Parent)", then "Name 2",
/// "Name 3"… — and the existing folder is left alone.
func newSettingsName(for relativePath: String, destination: URL, manifest: [String: String]) -> String {
    let fm = FileManager.default
    func isFree(_ name: String) -> Bool {
        let path = destination.appendingPathComponent(name).path
        return manifest[name] == nil && name != settingsManifestFileName
            && !fm.fileExists(atPath: path)
            && (try? fm.destinationOfSymbolicLink(atPath: path)) == nil
    }
    let base = (relativePath as NSString).lastPathComponent
    let parent = ((relativePath as NSString).deletingLastPathComponent as NSString).lastPathComponent
    var candidates = [base]
    if !parent.isEmpty { candidates.append("\(base) (\(parent))") }
    if let free = candidates.first(where: isFree) { return free }
    var n = 2
    while !isFree("\(base) \(n)") { n += 1 }
    return "\(base) \(n)"
}

// MARK: - Status

enum AppSettingsSyncStatus: Equatable {
    /// No destination folder chosen yet.
    case noDestination
    /// The chosen destination folder isn't there (e.g. an unplugged drive).
    case destinationMissing
    /// Nothing on this Mac and nothing in the destination — the app probably
    /// isn't installed here.
    case notFound
    /// Not linked. `inDestination` means it's already in the destination
    /// (another Mac moved it there), so linking uses that copy.
    case notSynced(inDestination: Bool)
    case synced
    /// Linked, but not to its folder in the current destination — usually
    /// left over from another destination. Needs manual attention.
    case linkedElsewhere(String)
}

/// `remote` is the item's folder in the destination if one is recorded.
func appSettingsStatus(local: URL, remote: URL?) -> AppSettingsSyncStatus {
    let fm = FileManager.default
    if let destPath = try? fm.destinationOfSymbolicLink(atPath: local.path) {
        let existing = URL(fileURLWithPath: destPath).standardizedFileURL.path
        return existing == remote?.standardizedFileURL.path ? .synced : .linkedElsewhere(existing)
    }
    if let remote, fm.fileExists(atPath: remote.path) { return .notSynced(inDestination: true) }
    if !fm.fileExists(atPath: local.path) { return .notFound }
    return .notSynced(inDestination: false)
}

// MARK: - The user's own choices

/// What one user chose in Settings Sync — the per-user counterpart to the
/// global `SettingsCatalog`. Kept in UserDefaults on each Mac and, when signed
/// in, mirrored to the account's settings (GET/PATCH /api/v1/settings) so the
/// user's other Macs start from the same choices. Which items are actually
/// linked is per-Mac (the symlinks) and lives in the destination's manifest,
/// not here.
struct SettingsSyncPrefs: Codable, Equatable {
    /// "~/…" when inside the home folder (so it means the same place on every
    /// Mac), otherwise an absolute path.
    var destination: String?
    /// Folders and files the user added by hand, as "owner<TAB>home-relative path"
    /// (account settings only hold strings and arrays of strings).
    var customPaths: [String]?

    enum CodingKeys: String, CodingKey {
        case destination = "settingsSync.destination"
        case customPaths = "settingsSync.customPaths"
    }

    static func encodeDestination(_ url: URL, home: URL) -> String {
        homeRelativePath(of: url, home: home).map { "~/\($0)" } ?? url.standardizedFileURL.path
    }

    static func decodeDestination(_ string: String, home: URL) -> URL {
        string.hasPrefix("~/") ? home.appendingPathComponent(String(string.dropFirst(2)))
                               : URL(fileURLWithPath: string)
    }

    static func encodeCustomPaths(_ paths: [String: [String]]) -> [String] {
        paths.keys.sorted().flatMap { owner in paths[owner, default: []].map { "\(owner)\t\($0)" } }
    }

    static func decodeCustomPaths(_ entries: [String]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for entry in entries {
            let parts = entry.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[1].hasPrefix("/"), !parts[1].contains("..") else { continue }
            result[parts[0], default: []].append(parts[1])
        }
        return result
    }
}

// MARK: - Manager

@MainActor
final class AppSettingsSyncManager: ObservableObject {
    /// The folder settings get moved into — usually inside iCloud Drive or Dropbox.
    @Published private(set) var destination: URL?
    /// The destination's record of what it holds; see `settingsManifestFileName`.
    @Published private(set) var manifest: [String: String] = [:]
    /// Owner → home-relative paths added by hand.
    @Published private(set) var customPaths: [String: [String]] = [:]
    @Published private(set) var discoveredItems: [AppSettingsItem] = []
    /// Known settings locations: the web app's copy (fetched, or cached from
    /// the last fetch), else the one bundled with the app.
    @Published private(set) var catalog: SettingsCatalog
    @Published private(set) var hasDiscovered = false
    @Published private(set) var isDiscovering = false
    /// On-disk size of each local item, by home-relative path, so the UI can
    /// warn before moving something huge.
    @Published private(set) var sizes: [String: Int64] = [:]
    @Published var lastError: String?
    /// Home-relative paths being linked or unlinked right now.
    @Published private(set) var workingPaths: Set<String> = []

    let home: URL
    private let userDefaults: UserDefaults
    private let destinationDefaultsKey = "audiobunny.settingsSync.destination"
    private let customPathsDefaultsKey = "audiobunny.settingsSync.customPaths"

    /// Whether to mirror the user's choices to their account when signed in
    /// (off in tests, so they never touch a real account).
    private let syncsToAccount: Bool

    init(userDefaults: UserDefaults = .standard,
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         syncsToAccount: Bool = true) {
        self.userDefaults = userDefaults
        self.home = home
        self.syncsToAccount = syncsToAccount
        catalog = SettingsCatalog.loadCached() ?? .bundled
        if let path = userDefaults.string(forKey: destinationDefaultsKey) {
            destination = URL(fileURLWithPath: path)
        }
        customPaths = userDefaults.dictionary(forKey: customPathsDefaultsKey) as? [String: [String]] ?? [:]
        reloadManifest()
    }

    var items: [AppSettingsItem] {
        var seen = Set(discoveredItems.map(\.id))
        var result = discoveredItems
        for (owner, paths) in customPaths.sorted(by: { $0.key < $1.key }) {
            for path in paths {
                let item = AppSettingsItem.custom(owner: owner, relativePath: path)
                if seen.insert(item.id).inserted { result.append(item) }
            }
        }
        return result
    }

    var destinationAvailable: Bool {
        guard let destination else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDir) && isDir.boolValue
    }

    func reloadManifest() {
        manifest = destination.map { loadSettingsManifest(destination: $0) } ?? [:]
    }

    func chooseDestination(_ url: URL) {
        setDestination(url)
        pushAccountPrefs()
    }

    private func setDestination(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            lastError = "Couldn't use \(url.path): \(error.localizedDescription)"
            return
        }
        destination = url
        userDefaults.set(url.path, forKey: destinationDefaultsKey)
        lastError = nil
        reloadManifest()
    }

    func isAvailable(_ provider: CloudSyncProvider) -> Bool {
        provider.rootFolder(home: home) != nil
    }

    /// Points the destination at an "AudioBunny Settings" folder in iCloud
    /// Drive or Dropbox.
    func useProvider(_ provider: CloudSyncProvider) {
        guard let root = provider.rootFolder(home: home) else {
            lastError = "\(provider.displayName) isn't set up on this Mac."
            return
        }
        chooseDestination(suggestedSettingsDestination(providerRoot: root))
    }

    /// Finds every audio app and installed plugin with settings, then measures
    /// them. Pass every installed plugin (format duplicates are fine).
    func discover(plugins: [(name: String, manufacturer: String)]) async {
        await runDiscovery(plugins: plugins)
        // Fetch the account's choices and the web app's catalog after showing
        // results from what's here, so a slow or offline server never holds
        // up the list.
        let accountChanged = await pullAccountPrefs()
        let catalogChanged = await refreshCatalog()
        if accountChanged || catalogChanged {
            await runDiscovery(plugins: plugins)
        }
    }

    private func runDiscovery(plugins: [(name: String, manufacturer: String)]) async {
        reloadManifest()
        isDiscovering = true
        let home = self.home
        let manifest = self.manifest
        let catalog = self.catalog
        let found = await Task.detached(priority: .userInitiated) {
            discoverAppSettingsItems(home: home, manifest: manifest, plugins: plugins, catalog: catalog)
        }.value
        discoveredItems = found
        hasDiscovered = true
        isDiscovering = false

        let targets = Set(items.map(\.relativePath)).map { ($0, home.appendingPathComponent($0)) }
        sizes = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: targets.map { ($0.0, appSettingsDiskSize($0.1)) })
        }.value
    }

    /// Pulls the latest catalog from the web app (GET settings_catalog) and
    /// caches it. Offline or on any error, keeps whatever it already has.
    /// Returns whether the catalog changed.
    @discardableResult
    func refreshCatalog() async -> Bool {
        guard let fetched = try? await APIClient.settingsCatalog(), fetched.version > 0 else { return false }
        try? fetched.saveCache()
        guard fetched != catalog else { return false }
        catalog = fetched
        return true
    }

    /// Switching destinations would strand every existing link, so the UI
    /// locks the choice while anything is linked.
    var hasSyncedItems: Bool {
        items.contains {
            switch status(for: $0) {
            case .synced, .linkedElsewhere: return true
            default: return false
            }
        }
    }

    func localURL(for item: AppSettingsItem) -> URL { item.localURL(home: home) }

    func remoteURL(for item: AppSettingsItem) -> URL? {
        guard let destination, let name = recordedSettingsName(for: item.relativePath, manifest: manifest) else {
            return nil
        }
        return destination.appendingPathComponent(name)
    }

    func status(for item: AppSettingsItem) -> AppSettingsSyncStatus {
        guard destination != nil else { return .noDestination }
        guard destinationAvailable else { return .destinationMissing }
        return appSettingsStatus(local: localURL(for: item), remote: remoteURL(for: item))
    }

    func isWorking(_ item: AppSettingsItem) -> Bool { workingPaths.contains(item.relativePath) }

    @discardableResult
    func addCustomItem(at url: URL, owner: String = otherSettingsOwner) -> Bool {
        guard let relative = homeRelativePath(of: url, home: home) else {
            lastError = AppSettingsSyncError.unsafePath.errorDescription
            return false
        }
        if let destination {
            do {
                try validateAppSettingsPath(url, syncRoot: destination, home: home)
            } catch {
                lastError = error.localizedDescription
                return false
            }
        }
        var paths = customPaths[owner] ?? []
        if !paths.contains(relative) && !items.contains(where: { $0.owner == owner && $0.relativePath == relative }) {
            paths.append(relative)
            customPaths[owner] = paths
            userDefaults.set(customPaths, forKey: customPathsDefaultsKey)
            pushAccountPrefs()
        }
        lastError = nil
        return true
    }

    func removeCustomItem(_ item: AppSettingsItem) {
        customPaths[item.owner]?.removeAll { $0 == item.relativePath }
        if customPaths[item.owner]?.isEmpty == true { customPaths[item.owner] = nil }
        userDefaults.set(customPaths, forKey: customPathsDefaultsKey)
        pushAccountPrefs()
    }

    // MARK: Account

    /// This Mac's choices, in the shape stored on the account.
    var prefs: SettingsSyncPrefs {
        SettingsSyncPrefs(destination: destination.map { SettingsSyncPrefs.encodeDestination($0, home: home) },
                          customPaths: SettingsSyncPrefs.encodeCustomPaths(customPaths))
    }

    /// Adopts what the account has. The account's hand-added items replace
    /// this Mac's (so a removal on one Mac sticks everywhere). Its destination
    /// is only adopted when this Mac hasn't picked one and the folder's parent
    /// (e.g. Dropbox) exists here — each Mac may legitimately use its own.
    /// Returns whether anything changed; also reports whether the account is
    /// missing something this Mac has and should be sent it.
    func apply(_ account: SettingsSyncPrefs) -> (changed: Bool, needsPush: Bool) {
        var changed = false
        var needsPush = false
        if let entries = account.customPaths {
            let decoded = SettingsSyncPrefs.decodeCustomPaths(entries)
            if decoded != customPaths {
                customPaths = decoded
                userDefaults.set(customPaths, forKey: customPathsDefaultsKey)
                changed = true
            }
        } else if !customPaths.isEmpty {
            needsPush = true
        }
        if let string = account.destination {
            let url = SettingsSyncPrefs.decodeDestination(string, home: home)
            if destination == nil,
               FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
                setDestination(url)
                if destination != nil { changed = true }
            }
        } else if destination != nil {
            needsPush = true
        }
        return (changed, needsPush)
    }

    /// Pulls the signed-in user's Settings Sync choices. Returns whether they
    /// changed anything here.
    @discardableResult
    func pullAccountPrefs() async -> Bool {
        guard syncsToAccount, APIClient.isSignedIn,
              let account = try? await APIClient.settingsSyncPrefs() else { return false }
        let result = apply(account)
        if result.needsPush { pushAccountPrefs() }
        return result.changed
    }

    private func pushAccountPrefs() {
        guard syncsToAccount, APIClient.isSignedIn else { return }
        let prefs = self.prefs
        Task { try? await APIClient.saveSettingsSyncPrefs(prefs) }
    }

    func enableSync(for item: AppSettingsItem) async {
        guard let destination, destinationAvailable else {
            lastError = "Choose a destination folder first."
            return
        }
        // Another Mac may have added to the destination since we last looked.
        reloadManifest()
        let relative = item.relativePath
        let name = recordedSettingsName(for: relative, manifest: manifest)
            ?? newSettingsName(for: relative, destination: destination, manifest: manifest)
        let local = localURL(for: item)
        let remote = destination.appendingPathComponent(name)
        let home = self.home
        workingPaths.insert(relative)
        defer { workingPaths.remove(relative) }
        do {
            try await Task.detached(priority: .userInitiated) {
                try linkAppSettings(local: local, toSynced: remote, syncRoot: destination, home: home)
            }.value
            var updated = loadSettingsManifest(destination: destination)
            updated[name] = relative
            try saveSettingsManifest(updated, destination: destination)
            manifest = updated
            lastError = nil
        } catch {
            lastError = "Couldn't sync \(item.owner): \(error.localizedDescription)"
        }
    }

    /// Leaves the destination's copy (and its manifest entry) in place — other
    /// Macs may still be linked to it.
    func disableSync(for item: AppSettingsItem) async {
        let local = localURL(for: item)
        let relative = item.relativePath
        workingPaths.insert(relative)
        defer { workingPaths.remove(relative) }
        do {
            try await Task.detached(priority: .userInitiated) {
                try unlinkAppSettings(local: local)
            }.value
            lastError = nil
        } catch {
            lastError = "Couldn't stop syncing \(item.owner): \(error.localizedDescription)"
        }
    }
}
