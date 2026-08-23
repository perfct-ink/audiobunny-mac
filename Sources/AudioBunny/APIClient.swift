import Foundation

// MARK: - Configuration

enum APIClient {
    static var baseURL: String {
        UserDefaults.standard.string(forKey: "apiBaseURL") ?? "http://localhost:3000/api/v1"
    }

    private static let tokenKey = "audiobunny.jwt"
    private static var didMigrateToken = false

    private static var token: String? {
        get {
            migrateTokenToKeychainIfNeeded()
            return KeychainStore.get(key: tokenKey)
        }
        set {
            if let newValue {
                KeychainStore.set(newValue, key: tokenKey)
            } else {
                KeychainStore.remove(key: tokenKey)
            }
        }
    }

    /// Older builds stored the JWT in UserDefaults; move it to the Keychain once.
    private static func migrateTokenToKeychainIfNeeded() {
        guard !didMigrateToken else { return }
        didMigrateToken = true
        guard KeychainStore.get(key: tokenKey) == nil,
              let legacyToken = UserDefaults.standard.string(forKey: tokenKey) else { return }
        KeychainStore.set(legacyToken, key: tokenKey)
        UserDefaults.standard.removeObject(forKey: tokenKey)
    }

    static func clearToken() { token = nil }

    static var isSignedIn: Bool { token != nil }

    // MARK: - Auth

    static func register(username: String, email: String, password: String) async throws -> AuthResponse {
        try await post("auth/register", body: [
            "username": username, "email": email, "password": password
        ])
    }

    static func login(login: String, password: String) async throws -> AuthResponse {
        let response: AuthResponse = try await post("auth/login", body: [
            "login": login, "password": password
        ])
        token = response.token
        return response
    }

    static func me() async throws -> APIUser {
        try await get("auth/me")
    }

    static func signInWithApple(idToken: String, email: String? = nil) async throws -> AuthResponse {
        var body = ["id_token": idToken]
        if let email { body["email"] = email }
        let response: AuthResponse = try await post("auth/apple", body: body)
        token = response.token
        return response
    }

    static func signInWithGoogle(idToken: String) async throws -> AuthResponse {
        let response: AuthResponse = try await post("auth/google", body: ["id_token": idToken])
        token = response.token
        return response
    }

    // MARK: - Machines / sync

    static func registerMachine(name: String) async throws -> APIMachine {
        try await post("machines/register", body: ["client_uuid": MachineIdentity.id, "name": name])
    }

