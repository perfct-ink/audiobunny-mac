import Foundation

@MainActor
final class ComputerSyncManager: ObservableObject {
    @Published var isSyncing = false
    @Published var lastSyncError: String?
    @Published var lastSyncedAt: Date?

    // MARK: - Other computers on the account

    @Published private(set) var computers: [APIComputer] = []
    @Published var isLoadingComputers = false
    @Published var computersError: String?

    @Published private(set) var pluginsByComputer: [Int: [APIComputerPlugin]] = [:]
    @Published private(set) var loadingPluginsForComputerIDs: Set<Int> = []
    @Published private(set) var pluginsErrorByComputer: [Int: String] = [:]

    func syncNow(pluginManager: PluginManager, liveProjectManager: LiveProjectManager) async {
        isSyncing = true
        lastSyncError = nil
        do {
            let computer = try await APIClient.registerComputer(name: ComputerIdentity.name)
            try await APIClient.syncPlugins(computerID: computer.id, plugins: pluginManager.plugins)
            try await APIClient.syncProjects(liveProjectManager.folders)
            lastSyncedAt = Date()
        } catch {
            lastSyncError = error.localizedDescription
        }
        isSyncing = false
    }

    /// True if `computer` is the Mac AudioBunny is running on right now —
    /// computers are matched by hostname (see `ComputerIdentity.name`), which
    /// is what's registered, not by the private per-install `ComputerIdentity.id`.
    func isThisComputer(_ computer: APIComputer) -> Bool {
        computer.name == ComputerIdentity.name
    }

    func loadComputers() async {
        isLoadingComputers = true
        computersError = nil
        do {
            computers = try await APIClient.listComputers()
        } catch {
            computersError = error.localizedDescription
        }
        isLoadingComputers = false
    }

    /// Fetches a computer's synced plugin list, caching it. Pass `force: true`
    /// to re-fetch (e.g. a manual refresh) instead of using the cache.
    func loadPlugins(for computerID: Int, force: Bool = false) async {
        guard force || pluginsByComputer[computerID] == nil else { return }
        loadingPluginsForComputerIDs.insert(computerID)
        pluginsErrorByComputer[computerID] = nil
        do {
            pluginsByComputer[computerID] = try await APIClient.computerPlugins(computerID)
        } catch {
            pluginsErrorByComputer[computerID] = error.localizedDescription
        }
        loadingPluginsForComputerIDs.remove(computerID)
    }
}
