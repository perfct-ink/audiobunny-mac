import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct SamplesView: View {
    @EnvironmentObject var sampleManager: SampleManager
    @State private var showFolderPicker = false

    private var anySamples: Bool {
        sampleManager.folders.contains { !$0.samples.isEmpty }
    }

    private var selectedSample: SoundFile? {
        sampleManager.sample(withID: sampleManager.selectedID)
    }

    var body: some View {
        VStack(spacing: 0) {
            TabActionBar(title: "My Samples") {
                Toggle(isOn: $sampleManager.isLooping) {
                    Label("Loop", systemImage: "repeat")
                }
                .toggleStyle(.button)
                .help("Repeat the playing sample until stopped")

                if !sampleManager.folders.isEmpty {
                    Button {
                        try? FileManager.default.createDirectory(
                            at: sampleManager.favoritesFolderURL, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([sampleManager.favoritesFolderURL])
                    } label: {
                        Label("Favorites", systemImage: "heart")
                    }
                    .help("Show the favorites folder in Finder")

                    Button(action: sampleManager.rescanAll) {
                        Label("Rescan All", systemImage: "arrow.clockwise")
                    }
                    .disabled(sampleManager.folders.contains { $0.isScanning })
                    .help("Rescan all sample folders")
                }
                Button {
                    showFolderPicker = true
                } label: {
                    Label("Add Folder…", systemImage: "folder.badge.plus")
                }

                Menu {
                    Button("Clear Waveform Cache", role: .destructive) {
                        sampleManager.clearWaveformCache()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .help("More")
            }

            if sampleManager.finderTagSyncErrorCount > 0 {
                FinderTagSyncErrorBanner()
                Divider()
            }

            if anySamples {
                SampleTagFilterBar()
                Divider()
            }

            HStack(spacing: 0) {
                content

                if let sample = selectedSample {
                    Divider()
                    SampleInspector(playhead: sampleManager.playhead, sample: sample)
                        .frame(width: 320)
                }
            }
        }
        .background {
            // Spacebar toggles play/pause on the selected sample (there are no
            // text fields on this tab).
            Button("") {
                if let sample = selectedSample {
                    sampleManager.togglePlay(sample)
                } else {
                    sampleManager.stop()
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onChange(of: sampleManager.selectedID) { id in
            // Selecting a sample — a click or the arrow keys — plays it, after
            // a short debounce (see `scheduleAutoPlay`) so the selection/
            // highlight itself never waits on loading.
            guard let sample = sampleManager.sample(withID: id),
                  id != sampleManager.currentlyPlayingID else { return }
            sampleManager.scheduleAutoPlay(for: sample)
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls { sampleManager.addFolder(url) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if sampleManager.folders.isEmpty {
            LiveEmptyView(
                icon: "waveform.circle",
                title: "No Folders Added",
                message: "Click \"Add Folder…\" to scan one or more directories for sound files."
            )
            .frame(maxWidth: .infinity)
        } else {
            List(selection: $sampleManager.selectedID) {
                ForEach(sampleManager.folders) { folder in
                    let visible = sampleManager.visibleSamples(in: folder)
                    Section {
                        if folder.isScanning && folder.samples.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 14, height: 14)
                                Text("Scanning…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else if folder.samples.isEmpty {
                            Text("No supported audio files found")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if visible.isEmpty {
                            Text("No samples match the active tag filter")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(visible) { sample in
                                SampleRow(sample: sample, folderURL: folder.url)
                                    .tag(sample.id)
                            }
                        }
                    } header: {
                        SampleFolderHeader(folder: folder)
                    }
                }
            }
            .listStyle(.inset)
            .frame(maxWidth: .infinity)
            .onMoveCommand { direction in
                switch direction {
                case .up:   sampleManager.selectPrevious()
                case .down: sampleManager.selectNext()
                default:    break
                }
            }
        }
    }
}

// MARK: - Finder Tag sync error banner

struct FinderTagSyncErrorBanner: View {
    @EnvironmentObject var sampleManager: SampleManager

    var body: some View {
        let count = sampleManager.finderTagSyncErrorCount
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Couldn't save tags to the file on disk for \(count) sample\(count == 1 ? "" : "s") — probably a read-only or network volume. Tags still work fully in AudioBunny.")
                .font(.caption)
            Spacer()
            Button("Dismiss") { sampleManager.dismissFinderTagSyncErrors() }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }
}

// MARK: - Tag filter bar

struct SampleTagFilterBar: View {
    @EnvironmentObject var sampleManager: SampleManager

    var body: some View {
        let tags = sampleManager.availableTags   // precomputed on scan, not per render
        if tags.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        let on = sampleManager.activeTagFilters.contains(tag)
                        Button {
                            sampleManager.toggleTagFilter(tag)
                        } label: {
                            Text(tag)
                                .font(.caption).fontWeight(.medium)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(on ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12))
                                .foregroundStyle(on ? Color.accentColor : Color.primary)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(on ? Color.accentColor : .clear, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    if !sampleManager.activeTagFilters.isEmpty {
                        Button("Clear") { sampleManager.activeTagFilters.removeAll() }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
    }
}

// MARK: - Folder Section Header

struct SampleFolderHeader: View {
    @EnvironmentObject var sampleManager: SampleManager
    let folder: SampleFolder
    @State private var isHovering = false

    var body: some View {
        HStack {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
            Text(folder.name)
                .fontWeight(.medium)
            Spacer()
            if folder.isScanning {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 14, height: 14)
            } else if isHovering {
                HStack(spacing: 10) {
                    Button {
                        sampleManager.rescan(folderID: folder.id)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Rescan this folder")

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([folder.url])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .help("Show in Finder")

                    Button {
                        sampleManager.removeFolder(folder.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("Remove folder")
                }
                .foregroundStyle(.secondary)
            } else if !folder.samples.isEmpty {
                Text("\(folder.samples.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onHover { isHovering = $0 }
    }
}

// MARK: - Sample Row

struct SampleRow: View {
    @EnvironmentObject var sampleManager: SampleManager
    let sample: SoundFile
    /// The scanned root this sample was found under, so the row can show where
    /// it sits relative to that root rather than a long absolute path.
    var folderURL: URL? = nil

    private var isPlaying: Bool { sampleManager.currentlyPlayingID == sample.id }
    private var isFavorited: Bool { sampleManager.isFavorited(sample) }
    private var hasPlayed: Bool { sampleManager.hasPlayed(sample) }

    /// Sub-directory of the sample within the scanned folder (e.g. "Drums/808"),
    /// or an abbreviated absolute directory if we don't have the root. Empty when
    /// the file sits directly in the scanned folder.
    private var locationText: String {
        let dir = sample.url.deletingLastPathComponent()
        if let root = folderURL {
            let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
            if dir.path == root.path { return "" }
            if dir.path.hasPrefix(rootPath) { return String(dir.path.dropFirst(rootPath.count)) }
        }
        return dir.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                sampleManager.togglePlay(sample)
            } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                    .font(.title3)
                    .foregroundStyle(isPlaying ? Color.accentColor : .secondary)
                    .frame(width: 22)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(sample.name)
                    .lineLimit(1)
                    .foregroundStyle(hasPlayed && !isPlaying ? .secondary : .primary)
                if !locationText.isEmpty {
                    Text(locationText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(sample.url.path)
                }
            }

            Spacer(minLength: 8)

            // Inline waveform once it's been loaded (usually by the background
            // pre-warm). Coarse resolution + a single fill keeps scrolling smooth.
            if let waveform = sampleManager.waveform(for: sample) {
                WaveformView(waveform: waveform, resolution: 3)
                    .frame(width: 84, height: 20)
                    .allowsHitTesting(false)
            }

            if let duration = sampleManager.duration(for: sample) {
                Text(formatSampleDuration(duration))
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Button {
                sampleManager.toggleFavorite(sample)
            } label: {
                Image(systemName: isFavorited ? "heart.fill" : "heart")
                    .foregroundStyle(isFavorited ? .pink : .secondary)
            }
            .buttonStyle(.plain)
            .help(isFavorited ? "Remove from favorites folder" : "Copy to favorites folder")

            Text(sample.fileExtension)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .listRowBackground(hasPlayed ? Color.secondary.opacity(0.07) : nil as Color?)
        .contextMenu {
            Button(isFavorited ? "Remove from Favorites" : "Add to Favorites") {
                sampleManager.toggleFavorite(sample)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([sample.url])
            }
        }
    }
}

// MARK: - Selected-sample inspector (right sidebar)

struct SampleInspector: View {
    @EnvironmentObject var sampleManager: SampleManager
    @ObservedObject var playhead: PlayheadClock
    let sample: SoundFile

    private var isPlaying: Bool { sampleManager.currentlyPlayingID == sample.id }
    private var isFavorited: Bool { sampleManager.isFavorited(sample) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                transport
                waveform
                if let duration = sampleManager.duration(for: sample) {
                    LabeledContent("Length", value: formatSampleDuration(duration))
                        .font(.callout)
                }
                Divider()
                tagEditor
            }
            .padding(16)
        }
        .frame(maxHeight: .infinity)
        .background(.bar)
        .onAppear { sampleManager.loadWaveform(for: sample) }
        .onChange(of: sample.id) { _ in sampleManager.loadWaveform(for: sample) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(sample.name)
                .font(.headline)
                .lineLimit(2)
            Text(sample.url.deletingLastPathComponent().path
                .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(sample.url.path)
        }
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button {
                sampleManager.togglePlay(sample)
            } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(isPlaying ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            Button {
                sampleManager.isLooping.toggle()
            } label: {
                Image(systemName: "repeat")
                    .foregroundStyle(sampleManager.isLooping ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(sampleManager.isLooping ? "Looping — click to turn off" : "Loop the sample")

            Button {
                sampleManager.toggleFavorite(sample)
            } label: {
                Image(systemName: isFavorited ? "heart.fill" : "heart")
                    .foregroundStyle(isFavorited ? .pink : .secondary)
            }
            .buttonStyle(.plain)
            .help(isFavorited ? "Remove from favorites folder" : "Copy to favorites folder")

            Spacer()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([sample.url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Show in Finder")
        }
    }

    private var waveform: some View {
        WaveformView(
            waveform: sampleManager.waveform(for: sample),
            playhead: isPlaying ? playhead.fraction : nil,
            onScrub: { sampleManager.seek(toFraction: $0) }
        )
        .frame(height: 64)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private var tagEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags").font(.subheadline).fontWeight(.semibold)
            let current = Set(sampleManager.tags(for: sample))
            FlowLayout(spacing: 6) {
                ForEach(sampleTagVocabulary, id: \.self) { tag in
                    let auto = sampleManager.isAutoTag(tag, for: sample)
                    let on = current.contains(tag)
                    Button {
                        if !auto { sampleManager.toggleTag(tag, for: sample) }
                    } label: {
                        HStack(spacing: 3) {
                            if auto { Image(systemName: "sparkles").font(.system(size: 8)) }
                            Text(tag).font(.caption)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(on ? Color.accentColor.opacity(auto ? 0.15 : 0.28)
                                       : Color.secondary.opacity(0.12),
                                    in: Capsule())
                        .foregroundStyle(on ? Color.accentColor : Color.primary)
                        .overlay(Capsule().stroke(on ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(auto)
                    .help(auto ? "Auto-detected from the name or folder"
                              : (on ? "Remove tag" : "Add tag"))
                }
            }
            Text("Sparkled tags are detected automatically. Tags are also saved as Finder Tags on the file, so Finder and Spotlight see them too.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
