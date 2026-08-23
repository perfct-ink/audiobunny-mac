import Foundation

@MainActor
final class MachineSyncManager: ObservableObject {
    @Published var isSyncing = false
    @Published var lastSyncError: String?
    @Published var lastSyncedAt: Date?

    func syncNow(pluginManager: PluginManager, liveProjectManager: LiveProjectManager) async {
        isSyncing = true
        lastSyncError = nil
        do {
            let machine = try await APIClient.registerMachine(name: MachineIdentity.name)
            try await APIClient.syncPlugins(machineID: machine.id, plugins: pluginManager.plugins)
            try await APIClient.syncProjects(liveProjectManager.folders)
            lastSyncedAt = Date()
        } catch {
            lastSyncError = error.localizedDescription
        }
        isSyncing = false
    }
}
