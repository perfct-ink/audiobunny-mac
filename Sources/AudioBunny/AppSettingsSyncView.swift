import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - App Settings Sync Sheet

struct AppSettingsSyncSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var syncManager: AppSettingsSyncManager
    @EnvironmentObject var pluginManager: PluginManager
    @State private var showItemPicker = false
    @State private var pendingAction: (item: AppSettingsItem, enabling: Bool, inCloud: Bool)?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync App Settings").font(.title3).fontWeight(.semibold)
                    Text("Move your audio apps' and plugins' settings into iCloud Drive or Dropbox and link them back, so every Mac shares one copy.")
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

            providerSection
                .padding(16)

            if let error = syncManager.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            Divider()

            if syncManager.syncRoot == nil {
                VStack(spacing: 8) {
                    Image(systemName: "icloud.and.arrow.up")
                        .font(.system(size: 32, weight: .thin))
                        .foregroundStyle(.secondary)
                    Text(syncManager.provider == nil
                         ? "Choose iCloud Drive or Dropbox above to get started."
                         : "\(syncManager.provider!.displayName) isn't set up on this Mac.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !syncManager.hasDiscovered {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Looking for audio app and plugin settings…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    itemSection("Audio Apps", source: .audioApp)
                    itemSection("Plugins", source: .pluginVendor)
                    itemSection("Added by You", source: .custom)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Text("Preference plists and sandboxed apps can't be synced this way — macOS replaces the links.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Add Folder or File…") { showItemPicker = true }
                    .buttonStyle(.bordered)
                    .disabled(syncManager.syncRoot == nil)
            }
            .padding(12)
        }
        .frame(width: 620, height: 520)
        // Re-runs when the provider (and so its folder) changes, so items
        // another Mac already synced show up here, and when a plugin scan
        // finishes while the sheet is open.
        .task(id: "\(syncManager.syncRoot?.path ?? "")|\(pluginManager.plugins.count)") {
            await syncManager.discover(pluginManufacturers: pluginManager.plugins.map(\.manufacturer))
        }
        .fileImporter(isPresented: $showItemPicker, allowedContentTypes: [.folder, .item]) { result in
            if case .success(let url) = result {
                syncManager.addCustomItem(at: url)
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
                            await syncManager.enableSync(for: action.item)
                        } else {
                            await syncManager.disableSync(for: action.item)
                        }
                        pendingAction = nil
                    }
                }
                Button("Cancel", role: .cancel) { pendingAction = nil }
            }
        } message: {
            if let action = pendingAction {
                Text(confirmationMessage(action))
            }
        }
    }

    @ViewBuilder
    private func itemSection(_ title: String, source: AppSettingsItem.Source) -> some View {
        let sectionItems = syncManager.items.filter { $0.source == source }
        if !sectionItems.isEmpty {
            Section(title) {
                ForEach(sectionItems) { item in
                    AppSettingsSyncRow(item: item, pendingAction: $pendingAction)
                }
            }
        }
    }

    private var confirmationTitle: String {
        guard let action = pendingAction else { return "" }
        return action.enabling ? "Sync \(action.item.appName) settings?" : "Stop syncing \(action.item.appName) settings?"
    }

    private func confirmationMessage(_ action: (item: AppSettingsItem, enabling: Bool, inCloud: Bool)) -> String {
        let provider = syncManager.provider?.displayName ?? "the sync folder"
        if !action.enabling {
            return "This copies \(action.item.appName)'s settings back into a normal local folder on this Mac. The copy in \(provider) is untouched, so your other Macs keep syncing. Quit \(action.item.appName) first."
        }
        if action.inCloud {
            return "Another Mac already synced \(action.item.appName). This Mac will switch to those settings; its current ones are kept as a backup next to the original. Quit \(action.item.appName) first."
        }
        var message = "AudioBunny will move \(action.item.appName)'s settings into \(provider) and leave a link in their place. Quit \(action.item.appName) first."
        if let size = syncManager.sizes[action.item.id], size >= largeItemBytes {
            message += " This is \(formattedSize(size)), all of which will upload to \(provider)."
        }
        return message
    }

    @ViewBuilder
    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Sync with").foregroundStyle(.secondary)
                Picker("Sync with", selection: Binding(
                    get: { syncManager.provider },
                    set: { if let p = $0 { syncManager.chooseProvider(p) } }
                )) {
                    ForEach(CloudSyncProvider.allCases) { provider in
                        Text(provider.displayName).tag(Optional(provider))
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 240)
                .disabled(!syncManager.hasDiscovered || syncManager.hasSyncedItems)
                .help(syncManager.hasSyncedItems ? "Stop syncing everything first to switch." : "")
                Spacer()
                if let root = syncManager.syncRoot {
                    Button("Reveal") {
                        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([root])
                    }
                    .buttonStyle(.bordered)
                }
            }
            if let root = syncManager.syncRoot {
                Text(root.path)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            } else if let provider = syncManager.provider, !syncManager.isAvailable(provider) {
                Text("Install \(provider.displayName) and sign in, or pick the other option.")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }
}

/// Above this, the UI calls out how much will upload before syncing.
let largeItemBytes: Int64 = 1_000_000_000

func formattedSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

// MARK: - Per-item row

struct AppSettingsSyncRow: View {
    @EnvironmentObject var syncManager: AppSettingsSyncManager
    let item: AppSettingsItem
    @Binding var pendingAction: (item: AppSettingsItem, enabling: Bool, inCloud: Bool)?

    var body: some View {
        let status = syncManager.status(for: item)
        let working = syncManager.isWorking(item)

        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.appName).lineLimit(1)
                    Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(syncManager.localURL(for: item).path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if case .notSynced(inCloud: false) = status, let size = syncManager.sizes[item.id], size > 0 {
                Text(formattedSize(size))
                    .font(.caption2)
                    .foregroundStyle(size >= largeItemBytes ? Color.orange : Color.secondary)
                    .help(size >= largeItemBytes ? "Large — make sure your \(syncManager.provider?.displayName ?? "cloud") storage has room." : "")
            }

            statusView(status)

            if working {
                ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
            } else {
                switch status {
                case .notSynced(let inCloud):
                    Button("Sync") { pendingAction = (item, true, inCloud) }
                        .buttonStyle(.bordered)
                case .synced:
                    Button("Unsync") { pendingAction = (item, false, true) }
                        .buttonStyle(.bordered)
                case .noProvider, .providerUnavailable, .notFound, .linkedElsewhere:
                    EmptyView()
                }
                if item.isCustom && status != .synced {
                    Button {
                        syncManager.removeCustomItem(item)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove from this list")
                }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func statusView(_ status: AppSettingsSyncStatus) -> some View {
        switch status {
        case .noProvider, .providerUnavailable:
            EmptyView()
        case .notFound:
            Text("Not on this Mac").font(.caption2).foregroundStyle(.tertiary)
        case .notSynced(let inCloud):
            Text(inCloud ? "Available to sync" : "Not Synced")
                .font(.caption2).foregroundStyle(.secondary)
                .help(inCloud ? "Another Mac has already synced these settings." : "")
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
