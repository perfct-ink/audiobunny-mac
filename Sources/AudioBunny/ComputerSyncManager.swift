import Foundation

@MainActor
final class ComputerSyncManager: ObservableObject {
    @Published var isSyncing = false
    @Published var lastSyncError: String?
    @Published var lastSyncedAt: Date?

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
}
