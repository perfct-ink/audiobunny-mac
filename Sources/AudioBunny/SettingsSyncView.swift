import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Settings Sync tab

/// Moves audio apps' and plugins' settings into a destination folder (usually
/// in iCloud Drive or Dropbox) and links each one back to where its app
/// expects it.
struct SettingsSyncView: View {
    @EnvironmentObject var syncManager: AppSettingsSyncManager
    @EnvironmentObject var pluginManager: PluginManager
    @State private var searchText = ""
    @AppStorage("audiobunny.settingsSync.hideEmptyPlugins") private var hideEmptyPlugins = true
    @State private var showDestinationPicker = false
    @State private var showItemPicker = false
    /// The owner an item picked with `showItemPicker` gets added under.
    @State private var addingFor = otherSettingsOwner
    @State private var pendingAction: SettingsSyncAction?

    private struct InstalledPlugin: Hashable {
        let name: String
        let manufacturer: String
    }

    /// Installed plugins by name — the AU/VST2/VST3 builds of one plugin share settings.
    private var installedPlugins: [InstalledPlugin] {
        var seen = Set<String>()
        return pluginManager.plugins
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .filter { seen.insert($0.name.lowercased()).inserted }
            .map { InstalledPlugin(name: $0.name, manufacturer: $0.manufacturer) }
    }

