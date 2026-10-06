import Foundation

// MARK: - Pure helpers (no I/O side effects beyond what's explicitly documented)

/// Guards every sync filesystem operation: the path must sit under the user's
/// home folder (never home itself, never something outside it) — so a
/// malformed plugin name can never point a symlink swap somewhere unintended.
func isSafeSyncDirectory(_ url: URL) -> Bool {
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(home + "/") else { return false }
    return !path.dropFirst(home.count + 1).isEmpty
}

enum PresetSyncError: LocalizedError, Equatable {
    case unsafePath
    case unexpectedFile
    case alreadyLinkedElsewhere(String)
    case notLinked

    var errorDescription: String? {
        switch self {
        case .unsafePath:
            return "That folder isn't somewhere AudioBunny will touch."
        case .unexpectedFile:
            return "A file (not a folder) is already there — move it aside and try again."
        case .alreadyLinkedElsewhere(let path):
            return "Already linked to \(path) — remove that link by hand first."
        case .notLinked:
            return "This folder isn't currently synced."
        }
    }
}

/// Replaces `localDir` with a symlink to `remoteDir`, so both point at one
/// synced folder shared across machines:
///
/// - If `localDir` already links to `remoteDir`, this is a no-op.
/// - If `localDir` links elsewhere, it refuses — the caller must remove that
///   link by hand first, never something this function does automatically.
/// - If `localDir` is a real folder, its contents are merged into `remoteDir`
///   (a name collision keeps whichever file was modified more recently), and
///   the *original* folder is renamed aside as a timestamped backup — never
///   deleted — before the symlink is created in its place.
func linkPresetDirectory(local localDir: URL, toSynced remoteDir: URL) throws {
    let fm = FileManager.default
    guard isSafeSyncDirectory(localDir), isSafeSyncDirectory(remoteDir) else {
        throw PresetSyncError.unsafePath
    }

    if let existingDestPath = try? fm.destinationOfSymbolicLink(atPath: localDir.path) {
        let existing = URL(fileURLWithPath: existingDestPath).standardizedFileURL.path
        if existing == remoteDir.standardizedFileURL.path { return }
        throw PresetSyncError.alreadyLinkedElsewhere(existing)
    }

    try fm.createDirectory(at: remoteDir, withIntermediateDirectories: true)

    var isDir: ObjCBool = false
    let exists = fm.fileExists(atPath: localDir.path, isDirectory: &isDir)
    if exists && !isDir.boolValue { throw PresetSyncError.unexpectedFile }

    if exists {
        let localItems = (try? fm.contentsOfDirectory(
            at: localDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for item in localItems {
            let dest = remoteDir.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                let localDate = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let destDate = (try? dest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard let localDate, let destDate, localDate > destDate else { continue }
                try? fm.removeItem(at: dest)
                try? fm.copyItem(at: item, to: dest)
            } else {
                try? fm.copyItem(at: item, to: dest)
            }
        }
        let backup = localDir.deletingLastPathComponent()
            .appendingPathComponent("\(localDir.lastPathComponent) (pre-sync backup \(presetSyncBackupTimestamp()))")
        try fm.moveItem(at: localDir, to: backup)
    }

    try fm.createDirectory(at: localDir.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: localDir, withDestinationURL: remoteDir)
}

/// Reverses `linkPresetDirectory`: removes the symlink (never touching what it
/// points at) and copies the synced folder's contents back into a real local
/// folder, so the plugin keeps working normally, disconnected from the sync
/// folder.
func unlinkPresetDirectory(local localDir: URL) throws {
    let fm = FileManager.default
    guard isSafeSyncDirectory(localDir) else { throw PresetSyncError.unsafePath }
    guard let destPath = try? fm.destinationOfSymbolicLink(atPath: localDir.path) else {
        throw PresetSyncError.notLinked
    }
    try fm.removeItem(at: localDir) // removes the symlink itself, not its target
    try fm.copyItem(at: URL(fileURLWithPath: destPath), to: localDir)
}

func presetSyncBackupTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HHmmss"
    return formatter.string(from: Date())
}

// MARK: - Finding folders

/// Vendor layouts we know about, checked before any searching. Relative to `home`.
private func knownFolderPaths(pluginName: String, manufacturer: String) -> [String] {
    let name = pluginName.lowercased()
    var paths: [String] = []
    if name.contains("serum") {
        paths.append("Documents/Xfer/Serum Presets/Presets")
    }
    if manufacturer.lowercased().contains("native instruments") {
        paths.append("Documents/Native Instruments/\(pluginName)")
        paths.append("Documents/Native Instruments/User Content/\(pluginName)")
        paths.append("Library/Application Support/Native Instruments/\(pluginName)")
    }
    if name.contains("reason") {
        paths.append("Music/Reason Studios/User Library")
    }
    paths.append("Library/Audio/Presets/\(manufacturer)/\(pluginName)")
    return paths
}

/// Folders on this Mac that hold a plugin's user content: known vendor layouts,
/// then anything under the usual user-content roots whose name matches the
/// plugin (or sits under a folder named for its manufacturer). Only folders that
/// actually exist are returned.
func locatePluginFolders(pluginName: String, manufacturer: String, home: URL) -> [URL] {
    let fm = FileManager.default
    var found: [URL] = []
    var seen = Set<String>()
    func add(_ url: URL) {
        guard isDirectory(url), seen.insert(url.standardizedFileURL.path).inserted else { return }
        found.append(url)
    }

    for relative in knownFolderPaths(pluginName: pluginName, manufacturer: manufacturer) {
        add(home.appendingPathComponent(relative))
    }

    let needle = pluginName.lowercased()
    let maker = manufacturer.lowercased()
    guard needle.count >= 3 else { return found }
    let roots = ["Documents", "Music", "Library/Application Support", "Library/Audio/Presets"]
    for root in roots {
        for child in subdirectories(of: home.appendingPathComponent(root), fm: fm) {
            let childName = child.lastPathComponent.lowercased()
            if childName.contains(needle) {
                add(child)
            } else if maker.count >= 3, childName.contains(maker) {
                for grandchild in subdirectories(of: child, fm: fm)
                where grandchild.lastPathComponent.lowercased().contains(needle) {
                    add(grandchild)
                }
            }
        }
    }
    // Linking a parent would swallow the more specific folder inside it, so
    // keep only the innermost matches.
    return found.filter { candidate in
        let path = candidate.standardizedFileURL.path
        return !found.contains { $0.standardizedFileURL.path.hasPrefix(path + "/") }
    }
}

/// Each folder inside Ableton's User Library (Presets, Samples, Grooves, …).
func abletonUserLibraryFolders(home: URL) -> [URL] {
    subdirectories(of: home.appendingPathComponent("Music/Ableton/User Library"), fm: .default)
        .filter { $0.lastPathComponent != "Ableton Project Info" }
}

private func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
}

