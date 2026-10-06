import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Preset Sync Sheet

struct PresetSyncSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var presetSyncManager: PresetSyncManager
    @EnvironmentObject var pluginManager: PluginManager
    @State private var targets: [SyncTarget] = []
    @State private var isLoading = false
    @State private var showFolderPicker = false
    @State private var showManualFolderPicker = false
    @State private var addingFolderFor: String?
    @State private var pendingAction: (target: SyncTarget, enabling: Bool)?

    /// Every plugin by name (AU/VST2/VST3 variants share folders), then Ableton Live.
    private var owners: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for plugin in pluginManager.plugins.sorted(by: { $0.name < $1.name })
        where seen.insert(plugin.name.lowercased()).inserted {
            names.append(plugin.name)
        }
        return names + ["Ableton Live"]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync Presets").font(.title3).fontWeight(.semibold)
                    Text("Choose which folders to link to a shared folder so they stay in sync across your Macs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            folderSection
                .padding(16)

            if let error = presetSyncManager.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            Divider()

            if presetSyncManager.syncFolderURL == nil {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 32, weight: .thin))
                        .foregroundStyle(.secondary)
                    Text("Choose a sync folder above to get started.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isLoading && targets.isEmpty {
                ProgressView("Finding plugin folders…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(owners, id: \.self) { owner in
                        Section {
                            let rows = targets.filter { $0.owner == owner }
                            if rows.isEmpty {
                                Text("No folders found").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(rows) { target in
                                PresetSyncTargetRow(target: target, pendingAction: $pendingAction)
                            }
                        } header: {
                            HStack {
                                Text(owner)
                                Spacer()
                                Button("Add Folder…") {
                                    addingFolderFor = owner
                                    showManualFolderPicker = true
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 560, height: 520)
        .task { await reloadTargets() }
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                presetSyncManager.chooseSyncFolder(url)
            }
        }
        .fileImporter(isPresented: $showManualFolderPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result, let owner = addingFolderFor else { return }
            presetSyncManager.addManualFolder(url, owner: owner)
            Task { await reloadTargets() }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            titleVisibility: .visible
        ) {
            if let action = pendingAction {
                Button(action.enabling ? "Sync" : "Stop Syncing", role: action.enabling ? nil : .destructive) {
                    Task {
                        if action.enabling {
                            await presetSyncManager.enableSync(for: action.target)
                        } else {
                            await presetSyncManager.disableSync(for: action.target)
                        }
                        pendingAction = nil
                    }
                }
                Button("Cancel", role: .cancel) { pendingAction = nil }
            }
        } message: {
            if let action = pendingAction {
                Text(action.enabling
                     ? "AudioBunny will move the existing contents of \(action.target.label) (\(action.target.owner)) into the sync folder, keep a backup alongside the original, and replace it with a link. This affects the real app or plugin on this Mac."
                     : "This stops syncing \(action.target.label) (\(action.target.owner)) and copies its contents back into a normal local folder. The sync folder itself is untouched.")
            }
        }
    }

    private var confirmationTitle: String {
        guard let action = pendingAction else { return "" }
        return action.enabling
            ? "Sync \(action.target.label)?"
            : "Stop syncing \(action.target.label)?"
    }

    private func reloadTargets() async {
        isLoading = true
        defer { isLoading = false }
        let plugins = pluginManager.plugins.map { (name: $0.name, manufacturer: $0.manufacturer) }
        let manual = presetSyncManager.manualFolderURLs
        let home = FileManager.default.homeDirectoryForCurrentUser
        targets = await Task.detached(priority: .userInitiated) {
            syncTargets(plugins: plugins, manualFolders: manual, home: home)
        }.value
    }

    @ViewBuilder
    private var folderSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill.badge.gearshape")
                .foregroundStyle(.secondary)
            if let folder = presetSyncManager.syncFolderURL {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sync Folder").font(.caption).foregroundStyle(.secondary)
                    Text(folder.path).font(.callout).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    .buttonStyle(.bordered)
                Button("Change…") { showFolderPicker = true }
                    .buttonStyle(.bordered)
            } else {
                Text("Pick a folder that's already synced by iCloud Drive, Dropbox, or similar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose Folder…") { showFolderPicker = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Per-folder row

struct PresetSyncTargetRow: View {
    @EnvironmentObject var presetSyncManager: PresetSyncManager
    let target: SyncTarget
    @Binding var pendingAction: (target: SyncTarget, enabling: Bool)?

    var body: some View {
        let status = presetSyncManager.status(for: target)
        let working = presetSyncManager.isWorking(target)

        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.label).lineLimit(1)
                Text(target.localURL.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            statusView(status)

            if working {
                ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
            } else {
                switch status {
                case .noSyncFolder:
                    EmptyView()
                case .notSynced:
                    Button("Sync") { pendingAction = (target, true) }
                        .buttonStyle(.bordered)
                case .synced:
                    Button("Unsync") { pendingAction = (target, false) }
                        .buttonStyle(.bordered)
                case .linkedElsewhere:
                    EmptyView()
                }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func statusView(_ status: PresetSyncStatus) -> some View {
        switch status {
        case .noSyncFolder:
            EmptyView()
        case .notSynced:
            Text("Not Synced").font(.caption2).foregroundStyle(.secondary)
        case .synced:
            Label("Synced", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green).labelStyle(.titleAndIcon)
        case .linkedElsewhere(let path):
            Label("Linked elsewhere", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange)
                .help("Currently linked to \(path)")
        }
    }
}
