import Foundation
import AVFoundation

struct SoundFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL

    var name: String { url.deletingPathExtension().lastPathComponent }
    var fileExtension: String { url.pathExtension.uppercased() }
    var parentFolderName: String { url.deletingLastPathComponent().lastPathComponent }

    static func == (lhs: SoundFile, rhs: SoundFile) -> Bool { lhs.url == rhs.url }
}

struct SampleFolder: Identifiable {
    let id = UUID()
    let url: URL
    var samples: [SoundFile] = []
    var isScanning = false

    var name: String { url.lastPathComponent }
}

private let soundFileExtensions: Set<String> = ["wav", "aif", "aiff", "mp3", "m4a", "caf", "flac", "ogg"]

@MainActor
class SampleManager: NSObject, ObservableObject {
    @Published var folders: [SampleFolder] = []
    @Published var currentlyPlayingID: UUID?

    /// The row the user has selected — arrow keys move it (see the `List`
    /// selection binding in SamplesView), and `selectNext`/`selectPrevious`
    /// step it programmatically.
    @Published var selectedID: UUID?

    /// When on, the playing sample repeats until stopped.
    @Published var isLooping = false {
        didSet { player?.numberOfLoops = isLooping ? -1 : 0 }
    }

    /// Tags currently used to narrow the list; a sample is shown only if it
    /// carries *every* active tag.
    @Published var activeTagFilters: Set<String> = []

    /// Sample length in seconds, filled in lazily in the background after a scan.
    @Published private(set) var durations: [URL: TimeInterval] = [:]

    /// Cached waveform peaks per file (see `computeWaveformPeaks`), computed on
    /// demand when a sample is selected or played.
    @Published private(set) var waveforms: [URL: [Float]] = [:]

    /// Playback position (0...1) of the currently playing sample, for the
    /// waveform playhead. 0 when nothing is playing.
    @Published private(set) var playheadFraction: Double = 0

    /// Sample files auditioned this session — the list dims their rows so you
    /// can see what you've already heard while digging. Not persisted.
    @Published private(set) var playedURLs: Set<URL> = []

    /// Absolute paths of source files the user has favorited (a copy also lives
    /// in `favoritesFolderURL`).
    @Published private(set) var favoritedPaths: Set<String> = []

    /// path → user-assigned tags (on top of the auto-detected ones).
    @Published private(set) var manualTagsByPath: [String: Set<String>] = [:]

    private let savedPathsKey = "audiobunny.sampleFolderPaths"
    private let favoritesKey = "audiobunny.sampleFavorites"
    private let tagsKey = "audiobunny.sampleManualTags"
    private let userDefaults: UserDefaults
    private var player: AVAudioPlayer?
    private var durationTask: Task<Void, Never>?
    private var playheadTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?

    /// Ferries a non-Sendable value from a background task back to the main
    /// actor. Safe here: the `AVAudioPlayer` is created on the background task
    /// and only ever touched again on the main actor.
    private struct Handoff<T>: @unchecked Sendable { let value: T }

    /// - Parameters:
    ///   - userDefaults: injectable for testing; defaults to the app's real defaults.
    ///   - autoRescanOnLaunch: kicks off a background scan for each restored folder.
    init(userDefaults: UserDefaults = .standard, autoRescanOnLaunch: Bool = true) {
        self.userDefaults = userDefaults
        super.init()
        favoritedPaths = Set(userDefaults.stringArray(forKey: favoritesKey) ?? [])
        manualTagsByPath = SampleManager.decodeTags(userDefaults.data(forKey: tagsKey))
        let paths = userDefaults.stringArray(forKey: savedPathsKey) ?? []
        folders = paths.map { SampleFolder(url: URL(fileURLWithPath: $0)) }
        guard autoRescanOnLaunch else { return }
        for folder in folders {
            Task { await scan(folderID: folder.id) }
        }
    }

    func addFolder(_ url: URL) {
        guard !folders.contains(where: { $0.url.path == url.path }) else { return }
        let folder = SampleFolder(url: url)
        folders.append(folder)
        persistFolders()
        Task { await scan(folderID: folder.id) }
    }

