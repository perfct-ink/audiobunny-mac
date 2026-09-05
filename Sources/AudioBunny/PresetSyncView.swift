import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Preset Sync Sheet

struct PresetSyncSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var presetSyncManager: PresetSyncManager
    @EnvironmentObject var pluginManager: PluginManager
    @State private var showFolderPicker = false
    @State private var pendingAction: (plugin: SyncablePlugin, enabling: Bool)?

    /// Every installed plugin, deduplicated across its AU/VST2/VST3 variants —
    /// preset sync is per-plugin, not per-format.
    private var syncablePlugins: [SyncablePlugin] {
        var seen = Set<String>()
        var result: [SyncablePlugin] = []
        for plugin in pluginManager.plugins.sorted(by: { $0.name < $1.name }) {
            let p = SyncablePlugin(name: plugin.name, manufacturer: plugin.manufacturer)
            if seen.insert(p.id).inserted { result.append(p) }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync Presets").font(.title3).fontWeight(.semibold)
                    Text("Link plugin preset folders to a shared folder so they stay in sync across your Macs.")
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
            } else if syncablePlugins.isEmpty {
                Text("No plugins found — scan My Plugins first.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(syncablePlugins) { plugin in
                    PresetSyncPluginRow(plugin: plugin, pendingAction: $pendingAction)
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 560, height: 480)
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                presetSyncManager.chooseSyncFolder(url)
            }
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
                            await presetSyncManager.enableSync(for: action.plugin)
                        } else {
                            await presetSyncManager.disableSync(for: action.plugin)
                        }
                        pendingAction = nil
                    }
                }
                Button("Cancel", role: .cancel) { pendingAction = nil }
            }
        } message: {
            if let action = pendingAction {
                Text(action.enabling
                     ? "AudioBunny will move \(action.plugin.name)'s existing presets into the sync folder (keeping a backup alongside the original folder) and replace it with a link. This affects the real plugin, on this Mac."
                     : "This stops syncing \(action.plugin.name)'s presets and copies them back into a normal local folder. The sync folder itself is untouched.")
            }
        }
    }

    private var confirmationTitle: String {
        guard let action = pendingAction else { return "" }
        return action.enabling ? "Sync \(action.plugin.name) presets?" : "Stop syncing \(action.plugin.name) presets?"
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

// MARK: - Per-plugin row

struct PresetSyncPluginRow: View {
    @EnvironmentObject var presetSyncManager: PresetSyncManager
    let plugin: SyncablePlugin
    @Binding var pendingAction: (plugin: SyncablePlugin, enabling: Bool)?

    var body: some View {
        let status = presetSyncManager.status(for: plugin)
        let working = presetSyncManager.isWorking(plugin)

        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name).lineLimit(1)
                Text(presetSyncManager.localDirectory(for: plugin).path)
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
                    Button("Sync") { pendingAction = (plugin, true) }
                        .buttonStyle(.bordered)
                case .synced:
                    Button("Unsync") { pendingAction = (plugin, false) }
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