    private func matchesSearch(_ text: String) -> Bool {
        searchText.isEmpty || text.localizedCaseInsensitiveContains(searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            TabActionBar(title: "Settings Sync") {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search apps and plugins", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                .frame(width: 220)

                Toggle("Hide plugins with no settings found", isOn: $hideEmptyPlugins)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                Button {
                    addingFor = otherSettingsOwner
                    showItemPicker = true
                } label: {
                    Label("Add Folder or File…", systemImage: "plus")
                }
                .disabled(!syncManager.destinationAvailable)
                .help("Sync settings AudioBunny didn't find on its own")
            }

            destinationBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            if let error = syncManager.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error).font(.caption).foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            Divider()

            content
        }
        // Re-runs when the destination changes (so items another Mac already
        // moved there show up) and when a plugin scan finishes.
        .task(id: "\(syncManager.destination?.path ?? "")|\(pluginManager.plugins.count)") {
            await syncManager.discover(plugins: installedPlugins.map { (name: $0.name, manufacturer: $0.manufacturer) })
        }
        .fileImporter(isPresented: $showDestinationPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { syncManager.chooseDestination(url) }
        }
        .fileImporter(isPresented: $showItemPicker, allowedContentTypes: [.folder, .item]) { result in
            if case .success(let url) = result { syncManager.addCustomItem(at: url, owner: addingFor) }
        }
        .confirmationDialog(
            pendingAction?.title ?? "",
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            titleVisibility: .visible
        ) {
            if let action = pendingAction {
                Button(action.enabling ? "Move and Link" : "Unlink", role: action.enabling ? nil : .destructive) {
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

    // MARK: Destination

    @ViewBuilder
    private var destinationBar: some View {
        let locked = !syncManager.hasDiscovered || syncManager.hasSyncedItems
        HStack(spacing: 10) {
            Image(systemName: "folder.fill.badge.gearshape").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Destination").font(.caption).foregroundStyle(.secondary)
                if let destination = syncManager.destination {
                    Text(destination.path)
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(syncManager.destinationAvailable ? Color.primary : Color.orange)
                        .help(syncManager.destinationAvailable ? "" : "This folder isn't there right now.")
                } else {
                    Text("Choose where the original settings get moved to.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            ForEach(CloudSyncProvider.allCases) { provider in
                Button(provider.displayName) { syncManager.useProvider(provider) }
                    .buttonStyle(.bordered)
                    .disabled(locked || !syncManager.isAvailable(provider))
                    .help(syncManager.isAvailable(provider)
                          ? "Use an “AudioBunny Settings” folder in \(provider.displayName)"
                          : "\(provider.displayName) isn't set up on this Mac")
            }
            Button("Choose Folder…") { showDestinationPicker = true }
                .buttonStyle(.bordered)
                .disabled(locked)
            if let destination = syncManager.destination, syncManager.destinationAvailable {
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
                    .buttonStyle(.bordered)
            }
        }
        .help(syncManager.hasSyncedItems ? "Unlink everything first to change the destination." : "")
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        if syncManager.destination == nil {
            placeholder("folder.badge.gearshape", "Pick iCloud Drive, Dropbox, or any folder above to get started.")
        } else if !syncManager.destinationAvailable {
            placeholder("externaldrive.badge.questionmark", "The destination folder isn't there. Reconnect it or choose another.")
        } else if !syncManager.hasDiscovered {
            VStack(spacing: 8) {
                ProgressView()
                Text("Looking for app and plugin settings…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                let apps = syncManager.items.filter { $0.source == .audioApp && matchesSearch($0.owner) }
                if !apps.isEmpty {
                    Section("Audio Apps") {
                        ForEach(apps) { item in
                            SettingsSyncRow(item: item, title: item.owner, pendingAction: $pendingAction)
                        }
                    }
                }

                ForEach(installedPlugins.filter { matchesSearch($0.name) || matchesSearch($0.manufacturer) },
                        id: \.self) { plugin in
                    let rows = syncManager.items.filter { $0.owner == plugin.name && $0.source != .audioApp }
                    if !rows.isEmpty || !hideEmptyPlugins {
                        Section {
                            if rows.isEmpty {
                                Text("No settings folder found").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(rows) { item in
                                SettingsSyncRow(item: item,
                                                title: (item.relativePath as NSString).lastPathComponent,
                                                pendingAction: $pendingAction)
                            }
                        } header: {
                            HStack {
                                Text(plugin.name)
                                Text(plugin.manufacturer).foregroundStyle(.secondary)
                                Spacer()
                                Button("Add Folder…") {
                                    addingFor = plugin.name
                                    showItemPicker = true
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                            }
                        }
                    }
                }

                let other = syncManager.items.filter { $0.owner == otherSettingsOwner && matchesSearch($0.relativePath) }
                if !other.isEmpty {
                    Section("Added by You") {
                        ForEach(other) { item in
                            SettingsSyncRow(item: item, title: (item.relativePath as NSString).lastPathComponent,
                                            pendingAction: $pendingAction)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func placeholder(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .thin))
                .foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func confirmationMessage(_ action: SettingsSyncAction) -> String {
        let name = action.item.owner
        if !action.enabling {
            return "This copies \(name)'s settings back into a normal folder on this Mac. The copy in the destination is left alone, so other Macs linked to it keep working. Quit \(name) first."
        }
        if action.inDestination {
            return "These settings are already in the destination (moved there from another Mac). This Mac will switch to them; its own copy is kept as a backup next to the original. Quit \(name) first."
        }
        var message = "AudioBunny will move \(name)'s settings into the destination folder and put a link where they were, so \(name) keeps finding them. If a folder with the same name is already there, it's left alone and these go beside it. Quit \(name) first."
        if let size = syncManager.sizes[action.item.relativePath], size >= largeItemBytes {
            message += " This is \(formattedSize(size))."
        }
        return message
    }
}

struct SettingsSyncAction {
    let item: AppSettingsItem
    let enabling: Bool
    let inDestination: Bool

    var title: String {
        enabling ? "Move and link \(item.owner) settings?" : "Unlink \(item.owner) settings?"
    }
}

/// Above this, the UI calls out how much will be moved.
let largeItemBytes: Int64 = 1_000_000_000

func formattedSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

// MARK: - Row

struct SettingsSyncRow: View {
    @EnvironmentObject var syncManager: AppSettingsSyncManager
    let item: AppSettingsItem
    let title: String
    @Binding var pendingAction: SettingsSyncAction?

    var body: some View {
        let status = syncManager.status(for: item)
        let working = syncManager.isWorking(item)

        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).lineLimit(1)
                    Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(pathLine(status))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if case .notSynced(inDestination: false) = status,
               let size = syncManager.sizes[item.relativePath], size > 0 {
                Text(formattedSize(size))
                    .font(.caption2)
                    .foregroundStyle(size >= largeItemBytes ? Color.orange : Color.secondary)
            }

            statusView(status)

            if working {
                ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
            } else {
                switch status {
                case .notSynced(let inDestination):
                    Button("Sync") { pendingAction = SettingsSyncAction(item: item, enabling: true, inDestination: inDestination) }
                        .buttonStyle(.bordered)
                case .synced:
                    Button("Unlink") { pendingAction = SettingsSyncAction(item: item, enabling: false, inDestination: true) }
                        .buttonStyle(.bordered)
                case .noDestination, .destinationMissing, .notFound, .linkedElsewhere:
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

    /// "~/Library/Application Support/FabFilter → FabFilter" once linked.
    private func pathLine(_ status: AppSettingsSyncStatus) -> String {
        let local = "~/" + item.relativePath
        if status == .synced, let remote = syncManager.remoteURL(for: item) {
            return "\(local) → \(remote.lastPathComponent)"
        }
        return local
    }

    @ViewBuilder
    private func statusView(_ status: AppSettingsSyncStatus) -> some View {
        switch status {
        case .noDestination, .destinationMissing:
            EmptyView()
        case .notFound:
            Text("Not on this Mac").font(.caption2).foregroundStyle(.tertiary)
        case .notSynced(let inDestination):
            Text(inDestination ? "In destination" : "Not Synced")
                .font(.caption2).foregroundStyle(.secondary)
                .help(inDestination ? "Another Mac already moved these settings into the destination." : "")
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
