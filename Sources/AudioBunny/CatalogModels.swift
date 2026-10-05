import Foundation

// MARK: - Plugin Category

enum PluginCategory: String, Codable, CaseIterable, Hashable, Identifiable {
    case instrument
    case effect

    var id: String { rawValue }

    var label: String {
        switch self {
        case .instrument: return "Instrument"
        case .effect: return "Effect"
        }
    }

    var icon: String {
        switch self {
        case .instrument: return "pianokeys"
        case .effect: return "waveform"
        }
    }
}

// MARK: - Catalog Plugin

struct CatalogPlugin: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let developer: String
    let description: String
    let category: PluginCategory
    let formats: [String]   // "AU", "VST2", "VST3"
    let tags: [String]
    let version: String
    let websiteURL: String
    /// The developer's own site, when the catalog has one — distinct from the plugin's page.
    let developerURL: String?
    let price: String
    let thumbnailURL: String?

    /// Direct URL to a zip/pkg/dmg download.
    let downloadURL: String?
    /// GitHub "owner/repo" — used to resolve the latest release asset at runtime.
    let githubRepo: String?

    /// True when an automated install path exists.
    var isDownloadable: Bool { downloadURL != nil || githubRepo != nil }
    var isFree: Bool { price.lowercased().contains("free") }
}

// MARK: - Catalog Response

struct PluginCatalogResponse: Codable {
    let version: String
    let plugins: [CatalogPlugin]
}
