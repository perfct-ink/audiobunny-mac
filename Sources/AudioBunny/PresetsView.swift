import SwiftUI
import AppKit
import AuthenticationServices

// MARK: - Presets View

struct PresetsView: View {
    var isDiscover = false
    @EnvironmentObject var presetManager: PresetManager
    @State private var selectedPreset: APIPreset? = nil
    @State private var showUploadSheet = false
    @State private var showSyncSheet = false

    var body: some View {
        VStack(spacing: 0) {
            TabActionBar(title: isDiscover ? "Discover Presets" : "My Presets") {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search presets", text: $presetManager.searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                .frame(width: 220)

                if !isDiscover {
                    Button {
                        showSyncSheet = true
                    } label: {
                        Label("Sync Presets", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .help("Link plugin preset folders to a shared folder across your Macs")
                }

                if presetManager.currentUser != nil {
                    Button {
                        showUploadSheet = true
                    } label: {
                        Label("Upload Preset", systemImage: "arrow.up.circle")
                    }
                    .help("Share a preset from your library")
                }
            }

            // Plain HStack instead of NavigationSplitView: NavigationSplitView
            // automatically contributes a sidebar-collapse toggle to the title
            // bar, and .toolbar(removing: .sidebarToggle) did not reliably
            // suppress it. This sidebar is always shown, so an HStack avoids
            // the automatic toolbar item entirely rather than fighting it.
            HStack(spacing: 0) {
                PresetSidebarView(selectedPreset: $selectedPreset)
                    .frame(width: 300)

                Divider()

                if let preset = selectedPreset {
                    PresetDetailView(preset: preset, onInstalled: { selectedPreset = nil })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note.list")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Select a preset")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .sheet(isPresented: $showSyncSheet) {
            PresetSyncSheet(isPresented: $showSyncSheet)
        }
        .sheet(isPresented: $showUploadSheet) {
            UploadPresetSheet(isPresented: $showUploadSheet)
                .environmentObject(presetManager)
        }
        .task {
            if presetManager.presets.isEmpty {
                await presetManager.fetchPresets()
            }
        }
    }
}

// MARK: - Sidebar

struct PresetSidebarView: View {
    @EnvironmentObject var presetManager: PresetManager
    @Binding var selectedPreset: APIPreset?

    var body: some View {
        VStack(spacing: 0) {
            pluginFilterSection
            Divider()
            if !presetManager.availableGenres.isEmpty {
                genreFilterSection
                Divider()
            }
            if presetManager.currentUser != nil {
                favFilterRow
                Divider()
            }
            presetList
        }
        .onChange(of: presetManager.searchText) { _ in
            Task { await presetManager.fetchPresets() }
        }
    }

    @ViewBuilder
    private var pluginFilterSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PLUGIN")
                .font(.caption2).fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)

            Button {
                presetManager.selectedPluginId = nil
                presetManager.filterGenre = nil
                Task { await presetManager.fetchPresets() }
            } label: {
                pluginRow(id: nil, name: "All Presets",
                          count: presetManager.presets.count,
                          selected: presetManager.selectedPluginId == nil)
            }
            .buttonStyle(.plain)

            ForEach(presetManager.pluginGroups, id: \.id) { group in
                Button {
                    presetManager.selectedPluginId = group.id
                    presetManager.filterGenre = nil
                    Task { await presetManager.fetchPresets(pluginId: group.id) }
                } label: {
                    pluginRow(id: group.id, name: group.name,
                              count: group.count,
                              selected: presetManager.selectedPluginId == group.id)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func pluginRow(id: Int?, name: String, count: Int, selected: Bool) -> some View {
        HStack {
            Image(systemName: "music.note.list")
                .foregroundStyle(.purple)
                .frame(width: 16)
            Text(name).font(.body)
            Spacer()
            Text("\(count)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        .cornerRadius(6)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var genreFilterSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Genre:")
                .foregroundStyle(.secondary).font(.caption)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    filterChip("All", selected: presetManager.filterGenre == nil) {
                        presetManager.filterGenre = nil
                        Task { await presetManager.fetchPresets() }
                    }
                    ForEach(presetManager.availableGenres, id: \.self) { genre in
                        filterChip(genre, selected: presetManager.filterGenre == genre) {
                            presetManager.filterGenre = genre
                            Task { await presetManager.fetchPresets() }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .font(.caption)
    }

    @ViewBuilder
    private var favFilterRow: some View {
        Toggle(isOn: $presetManager.showFavoritesOnly) {
            Label("Favorites only", systemImage: "heart.fill")
                .font(.caption)
                .foregroundStyle(.pink)
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var presetList: some View {
        let presets = presetManager.filteredPresets
        if presetManager.isLoadingPresets {
            ProgressView("Loading presets...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if presets.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("No presets found")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(presets, selection: $selectedPreset) { preset in
                PresetRowView(preset: preset).tag(preset)
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private func filterChip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preset Row

struct PresetRowView: View {
    let preset: APIPreset
    @EnvironmentObject var presetManager: PresetManager

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name).font(.body).lineLimit(1)
                HStack(spacing: 4) {
                    Text(preset.author).font(.caption).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.secondary).font(.caption)
                    genreTag
                    if preset.isCommunity {
                        Image(systemName: "person.2.fill")
                            .font(.caption2).foregroundStyle(.blue)
                    }
                }
            }
            Spacer()
            HStack(spacing: 4) {
                if preset.favorited {
                    Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption)
                }
                if preset.installed {
                    Text("Installed")
                        .font(.caption2).fontWeight(.medium)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.green.opacity(0.2)).foregroundStyle(.green)
                        .cornerRadius(4)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var genreTag: some View {
        Text(preset.genre)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.purple.opacity(0.15)).foregroundStyle(.purple)
            .cornerRadius(4)
    }
}

// MARK: - Preset Detail

struct PresetDetailView: View {
    let preset: APIPreset
    let onInstalled: () -> Void
    @EnvironmentObject var presetManager: PresetManager
    @State private var isInstalling = false
    @State private var installError: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerCard
                descriptionSection
                detailsSection
                actionsSection
                Spacer()
            }
            .padding()
        }
    }

    @ViewBuilder
    private var headerCard: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.largeTitle).foregroundStyle(.purple)
                .frame(width: 50, height: 50)
                .background(Color.purple.opacity(0.1))
                .cornerRadius(10)

            VStack(alignment: .leading, spacing: 6) {
                Text(preset.name).font(.title2).fontWeight(.semibold)
                Text("by \(preset.author)").foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if let plugin = preset.pluginName {
                        Text(plugin)
                            .font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12)).foregroundStyle(.secondary)
                            .cornerRadius(6)
                    }
                    Text(preset.genre)
                        .font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.purple.opacity(0.15)).foregroundStyle(.purple)
                        .cornerRadius(6)
                    if preset.isCommunity {
                        Label("Community", systemImage: "person.2.fill")
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.blue.opacity(0.1)).foregroundStyle(.blue)
                            .cornerRadius(6)
                    }
                }
            }
            Spacer()
            if presetManager.currentUser != nil {
                Button { presetManager.toggleFavorite(preset) } label: {
                    Image(systemName: preset.favorited ? "heart.fill" : "heart")
                        .font(.title2)
                        .foregroundStyle(preset.favorited ? .pink : .secondary)
                }
                .buttonStyle(.plain)
                .help(preset.favorited ? "Remove from favorites" : "Add to favorites")
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    @ViewBuilder
    private var descriptionSection: some View {
        if let desc = preset.description {
            GroupBox("About") {
                Text(desc).frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
        }
    }

    @ViewBuilder
    private var detailsSection: some View {
        GroupBox("Details") {
            SeparatedRows(pairs: detailPairs)
        }
    }

    private var detailPairs: [(String, String)] {
        var pairs: [(String, String)] = []
        if let plugin = preset.pluginName { pairs.append(("Plugin", plugin)) }
        pairs.append(("Author", preset.author))
        pairs.append(("Genre", preset.genre))
        pairs.append(("File Type", ".\(preset.fileExtension.uppercased())"))
        if let size = preset.fileSizeBytes {
            pairs.append(("File Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
        }
        if !preset.tags.isEmpty { pairs.append(("Tags", preset.tags.joined(separator: ", "))) }
        return pairs
    }

    @ViewBuilder
    private var actionsSection: some View {
        GroupBox("Actions") {
            VStack(alignment: .leading, spacing: 12) {
                if presetManager.currentUser == nil {
                    HStack(spacing: 8) {
                        Image(systemName: "person.circle").foregroundStyle(.secondary)
                        Text("Sign in to install, favorite, and track your presets.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Divider()
                }

                if preset.installed {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Installed").foregroundStyle(.secondary)
                    }
                } else if preset.isDownloadable {
                    if isInstalling {
                        ProgressView("Installing…").progressViewStyle(.linear)
                    } else {
                        Button {
                            Task { await doInstall() }
                        } label: {
                            Label("Install Preset", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if let err = installError {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                    if presetManager.currentUser != nil {
                        Text("Preset will be saved to your \(preset.pluginName ?? "plugin") presets folder.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No download available. Source this preset manually.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func doInstall() async {
        isInstalling = true
        installError = nil
        do {
            try await presetManager.installPreset(preset)
        } catch {
            installError = error.localizedDescription
        }
        isInstalling = false
    }

}

// MARK: - Account Sheet

struct AccountSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var presetManager: PresetManager
    @State private var isRegister = false
    @State private var login = ""
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 20) {
            Text(isRegister ? "Create Account" : "Sign In")
                .font(.title2).fontWeight(.semibold)

            Text(isRegister
                 ? "Create a free account to track installs, favorites, and share presets."
                 : "Sign in to track your presets across devices.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 12) {
                if isRegister {
                    labeledField("Username", text: $username, placeholder: "e.g. AudioFan")
                    labeledField("Email", text: $email, placeholder: "you@example.com")
                } else {
                    labeledField("Email or username", text: $login, placeholder: "you@example.com")
                }
                labeledField("Password", text: $password, placeholder: "••••••••", secure: true)
            }

            if let err = presetManager.authError {
                Text(err).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Button("Cancel") { isPresented = false }.buttonStyle(.bordered)
                Spacer()
                Button(isRegister ? "Create Account" : "Sign In") {
                    Task { await submit() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitDisabled || presetManager.isLoadingAuth)

                if presetManager.isLoadingAuth {
                    ProgressView().scaleEffect(0.8)
                }
            }

            Button(isRegister ? "Already have an account? Sign In" : "New to AudioBunny? Create Account") {
                isRegister.toggle()
                presetManager.authError = nil
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Color.accentColor)

            HStack {
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
                Text("or").font(.caption).foregroundStyle(.secondary)
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
            }

            VStack(spacing: 8) {
                SignInWithAppleButton(.signIn, onRequest: { request in
                    request.requestedScopes = [.email, .fullName]
                }, onCompletion: { result in
                    guard case .success(let authorization) = result,
                          let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                          let tokenData = credential.identityToken,
                          let idToken = String(data: tokenData, encoding: .utf8)
                    else { return }
                    Task {
                        await presetManager.loginWithApple(idToken: idToken, email: credential.email)
                        if presetManager.authError == nil { isPresented = false }
                    }
                })
                .signInWithAppleButtonStyle(.black)
                .frame(height: 32)

                Button {
                    Task {
                        await presetManager.signInWithGoogle()
                        if presetManager.authError == nil { isPresented = false }
                    }
                } label: {
                    Text("Sign in with Google").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(30)
        .frame(width: 380)
    }

    private var isSubmitDisabled: Bool {
        isRegister
            ? username.isEmpty || email.isEmpty || password.isEmpty
            : login.isEmpty || password.isEmpty
    }

    private func submit() async {
        if isRegister {
            await presetManager.register(username: username, email: email, password: password)
        } else {
            await presetManager.login(login: login, password: password)
        }
        if presetManager.authError == nil { isPresented = false }
    }

    @ViewBuilder
    private func labeledField(_ label: String, text: Binding<String>, placeholder: String, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if secure {
                SecureField(placeholder, text: text).textFieldStyle(.roundedBorder)
            } else {
                TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
            }
        }
    }
}

// MARK: - Upload Preset Sheet

struct UploadPresetSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var presetManager: PresetManager

    @State private var name = ""
    @State private var genre = ""
    @State private var description = ""
    @State private var tags = ""
    @State private var selectedPluginId: Int? = nil
    @State private var selectedFileURL: URL? = nil
    @State private var isUploading = false
    @State private var uploadError: String? = nil

    private let genres = ["Bass", "Lead", "Pad", "Arp", "FX", "Pluck", "Chord",
                          "Keys", "Clean", "Crunch", "High Gain", "Metal", "Blues",
                          "Jazz", "Ambient", "Rock", "Other"]

    var body: some View {
        VStack(spacing: 20) {
            Text("Upload Preset").font(.title2).fontWeight(.semibold)

            Form {
                Picker("Plugin", selection: $selectedPluginId) {
                    Text("Select a plugin").tag(Int?.none)
                    ForEach(presetManager.pluginGroups, id: \.id) { group in
                        Text(group.name).tag(Int?.some(group.id))
                    }
                }

                TextField("Preset Name", text: $name)

                Picker("Genre", selection: $genre) {
                    Text("Select genre").tag("")
                    ForEach(genres, id: \.self) { Text($0).tag($0) }
                }

                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(3)

                TextField("Tags (comma-separated)", text: $tags)

                HStack {
                    if let url = selectedFileURL {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(url.lastPathComponent).font(.caption).lineLimit(1)
                    } else {
                        Text("No file selected").foregroundStyle(.secondary).font(.caption)
                    }
                    Spacer()
                    Button("Choose File…") { pickFile() }
                }
            }
            .formStyle(.grouped)

            if let err = uploadError {
                Text(err).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Button("Cancel") { isPresented = false }.buttonStyle(.bordered)
                Spacer()
                Button("Upload") {
                    Task { await upload() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canUpload || isUploading)

                if isUploading { ProgressView().scaleEffect(0.8) }
            }
        }
        .padding(30)
        .frame(width: 480)
    }

    private var canUpload: Bool {
        selectedPluginId != nil && !name.isEmpty && !genre.isEmpty && selectedFileURL != nil
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        panel.message = "Select a preset file (.fxp, .ngrr, etc.)"
        if panel.runModal() == .OK {
            selectedFileURL = panel.url
        }
    }

    private func upload() async {
        guard let pluginId = selectedPluginId, let fileURL = selectedFileURL else { return }
        isUploading = true
        uploadError = nil
        do {
            let tagList = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            try await presetManager.uploadPreset(
                pluginId: pluginId, name: name,
                author: presetManager.currentUser?.username ?? "Unknown",
                genre: genre, description: description,
                tags: tagList, fileURL: fileURL
            )
            isPresented = false
        } catch {
            uploadError = error.localizedDescription
        }
        isUploading = false
    }
}
