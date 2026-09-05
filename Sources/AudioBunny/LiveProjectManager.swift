import Foundation

// MARK: - Parsing (free functions, nonisolated, safe to call from Task.detached)

func parseAbletonProject(at url: URL) throws -> LiveProject {
    let xmlData = try decompressAbletonFile(at: url)
    let xmlDoc = try XMLDocument(data: xmlData, options: [])

    var plugins: [LiveProjectPlugin] = []
    var seen = Set<String>()

    func add(name: String, manufacturer: String?, type: PluginType) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let key = "\(type.rawValue)|\(trimmed.lowercased())"
        guard seen.insert(key).inserted else { return }
        plugins.append(LiveProjectPlugin(name: trimmed, manufacturer: manufacturer, type: type))
    }

    for node in (try? xmlDoc.nodes(forXPath: "//VstPluginInfo")) ?? [] {
        guard let el = node as? XMLElement else { continue }
        add(
            name: el.elements(forName: "PlugName").first?.attribute(forName: "Value")?.stringValue ?? "",
            manufacturer: el.elements(forName: "Manufacturer").first?.attribute(forName: "Value")?.stringValue,
            type: .vst2
        )
    }

    for node in (try? xmlDoc.nodes(forXPath: "//Vst3PluginInfo")) ?? [] {
        guard let el = node as? XMLElement else { continue }
        add(
            name: el.elements(forName: "Name").first?.attribute(forName: "Value")?.stringValue ?? "",
            manufacturer: el.elements(forName: "Vendor").first?.attribute(forName: "Value")?.stringValue,
            type: .vst3
        )
    }

    for node in (try? xmlDoc.nodes(forXPath: "//AuPluginInfo")) ?? [] {
        guard let el = node as? XMLElement else { continue }
        add(
            name: el.elements(forName: "Name").first?.attribute(forName: "Value")?.stringValue ?? "",
            manufacturer: el.elements(forName: "Manufacturer").first?.attribute(forName: "Value")?.stringValue,
            type: .audioUnit
        )
    }

    return LiveProject(url: url, plugins: plugins)
}

/// True if `url` lives inside an Ableton "Backup" folder — the timestamped set
/// copies Live writes to `.../Some Project/Backup/Some Project [2024-01-02 …].als`.
/// These aren't projects you actively work on, so `My Projects` skips them
/// unless "Include Backups" is turned on.
func isBackupProjectURL(_ url: URL) -> Bool {
    url.pathComponents.dropLast().contains { $0.caseInsensitiveCompare("Backup") == .orderedSame }
}

/// True if `url` is an iCloud / File-Provider item whose contents aren't on this
/// Mac yet. Reading such a file triggers a full download, so `My Projects` lists
/// it but leaves it unparsed until the user fetches it.
func isCloudPlaceholder(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    ]) else { return false }
    guard values.isUbiquitousItem == true else { return false }
    return values.ubiquitousItemDownloadingStatus == .notDownloaded
}

/// Parses with an overall time budget. decompressAbletonFile already bounds
/// the gunzip step itself, but this is the outer safety net in case parsing
/// as a whole doesn't finish in time — nil means "genuinely failed, skip it"
/// (unchanged prior behavior); a project with `timedOut: true` means "still
/// running after `timeoutSeconds`, but list it rather than silently drop it."
func parseAbletonProjectWithTimeout(at url: URL, timeoutSeconds: Double) async -> LiveProject? {
    switch await withTimeout(seconds: timeoutSeconds, operation: {
        try? await Task.detached { try parseAbletonProject(at: url) }.value
    }) {
    case .completed(let project): return project
    case .timedOut: return LiveProject(url: url, plugins: [], timedOut: true)
    }
}

private func decompressAbletonFile(at url: URL) throws -> Data {
    // Bounded with a timeout+kill (same helper used for VST2 probing): a file
    // on a stalled network mount, or a corrupt/oversized gzip stream, can hang
    // gunzip indefinitely otherwise.
    guard let data = runProcessWithTimeout(
        executable: "/usr/bin/gunzip",
        arguments: ["-c", url.path],
        timeoutSeconds: 60
    ), !data.isEmpty else {
        throw NSError(domain: "LiveProjectManager", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not read \(url.lastPathComponent)"
        ])
    }
    return data
}

// MARK: - Project Folder

struct ProjectFolder: Identifiable {
    let id = UUID()
    let url: URL
    var projects: [LiveProject] = []
    var isScanning = false
    var scanCurrentIndex = 0
    var scanTotalCount = 0
    var scanCurrentFile = ""
    var scanFoundCount = 0

    var name: String { url.lastPathComponent }

