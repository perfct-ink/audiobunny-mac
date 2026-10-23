import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Manager

/// Result of a preset install, shown once it finishes.
struct PresetInstallSummary: Identifiable, Equatable {
    let id = UUID()
    var installed = 0
    var alreadyInstalled = 0
    /// Plugin name → presets installed (or already there) for it.
    var perPlugin: [String: Int] = [:]
    /// Each plugin's preset folder that received files, for "Show in Finder".
    var folders: [URL] = []
    var failures: [String] = []
}

/// Handles files dropped onto the window: plugin bundles open in their own
/// window with an Install button (PluginManager.openBundle); presets are matched to installed plugins and copied into
/// each plugin's preset folder. If every preset matched, they install right
/// away; otherwise the review sheet lets the user pick plugins first.
@MainActor
final class DropInstallManager: ObservableObject {
    /// Presets waiting on the review sheet (some couldn't be matched).
    @Published var review: [PresetInstallItem]?
    @Published private(set) var candidates: [PresetPluginCandidate] = []
    @Published var summary: PresetInstallSummary?
    @Published private(set) var isWorking = false
    /// Shown when a drop had nothing AudioBunny can install.
    @Published var nothingToInstall: String?

    private var extractionRoot: URL?
    private let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    func handleDrop(_ urls: [URL], pluginManager: PluginManager) {
        guard !urls.isEmpty, !isWorking else { return }
        isWorking = true
        Task {
            // Matching needs the plugin list; at launch the first scan may still be running.
            while pluginManager.isScanning { try? await Task.sleep(for: .milliseconds(300)) }
            let scanned = pluginManager.plugins.map { plugin in
                (name: plugin.name, manufacturer: plugin.manufacturer, type: plugin.type,
                 fileURL: plugin.fileURL,
                 auCodes: plugin.audioComponentDescription.map {
                     AUCodeKey(type: auCodeString($0.componentType),
                               subtype: auCodeString($0.componentSubType),
                               manufacturer: auCodeString($0.componentManufacturer))
                 })
            }
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AudioBunny-drop-\(UUID().uuidString)", isDirectory: true)
            let (candidates, dropped) = await Task.detached(priority: .userInitiated) {
                let candidates = presetCandidates(from: scanned)
                return (candidates, collectDroppedFiles(urls, plugins: candidates, extractionRoot: root))
            }.value
            cleanUpExtraction()
            extractionRoot = root
            self.candidates = candidates.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            isWorking = false

            for bundle in dropped.pluginBundles { pluginManager.openBundle(at: bundle) }

            if dropped.presets.isEmpty {
                if dropped.pluginBundles.isEmpty {
                    nothingToInstall = "AudioBunny installs plugins (.component, .vst, .vst3) and presets (\(presetFileExtensions.sorted().map { "." + $0 }.joined(separator: ", "))). Nothing it recognizes was in what you dropped."
                }
                cleanUpExtraction()
            } else if dropped.presets.allSatisfy({ $0.plugin != nil }) {
                install(dropped.presets)
            } else {
                review = dropped.presets
            }
        }
    }

    func setPlugin(_ plugin: PresetPluginCandidate?, for itemID: UUID) {
        guard let index = review?.firstIndex(where: { $0.id == itemID }) else { return }
        review?[index].plugin = plugin
    }

    /// Sets the plugin on every unmatched preset in the review at once.
    func setPluginForUnmatched(_ plugin: PresetPluginCandidate) {
        guard var items = review else { return }
        for index in items.indices where items[index].plugin == nil { items[index].plugin = plugin }
        review = items
    }

    func destination(for item: PresetInstallItem) -> URL? {
        try? presetDestination(for: item, home: home)
    }

    func cancelReview() {
        // Also called when the sheet closes after Install, which already
        // cleared the review and still needs the extracted files.
        guard review != nil else { return }
        review = nil
        cleanUpExtraction()
    }

    /// Installs every item that has a plugin; the rest are skipped.
    func install(_ items: [PresetInstallItem]) {
        review = nil
        isWorking = true
        let home = home
        Task {
            let summary = await Task.detached(priority: .userInitiated) {
                var summary = PresetInstallSummary()
                var folders = Set<String>()
                for item in items {
                    guard let plugin = item.plugin else { continue }
                    do {
                        switch try installPresetFile(item, home: home) {
                        case .installed: summary.installed += 1
                        case .alreadyInstalled: summary.alreadyInstalled += 1
                        }
                        summary.perPlugin[plugin.name, default: 0] += 1
                        let folder = presetInstallFolder(for: plugin, fileExtension: item.source.pathExtension, home: home)
                        if folders.insert(folder.path).inserted { summary.folders.append(folder) }
                    } catch {
                        summary.failures.append("\(item.source.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                return summary
            }.value
            cleanUpExtraction()
            isWorking = false
            self.summary = summary
        }
    }

    private func cleanUpExtraction() {
        if let root = extractionRoot { try? FileManager.default.removeItem(at: root) }
        extractionRoot = nil
    }
}

/// File URLs from a SwiftUI drop's item providers.
func loadDroppedFileURLs(_ providers: [NSItemProvider]) async -> [URL] {
    var urls: [URL] = []
    for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        let url: URL? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
        if let url, url.isFileURL { urls.append(url) }
    }
    return urls
}

// MARK: - Window drop target

/// Makes the view accept dropped files (highlighting while dragged over) and
/// hosts the review sheet, result sheet and errors for them.
struct DropInstallTarget: ViewModifier {
    @EnvironmentObject var dropManager: DropInstallManager
    @EnvironmentObject var pluginManager: PluginManager
    @State private var isTargeted = false
    var onDrop: () -> Void = {}

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                Task { @MainActor in
                    let urls = await loadDroppedFileURLs(providers)
                    onDrop()
                    dropManager.handleDrop(urls, pluginManager: pluginManager)
                }
                return true
            }
            .overlay {
                if isTargeted {
                    DropTargetOverlay()
                } else if dropManager.isWorking {
                    ProgressView("Installing…")
                        .padding(20)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
                }
            }
            .sheet(isPresented: Binding(
                get: { dropManager.review != nil },
                set: { if !$0 { dropManager.cancelReview() } }
            )) {
                PresetDropReviewSheet()
                    .environmentObject(dropManager)
            }
            .sheet(item: $dropManager.summary) { summary in
                PresetInstallSummarySheet(summary: summary) { dropManager.summary = nil }
            }
            .alert(
                "Nothing to Install",
                isPresented: Binding(
                    get: { dropManager.nothingToInstall != nil },
                    set: { if !$0 { dropManager.nothingToInstall = nil } }
                ),
                presenting: dropManager.nothingToInstall
            ) { _ in
                Button("OK") { dropManager.nothingToInstall = nil }
            } message: { message in
                Text(message)
            }
    }
}

