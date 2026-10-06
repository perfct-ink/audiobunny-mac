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

/// The folder AudioBunny owns inside a provider's root. Everything it syncs
/// goes under here, never loose in the user's Dropbox / iCloud Drive.
func appSettingsSyncRoot(providerRoot: URL) -> URL {
    providerRoot.appendingPathComponent("AudioBunny/App Settings")
}

// MARK: - Items

/// One app-settings file or folder that can be synced, identified by its path
/// relative to the home folder (which is also where it lives inside the sync
/// root, so every Mac maps it to the same place and nothing can collide).
struct AppSettingsItem: Identifiable, Hashable {
    enum Source: Int, Hashable {
        /// A DAW or audio app from `knownAppSettingsItems`.
        case audioApp
        /// A vendor folder matched to an installed plugin's manufacturer.
        case pluginVendor
        /// Added by hand.
        case custom
    }

    let appName: String
    let detail: String
    let relativePath: String
    var source: Source = .audioApp

    var id: String { relativePath }
    var isCustom: Bool { source == .custom }

    func localURL(home: URL) -> URL {
        home.appendingPathComponent(relativePath)
    }

    func remoteURL(syncRoot: URL) -> URL {
        syncRoot.appendingPathComponent(relativePath)
    }

    /// A user-chosen path, named after its last component.
    static func custom(relativePath: String) -> AppSettingsItem {
        AppSettingsItem(appName: (relativePath as NSString).lastPathComponent,
                        detail: "Added by you",
                        relativePath: relativePath,
                        source: .custom)
    }
}

/// Audio apps whose settings live in a folder that's safe to symlink as a
/// whole: user content and preferences, not licenses or machine-specific
/// caches. Only the ones present on this Mac (or already in the sync folder)
/// are shown. Anything else can be added by hand.
let knownAppSettingsItems: [AppSettingsItem] = [
    AppSettingsItem(appName: "Ableton Live", detail: "User Library (presets, templates, defaults)",
                    relativePath: "Music/Ableton/User Library"),
    AppSettingsItem(appName: "Logic Pro & MainStage", detail: "Patches, channel strips, key commands, templates",
                    relativePath: "Music/Audio Music Apps"),
    AppSettingsItem(appName: "Bitwig Studio", detail: "Library, templates, controller scripts",
                    relativePath: "Documents/Bitwig Studio"),
    AppSettingsItem(appName: "REAPER", detail: "Preferences, actions, scripts, themes",
                    relativePath: "Library/Application Support/REAPER"),
    AppSettingsItem(appName: "FL Studio", detail: "User data, presets, templates",
                    relativePath: "Documents/Image-Line"),
    AppSettingsItem(appName: "Studio One", detail: "User presets, templates, scripts",
                    relativePath: "Documents/Studio One"),
    AppSettingsItem(appName: "Pro Tools", detail: "Templates, I/O settings",
                    relativePath: "Documents/Pro Tools"),
    AppSettingsItem(appName: "Cubase & Nuendo", detail: "User content, templates",
                    relativePath: "Documents/Steinberg"),
    AppSettingsItem(appName: "Native Instruments", detail: "User content (Kontakt, Massive X, Komplete Kontrol…)",
                    relativePath: "Documents/Native Instruments"),
]

/// Versioned settings folders: every child of `parent` whose name starts with
/// `prefix` is its own item (e.g. `~/Library/Preferences/Cubase 13`).
let versionedAppSettingsFolders: [(appName: String, parent: String, prefix: String)] = [
    ("Cubase", "Library/Preferences", "Cubase "),
    ("Nuendo", "Library/Preferences", "Nuendo "),
]

