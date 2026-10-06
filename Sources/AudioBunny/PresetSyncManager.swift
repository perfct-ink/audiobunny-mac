import Foundation

// MARK: - Pure helpers (no I/O side effects beyond what's explicitly documented)

/// Where a plugin keeps the presets *you* save from inside it — the real,
/// vendor-defined directory. (Not the same as `PresetManager`'s
/// `presetDirectory`, which is a folder AudioBunny owns for its own catalog
/// downloads.) Known per-vendor layouts first, falling back to Apple's
/// standard `~/Library/Audio/Presets/<manufacturer>/<plugin>`, which many AU
/// hosts — and some VST hosts' preset browsers — honor too.
func vendorPresetDirectory(pluginName: String, manufacturer: String) -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let lower = pluginName.lowercased()
    if lower.contains("serum") {
        return home.appendingPathComponent("Documents/Xfer/Serum Presets/Presets")
    }
    if lower.contains("guitar rig") {
        return home.appendingPathComponent("Documents/Native Instruments/Guitar Rig 7/Presets")
    }
    return home.appendingPathComponent("Library/Audio/Presets/\(manufacturer)/\(pluginName)")
}

/// Identifies a plugin for sync purposes independent of format — the AU and
/// VST3 builds of the same instrument share one preset folder and must share
/// one sync identity.
func presetSyncKey(pluginName: String, manufacturer: String) -> String {
    "\(manufacturer)|\(pluginName)".lowercased()
}

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
            return "This plugin's presets aren't currently synced."
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

    // The parent usually already exists (that's where the real folder was), but
    // for a plugin whose preset directory has never been created — common for
    // the Apple-standard fallback location — it won't, and createSymbolicLink
    // requires it to.
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

// MARK: - Manager

/// A plugin as far as preset sync cares: just enough to derive its preset
/// folder and identity, decoupled from `AudioPlugin`/format variants.
struct SyncablePlugin: Identifiable, Hashable {
    let name: String
    let manufacturer: String
    var id: String { presetSyncKey(pluginName: name, manufacturer: manufacturer) }
}

enum PresetSyncStatus: Equatable {
    /// No sync folder has been chosen yet.
    case noSyncFolder
    /// Not linked — the plugin's preset folder (if any) is still local-only.
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

    private let userDefaults: UserDefaults
    private let folderDefaultsKey = "audiobunny.presetSyncFolder"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let path = userDefaults.string(forKey: folderDefaultsKey) {
            syncFolderURL = URL(fileURLWithPath: path)
        }
    }

    func chooseSyncFolder(_ url: URL) {
        syncFolderURL = url
        userDefaults.set(url.path, forKey: folderDefaultsKey)
    }

    func localDirectory(for plugin: SyncablePlugin) -> URL {
        vendorPresetDirectory(pluginName: plugin.name, manufacturer: plugin.manufacturer)
    }

    /// Where this plugin's presets live inside the sync folder. Named after the
    /// plugin (not its lowercased key) so it reads sensibly in Finder.
    func remoteDirectory(for plugin: SyncablePlugin) -> URL? {
        guard let syncFolderURL else { return nil }
        let name = "\(plugin.manufacturer) — \(plugin.name)".replacingOccurrences(of: "/", with: "-")
        return syncFolderURL.appendingPathComponent(name)
    }

    func status(for plugin: SyncablePlugin) -> PresetSyncStatus {
        guard let remote = remoteDirectory(for: plugin) else { return .noSyncFolder }
        let local = localDirectory(for: plugin)
        if let destPath = try? FileManager.default.destinationOfSymbolicLink(atPath: local.path) {
            let existing = URL(fileURLWithPath: destPath).standardizedFileURL.path
            return existing == remote.standardizedFileURL.path ? .synced : .linkedElsewhere(existing)
        }
        return .notSynced
    }

    func isWorking(_ plugin: SyncablePlugin) -> Bool { workingKeys.contains(plugin.id) }

    func enableSync(for plugin: SyncablePlugin) async {
        guard let remote = remoteDirectory(for: plugin) else {
            lastError = "Choose a sync folder first."
            return
        }
        let local = localDirectory(for: plugin)
        workingKeys.insert(plugin.id)
        defer { workingKeys.remove(plugin.id) }
        do {
            try await Task.detached(priority: .userInitiated) {
                try linkPresetDirectory(local: local, toSynced: remote)
            }.value
            lastError = nil
        } catch {
            lastError = "Couldn't sync \(plugin.name) presets: \(error.localizedDescription)"
        }
    }

    func disableSync(for plugin: SyncablePlugin) async {
        let local = localDirectory(for: plugin)
        workingKeys.insert(plugin.id)
        defer { workingKeys.remove(plugin.id) }
        do {
            try await Task.detached(priority: .userInitiated) {
                try unlinkPresetDirectory(local: local)
            }.value
            lastError = nil
        } catch {
            lastError = "Couldn't stop syncing \(plugin.name) presets: \(error.localizedDescription)"
        }
    }
}
