import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct LiveProjectsView: View {
    @EnvironmentObject var liveProjectManager: LiveProjectManager
    @EnvironmentObject var pluginManager: PluginManager
    @State private var selection: UUID?
    @State private var showDirectoryPicker = false

    private func isFolderID(_ id: UUID) -> Bool {
        liveProjectManager.folders.contains { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabActionBar(title: "My Projects") {
                Toggle(isOn: $liveProjectManager.includeBackupProjects) {
                    Label("Include Backups", systemImage: "clock.arrow.circlepath")
                }
                .toggleStyle(.checkbox)
                .help("Include projects inside Ableton \"Backup\" folders when scanning")

                Button(action: pluginManager.refresh) {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(pluginManager.isScanning)
                .help("Rescan installed plugins")

                Button {
                    showDirectoryPicker = true
                } label: {
                    Label("Add Project Folder…", systemImage: "folder.badge.plus")
                }
            }

            // Plain HStack instead of NavigationSplitView: NavigationSplitView
            // automatically contributes a sidebar-collapse toggle to the title
            // bar, and .toolbar(removing: .sidebarToggle) did not reliably
            // suppress it. This sidebar is always shown, so an HStack avoids
            // the automatic toolbar item entirely rather than fighting it.
            HStack(spacing: 0) {
                sidebarContent
                    .frame(width: 280)

                Divider()

                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .fileImporter(
            isPresented: $showDirectoryPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls { liveProjectManager.addFolder(url) }
                if selection == nil { selection = urls.first.flatMap { u in
                    liveProjectManager.folders.first { $0.url.path == u.path }?.id
                } }
            }
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    var sidebarContent: some View {
        ZStack {
            if liveProjectManager.folders.isEmpty {
                LiveEmptyView(
                    icon: "folder.badge.questionmark",
                    title: "No Project Folders",
                    message: "Click \"Add Project Folder…\" to track a directory of Ableton Live projects."
                )
            } else {
                List(selection: $selection) {
                    ForEach(liveProjectManager.folders) { folder in
                        FolderRow(
                            folder: folder,
                            onRescan: { Task { await liveProjectManager.rescan(folderID: folder.id) } },
                            onDelete: {
                                if selection == folder.id { selection = nil }
                                liveProjectManager.removeFolder(folder.id)
                            }
                        )
                        .tag(folder.id)
                        .contextMenu {
                            Button("Rescan") {
                                Task { await liveProjectManager.rescan(folderID: folder.id) }
                            }
                            Button("Remove Folder", role: .destructive) {
                                if selection == folder.id { selection = nil }
                                liveProjectManager.removeFolder(folder.id)
                            }
                        }

                        if folder.isScanning {
                            FolderScanProgressRow(folder: folder)
                        }

                        ForEach(folder.projects) { project in
                            ProjectSidebarRow(project: project)
                                .tag(project.id)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    var detailContent: some View {
        if let sel = selection, isFolderID(sel), let folder = liveProjectManager.folders.first(where: { $0.id == sel }) {
            VStack(spacing: 0) {
                Text(folder.name)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider()
                PluginsListView(plugins: folder.allUniquePlugins, folder: folder)
            }
        } else if let sel = selection, let project = liveProjectManager.project(withID: sel) {
            ProjectDetailView(project: project)
        } else {
            LiveEmptyView(
                icon: "doc.richtext",
                title: "Select a Folder or Project",
                message: "Choose a project folder or project from the sidebar to see its plugins."
            )
        }
    }
}

// MARK: - Folder Sidebar Row

struct FolderRow: View {
    @EnvironmentObject var pluginManager: PluginManager
    let folder: ProjectFolder
    let onRescan: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    var missingCount: Int {
        folder.allUniquePlugins.filter { !$0.isInstalled(in: pluginManager.plugins) }.count
    }

    var body: some View {
        HStack {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if !folder.projects.isEmpty {
                    let n = folder.projects.count
                    Text("\(n) project\(n == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isHovering {
                HStack(spacing: 10) {
                    Button(action: onRescan) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Rescan")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
                .foregroundStyle(.secondary)
            } else if missingCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text("\(missingCount)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 2)
        .onHover { hovering in isHovering = hovering }
    }
}

// MARK: - Folder Scan Progress Row (inline, directly under the folder)

struct FolderScanProgressRow: View {
    let folder: ProjectFolder

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if folder.scanTotalCount > 0 {
                ProgressView(
                    value: Double(folder.scanCurrentIndex),
                    total: Double(folder.scanTotalCount)
                )
                .progressViewStyle(.linear)
                HStack(spacing: 4) {
                    Text("\(folder.scanCurrentIndex) of \(folder.scanTotalCount)")
                        .monospacedDigit()
                    Text("·").foregroundStyle(.tertiary)
                    Text(folder.scanCurrentFile)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text(folder.scanCurrentFile.isEmpty ? "Finding projects…" : folder.scanCurrentFile)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, 16)
        .padding(.vertical, 3)
    }
}

// MARK: - Project Sidebar Row

struct ProjectSidebarRow: View {
    @EnvironmentObject var pluginManager: PluginManager
    @EnvironmentObject var liveProjectManager: LiveProjectManager
    let project: LiveProject
    @State private var isHovering = false
    @State private var isRescanning = false

    var missingCount: Int {
        project.plugins.filter { !$0.isInstalled(in: pluginManager.plugins) }.count
    }

    var body: some View {
        HStack {
            if project.pending {
                ProgressView()
                    .scaleEffect(0.4)
                    .frame(width: 16, height: 16)
            } else if project.notDownloaded {
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .help("In iCloud — not downloaded to this Mac")
            } else if project.timedOut {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .frame(width: 16)
                    .help("Skipped: took longer than 1 minute to scan")
            } else {
                Image(systemName: missingCount == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(missingCount == 0 ? .green : .red)
                    .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .lineLimit(1)
                let n = project.plugins.count
                Text(project.pending ? "Scanning…"
                     : (project.notDownloaded ? "In iCloud — not downloaded"
                        : (project.timedOut ? "Skipped (timed out)"
                           : (n == 0 ? "No plugins" : "\(n) plugin\(n == 1 ? "" : "s")"))))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isRescanning {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            } else if isHovering {
                HStack(spacing: 10) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([project.url])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .help("Show enclosing folder in Finder")

                    Button {
                        isRescanning = true
                        Task {
                            if project.notDownloaded {
                                await liveProjectManager.downloadProject(projectID: project.id)
                            } else {
                                await liveProjectManager.rescanProject(projectID: project.id)
                            }
                            isRescanning = false
                        }
                    } label: {
                        Image(systemName: project.notDownloaded ? "icloud.and.arrow.down" : "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help(project.notDownloaded ? "Download from iCloud and scan" : "Rescan this project")
                }
                .foregroundStyle(.secondary)
            } else if !project.pending && !project.notDownloaded && !project.timedOut && missingCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text("\(missingCount)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.leading, 16)
        .padding(.vertical, 2)
        .onHover { hovering in isHovering = hovering }
    }
}

// MARK: - Project Detail (location + plugins, or a Scan button if unscanned)

struct ProjectDetailView: View {
    @EnvironmentObject var liveProjectManager: LiveProjectManager
    let project: LiveProject
    @State private var isScanning = false

    var body: some View {
        VStack(spacing: 0) {
            Text(project.name)
                .font(.title3)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)

            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text(project.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([project.url])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show enclosing folder in Finder")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            if project.notDownloaded {
                VStack(spacing: 12) {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 34, weight: .thin))
                        .foregroundStyle(.secondary)
                    Text("This project is in iCloud and hasn't been downloaded to this Mac.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if isScanning {
                        ProgressView("Downloading…")
                    } else {
                        Button {
                            isScanning = true
                            Task {
                                await liveProjectManager.downloadProject(projectID: project.id)
                                isScanning = false
                            }
                        } label: {
                            Label("Download & Scan", systemImage: "icloud.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
            } else if project.pending {
                VStack(spacing: 12) {
                    Text("This project hasn't been scanned yet.")
                        .foregroundStyle(.secondary)
                    if isScanning {
                        ProgressView()
                    } else {
                        Button {
                            isScanning = true
                            Task {
                                await liveProjectManager.rescanProject(projectID: project.id)
                                isScanning = false
                            }
                        } label: {
                            Label("Scan", systemImage: "play.circle")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PluginsListView(plugins: project.plugins)
            }
        }
    }
}

// MARK: - Plugins List (detail pane)

struct PluginsListView: View {
    @EnvironmentObject var pluginManager: PluginManager
    let plugins: [LiveProjectPlugin]
    var folder: ProjectFolder? = nil

    var missing: [LiveProjectPlugin]   { plugins.filter { !$0.isInstalled(in: pluginManager.plugins) } }
    var installed: [LiveProjectPlugin] { plugins.filter {  $0.isInstalled(in: pluginManager.plugins) } }

    var body: some View {
        if plugins.isEmpty {
            LiveEmptyView(
                icon: "waveform",
                title: "No Plugins",
                message: "No plugins found in this selection."
            )
        } else {
            List {
                if !missing.isEmpty {
                    Section("Missing (\(missing.count))") {
                        ForEach(missing) { plugin in
                            PluginUsageRow(
                                plugin: plugin,
                                isInstalled: false,
                                projectCount: folder?.projectCount(for: plugin)
                            )
                        }
                    }
                }
                if !installed.isEmpty {
                    Section("Installed (\(installed.count))") {
                        ForEach(installed) { plugin in
                            PluginUsageRow(
                                plugin: plugin,
                                isInstalled: true,
                                projectCount: folder?.projectCount(for: plugin)
                            )
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

// MARK: - Plugin Usage Row

struct PluginUsageRow: View {
    let plugin: LiveProjectPlugin
    let isInstalled: Bool
    var projectCount: Int? = nil

    var body: some View {
        HStack {
            Image(systemName: isInstalled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isInstalled ? .green : .red)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                HStack(spacing: 8) {
                    if let mfr = plugin.manufacturer {
                        Text(mfr)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let count = projectCount {
                        Text("\(count) project\(count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            if let type = plugin.type {
                Text(type.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Empty State

struct LiveEmptyView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