/// Where plugin vendors keep settings, presets and authorizations-free state.
/// Each child folder here that matches an installed plugin's manufacturer is
/// offered for sync.
let pluginVendorSettingsParents = [
    "Library/Application Support",
    "Library/Preferences",
    "Documents",
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

/// Everything worth offering for sync on this Mac: known audio apps and
/// versioned DAW preference folders that exist here or in the sync folder,
/// plus vendor folders that match an installed plugin's manufacturer.
/// Does filesystem I/O — call off the main thread.
func discoverAppSettingsItems(home: URL, syncRoot: URL?, pluginManufacturers: [String]) -> [AppSettingsItem] {
    let fm = FileManager.default
    func present(_ relativePath: String) -> Bool {
        let local = home.appendingPathComponent(relativePath)
        if (try? fm.destinationOfSymbolicLink(atPath: local.path)) != nil { return true }
        if fm.fileExists(atPath: local.path) { return true }
        if let syncRoot { return fm.fileExists(atPath: syncRoot.appendingPathComponent(relativePath).path) }
        return false
    }
    /// Child folders (or links to folders) of a home-relative parent, here and
    /// in the sync folder, so a second Mac sees what the first one synced.
    func childFolders(of parent: String) -> Set<String> {
        var names = Set<String>()
        for base in [home, syncRoot].compactMap({ $0 }) {
            let dir = base.appendingPathComponent(parent)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !name.hasPrefix(".") {
                guard !name.contains("pre-sync backup") else { continue }
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir), isDir.boolValue {
                    names.insert(name)
                }
            }
        }
        return names
    }

    var result = knownAppSettingsItems.filter { present($0.relativePath) }
    var seen = Set(result.map(\.id))
    var claimedFolders = Set(knownAppSettingsItems.map(\.id))

    for versioned in versionedAppSettingsFolders {
        for name in childFolders(of: versioned.parent).sorted() where name.hasPrefix(versioned.prefix) {
            let relative = "\(versioned.parent)/\(name)"
            guard seen.insert(relative).inserted else { continue }
            claimedFolders.insert(relative)
            result.append(AppSettingsItem(appName: name, detail: "\(versioned.appName) preferences",
                                          relativePath: relative))
        }
    }

    let manufacturers = Set(pluginManufacturers.filter { !$0.isEmpty })
    var vendorItems: [AppSettingsItem] = []
    for parent in pluginVendorSettingsParents {
        for name in childFolders(of: parent) {
            let relative = "\(parent)/\(name)"
            guard !claimedFolders.contains(relative),
                  let manufacturer = manufacturers.first(where: { vendorFolderMatches(folderName: name, manufacturer: $0) }),
                  seen.insert(relative).inserted else { continue }
            let place = parent == "Documents" ? "Documents" : (parent as NSString).lastPathComponent
            vendorItems.append(AppSettingsItem(appName: manufacturer, detail: "Plugin settings in \(place)",
                                               relativePath: relative, source: .pluginVendor))
        }
    }
    result += vendorItems.sorted {
        ($0.appName.lowercased(), $0.relativePath) < ($1.appName.lowercased(), $1.relativePath)
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
            return "That overlaps the sync folder itself."
        case .nothingToSync:
            return "There's nothing there yet, on this Mac or in the sync folder."
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
/// - Only a local copy (first Mac): it's *moved* into the sync folder, then
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

enum AppSettingsSyncStatus: Equatable {
    /// No provider chosen yet.
    case noProvider
    /// The chosen provider isn't set up on this Mac.
    case providerUnavailable
    /// Nothing on this Mac and nothing in the sync folder — the app probably
    /// isn't installed here.
    case notFound
    /// Not linked. `inCloud` means another Mac already synced it, so linking
    /// will use that copy.
    case notSynced(inCloud: Bool)
    case synced
    /// Linked, but not to where the current provider would put it — usually
    /// left over from another provider choice. Needs manual attention.
    case linkedElsewhere(String)
}

func appSettingsStatus(local: URL, remote: URL) -> AppSettingsSyncStatus {
    let fm = FileManager.default
    if let destPath = try? fm.destinationOfSymbolicLink(atPath: local.path) {
        let existing = URL(fileURLWithPath: destPath).standardizedFileURL.path
        return existing == remote.standardizedFileURL.path ? .synced : .linkedElsewhere(existing)
    }
    let inCloud = fm.fileExists(atPath: remote.path)
    if !inCloud && !fm.fileExists(atPath: local.path) { return .notFound }
    return .notSynced(inCloud: inCloud)
}

// MARK: - Manager

@MainActor
final class AppSettingsSyncManager: ObservableObject {
    @Published private(set) var provider: CloudSyncProvider?
    /// The AudioBunny folder inside the chosen provider, or nil if no provider
    /// is chosen or it isn't set up on this Mac.
    @Published private(set) var syncRoot: URL?
    @Published private(set) var customItems: [AppSettingsItem] = []
    /// Audio apps and plugin vendor folders found on this Mac (or already in
    /// the sync folder). Empty until `discover` has run.
    @Published private(set) var discoveredItems: [AppSettingsItem] = []
    @Published private(set) var hasDiscovered = false
    @Published private(set) var isDiscovering = false
    /// On-disk size of each item's local copy, by item id, filled in after
    /// discovery so the UI can warn before uploading something huge.
    @Published private(set) var sizes: [String: Int64] = [:]
    @Published var lastError: String?
    @Published private(set) var workingIDs: Set<String> = []

    let home: URL
    private let userDefaults: UserDefaults
    private let providerDefaultsKey = "audiobunny.appSettingsSync.provider"
    private let customItemsDefaultsKey = "audiobunny.appSettingsSync.customItems"

    init(userDefaults: UserDefaults = .standard,
         home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.userDefaults = userDefaults
        self.home = home
        if let raw = userDefaults.string(forKey: providerDefaultsKey) {
            provider = CloudSyncProvider(rawValue: raw)
        }
        customItems = (userDefaults.stringArray(forKey: customItemsDefaultsKey) ?? [])
            .map(AppSettingsItem.custom(relativePath:))
        refreshSyncRoot()
    }

    var items: [AppSettingsItem] {
        let discovered = Set(discoveredItems.map(\.id))
        return discoveredItems + customItems.filter { !discovered.contains($0.id) }
    }

    /// Finds every audio app and installed plugin vendor with settings to
    /// sync, then measures them. Pass the manufacturers of every installed
    /// plugin (duplicates are fine).
    func discover(pluginManufacturers: [String]) async {
        refreshSyncRoot()
        isDiscovering = true
        let home = self.home
        let syncRoot = self.syncRoot
        let found = await Task.detached(priority: .userInitiated) {
            discoverAppSettingsItems(home: home, syncRoot: syncRoot, pluginManufacturers: pluginManufacturers)
        }.value
        discoveredItems = found
        hasDiscovered = true
        isDiscovering = false

        let targets = items.map { ($0.id, localURL(for: $0)) }
        sizes = await Task.detached(priority: .utility) {
            Dictionary(targets.map { ($0.0, appSettingsDiskSize($0.1)) }, uniquingKeysWith: { a, _ in a })
        }.value
    }

    /// Re-detects the provider's folder — call when the sync UI appears, since
    /// Dropbox / iCloud Drive may have been set up since launch.
    func refreshSyncRoot() {
        syncRoot = provider?.rootFolder(home: home).map { appSettingsSyncRoot(providerRoot: $0) }
    }

    func isAvailable(_ provider: CloudSyncProvider) -> Bool {
        provider.rootFolder(home: home) != nil
    }

    func chooseProvider(_ newProvider: CloudSyncProvider) {
        provider = newProvider
        userDefaults.set(newProvider.rawValue, forKey: providerDefaultsKey)
        refreshSyncRoot()
    }

    /// Switching providers would strand every existing link (they'd all show
    /// "linked elsewhere"), so the UI locks the choice while anything is synced.
    var hasSyncedItems: Bool {
        items.contains {
            switch status(for: $0) {
            case .synced, .linkedElsewhere: return true
            default: return false
            }
        }
    }

    func localURL(for item: AppSettingsItem) -> URL { item.localURL(home: home) }

    func status(for item: AppSettingsItem) -> AppSettingsSyncStatus {
        guard provider != nil else { return .noProvider }
        guard let syncRoot else { return .providerUnavailable }
        return appSettingsStatus(local: localURL(for: item), remote: item.remoteURL(syncRoot: syncRoot))
    }

    func isWorking(_ item: AppSettingsItem) -> Bool { workingIDs.contains(item.id) }

    @discardableResult
    func addCustomItem(at url: URL) -> Bool {
        guard let relative = homeRelativePath(of: url, home: home) else {
            lastError = AppSettingsSyncError.unsafePath.errorDescription
            return false
        }
        if let syncRoot {
            do {
                try validateAppSettingsPath(url, syncRoot: syncRoot, home: home)
            } catch {
                lastError = error.localizedDescription
                return false
            }
        }
        guard !items.contains(where: { $0.id == relative }) else { return true }
        customItems.append(.custom(relativePath: relative))
        persistCustomItems()
        lastError = nil
        return true
    }

    func removeCustomItem(_ item: AppSettingsItem) {
        customItems.removeAll { $0.id == item.id }
        persistCustomItems()
    }

    private func persistCustomItems() {
        userDefaults.set(customItems.map(\.relativePath), forKey: customItemsDefaultsKey)
    }

    func enableSync(for item: AppSettingsItem) async {
        guard let syncRoot else {
            lastError = "Choose iCloud Drive or Dropbox first."
            return
        }
        let local = localURL(for: item)
        let remote = item.remoteURL(syncRoot: syncRoot)
        let home = self.home
        workingIDs.insert(item.id)
        defer { workingIDs.remove(item.id) }
        do {
            try await Task.detached(priority: .userInitiated) {
                try linkAppSettings(local: local, toSynced: remote, syncRoot: syncRoot, home: home)
            }.value
            lastError = nil
        } catch {
            lastError = "Couldn't sync \(item.appName): \(error.localizedDescription)"
        }
    }

    func disableSync(for item: AppSettingsItem) async {
        let local = localURL(for: item)
        workingIDs.insert(item.id)
        defer { workingIDs.remove(item.id) }
        do {
            try await Task.detached(priority: .userInitiated) {
                try unlinkAppSettings(local: local)
            }.value
            lastError = nil
        } catch {
            lastError = "Couldn't stop syncing \(item.appName): \(error.localizedDescription)"
        }
    }
}