    static func syncPlugins(machineID: Int, plugins: [AudioPlugin]) async throws {
        var req = try makeRequest("machines/\(machineID)/sync_plugins", method: "POST")
        let body: [String: Any] = [
            "plugins": plugins.map {
                [
                    "name": $0.name,
                    "manufacturer": $0.manufacturer,
                    "plugin_type": $0.type.rawValue,
                    "version": $0.version ?? "",
                ]
            }
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let _: OkResponse = try await decode(perform: req)
    }

    static func syncProjects(_ folders: [ProjectFolder]) async throws {
        var req = try makeRequest("sync/projects", method: "POST")
        let payload = folders.flatMap { $0.projects }.map { project -> [String: Any] in
            let parent = project.url.deletingLastPathComponent().lastPathComponent
            return [
                "identifier": "\(parent)/\(project.name)",
                "name": project.name,
                "plugins": project.plugins.map {
                    ["name": $0.name, "manufacturer": $0.manufacturer ?? "", "plugin_type": $0.type?.rawValue ?? ""]
                },
            ]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["projects": payload])
        let _: OkResponse = try await decode(perform: req)
    }

    // MARK: - Plugins

    static func listPlugins(q: String? = nil) async throws -> [APIPlugin] {
        var params: [String: String] = [:]
        if let q { params["q"] = q }
        return try await get("plugins", params: params)
    }

    // MARK: - Presets

    static func listPresets(pluginId: Int? = nil, genre: String? = nil, q: String? = nil, community: Bool? = nil) async throws -> [APIPreset] {
        var params: [String: String] = [:]
        if let pluginId  { params["plugin_id"] = String(pluginId) }
        if let genre     { params["genre"] = genre }
        if let q         { params["q"] = q }
        if let community { params["community"] = community ? "true" : "false" }
        return try await get("presets", params: params)
    }

    static func getPreset(_ id: Int) async throws -> APIPreset {
        try await get("presets/\(id)")
    }

    static func uploadPreset(pluginId: Int, name: String, author: String, genre: String, description: String, tags: [String], fileURL: URL, fileExtension: String) async throws -> APIPreset {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        func append(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        append("plugin_id",   String(pluginId))
        append("name",        name)
        append("author",      author)
        append("genre",       genre)
        append("description", description)
        append("tags",        tags.joined(separator: ","))

        let fileData = try Data(contentsOf: fileURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = try makeRequest("presets", method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try await decode(perform: req)
    }

    static func submitPlugin(
        name: String, manufacturer: String, category: String, formats: [String],
        description: String, version: String, websiteURL: String, githubRepo: String,
        tags: String, isFree: Bool, priceUsd: Double?
    ) async throws -> APIPlugin {
        var body: [String: String] = [
            "name": name, "manufacturer": manufacturer,
            "category": category, "plugin_type": "VST 3",
            "description": description, "version": version,
            "website_url": websiteURL, "github_repo": githubRepo,
            "tags": tags, "is_free": isFree ? "true" : "false",
        ]
        if let price = priceUsd { body["price_usd"] = String(price) }
        // formats needs special handling as array
        var req = try makeRequest("plugins", method: "POST")
        var bodyDict: [String: Any] = body.mapValues { $0 as Any }
        bodyDict["formats"] = formats
        req.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        return try await decode(perform: req)
    }

    static func downloadPreset(_ id: Int) async throws -> Data {
        let req = try makeRequest("presets/\(id)/download")
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    // MARK: - Preset favorites

    static func favoritePreset(_ id: Int) async throws {
        let _: OkResponse = try await post("favorites/presets/\(id)", body: [:])
    }

    static func unfavoritePreset(_ id: Int) async throws {
        let _: OkResponse = try await delete("favorites/presets/\(id)")
    }

    static func favoritedPresets() async throws -> [APIPreset] {
        try await get("favorites/presets")
    }

    // MARK: - Preset installs

    /// macOS direct install: status = completed
    static func markInstalled(_ id: Int) async throws {
        let _: APIInstall = try await post("installs/presets/\(id)", body: ["status": "completed"])
    }

    /// Web-queued installs waiting for the macOS app
    static func queuedInstalls() async throws -> [APIInstall] {
        try await get("installs/presets", params: ["status": "queued"])
    }

    /// macOS app marks a queued install as done
    static func completeInstall(_ id: Int) async throws {
        let _: APIInstall = try await patch("installs/presets/\(id)", body: ["status": "completed"])
    }

    // MARK: - Generics

    private static func get<T: Decodable>(_ path: String, params: [String: String] = [:]) async throws -> T {
        var req = try makeRequest(path, params: params)
        req.httpMethod = "GET"
        return try await decode(perform: req)
    }

    private static func post<T: Decodable>(_ path: String, body: [String: String]) async throws -> T {
        var req = try makeRequest(path, method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await decode(perform: req)
    }

    private static func patch<T: Decodable>(_ path: String, body: [String: String]) async throws -> T {
        var req = try makeRequest(path, method: "PATCH")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await decode(perform: req)
    }

    private static func delete<T: Decodable>(_ path: String) async throws -> T {
        let req = try makeRequest(path, method: "DELETE")
        return try await decode(perform: req)
    }

    private static func makeRequest(_ path: String, method: String = "GET", params: [String: String] = [:]) throws -> URLRequest {
        guard var components = URLComponents(string: "\(baseURL)/\(path)") else {
            throw APIError.invalidURL
        }
        if !params.isEmpty {
            components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private static func decode<T: Decodable>(perform req: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let msg = (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.error ?? "HTTP \(http.statusCode)"
            throw APIError.serverError(msg)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidURL
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:           return "Invalid API URL"
        case .serverError(let m):   return m
        }
    }
}

private struct APIErrorBody: Decodable { let error: String }
private struct OkResponse: Decodable { let ok: Bool }