/// Visible, non-"conflicted copy" subfolders of `url`, sorted by name.
private func subdirectories(of url: URL, fm: FileManager) -> [URL] {
    guard let items = try? fm.contentsOfDirectory(
        at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
    return items
        .filter { isDirectory($0) && !$0.lastPathComponent.localizedCaseInsensitiveContains("conflicted") }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

// MARK: - Manager

/// One folder that can be synced, shown under the plugin (or app) it belongs to.
struct SyncTarget: Identifiable, Hashable, Sendable {
    let owner: String
    let localURL: URL
    var id: String { localURL.standardizedFileURL.path }
    var label: String { localURL.lastPathComponent }
    /// Where this folder lives inside the sync folder, named so it reads sensibly in Finder.
    var remoteName: String { "\(owner) — \(label)".replacingOccurrences(of: "/", with: "-") }
}

/// Every syncable folder on this Mac: each plugin's located folders (plus any
/// the user added by hand) and Ableton Live's User Library folders.
func syncTargets(plugins: [(name: String, manufacturer: String)],
                 manualFolders: [String: [URL]],
                 home: URL) -> [SyncTarget] {
    var seen = Set<String>()
    var targets: [SyncTarget] = []
    func add(_ target: SyncTarget) {
        if seen.insert(target.id).inserted { targets.append(target) }
    }

    var namesSeen = Set<String>()
    for plugin in plugins where namesSeen.insert(plugin.name.lowercased()).inserted {
        for url in locatePluginFolders(pluginName: plugin.name, manufacturer: plugin.manufacturer, home: home) {
            add(SyncTarget(owner: plugin.name, localURL: url))
        }
        for url in manualFolders[plugin.name] ?? [] {
            add(SyncTarget(owner: plugin.name, localURL: url))
        }
    }
    for url in abletonUserLibraryFolders(home: home) {
        add(SyncTarget(owner: "Ableton Live", localURL: url))
    }
    return targets.sorted {
        let byOwner = $0.owner.localizedStandardCompare($1.owner)
        return byOwner == .orderedSame
            ? $0.label.localizedStandardCompare($1.label) == .orderedAscending
            : byOwner == .orderedAscending
    }
}

enum PresetSyncStatus: Equatable {
    /// No sync folder has been chosen yet.
    case noSyncFolder
    /// Not linked — the folder is still local-only.
    case notSynced
    /// Linked to the expected folder inside the chosen sync folder.
    case synced
    /// Linked, but to somewhere other than the current sync folder — probably
    /// left over from a different sync folder choice. Needs manual attention.
    case linkedElsewhere(String)
}

@MainActor
final class PresetSyncManager: ObservableObject {
    @Published var syncFolderURL: URL?
    @Published var lastError: String?
    @Published private(set) var workingKeys: Set<String> = []
    @Published private(set) var manualFolders: [String: [String]] = [:]

    private let userDefaults: UserDefaults
    private let folderDefaultsKey = "audiobunny.presetSyncFolder"
    private let manualFoldersDefaultsKey = "audiobunny.presetSyncManualFolders"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let path = userDefaults.string(forKey: folderDefaultsKey) {
            syncFolderURL = URL(fileURLWithPath: path)
        }
        manualFolders = userDefaults.dictionary(forKey: manualFoldersDefaultsKey) as? [String: [String]] ?? [:]
    }

    func chooseSyncFolder(_ url: URL) {
        syncFolderURL = url
        userDefaults.set(url.path, forKey: folderDefaultsKey)
    }

    func addManualFolder(_ url: URL, owner: String) {
        var paths = manualFolders[owner] ?? []
        guard !paths.contains(url.path) else { return }
        paths.append(url.path)
        manualFolders[owner] = paths
        userDefaults.set(manualFolders, forKey: manualFoldersDefaultsKey)
    }

    var manualFolderURLs: [String: [URL]] {
        manualFolders.mapValues { $0.map { URL(fileURLWithPath: $0) } }
    }

    /// Where this folder goes inside the sync folder.
    func remoteDirectory(for target: SyncTarget) -> URL? {
        syncFolderURL?.appendingPathComponent(target.remoteName)
    }

    func status(for target: SyncTarget) -> PresetSyncStatus {
        guard let remote = remoteDirectory(for: target) else { return .noSyncFolder }
        if let destPath = try? FileManager.default.destinationOfSymbolicLink(atPath: target.localURL.path) {
            let existing = URL(fileURLWithPath: destPath).standardizedFileURL.path
            return existing == remote.standardizedFileURL.path ? .synced : .linkedElsewhere(existing)
        }
        return .notSynced
    }

    func isWorking(_ target: SyncTarget) -> Bool { workingKeys.contains(target.id) }

    func enableSync(for target: SyncTarget) async {
        guard let remote = remoteDirectory(for: target) else {
            lastError = "Choose a sync folder first."
            return
        }
        let local = target.localURL
        workingKeys.insert(target.id)
        defer { workingKeys.remove(target.id) }
        do {
            try await Task.detached(priority: .userInitiated) {
                try linkPresetDirectory(local: local, toSynced: remote)
            }.value
            lastError = nil
        } catch {
            lastError = "Couldn't sync \(target.label) (\(target.owner)): \(error.localizedDescription)"
        }
    }

    func disableSync(for target: SyncTarget) async {
        let local = target.localURL
        workingKeys.insert(target.id)
        defer { workingKeys.remove(target.id) }
        do {
            try await Task.detached(priority: .userInitiated) {
                try unlinkPresetDirectory(local: local)
            }.value
            lastError = nil
        } catch {
            lastError = "Couldn't stop syncing \(target.label) (\(target.owner)): \(error.localizedDescription)"
        }
    }
}
