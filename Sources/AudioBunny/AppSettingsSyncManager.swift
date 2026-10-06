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
    let appName: String
    let detail: String
    let relativePath: String
    var isCustom = false

    var id: String { relativePath }

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
                        isCustom: true)
    }
}

/// Music apps whose settings live in a folder that's safe to symlink as a
/// whole: user content and preferences, not licenses or machine-specific
/// caches. Anything else can be added by hand.
let knownAppSettingsItems: [AppSettingsItem] = [
    AppSettingsItem(appName: "Ableton Live", detail: "User Library (presets, templates, defaults)",
                    relativePath: "Music/Ableton/User Library"),
    AppSettingsItem(appName: "Logic Pro & MainStage", detail: "Patches, channel strips, key commands, templates",
                    relativePath: "Music/Audio Music Apps"),
    AppSettingsItem(appName: "Bitwig Studio", detail: "Library, templates, controller scripts",
                    relativePath: "Documents/Bitwig Studio"),
    AppSettingsItem(appName: "REAPER", detail: "Preferences, actions, scripts, themes",
                    relativePath: "Library/Application Support/REAPER"),
]

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
        let known = Set(knownAppSettingsItems.map(\.id))
        return knownAppSettingsItems + customItems.filter { !known.contains($0.id) }
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
        items.contains { status(for: $0) == .synced }
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
