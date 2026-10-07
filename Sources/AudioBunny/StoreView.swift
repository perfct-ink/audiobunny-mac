import SwiftUI

enum DiscoverResource: String, CaseIterable, Identifiable {
    case plugins = "Plugins"
    case presets = "Presets"
    case samples = "Samples"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .plugins: return "waveform"
        case .presets: return "music.note.list"
        case .samples: return "play.circle"
        }
    }
}

struct DiscoverView: View {
    @AppStorage("audiobunny.discoverResource") private var resource: DiscoverResource = .plugins

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(DiscoverResource.allCases) { item in
                    Button {
                        resource = item
                    } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .foregroundStyle(resource == item ? Color.accentColor : Color.secondary)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(resource == item ? Color.accentColor.opacity(0.15) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(resource == item ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            switch resource {
            case .plugins:
                StoreView()
            case .presets:
                PresetsView(isDiscover: true)
            case .samples:
                VStack(spacing: 12) {
                    Image(systemName: "play.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Discover Samples")
                        .font(.title2).fontWeight(.semibold)
                    Text("Sample discovery is coming soon. Explore your local collection in My Samples.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Discover (Store) View

struct StoreView: View {
    @EnvironmentObject var manager: PluginManager
    @EnvironmentObject var catalogManager: CatalogManager
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var presetManager: PresetManager
    @State private var showSubmitSheet = false

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    HStack(spacing: 12) {
                        searchField
                        Spacer(minLength: 12)
                        filterBar
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    pluginGrid
                }
                .padding(20)
            }
        }
        .sheet(isPresented: $showSubmitSheet) {
            SubmitPluginSheet(isPresented: $showSubmitSheet)
                .environmentObject(presetManager)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Discover")
                .font(.largeTitle)
                .fontWeight(.bold)
            HStack {
                Text("Browse instruments and effects shared by the community, and install them straight into your plugin folders.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showSubmitSheet = true
                } label: {
                    Label("Submit Plugin", systemImage: "plus.circle")
                }
                .help("Submit a plugin to the catalog")
            }
        }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search plugins", text: $catalogManager.searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .frame(maxWidth: 320, alignment: .leading)
    }

    // MARK: Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Category
                filterChip("All",         icon: "square.grid.2x2",             selected: catalogManager.filterCategory == nil) {
                    catalogManager.filterCategory = nil
                }
                filterChip("Instruments", icon: PluginCategory.instrument.icon, selected: catalogManager.filterCategory == .instrument) {
                    catalogManager.filterCategory = catalogManager.filterCategory == .instrument ? nil : .instrument
                }
                filterChip("Effects",     icon: PluginCategory.effect.icon,     selected: catalogManager.filterCategory == .effect) {
                    catalogManager.filterCategory = catalogManager.filterCategory == .effect ? nil : .effect
                }

                Divider().frame(height: 20)

                // Format (text-only chips, matching card badges)
                textChip("AU",   selected: catalogManager.filterFormat == "AU")   { catalogManager.filterFormat = catalogManager.filterFormat == "AU"   ? nil : "AU" }
                textChip("VST2", selected: catalogManager.filterFormat == "VST2") { catalogManager.filterFormat = catalogManager.filterFormat == "VST2" ? nil : "VST2" }
                textChip("VST3", selected: catalogManager.filterFormat == "VST3") { catalogManager.filterFormat = catalogManager.filterFormat == "VST3" ? nil : "VST3" }

                Divider().frame(height: 20)

                // Free toggle
                filterChip("Free", icon: "gift", selected: catalogManager.filterFree) {
                    catalogManager.filterFree.toggle()
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: Grid

    private var pluginGrid: some View {
        let plugins = catalogManager.filteredPlugins(installedPlugins: manager.plugins)
        return Group {
            if plugins.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("No plugins found")
                        .foregroundStyle(.secondary)
                    Text("Try a different search or filter.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
        LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(plugins) { plugin in
                        NavigationLink {
                            CatalogPluginDetailPage(plugin: plugin)
                                .environmentObject(manager)
                                .environmentObject(catalogManager)
                                .environmentObject(downloadManager)
                        } label: {
                            PluginDiscoverCard(plugin: plugin)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Chip helpers

    @ViewBuilder
    private func filterChip(_ label: String, icon: String, selected: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.caption).fontWeight(.medium)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .cornerRadius(7)
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func textChip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption).fontWeight(.medium)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .cornerRadius(7)
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Plugin Discover Card

struct PluginDiscoverCard: View {
    let plugin: CatalogPlugin
    @EnvironmentObject var manager: PluginManager
    @EnvironmentObject var catalogManager: CatalogManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Art — fixed 110 pt, hard-clipped
            pluginArt
                .frame(height: 110)
                .clipped()

            // Info — fixed 72 pt, overflow is hidden
            VStack(alignment: .leading, spacing: 5) {
                Text(plugin.name)
                    .font(.headline).lineLimit(1).foregroundStyle(.primary)
                Text(plugin.developer)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 5) {
                    categoryBadge
                    ForEach(plugin.formats.prefix(3), id: \.self) { formatBadge($0) }
                    Spacer(minLength: 0)
                    priceBadge
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(height: 72, alignment: .top)
            .clipped()
        }
        // Hard 182 pt outer frame — nothing escapes this
        .frame(height: 182, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Art

    @ViewBuilder
    private var pluginArt: some View {
        if let urlString = plugin.thumbnailURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if case .success(let img) = phase { img.resizable().scaledToFill() }
                else { artPlaceholder }
            }
        } else {
            artPlaceholder
        }
    }

    private var artPlaceholder: some View {
        ZStack {
            LinearGradient(colors: [placeholderColor.opacity(0.7), placeholderColor],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 6) {
                Image(systemName: plugin.category.icon)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.white.opacity(0.9))
                Text(plugin.name.prefix(1))
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    // MARK: Badges

    // Icon only + tooltip — no text
    private var categoryBadge: some View {
        Image(systemName: plugin.category.icon)
            .font(.caption2).fontWeight(.semibold)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(categoryColor.opacity(0.15))
            .foregroundStyle(categoryColor)
            .cornerRadius(4)
            .help(plugin.category.label)
    }

    // Text only — no icon. Colour matches the My Plugins list badges.
    @ViewBuilder
    private func formatBadge(_ format: String) -> some View {
        Text(format)
            .font(.caption2).fontWeight(.semibold)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(pluginFormatColor(format), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.white)
    }

    private var priceBadge: some View {
        Text(plugin.price)
            .font(.caption2).fontWeight(.semibold)
            .foregroundStyle(plugin.isFree ? Color.green : Color.secondary)
    }

    private var categoryColor: Color { plugin.category == .instrument ? .purple : .teal }

    private var placeholderColor: Color {
        let colors: [Color] = [.purple, .teal, .blue, .indigo, .pink, .orange, .mint]
        return colors[abs(plugin.name.hashValue) % colors.count]
    }
}

// MARK: - Full-window Plugin Detail

struct CatalogPluginDetailPage: View {
    let plugin: CatalogPlugin
    @EnvironmentObject var manager: PluginManager
    @EnvironmentObject var catalogManager: CatalogManager
    @EnvironmentObject var downloadManager: DownloadManager

    private var installedPlugin: AudioPlugin? {
        catalogManager.installedPlugin(for: plugin, in: manager.plugins)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Hero art
                heroArt
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipped()

                VStack(alignment: .leading, spacing: 24) {
                    // Header row
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(plugin.name)
                                .font(.largeTitle).fontWeight(.bold)
                            Text(plugin.developer)
                                .font(.title3).foregroundStyle(.secondary)
                            badgeRow
                        }
                        Spacer()
                        installButton
                    }

                    Divider()

                    // About
                    VStack(alignment: .leading, spacing: 8) {
                        Text("About").font(.headline)
                        Text(plugin.description)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Details grid
                    detailsSection

                    // Tags
                    if !plugin.tags.isEmpty {
                        tagsSection
                    }
                }
                .padding(28)
            }
        }
        .navigationBarBackButtonHidden(false)
    }

    // MARK: Hero

    @ViewBuilder
    private var heroArt: some View {
        if let urlString = plugin.thumbnailURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if case .success(let img) = phase { img.resizable().scaledToFill() }
                else { heroPlaceholder }
            }
        } else {
            heroPlaceholder
        }
    }

    private var heroPlaceholder: some View {
        let color: Color = {
            let colors: [Color] = [.purple, .teal, .blue, .indigo, .pink, .orange, .mint]
            return colors[abs(plugin.name.hashValue) % colors.count]
        }()
        return ZStack {
            LinearGradient(colors: [color.opacity(0.5), color],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: plugin.category.icon)
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: Badges row

    private var badgeRow: some View {
        HStack(spacing: 6) {
            Label(plugin.category.label, systemImage: plugin.category.icon)
                .font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                .background((plugin.category == .instrument ? Color.purple : Color.teal).opacity(0.15))
                .foregroundStyle(plugin.category == .instrument ? .purple : .teal)
                .cornerRadius(6)
            ForEach(plugin.formats, id: \.self) { format in
                Text(format)
                    .font(.caption).fontWeight(.semibold)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(pluginFormatColor(format), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
            }
            Text(plugin.price)
                .font(.caption).fontWeight(.semibold)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(plugin.isFree ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08))
                .foregroundStyle(plugin.isFree ? Color.green : Color.secondary)
                .cornerRadius(6)
        }
    }

    // MARK: Install button

    @ViewBuilder
    private var installButton: some View {
        if let state = downloadManager.states[plugin.id] {
            if state.isFailed {
                Button("Retry") {
                    downloadManager.dismissError(for: plugin.id)
                    downloadManager.install(plugin)
                }
                .buttonStyle(.borderedProminent).tint(.red)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView(value: state.progressFraction)
                        .frame(width: 140)
                    Text(state.label).font(.caption).foregroundStyle(.secondary)
                    Button("Cancel") { downloadManager.cancel(plugin.id) }
                        .buttonStyle(.bordered).tint(.orange).font(.caption)
                }
            }
        } else if installedPlugin != nil {
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
        } else if plugin.isDownloadable {
            Button {
                downloadManager.install(plugin)
            } label: {
                Label("Install", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else {
            Button {
                catalogManager.openWebsite(plugin)
            } label: {
                Label("Get Plugin", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: Details grid

    private var detailsSection: some View {
        GroupBox("Details") {
            SeparatedRows(rows: detailRows)
        }
    }

    private var detailRows: [AnyView] {
        var rows: [AnyView] = [
            detailRow("Developer", plugin.developer),
            detailRow("Version",   plugin.version),
            detailRow("Category",  plugin.category.label),
            detailRow("Formats",   plugin.formats.joined(separator: ", ")),
            detailRow("Price",     plugin.price),
        ]
        if let site = Self.webURL(plugin.websiteURL) {
            rows.append(linkRow("Website", site))
        }
        if let site = Self.webURL(plugin.developerURL ?? "") {
            rows.append(linkRow("Developer site", site))
        }
        return rows
    }

    private func linkRow(_ label: String, _ site: URL) -> AnyView {
        AnyView(
            HStack(alignment: .top) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)
                Link(destination: site) {
                    HStack(spacing: 4) {
                        Text(site.host ?? site.absoluteString).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "arrow.up.right.square")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 7).padding(.horizontal, 8)
        )
    }

    private static func webURL(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let url = URL(string: s),
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }

    private func detailRow(_ label: String, _ value: String) -> AnyView {
        AnyView(
            HStack(alignment: .top) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)
                Text(value)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 7).padding(.horizontal, 8)
        )
    }

    // MARK: Tags

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags").font(.headline)
            FlowLayout(spacing: 6) {
                ForEach(plugin.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.1))
                        .foregroundStyle(.secondary)
                        .cornerRadius(5)
                }
            }
        }
    }
}

// MARK: - Simple flow layout for tags

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.map { $0.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0 }
                         .reduce(0) { $0 + $1 + spacing } - spacing
        return CGSize(width: proposal.width ?? 0, height: max(height, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in computeRows(proposal: proposal, subviews: subviews) {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            var x = bounds.minX
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubview]] {
        var rows: [[LayoutSubview]] = [[]]
        var x: CGFloat = 0
        let maxWidth = proposal.width ?? .infinity
        for subview in subviews {
            let w = subview.sizeThatFits(.unspecified).width
            if x + w > maxWidth && !rows[rows.count - 1].isEmpty {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(subview)
            x += w + spacing
        }
        return rows
    }
}


// MARK: - Submit Plugin Sheet

struct SubmitPluginSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var presetManager: PresetManager

    @State private var name = ""
    @State private var manufacturer = ""
    @State private var category: PluginCategory = .instrument
    @State private var formats: Set<String> = ["VST3"]
    @State private var description = ""
    @State private var version = ""
    @State private var websiteURL = ""
    @State private var githubRepo = ""
    @State private var tags = ""
    @State private var isFree = true
    @State private var priceUsd = ""
    @State private var isSubmitting = false
    @State private var error: String? = nil
    @State private var submitted = false

    private let allFormats = ["AU", "VST2", "VST3"]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Submit a Plugin")
                    .font(.title3).fontWeight(.semibold)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            if presetManager.currentUser == nil {
                // Not logged in
                VStack(spacing: 16) {
                    Image(systemName: "person.circle")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Sign in to submit plugins")
                        .font(.headline)
                    Text("Create a free account to contribute to the AudioBunny plugin catalog.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Sign In / Create Account") {
                        isPresented = false
                        // AccountSheet will be shown from PresetsView if needed
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(40)
                .frame(maxWidth: .infinity)
            } else if submitted {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48)).foregroundStyle(.green)
                    Text("Submitted for Review")
                        .font(.headline)
                    Text("Your submission will be reviewed and appear in the catalog once approved.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Done") { isPresented = false }
                        .buttonStyle(.borderedProminent)
                }
                .padding(40)
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        row("Plugin Name") {
                            TextField("e.g. Serum", text: $name).textFieldStyle(.roundedBorder)
                        }
                        row("Developer / Manufacturer") {
                            TextField("e.g. Xfer Records", text: $manufacturer).textFieldStyle(.roundedBorder)
                        }
                        row("Category") {
                            HStack(spacing: 8) {
                                ForEach(PluginCategory.allCases) { c in
                                    Button {
                                        category = c
                                    } label: {
                                        Label(c.label, systemImage: c.icon)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(category == c ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                                            .foregroundStyle(category == c ? Color.accentColor : Color.primary)
                                            .cornerRadius(6)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(category == c ? Color.accentColor : Color.clear, lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        row("Formats") {
                            HStack(spacing: 8) {
                                ForEach(allFormats, id: \.self) { f in
                                    Toggle(f, isOn: Binding(
                                        get: { formats.contains(f) },
                                        set: { if $0 { formats.insert(f) } else { formats.remove(f) } }
                                    ))
                                    .toggleStyle(.checkbox)
                                }
                            }
                        }
                        row("Description") {
                            TextEditor(text: $description)
                                .frame(height: 60)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                        }
                        HStack(spacing: 14) {
                            VStack(alignment: .leading) {
                                Text("Version").font(.caption).foregroundStyle(.secondary)
                                TextField("e.g. 2.1.0", text: $version).textFieldStyle(.roundedBorder)
                            }
                            VStack(alignment: .leading) {
                                Text("Website URL").font(.caption).foregroundStyle(.secondary)
                                TextField("https://…", text: $websiteURL).textFieldStyle(.roundedBorder)
                            }
                        }
                        row("GitHub Repo (optional)") {
                            TextField("owner/repo", text: $githubRepo).textFieldStyle(.roundedBorder)
                        }
                        row("Tags (comma-separated)") {
                            TextField("synth, wavetable, free", text: $tags).textFieldStyle(.roundedBorder)
                        }
                        HStack(spacing: 12) {
                            Toggle("Free plugin", isOn: $isFree).toggleStyle(.checkbox)
                            if !isFree {
                                TextField("Price (USD)", text: $priceUsd)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 120)
                            }
                        }

                        if let err = error {
                            Text(err).foregroundStyle(.red).font(.caption)
                        }
                    }
                    .padding(20)
                }

                Divider()

                HStack {
                    Button("Cancel") { isPresented = false }.buttonStyle(.bordered)
                    Spacer()
                    Button("Submit for Review") {
                        Task { await submit() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || manufacturer.isEmpty || formats.isEmpty || isSubmitting)

                    if isSubmitting { ProgressView().scaleEffect(0.8) }
                }
                .padding(16)
            }
        }
        .frame(width: 500, height: presetManager.currentUser == nil || submitted ? 320 : 560)
    }

    @ViewBuilder
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func submit() async {
        isSubmitting = true
        error = nil
        do {
            _ = try await APIClient.submitPlugin(
                name: name, manufacturer: manufacturer,
                category: category.rawValue, formats: Array(formats),
                description: description, version: version,
                websiteURL: websiteURL, githubRepo: githubRepo,
                tags: tags, isFree: isFree,
                priceUsd: isFree ? nil : Double(priceUsd)
            )
            submitted = true
        } catch {
            self.error = error.localizedDescription
        }
        isSubmitting = false
    }
}
