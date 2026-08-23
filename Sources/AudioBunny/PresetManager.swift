import Foundation
import AppKit

// MARK: - Preset install paths per plugin

private let presetInstallPaths: [Int: String] = [:]  // populated at runtime from plugin names

private func presetDirectory(pluginName: String?) -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    switch pluginName?.lowercased() {
    case let n? where n.contains("serum"):
        return home.appendingPathComponent("Documents/Xfer/Serum Presets/Presets/AudioBunny")
    case let n? where n.contains("guitar rig"):
        return home.appendingPathComponent("Documents/Native Instruments/Guitar Rig 7/Presets/AudioBunny")
    default:
        return home.appendingPathComponent("Documents/AudioBunny Presets/\(pluginName ?? "Unknown")")
    }
}

// MARK: - Preset Manager

@MainActor
final class PresetManager: ObservableObject {
    // Auth
    @Published var currentUser: APIUser? = nil
    @Published var isLoadingAuth = false
    @Published var authError: String? = nil

    // Presets
    @Published var presets: [APIPreset] = []
    @Published var isLoadingPresets = false
    @Published var presetError: String? = nil

    // Filters
    @Published var searchText = ""
    @Published var selectedPluginId: Int? = nil
    @Published var filterGenre: String? = nil
    @Published var showFavoritesOnly = false

    // Install queue polling
    private var pollTask: Task<Void, Never>? = nil

    init() {
        restoreSession()
    }

    // MARK: Session

    private func restoreSession() {
        guard APIClient.isSignedIn else { return }
        Task {
            isLoadingAuth = true
            do {
                currentUser = try await APIClient.me()
                await fetchPresets()
                startQueuePolling()
            } catch {
                APIClient.clearToken()
            }
            isLoadingAuth = false
        }
    }

    // MARK: Auth

    func register(username: String, email: String, password: String) async {
        isLoadingAuth = true
        authError = nil
        do {
            let response = try await APIClient.register(username: username, email: email, password: password)
            // login separately to store token
            _ = try await APIClient.login(login: email, password: password)
            currentUser = response.user
            await fetchPresets()
            startQueuePolling()
        } catch {
            authError = error.localizedDescription
        }
        isLoadingAuth = false
    }

    func login(login: String, password: String) async {
        isLoadingAuth = true
        authError = nil
        do {
            let response = try await APIClient.login(login: login, password: password)
            currentUser = response.user
            await fetchPresets()
            startQueuePolling()
        } catch {
            authError = error.localizedDescription
        }
        isLoadingAuth = false
    }

    func loginWithApple(idToken: String, email: String?) async {
        isLoadingAuth = true
        authError = nil
        do {
            let response = try await APIClient.signInWithApple(idToken: idToken, email: email)
            currentUser = response.user
            await fetchPresets()
            startQueuePolling()
        } catch {
            authError = error.localizedDescription
        }
        isLoadingAuth = false
    }

    func signInWithGoogle() async {
        isLoadingAuth = true
        authError = nil
        do {
            let idToken = try await GoogleOAuth.signIn()
            let response = try await APIClient.signInWithGoogle(idToken: idToken)
            currentUser = response.user
            await fetchPresets()
            startQueuePolling()
        } catch {
            authError = error.localizedDescription
        }
        isLoadingAuth = false
    }

    func logout() {
        APIClient.clearToken()
        currentUser = nil
        stopQueuePolling()
        Task { await fetchPresets() }
    }

    // MARK: Presets

    func fetchPresets(pluginId: Int? = nil) async {
        isLoadingPresets = true
        presetError = nil
        do {
            presets = try await APIClient.listPresets(
                pluginId: pluginId ?? selectedPluginId,
                genre:    filterGenre,
                q:        searchText.isEmpty ? nil : searchText
            )
        } catch {
            presetError = error.localizedDescription
        }
        isLoadingPresets = false
    }

    var filteredPresets: [APIPreset] {
        presets.filter { preset in
            let matchesPlugin = selectedPluginId == nil || preset.pluginId == selectedPluginId
            let matchesGenre  = filterGenre == nil || preset.genre == filterGenre
            let matchesFav    = !showFavoritesOnly || preset.favorited
            let matchesSearch = searchText.isEmpty ||
                preset.name.localizedCaseInsensitiveContains(searchText) ||
                preset.author.localizedCaseInsensitiveContains(searchText) ||
                preset.genre.localizedCaseInsensitiveContains(searchText) ||
                preset.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            return matchesPlugin && matchesGenre && matchesFav && matchesSearch
        }
    }

    var pluginGroups: [(id: Int, name: String, count: Int)] {
        let grouped = Dictionary(grouping: presets, by: \.pluginId)
        return grouped.compactMap { (pluginId, presets) in
            guard let name = presets.first?.pluginName else { return nil }
            return (id: pluginId, name: name, count: presets.count)
        }.sorted { $0.name < $1.name }
    }

    var availableGenres: [String] {
        let source = selectedPluginId == nil ? presets : presets.filter { $0.pluginId == selectedPluginId }
        return Array(Set(source.map(\.genre))).sorted()
    }

    // MARK: Favorite

    func toggleFavorite(_ preset: APIPreset) {
        guard currentUser != nil else { return }
        Task {
            do {
                if preset.favorited {
                    try await APIClient.unfavoritePreset(preset.id)
                } else {
                    try await APIClient.favoritePreset(preset.id)
                }
                await fetchPresets()
            } catch { }
        }
    }

    // MARK: Install

    func installPreset(_ preset: APIPreset) async throws {
        guard preset.isDownloadable else { return }
        let data = try await APIClient.downloadPreset(preset.id)
        let destDir = presetDirectory(pluginName: preset.pluginName)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent("\(preset.name).\(preset.fileExtension)")
        try data.write(to: dest)
        if currentUser != nil {
            try await APIClient.markInstalled(preset.id)
            await fetchPresets()
        }
    }

    // MARK: Upload

    func uploadPreset(pluginId: Int, name: String, author: String, genre: String, description: String, tags: [String], fileURL: URL) async throws {
        let ext = fileURL.pathExtension.lowercased()
        _ = try await APIClient.uploadPreset(
            pluginId: pluginId, name: name, author: author,
            genre: genre, description: description, tags: tags,
            fileURL: fileURL, fileExtension: ext
        )
        await fetchPresets()
    }

    // MARK: Queue polling (web→macOS install requests)

    private func startQueuePolling() {
        stopQueuePolling()
        pollTask = Task {
            while !Task.isCancelled {
                await processQueuedInstalls()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func stopQueuePolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func processQueuedInstalls() async {
        guard currentUser != nil else { return }
        do {
            let queued = try await APIClient.queuedInstalls()
            for install in queued {
                guard install.isDownloadable else {
                    try? await APIClient.completeInstall(install.installId)
                    continue
                }
                do {
                    let data = try await APIClient.downloadPreset(install.id)
                    let destDir = presetDirectory(pluginName: install.pluginName)
                    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                    let dest = destDir.appendingPathComponent("\(install.name).\(install.fileExtension)")
                    try data.write(to: dest)
                    try await APIClient.completeInstall(install.installId)
                } catch { }
            }
            if !queued.isEmpty { await fetchPresets() }
        } catch { }
    }
}