    func removeFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        persistFolders()
    }

    func rescan(folderID: UUID) {
        Task { await scan(folderID: folderID) }
    }

    func rescanAll() {
        for folder in folders {
            Task { await scan(folderID: folder.id) }
        }
    }

    private func persistFolders() {
        userDefaults.set(folders.map { $0.url.path }, forKey: savedPathsKey)
    }

    private func scan(folderID: UUID) async {
        guard let idx = folders.firstIndex(where: { $0.id == folderID }) else { return }
        let url = folders[idx].url
        folders[idx].isScanning = true

        // Filesystem enumeration is synchronous and can take a moment for large
        // sample libraries; run it off the main actor so the UI stays responsive.
        let found: [SoundFile] = await Task.detached(priority: .userInitiated) {
            var results: [SoundFile] = []
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return results }
            for case let fileURL as URL in enumerator {
                if soundFileExtensions.contains(fileURL.pathExtension.lowercased()) {
                    results.append(SoundFile(url: fileURL))
                }
            }
            return results
        }.value

        guard let idx2 = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[idx2].samples = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        folders[idx2].isScanning = false

        scheduleDurationLoading()
    }

    // MARK: - Duration (loaded one file at a time in the background)

    private func scheduleDurationLoading() {
        durationTask?.cancel()
        let pending = folders.flatMap { $0.samples.map(\.url) }.filter { durations[$0] == nil }
        guard !pending.isEmpty else { return }
        durationTask = Task { [weak self] in
            for fileURL in pending {
                if Task.isCancelled { return }
                let seconds = await Task.detached(priority: .utility) {
                    guard let file = try? AVAudioFile(forReading: fileURL) else { return nil as TimeInterval? }
                    let rate = file.processingFormat.sampleRate
                    guard rate > 0 else { return nil as TimeInterval? }
                    return TimeInterval(file.length) / rate
                }.value
                guard let self, let seconds else { continue }
                self.durations[fileURL] = seconds
            }
        }
    }

    func duration(for sample: SoundFile) -> TimeInterval? { durations[sample.url] }

    // MARK: - Waveform

    func waveform(for sample: SoundFile) -> [Float]? { waveforms[sample.url] }

    /// Computes and caches the waveform for `sample`. The decode/scan runs on a
    /// background (`.utility`) task so it never blocks the UI, and a still-running
    /// computation for a previous selection is cancelled — rapidly arrowing
    /// through the list only ever finishes the waveform you land on.
    func loadWaveform(for sample: SoundFile) {
        let url = sample.url
        if waveforms[url] != nil { return }
        waveformTask?.cancel()
        waveformTask = Task.detached(priority: .utility) { [weak self] in
            guard let peaks = computeWaveformPeaks(url: url), !Task.isCancelled else { return }
            await self?.storeWaveform(peaks, for: url)
        }
    }

    private func storeWaveform(_ peaks: [Float], for url: URL) {
        waveforms[url] = peaks
    }

    // MARK: - Seeking / playhead

    func seek(toFraction fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        playheadFraction = clamped
        guard let player, player.duration > 0 else { return }
        player.currentTime = clamped * player.duration
    }

    private func startPlayheadUpdates() {
        playheadTask?.cancel()
        playheadTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player, player.isPlaying, player.duration > 0 else { return }
                self.playheadFraction = player.currentTime / player.duration
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    // MARK: - Selection / keyboard navigation

    private var orderedSampleIDs: [UUID] { folders.flatMap { $0.samples.map(\.id) } }

    func selectNext() { moveSelection(by: 1) }
    func selectPrevious() { moveSelection(by: -1) }

    private func moveSelection(by delta: Int) {
        let ids = orderedSampleIDs
        guard !ids.isEmpty else { return }
        guard let current = selectedID, let i = ids.firstIndex(of: current) else {
            selectedID = ids.first
            return
        }
        let next = min(max(i + delta, 0), ids.count - 1)
        selectedID = ids[next]
    }

    // MARK: - Playback

    func sample(withID id: UUID?) -> SoundFile? {
        guard let id else { return nil }
        return folders.lazy.flatMap(\.samples).first { $0.id == id }
    }

    /// Starts (or restarts, from the top) playback of `sample`, selecting it and
    /// loading its waveform. This is what a plain selection — single click or the
    /// arrow keys — triggers.
    ///
    /// `AVAudioPlayer` creation (file decode / `prepareToPlay`) is done on a
    /// background task, not the main actor — it can stall for hundreds of ms on
    /// a large file. A short debounce means holding an arrow key to scrub the
    /// list only actually loads the sample you settle on.
    func play(_ sample: SoundFile) {
        selectedID = sample.id
        playedURLs.insert(sample.url)
        loadWaveform(for: sample)
        stop()

        let url = sample.url
        let sampleID = sample.id
        currentlyPlayingID = sampleID          // optimistic — cleared below if it fails to load

        playbackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }

            let handoff: Handoff<AVAudioPlayer>? = await Task.detached(priority: .userInitiated) {
                guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
                player.prepareToPlay()
                return Handoff(value: player)
            }.value

            guard let self, !Task.isCancelled, self.selectedID == sampleID else { return }
            guard let newPlayer = handoff?.value else {
                if self.currentlyPlayingID == sampleID { self.currentlyPlayingID = nil }
                return
            }
            newPlayer.delegate = self
            newPlayer.numberOfLoops = self.isLooping ? -1 : 0
            self.player = newPlayer
            newPlayer.play()
            self.currentlyPlayingID = sampleID
            self.startPlayheadUpdates()
        }
    }

    func hasPlayed(_ sample: SoundFile) -> Bool { playedURLs.contains(sample.url) }

    /// Play/stop toggle for the ▶︎/⏹ buttons.
    func togglePlay(_ sample: SoundFile) {
        if currentlyPlayingID == sample.id {
            stop()
        } else {
            play(sample)
        }
    }

    func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        player?.stop()
        player = nil
        currentlyPlayingID = nil
        playheadTask?.cancel()
        playheadTask = nil
        playheadFraction = 0
    }

    // MARK: - Favorites (copied into a folder on disk)

    var favoritesFolderURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/AudioBunny Favorites", isDirectory: true)
    }

    func isFavorited(_ sample: SoundFile) -> Bool { favoritedPaths.contains(sample.url.path) }

    /// Adds the sample to the favorites folder (copying the file) or removes it
    /// again. The original file is never touched.
    func toggleFavorite(_ sample: SoundFile) {
        let fm = FileManager.default
        if favoritedPaths.contains(sample.url.path) {
            let copy = favoritesCopyURL(for: sample)
            try? fm.removeItem(at: copy)
            favoritedPaths.remove(sample.url.path)
        } else {
            try? fm.createDirectory(at: favoritesFolderURL, withIntermediateDirectories: true)
            let dest = favoritesCopyURL(for: sample)
            if !fm.fileExists(atPath: dest.path) {
                try? fm.copyItem(at: sample.url, to: dest)
            }
            favoritedPaths.insert(sample.url.path)
        }
        userDefaults.set(Array(favoritedPaths).sorted(), forKey: favoritesKey)
    }

    /// Where a favorited sample's copy lives. Prefixed with the parent folder
    /// name so two "Kick.wav"s from different packs don't collide.
    private func favoritesCopyURL(for sample: SoundFile) -> URL {
        let prefix = sample.parentFolderName.replacingOccurrences(of: "/", with: "_")
        return favoritesFolderURL.appendingPathComponent("\(prefix) — \(sample.url.lastPathComponent)")
    }

    // MARK: - Tags

    /// Auto-detected tags (from the filename + parent folder) plus any the user
    /// added by hand, sorted.
    func tags(for sample: SoundFile) -> [String] {
        let auto = autoTags(forFileName: sample.name, parentFolderName: sample.parentFolderName)
        let manual = manualTagsByPath[sample.url.path] ?? []
        return auto.union(manual).sorted()
    }

    func isAutoTag(_ tag: String, for sample: SoundFile) -> Bool {
        autoTags(forFileName: sample.name, parentFolderName: sample.parentFolderName).contains(tag)
    }

    /// Adds or removes a manual tag. Auto-detected tags can't be removed (they'd
    /// just come back on the next scan), only added-to.
    func toggleTag(_ tag: String, for sample: SoundFile) {
        var set = manualTagsByPath[sample.url.path] ?? []
        if set.contains(tag) { set.remove(tag) } else { set.insert(tag) }
        manualTagsByPath[sample.url.path] = set.isEmpty ? nil : set
        persistTags()
    }

    func toggleTagFilter(_ tag: String) {
        if activeTagFilters.contains(tag) { activeTagFilters.remove(tag) }
        else { activeTagFilters.insert(tag) }
    }

    /// The samples in `folder` that pass the active tag filter (all of them when
    /// no filter is set).
    func visibleSamples(in folder: SampleFolder) -> [SoundFile] {
        guard !activeTagFilters.isEmpty else { return folder.samples }
        return folder.samples.filter { activeTagFilters.isSubset(of: Set(tags(for: $0))) }
    }

    private func persistTags() {
        let encodable = manualTagsByPath.mapValues { Array($0).sorted() }
        userDefaults.set(try? JSONEncoder().encode(encodable), forKey: tagsKey)
    }

    private static func decodeTags(_ data: Data?) -> [String: Set<String>] {
        guard let data, let raw = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return raw.mapValues { Set($0) }
    }
}

extension SampleManager: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stop()
        }
    }
}
