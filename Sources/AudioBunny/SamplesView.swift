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
        guard let id = sampleManager.selectedID else { return nil }
        return sampleManager.folders.lazy.flatMap(\.samples).first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabActionBar(title: "Samples") {
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
            }

            if anySamples {
                SampleTagFilterBar()
                Divider()
            }

            content

            if let sample = selectedSample {
                Divider()
                SampleWaveformBar(sample: sample)
            }
        }
        .onChange(of: sampleManager.selectedID) { id in
            // Selecting a sample — a click or the arrow keys — plays it.
            guard let sample = sampleManager.sample(withID: id),
                  id != sampleManager.currentlyPlayingID else { return }
            sampleManager.play(sample)
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

// MARK: - Tag filter bar

struct SampleTagFilterBar: View {
    @EnvironmentObject var sampleManager: SampleManager

    /// Only vocabulary tags that actually occur in the scanned library.
    private var availableTags: [String] {
        var present = Set<String>()
        for folder in sampleManager.folders {
            for sample in folder.samples {
                present.formUnion(sampleManager.tags(for: sample))
            }
        }
        return sampleTagVocabulary.filter { present.contains($0) }
    }

    var body: some View {
        let tags = availableTags
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
                let tags = sampleManager.tags(for: sample)
                if !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tags.prefix(6), id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer()

            // Show the waveform inline once it's been computed (for the selected
            // sample, in the bar below) — never triggers a compute from here.
            if let peaks = sampleManager.waveform(for: sample) {
                WaveformView(peaks: peaks)
                    .frame(width: 96, height: 22)
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
            Menu("Tags") {
                let current = Set(sampleManager.tags(for: sample))
                ForEach(sampleTagVocabulary, id: \.self) { tag in
                    let auto = sampleManager.isAutoTag(tag, for: sample)
                    Toggle(auto ? "\(tag) (auto)" : tag, isOn: Binding(
                        get: { current.contains(tag) },
                        set: { _ in sampleManager.toggleTag(tag, for: sample) }
                    ))
                    .disabled(auto)
                }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([sample.url])
            }
        }
    }
}

// MARK: - Waveform bar (selected sample, with scrubbable playhead)

struct SampleWaveformBar: View {
    @EnvironmentObject var sampleManager: SampleManager
    let sample: SoundFile

    var body: some View {
        let isPlaying = sampleManager.currentlyPlayingID == sample.id
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Button {
                    sampleManager.togglePlay(sample)
                } label: {
                    Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(isPlaying ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)

                Button {
                    sampleManager.isLooping.toggle()
                } label: {
                    Image(systemName: "repeat")
                        .font(.callout)
                        .foregroundStyle(sampleManager.isLooping ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(sampleManager.isLooping ? "Looping — click to turn off" : "Loop the sample")

                Text(sample.name)
                    .font(.callout)
                    .lineLimit(1)

                Spacer()

                if let duration = sampleManager.duration(for: sample) {
                    Text(formatSampleDuration(duration))
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            WaveformView(
                peaks: sampleManager.waveform(for: sample) ?? [],
                playhead: isPlaying ? sampleManager.playheadFraction : nil,
                onScrub: { sampleManager.seek(toFraction: $0) }
            )
            .frame(height: 46)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear { sampleManager.loadWaveform(for: sample) }
        .onChange(of: sample.id) { _ in sampleManager.loadWaveform(for: sample) }
    }
}
