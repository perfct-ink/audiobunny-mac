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

/// Publishes the playing sample's 0…1 position on its own object, so the ~30 Hz
/// updates only invalidate the waveform view — not the whole sample list, which
/// observes `SampleManager` as a whole.
@MainActor
final class PlayheadClock: ObservableObject {
    @Published var fraction: Double = 0
}

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

    /// Waveform overviews per file, filled from the on-disk `WaveformCache` or
    /// computed on demand when a sample is selected or played.
    @Published private(set) var waveforms: [URL: Waveform] = [:]

    /// The playing sample's 0...1 position. On its own object so the ~30 Hz
    /// updates only re-render the waveform bar, never the (potentially huge)
    /// sample list, which observes `SampleManager` as a whole.
    let playhead = PlayheadClock()

    /// Vocabulary tags that actually occur in the scanned library — recomputed
    /// only when folders or manual tags change, not per render.
    @Published private(set) var availableTags: [String] = []

    /// Sample files auditioned this session — the list dims their rows so you
    /// can see what you've already heard while digging. Not persisted.
    @Published private(set) var playedURLs: Set<URL> = []

    /// Absolute paths of source files the user has favorited (a copy also lives
    /// in `favoritesFolderURL`).
    @Published private(set) var favoritedPaths: Set<String> = []

    /// path → user-assigned tags (on top of the auto-detected ones).
    @Published private(set) var manualTagsByPath: [String: Set<String>] = [:]

    /// Files whose tags couldn't be written to disk as Finder Tags this session
    /// (read-only volume, network share, …) — they still work fully in
    /// AudioBunny, this just surfaces that the file itself wasn't updated.
    @Published private(set) var finderTagSyncErrorCount = 0

    private let savedPathsKey = "audiobunny.sampleFolderPaths"
    private let favoritesKey = "audiobunny.sampleFavorites"
    private let tagsKey = "audiobunny.sampleManualTags"
    private let userDefaults: UserDefaults
    private var player: AVAudioPlayer?
    private var durationTask: Task<Void, Never>?
    private var playheadTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var prewarmTask: Task<Void, Never>?
    private var autoPlayTask: Task<Void, Never>?
    private var finderTagSyncTask: Task<Void, Never>?

    /// Auto-tags per sample, computed once per scan instead of per render.
    private var autoTagsByURL: [URL: Set<String>] = [:]
    /// Waveforms produced by the background pre-warm, merged into `waveforms` in
    /// batches (see `stageWaveform`) so processing a big library doesn't
    /// re-render the list once per file.
    private var stagedWaveforms: [URL: Waveform] = [:]
    private var waveformFlushTask: Task<Void, Never>?

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
        rebuildTagIndex()
        prewarmWaveforms()
        finderTagSyncTask?.cancel()
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

    private struct ScanResult: Sendable {
        var samples: [SoundFile]
        /// Vocabulary Finder Tags already present on disk for each file — read
        /// during the same enumeration pass (the keys are prefetched, so this is
        /// free), used to hydrate `manualTagsByPath` below.
        var existingVocabTagsByURL: [URL: Set<String>]
    }

    private func scan(folderID: UUID) async {
        guard let idx = folders.firstIndex(where: { $0.id == folderID }) else { return }
        let url = folders[idx].url
        folders[idx].isScanning = true

        // Filesystem enumeration is synchronous and can take a moment for large
        // sample libraries; run it off the main actor so the UI stays responsive.
        let result: ScanResult = await Task.detached(priority: .userInitiated) {
            var samples: [SoundFile] = []
            var tagsByURL: [URL: Set<String>] = [:]
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .tagNamesKey],
                options: [.skipsHiddenFiles]
            ) else { return ScanResult(samples: samples, existingVocabTagsByURL: tagsByURL) }
            for case let fileURL as URL in enumerator {
                guard soundFileExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
                samples.append(SoundFile(url: fileURL))
                let vocab = vocabularyFinderTags(at: fileURL)
                if !vocab.isEmpty { tagsByURL[fileURL] = vocab }
            }
            return ScanResult(samples: samples, existingVocabTagsByURL: tagsByURL)
        }.value

        guard let idx2 = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[idx2].samples = result.samples.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        folders[idx2].isScanning = false

        hydrateManualTags(from: result.existingVocabTagsByURL)
        rebuildTagIndex()
        scheduleDurationLoading()
        prewarmWaveforms()
        syncAllFinderTags()
    }

    /// Absorbs vocabulary Finder Tags already on disk (set by a previous run,
    /// by hand in Finder, or synced in from another Mac) into the manual-tag
    /// store, so they aren't lost and don't cause a redundant write later.
    private func hydrateManualTags(from tagsByURL: [URL: Set<String>]) {
        guard !tagsByURL.isEmpty else { return }
        var changed = false
        for (fileURL, fileTags) in tagsByURL {
            let auto = autoTags(forFileName: fileURL.deletingPathExtension().lastPathComponent,
                                parentFolderName: fileURL.deletingLastPathComponent().lastPathComponent)
            let extra = fileTags.subtracting(auto)
            guard !extra.isEmpty else { continue }
            let path = fileURL.path
            var set = manualTagsByPath[path] ?? []
            let before = set
            set.formUnion(extra)
            if set != before { manualTagsByPath[path] = set; changed = true }
        }
        if changed { persistTags() }
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

    func waveform(for sample: SoundFile) -> Waveform? {
        waveforms[sample.url] ?? stagedWaveforms[sample.url]
    }

    private func hasWaveform(_ url: URL) -> Bool {
        waveforms[url] != nil || stagedWaveforms[url] != nil
    }

    /// Loads the waveform for `sample` right now — from the persistent
    /// `WaveformCache` when it's there, otherwise computed and cached. Runs on a
    /// background (`.utility`, ahead of the pre-warm) task so it never blocks the
    /// UI, and a still-running job for a previous selection is cancelled.
    func loadWaveform(for sample: SoundFile) {
        let url = sample.url
        if hasWaveform(url) { return }
        waveformTask?.cancel()
        waveformTask = Task.detached(priority: .utility) { [weak self] in
            if let cached = await WaveformCache.shared.load(sourceURL: url) {
                await self?.storeWaveform(cached, for: url)
                return
            }
            guard let waveform = computeWaveform(url: url) else { return }
            await WaveformCache.shared.store(waveform, sourceURL: url)
            await self?.storeWaveform(waveform, for: url)
        }
    }

    /// Immediate publish — the selected sample's waveform, which the user is
    /// waiting on.
    private func storeWaveform(_ waveform: Waveform, for url: URL) {
        stagedWaveforms[url] = nil
        waveforms[url] = waveform
    }

    /// Batched publish — pre-warmed waveforms are merged into `waveforms` at
    /// ~2 Hz so a big library doesn't re-render the list once per file.
    private func stageWaveform(_ waveform: Waveform, for url: URL) {
        guard waveforms[url] == nil else { return }
        stagedWaveforms[url] = waveform
        guard waveformFlushTask == nil else { return }
        waveformFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            self.waveformFlushTask = nil
            guard !self.stagedWaveforms.isEmpty else { return }
            self.waveforms.merge(self.stagedWaveforms) { current, _ in current }
            self.stagedWaveforms.removeAll()
        }
    }

    /// Computes (and persists) a waveform for every scanned sample, one at a
    /// time at background priority. Cache hits are near-free; misses fill the
    /// disk cache so a later click is instant, and rows can show their waveform
    /// without being selected first.
    private func prewarmWaveforms() {
        prewarmTask?.cancel()
        let urls = folders.flatMap { $0.samples.map(\.url) }
        guard !urls.isEmpty else { return }
        prewarmTask = Task { [weak self] in
            for url in urls {
                if Task.isCancelled { return }
                guard let self else { return }
                if self.hasWaveform(url) { continue }
                let waveform = await Task.detached(priority: .background) { () -> Waveform? in
                    if let cached = await WaveformCache.shared.load(sourceURL: url) { return cached }
                    guard let computed = computeWaveform(url: url) else { return nil }
                    await WaveformCache.shared.store(computed, sourceURL: url)
                    return computed
                }.value
                if let waveform { self.stageWaveform(waveform, for: url) }
            }
        }
    }

    /// Removes every persisted waveform and re-runs the pre-warm.
    func clearWaveformCache() {
        Task {
            await WaveformCache.shared.clear()
            waveforms.removeAll()
            stagedWaveforms.removeAll()
            prewarmWaveforms()
        }
    }

    // MARK: - Seeking / playhead

    func seek(toFraction fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        playhead.fraction = clamped
        guard let player, player.duration > 0 else { return }
        player.currentTime = clamped * player.duration
    }

    private func startPlayheadUpdates() {
        playheadTask?.cancel()
        playheadTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player, player.isPlaying, player.duration > 0 else { return }
                self.playhead.fraction = player.currentTime / player.duration
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

    /// Called whenever `selectedID` changes via a click or the arrow keys.
    /// Moving the selection itself is instant — the row highlight updates the
    /// moment `selectedID` is set — but this defers actually loading/playing
    /// the newly-selected sample for a beat, so holding an arrow key to skim
    /// the list only ever loads the one you settle on rather than tearing down
    /// and re-creating a player (plus re-triggering waveform loads) for every
    /// sample flown past.
    func scheduleAutoPlay(for sample: SoundFile) {
        autoPlayTask?.cancel()
        autoPlayTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled, self.selectedID == sample.id else { return }
            self.play(sample)
        }
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
        autoPlayTask?.cancel()
        autoPlayTask = nil
        playbackTask?.cancel()
        playbackTask = nil
        if let current = player {
            player = nil
            // Tearing down an AVAudioPlayer can stall briefly; do it off-main.
            let boxed = Handoff(value: current)
            Task.detached(priority: .utility) { boxed.value.stop() }
        }
        currentlyPlayingID = nil
        playheadTask?.cancel()
        playheadTask = nil
        playhead.fraction = 0
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

    /// Auto-tags for `sample`, from the per-scan index (falling back to a live
    /// compute for samples added outside `scan`, e.g. in tests).
    private func cachedAutoTags(for sample: SoundFile) -> Set<String> {
        autoTagsByURL[sample.url]
            ?? autoTags(forFileName: sample.name, parentFolderName: sample.parentFolderName)
    }

    private func allTags(for sample: SoundFile) -> Set<String> {
        cachedAutoTags(for: sample).union(manualTagsByPath[sample.url.path] ?? [])
    }

    /// Auto-detected tags plus any the user added by hand, sorted.
    func tags(for sample: SoundFile) -> [String] {
        allTags(for: sample).sorted()
    }

    func isAutoTag(_ tag: String, for sample: SoundFile) -> Bool {
        cachedAutoTags(for: sample).contains(tag)
    }

    /// Adds or removes a manual tag. Auto-detected tags can't be removed (they'd
    /// just come back on the next scan), only added-to.
    func toggleTag(_ tag: String, for sample: SoundFile) {
        var set = manualTagsByPath[sample.url.path] ?? []
        if set.contains(tag) { set.remove(tag) } else { set.insert(tag) }
        manualTagsByPath[sample.url.path] = set.isEmpty ? nil : set
        persistTags()
        refreshAvailableTags()
        Task { await syncFinderTagsNow(for: sample, priority: .utility) }
    }

    func toggleTagFilter(_ tag: String) {
        if activeTagFilters.contains(tag) { activeTagFilters.remove(tag) }
        else { activeTagFilters.insert(tag) }
    }

    /// The samples in `folder` that pass the active tag filter (all of them when
    /// no filter is set).
    func visibleSamples(in folder: SampleFolder) -> [SoundFile] {
        guard !activeTagFilters.isEmpty else { return folder.samples }
        return folder.samples.filter { activeTagFilters.isSubset(of: allTags(for: $0)) }
    }

    /// Rebuilds the auto-tag index for every scanned sample. Called after a scan
    /// or a folder removal — not per render.
    private func rebuildTagIndex() {
        var index: [URL: Set<String>] = [:]
        for folder in folders {
            for sample in folder.samples {
                index[sample.url] = autoTags(forFileName: sample.name,
                                             parentFolderName: sample.parentFolderName)
            }
        }
        autoTagsByURL = index
        refreshAvailableTags()
    }

    private func refreshAvailableTags() {
        var present = Set<String>()
        for tags in autoTagsByURL.values { present.formUnion(tags) }
        for tags in manualTagsByPath.values { present.formUnion(tags) }
        availableTags = sampleTagVocabulary.filter { present.contains($0) }
    }

    private func persistTags() {
        let encodable = manualTagsByPath.mapValues { Array($0).sorted() }
        userDefaults.set(try? JSONEncoder().encode(encodable), forKey: tagsKey)
    }

    // MARK: - Finder Tags sync (mirrors auto + manual tags onto the file itself)

    /// Writes every sample's current tag set (auto + manual) onto its file as
    /// Finder Tags, one file at a time at background priority. A file whose
    /// Finder Tags already match is skipped (no-op), so a rescan only ever
    /// writes what actually changed. Foreign Finder Tags the user already had
    /// on a file (anything outside our vocabulary) are always preserved.
    private func syncAllFinderTags() {
        finderTagSyncTask?.cancel()
        let samples = folders.flatMap(\.samples)
        guard !samples.isEmpty else { return }
        finderTagSyncTask = Task { [weak self] in
            for sample in samples {
                if Task.isCancelled { return }
                guard let self else { return }
                await self.syncFinderTagsNow(for: sample, priority: .background)
            }
        }
    }

    /// Syncs a single sample's tags to disk right away — used for the write-
    /// through when the user changes a tag by hand, and by `syncAllFinderTags`
    /// for the full-library pass after a scan.
    private func syncFinderTagsNow(for sample: SoundFile, priority: TaskPriority) async {
        let desired = allTags(for: sample)
        let url = sample.url
        let failed = await Task.detached(priority: priority) { () -> Bool in
            do {
                _ = try syncFinderTags(desired: desired, at: url)
                return false
            } catch {
                return true
            }
        }.value
        if failed { finderTagSyncErrorCount += 1 }
    }

    /// Clears the "couldn't write tags to N files" banner.
    func dismissFinderTagSyncErrors() {
        finderTagSyncErrorCount = 0
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