// MARK: - Drop overlay

/// Shown over the whole window while files are dragged over it.
struct DropTargetOverlay: View {
    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.08)
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                .padding(10)
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
                Text("Drop to install")
                    .font(.title2.weight(.semibold))
                Text("Plugins open with an Install button. Presets go to the plugin they belong to.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - First-launch hint

/// A one-time banner telling new users they can drop plugins and presets onto
/// the window. Dismissing it (or doing a first drop) hides it for good.
struct DropInstallHint: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Drag plugins and presets into this window to install them")
                    .fontWeight(.semibold)
                Text("Plugins (.component, .vst, .vst3) open with an Install button. Presets, folders and .zip packs are matched to the plugin they belong to and put where it looks for them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Got It", action: onDismiss)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.1))
    }
}

// MARK: - Review sheet

/// Lists dropped presets with the plugin each was matched to; unmatched ones
/// get a picker. Install copies everything that has a plugin.
struct PresetDropReviewSheet: View {
    @EnvironmentObject var dropManager: DropInstallManager

    var body: some View {
        let items = dropManager.review ?? []
        let unmatched = items.filter { $0.plugin == nil }.count
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Install \(items.count) Preset\(items.count == 1 ? "" : "s")")
                    .font(.title2.weight(.semibold))
                Text(unmatched == 0
                     ? "Each preset will be copied into its plugin's preset folder."
                     : "AudioBunny couldn't tell which plugin \(unmatched == 1 ? "1 preset belongs" : "\(unmatched) presets belong") to. Pick one, or leave it on Skip.")
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            if unmatched > 1, !dropManager.candidates.isEmpty {
                HStack {
                    Text("Set all unmatched to:")
                    Menu("Choose Plugin") {
                        ForEach(dropManager.candidates) { plugin in
                            Button(plugin.name) { dropManager.setPluginForUnmatched(plugin) }
                        }
                    }
                    .fixedSize()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }

            Divider()
            List(items) { item in
                row(item)
            }
            .frame(minHeight: 260)
            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dropManager.cancelReview() }
                    .keyboardShortcut(.cancelAction)
                Button("Install") { dropManager.install(items) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(items.allSatisfy { $0.plugin == nil })
            }
            .padding(16)
        }
        .frame(width: 680, height: 500)
    }

    private func row(_ item: PresetInstallItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.source.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let dest = dropManager.destination(for: item) {
                    Text(dest.deletingLastPathComponent().path
                        .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer()
            Picker("", selection: Binding(
                get: { item.plugin },
                set: { dropManager.setPlugin($0, for: item.id) }
            )) {
                Text("Skip").tag(PresetPluginCandidate?.none)
                Divider()
                ForEach(dropManager.candidates) { plugin in
                    Text(plugin.name).tag(Optional(plugin))
                }
            }
            .labelsHidden()
            .frame(width: 200)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Result sheet

struct PresetInstallSummarySheet: View {
    let summary: PresetInstallSummary
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: summary.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(summary.failures.isEmpty ? Color.green : Color.orange)

            if !summary.perPlugin.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(summary.perPlugin.keys.sorted(), id: \.self) { name in
                        Text("\(name): \(summary.perPlugin[name]!) preset\(summary.perPlugin[name]! == 1 ? "" : "s")")
                    }
                }
            }
            if summary.alreadyInstalled > 0 {
                Text("\(summary.alreadyInstalled) \(summary.alreadyInstalled == 1 ? "was" : "were") already installed and left as is.")
                    .foregroundStyle(.secondary)
            }
            if !summary.failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(summary.failures, id: \.self) { Text($0).font(.caption) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }

            HStack {
                if !summary.folders.isEmpty {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(summary.folders)
                    }
                }
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var title: String {
        let total = summary.installed + summary.alreadyInstalled
        if total == 0 { return "No presets installed" }
        return "Installed \(total) preset\(total == 1 ? "" : "s")"
    }
}