    var allUniquePlugins: [LiveProjectPlugin] {
        var seen = Set<String>()
        var result: [LiveProjectPlugin] = []
        for project in projects {
            for plugin in project.plugins {
                let key = "\(plugin.type?.rawValue ?? "")|\(plugin.name.lowercased())"
                if seen.insert(key).inserted { result.append(plugin) }
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func projectCount(for plugin: LiveProjectPlugin) -> Int {
        projects.filter { project in
            project.plugins.contains { p in
                p.name.lowercased() == plugin.name.lowercased() && p.type == plugin.type
            }
        }.count
    }
}

/// Caps simultaneous project parses at 10 *globally*, across every folder —
/// not per folder. Each parse spawns its own gunzip subprocess, and folders
/// are each scanned in their own Task (see LiveProjectManager.rescan/addFolder/
/// init), so without a shared limiter, N folders scanning at once could spawn
/// up to N×10 subprocesses simultaneously. Every parse acquires a slot here
/// before doing any real work and releases it when done; a folder's full file
/// list is enumerated up front (fast, no decompression) and only the actual
/// parsing is throttled.
actor ProjectScanLimiter {
    static let shared = ProjectScanLimiter(maxConcurrent: 10)

    private let maxConcurrent: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
        self.available = maxConcurrent
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Parses a single project's file, waiting for a free global slot first (see
/// `ProjectScanLimiter`) so at most 10 parses run at once across all folders.
private func parseAbletonProjectThrottled(at url: URL) async -> LiveProject? {
    await ProjectScanLimiter.shared.acquire()
    let result = await parseAbletonProjectWithTimeout(at: url, timeoutSeconds: 60)
    await ProjectScanLimiter.shared.release()
    return result
}

// MARK: - Manager

@MainActor
class LiveProjectManager: ObservableObject {
    @Published var folders: [ProjectFolder] = []

    private let savedPathsKey = "audiobunny.projectFolderPaths"
    private let includeBackupsKey = "audiobunny.includeBackupProjects"
    private let userDefaults: UserDefaults

    /// When false (the default), `.als` files inside an Ableton "Backup" folder
    /// are skipped when scanning. Toggling this rescans every folder.
    @Published var includeBackupProjects: Bool {
        didSet {
            guard includeBackupProjects != oldValue else { return }
            userDefaults.set(includeBackupProjects, forKey: includeBackupsKey)
            for folder in folders {
                Task { await rescan(folderID: folder.id) }
            }
        }
    }

    /// - Parameters:
    ///   - userDefaults: injectable for testing; defaults to the app's real defaults.
    ///   - autoRescanOnLaunch: kicks off a background rescan for each restored folder.
    ///     Disabled in tests that only care about persisted paths, not live scan results.
    init(userDefaults: UserDefaults = .standard, autoRescanOnLaunch: Bool = true) {
        self.userDefaults = userDefaults
        self.includeBackupProjects = userDefaults.bool(forKey: includeBackupsKey)
        let paths = userDefaults.stringArray(forKey: savedPathsKey) ?? []
        folders = paths.map { ProjectFolder(url: URL(fileURLWithPath: $0)) }
        guard autoRescanOnLaunch else { return }
        for folder in folders {
            Task { await rescan(folderID: folder.id) }
        }
    }

    func addFolder(_ url: URL) {
        guard !folders.contains(where: { $0.url.path == url.path }) else { return }
        let folder = ProjectFolder(url: url)
        folders.append(folder)
        persistFolders()
        Task { await rescan(folderID: folder.id) }
    }

    func removeFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        persistFolders()
    }

    private func persistFolders() {
        userDefaults.set(folders.map { $0.url.path }, forKey: savedPathsKey)
    }

    func rescan(folderID: UUID) async {
        guard let idx = folders.firstIndex(where: { $0.id == folderID }) else { return }
        let url = folders[idx].url

        folders[idx].isScanning = true
        folders[idx].scanCurrentIndex = 0
        folders[idx].scanTotalCount = 0
        folders[idx].scanFoundCount = 0
        folders[idx].scanCurrentFile = "Finding projects…"
        folders[idx].projects = []

        // First pass: enumerate all .als paths (fast, no decompression), noting
        // which are cloud placeholders that must not be read yet.
        let includeBackups = includeBackupProjects
        let scanned: [(url: URL, cloud: Bool)] = await Task.detached(priority: .userInitiated) {
            var results: [(URL, Bool)] = []
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return results }
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension.lowercased() == "als" else { continue }
                if !includeBackups && isBackupProjectURL(fileURL) { continue }
                results.append((fileURL, isCloudPlaceholder(fileURL)))
            }
            return results
        }.value

        let alsURLs = scanned.map(\.url)
        let cloudURLs = Set(scanned.filter(\.cloud).map(\.url))

        guard let idx2 = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[idx2].scanTotalCount = alsURLs.count - cloudURLs.count

        // Show every discovered project immediately as a placeholder (name known,
        // no plugin data yet), sorted up front — parseable ones start "pending"
        // and fill in below; cloud placeholders are listed as not-downloaded and
        // left alone until the user fetches them.
        folders[idx2].projects = scanned
            .map { LiveProject(url: $0.url, plugins: [], pending: !$0.cloud, notDownloaded: $0.cloud) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Second pass: parse every file, but each parse waits for a free slot
        // on the *global* ProjectScanLimiter (shared across every folder, not
        // just this one) before doing real work, so at most 10 gunzip
        // subprocesses run at once no matter how many folders are scanning
        // simultaneously. All tasks are queued here; the limiter is what
        // actually throttles them.
        var completedCount = 0

        await withTaskGroup(of: (URL, LiveProject?).self) { group in
            for fileURL in alsURLs where !cloudURLs.contains(fileURL) {
                group.addTask {
                    (fileURL, await parseAbletonProjectThrottled(at: fileURL))
                }
            }

            while let (fileURL, result) = await group.next() {
                guard let idx3 = folders.firstIndex(where: { $0.id == folderID }) else {
                    group.cancelAll()
                    return
                }

                completedCount += 1
                folders[idx3].scanCurrentIndex = completedCount
                folders[idx3].scanCurrentFile = fileURL.lastPathComponent

                if let projIdx = folders[idx3].projects.firstIndex(where: { $0.url == fileURL }) {
                    if let project = result {
                        folders[idx3].projects[projIdx].plugins = project.plugins
                        folders[idx3].projects[projIdx].timedOut = project.timedOut
                        folders[idx3].projects[projIdx].pending = false
                        folders[idx3].scanFoundCount += 1
                    } else {
                        // Genuine parse failure (not a timeout) — drop the placeholder,
                        // matching the prior behavior of never listing unparseable files.
                        folders[idx3].projects.remove(at: projIdx)
                    }
                }
            }
        }

        guard let idx5 = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[idx5].isScanning = false
        folders[idx5].scanCurrentFile = ""
    }

    /// Re-parses a single project's .als file in place, preserving its id
    /// (stable for UI selection) while refreshing its plugin data.
    func rescanProject(projectID: UUID) async {
        guard let folderIdx = folders.firstIndex(where: { folder in folder.projects.contains { $0.id == projectID } }),
              let projectIdx = folders[folderIdx].projects.firstIndex(where: { $0.id == projectID }) else { return }
        let url = folders[folderIdx].projects[projectIdx].url

        guard let updated = await parseAbletonProjectThrottled(at: url) else { return }

        // Re-locate in case folders/projects changed while we were awaiting.
        guard let folderIdx2 = folders.firstIndex(where: { folder in folder.projects.contains { $0.id == projectID } }),
              let projectIdx2 = folders[folderIdx2].projects.firstIndex(where: { $0.id == projectID }) else { return }
        folders[folderIdx2].projects[projectIdx2].plugins = updated.plugins
        folders[folderIdx2].projects[projectIdx2].timedOut = updated.timedOut
    }

    /// Pulls a cloud-only project down from iCloud / the File Provider, then
    /// parses it. Bounded — if it hasn't materialised in ~60s the project stays
    /// marked not-downloaded.
    func downloadProject(projectID: UUID) async {
        guard let folderIdx = folders.firstIndex(where: { f in f.projects.contains { $0.id == projectID } }),
              let projIdx = folders[folderIdx].projects.firstIndex(where: { $0.id == projectID }) else { return }
        let url = folders[folderIdx].projects[projIdx].url
        folders[folderIdx].projects[projIdx].pending = true

        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        let downloaded = await Task.detached(priority: .utility) { () -> Bool in
            for _ in 0..<120 {
                if !isCloudPlaceholder(url) { return true }
                try? await Task.sleep(for: .milliseconds(500))
            }
            return !isCloudPlaceholder(url)
        }.value

        guard let fIdx = folders.firstIndex(where: { f in f.projects.contains { $0.id == projectID } }),
              let pIdx = folders[fIdx].projects.firstIndex(where: { $0.id == projectID }) else { return }

        guard downloaded else {
            folders[fIdx].projects[pIdx].pending = false   // still in the cloud
            return
        }
        folders[fIdx].projects[pIdx].notDownloaded = false

        let parsed = await parseAbletonProjectThrottled(at: url)
        guard let fIdx2 = folders.firstIndex(where: { f in f.projects.contains { $0.id == projectID } }),
              let pIdx2 = folders[fIdx2].projects.firstIndex(where: { $0.id == projectID }) else { return }
        folders[fIdx2].projects[pIdx2].plugins = parsed?.plugins ?? []
        folders[fIdx2].projects[pIdx2].timedOut = parsed?.timedOut ?? false
        folders[fIdx2].projects[pIdx2].pending = false
    }

    var isScanning: Bool { folders.contains { $0.isScanning } }

    func project(withID id: UUID) -> LiveProject? {
        for folder in folders {
            if let project = folder.projects.first(where: { $0.id == id }) { return project }
        }
        return nil
    }

    func folder(containing projectID: UUID) -> ProjectFolder? {
        folders.first { folder in folder.projects.contains { $0.id == projectID } }
    }
}
