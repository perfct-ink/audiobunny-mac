import Foundation
import AppKit

// MARK: - Catalog Manager

@MainActor
class CatalogManager: ObservableObject {
    @Published var catalogPlugins: [CatalogPlugin] = []
    @Published var searchText = ""
    @Published var filterCategory: PluginCategory? = nil
    @Published var filterFormat: String? = nil
    @Published var filterFree: Bool = false

    init() {
        loadFromBundle()          // show something immediately
        Task { await loadFromAPI() } // update from server
    }

    // MARK: Loading

    private func loadFromBundle() {
        guard let url = Bundle.module.url(forResource: "PluginCatalog", withExtension: "json") else {
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let response = try JSONDecoder().decode(PluginCatalogResponse.self, from: data)
            if catalogPlugins.isEmpty {
                catalogPlugins = response.plugins
            }
        } catch {
            print("CatalogManager: bundle decode error: \(error)")
        }
    }

    func loadFromAPI() async {
        do {
            let plugins = try await APIClient.listPlugins()
            catalogPlugins = plugins.compactMap(CatalogPlugin.init(api:))
        } catch {
            // API unreachable — bundle fallback is already loaded
        }
    }

    // MARK: Filtering

    func filteredPlugins(installedPlugins: [AudioPlugin]) -> [CatalogPlugin] {
        catalogPlugins.filter { plugin in
            let matchesCategory = filterCategory == nil || plugin.category == filterCategory
            let matchesFormat   = filterFormat == nil || plugin.formats.contains(filterFormat!)
            let matchesFree     = !filterFree || plugin.isFree
            let matchesSearch   = searchText.isEmpty ||
                plugin.name.localizedCaseInsensitiveContains(searchText) ||
                plugin.developer.localizedCaseInsensitiveContains(searchText) ||
                plugin.description.localizedCaseInsensitiveContains(searchText) ||
                plugin.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            return matchesCategory && matchesFormat && matchesFree && matchesSearch
        }
    }

    func installedPlugin(for catalogPlugin: CatalogPlugin, in plugins: [AudioPlugin]) -> AudioPlugin? {
        plugins.first { installed in
            let nameMatch = installed.name.localizedCaseInsensitiveContains(catalogPlugin.name) ||
                catalogPlugin.name.localizedCaseInsensitiveContains(installed.name)
            let formatMatch = catalogPlugin.formats.contains { format in
                switch format {
                case "AU":   return installed.type == .audioUnit
                case "VST2": return installed.type == .vst2
                case "VST3": return installed.type == .vst3
                default:     return false
                }
            }
            return nameMatch && formatMatch
        }
    }

    func isInstalled(_ catalogPlugin: CatalogPlugin, in plugins: [AudioPlugin]) -> Bool {
        installedPlugin(for: catalogPlugin, in: plugins) != nil
    }

    func openWebsite(_ plugin: CatalogPlugin) {
        guard let url = URL(string: plugin.websiteURL) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - CatalogPlugin from API

extension CatalogPlugin {
    init?(api p: APIPlugin) {
        let rawCategory = p.category ?? "instrument"
        guard let cat = PluginCategory(rawValue: rawCategory) else { return nil }
        let fmts = p.formats ?? [p.pluginType]
            .map { t -> String in
                switch t {
                case "Audio Unit": return "AU"
                case "VST 2":      return "VST2"
                case "VST 3":      return "VST3"
                default:           return t
                }
            }
        let price: String = p.isFree ? "Free" : (p.priceUsd.map { "$\(Int($0))" } ?? "—")
        self.init(
            id:           String(p.id),
            name:         p.name,
            developer:    p.manufacturer,
            description:  p.description ?? "",
            category:     cat,
            formats:      fmts,
            tags:         p.tags?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? [],
            version:      p.version ?? "",
            websiteURL:   p.websiteUrl ?? "",
            developerURL: p.manufacturerUrl,
            price:        price,
            thumbnailURL: p.thumbnailUrl,
            downloadURL:  p.downloadUrl,
            githubRepo:   p.githubRepo
        )
    }
}
