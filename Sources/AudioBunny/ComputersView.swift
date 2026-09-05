import SwiftUI

// MARK: - Other Computers sheet (My Plugins → Computers)

struct OtherComputersSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var computerSyncManager: ComputerSyncManager
    @State private var selectedComputerID: Int?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                computerList
                    .frame(width: 220)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 640, height: 440)
        .task { await computerSyncManager.loadComputers() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Computers").font(.title3).fontWeight(.semibold)
                Text("Other Macs signed into your account, and what AudioBunny found there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await computerSyncManager.loadComputers() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh the computer list")

            Button { isPresented = false } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    @ViewBuilder
    private var computerList: some View {
        if computerSyncManager.isLoadingComputers && computerSyncManager.computers.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = computerSyncManager.computersError, computerSyncManager.computers.isEmpty {
            errorView(error)
        } else if computerSyncManager.computers.isEmpty {
            Text("No computers synced yet. Use \"Sync Now\" first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selectedComputerID) {
                ForEach(computerSyncManager.computers) { computer in
                    ComputerRow(computer: computer, isThisComputer: computerSyncManager.isThisComputer(computer))
                        .tag(computer.id)
                }
            }
            .listStyle(.sidebar)
            .onAppear {
                if selectedComputerID == nil { selectedComputerID = computerSyncManager.computers.first?.id }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedComputerID,
           let computer = computerSyncManager.computers.first(where: { $0.id == id }) {
            ComputerPluginsDetail(computer: computer)
        } else {
            Text("Select a computer")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Computer row

struct ComputerRow: View {
    let computer: APIComputer
    let isThisComputer: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isThisComputer ? "laptopcomputer" : "desktopcomputer")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(computer.name).lineLimit(1)
                    if isThisComputer {
                        Text("This Mac")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text("\(computer.pluginCount) plugin\(computer.pluginCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Selected computer's plugin list

struct ComputerPluginsDetail: View {
    @EnvironmentObject var computerSyncManager: ComputerSyncManager
    @EnvironmentObject var pluginManager: PluginManager
    let computer: APIComputer

    /// "manufacturer|name" for everything installed on *this* Mac, so the list
    /// can flag what the other computer has that this one doesn't.
    private var installedHere: Set<String> {
        Set(pluginManager.plugins.map { "\($0.manufacturer)|\($0.name)".lowercased() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(computer.name).font(.headline)
                Spacer()
                Button {
                    Task { await computerSyncManager.loadPlugins(for: computer.id, force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh this computer's plugin list")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            Divider()
            content
        }
        .task(id: computer.id) { await computerSyncManager.loadPlugins(for: computer.id) }
    }

    @ViewBuilder
    private var content: some View {
        let plugins = computerSyncManager.pluginsByComputer[computer.id]
        if computerSyncManager.loadingPluginsForComputerIDs.contains(computer.id) && plugins == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = computerSyncManager.pluginsErrorByComputer[computer.id], plugins == nil {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let plugins, !plugins.isEmpty {
            List(plugins) { plugin in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plugin.name).lineLimit(1)
                        Text(plugin.manufacturer).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !installedHere.contains("\(plugin.manufacturer)|\(plugin.name)".lowercased()) {
                        Text("Not on this Mac")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(plugin.pluginType)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        } else {
            Text("No plugins synced from this computer yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
