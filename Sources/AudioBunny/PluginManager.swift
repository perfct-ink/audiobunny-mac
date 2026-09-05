import Foundation
import AVFoundation
import AudioToolbox
import Combine

// MARK: - Plugin Manager

@MainActor
class PluginManager: ObservableObject {
    @Published var plugins: [AudioPlugin] = []
    @Published var isScanning = false
    @Published var filterType: PluginType? = nil
    @Published var filterStatus: PluginStatusFilter = .all
    @Published var searchText = ""

    enum PluginStatusFilter: String, CaseIterable {
        case all = "All"
        case untested = "Untested"
        case active = "Active"
        case failed = "Failed"
        case disabled = "Disabled"
    }

    // Standard plugin search paths
    private let systemAUPath = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/Components")
    private let userAUPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Audio/Plug-Ins/Components")
    private let systemVST2Path = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST")
    private let userVST2Path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Audio/Plug-Ins/VST")
    private let systemVST3Path = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST3")
    private let userVST3Path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Audio/Plug-Ins/VST3")

    nonisolated var disabledFolderURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Audio/Plug-Ins/Disabled")
    }

    nonisolated private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var filteredPlugins: [AudioPlugin] {
        plugins.filter { plugin in
            let matchesType = filterType == nil || plugin.type == filterType
            let matchesSearch = searchText.isEmpty ||
                plugin.name.localizedCaseInsensitiveContains(searchText) ||
                plugin.manufacturer.localizedCaseInsensitiveContains(searchText)
            let matchesStatus: Bool = {
                switch filterStatus {
                case .all: return true
                case .untested:
                    if case .untested = plugin.status { return true }
                    return false
                case .active:
                    if case .active = plugin.status { return true }
                    return false
                case .failed:
                    if case .failed = plugin.status { return true }
                    return false
                case .disabled: return plugin.status == .disabled
                }
            }()
            return matchesType && matchesSearch && matchesStatus
        }
    }

    var pluginCounts: (total: Int, active: Int, failed: Int, disabled: Int, untested: Int) {
        let total = plugins.count
        let active = plugins.filter { if case .active = $0.status { return true }; return false }.count
        let failed = plugins.filter { if case .failed = $0.status { return true }; return false }.count
        let disabled = plugins.filter { $0.status == .disabled }.count
        let untested = plugins.filter { if case .untested = $0.status { return true }; return false }.count
        return (total, active, failed, disabled, untested)
    }

    func refresh() {
        Task {
            await scan()
        }
    }

    private func scan() async {
        isScanning = true

        // AVAudioUnitComponentManager enumeration and filesystem/bundle scans are
        // synchronous and can take a noticeable moment; run them off the main actor
        // so they don't contend with SwiftUI's initial window layout at launch.
        let discovered: [AudioPlugin] = await Task.detached { [self] in
            var discovered: [AudioPlugin] = []

            // Scan Audio Units via AVAudioUnitComponentManager
            discovered += scanAudioUnits()

            // Scan VST2
            discovered += scanVSTDirectory(systemVST2Path, type: .vst2)
            discovered += scanVSTDirectory(userVST2Path, type: .vst2)

            // Scan VST3
            discovered += scanVSTDirectory(systemVST3Path, type: .vst3)
            discovered += scanVSTDirectory(userVST3Path, type: .vst3)

            // Also scan disabled folder to restore disabled status
            let disabledAU = scanDisabledPlugins(extension: "component", type: .audioUnit)
            let disabledVST2 = scanDisabledPlugins(extension: "vst", type: .vst2)
            let disabledVST3 = scanDisabledPlugins(extension: "vst3", type: .vst3)
            let disabled = disabledAU + disabledVST2 + disabledVST3
            for p in disabled { p.status = .disabled }
            discovered += disabled

            return discovered
        }.value

        // Deduplicate by stable identity — NOT by fileURL. AVAudioUnitComponent
        // doesn't reliably expose a bundle path, so keying on one here used to
        // collapse the whole AU list down to a couple of entries.
        var seen = Set<String>()
        let deduped = discovered.filter { seen.insert($0.identityKey).inserted }

        // Restore last known test result for plugins whose name+version we've
        // tested before (persists across launches — see recordTestResult).
        let history = loadTestHistory()
        for plugin in deduped {
            guard plugin.status == .untested,
                  let key = testHistoryKey(for: plugin),
                  let record = history[key] else { continue }
            plugin.status = record.status
        }

        // Preserve existing (this-session) test results for plugins we already
        // know about. Keyed by identity, not fileURL — distinct components can
        // share one bundle (e.g. an instrument and its MIDI-effect variant), so
        // fileURL is not unique here.
        let existingByIdentity = Dictionary(plugins.map { ($0.identityKey, $0.status) },
                                            uniquingKeysWith: { first, _ in first })
        for plugin in deduped {
            if let existingStatus = existingByIdentity[plugin.identityKey], plugin.status != .disabled {
                plugin.status = existingStatus
            }
        }

        // A user-assigned category (see setCategory) always wins over whatever
        // auto-detection produced — applies to every format variant sharing a
        // name, matching preferredCategory's cross-variant grouping.
        let overrides = loadCategoryOverrides()
        for plugin in deduped {
            if let override = overrides[categoryOverrideKey(for: plugin)] {
                plugin.category = override
            }
        }

        plugins = deduped.sorted { $0.name < $1.name }
        isScanning = false
    }

    // MARK: - Category Overrides (user-assigned, persisted across launches)

    private let categoryOverrideDefaultsKey = "audiobunny.categoryOverrides"

    /// Keyed by name only (not format) so setting a category for one variant
    /// (e.g. the AU build) applies to every other format of the same plugin.
    private func categoryOverrideKey(for plugin: AudioPlugin) -> String {
        plugin.name.lowercased()
    }

    private func loadCategoryOverrides() -> [String: PluginCategory] {
        guard let data = userDefaults.data(forKey: categoryOverrideDefaultsKey),
              let overrides = try? JSONDecoder().decode([String: PluginCategory].self, from: data) else {
            return [:]
        }
        return overrides
    }

    /// User-provided correction for a plugin AudioBunny couldn't categorize
    /// (or got wrong). Persists so it survives rescans and relaunches, and
    /// applies to every installed format variant of the same plugin name.
    func setCategory(_ category: PluginCategory, for plugin: AudioPlugin) {
        let key = categoryOverrideKey(for: plugin)
        for variant in plugins where categoryOverrideKey(for: variant) == key {
            variant.category = category
        }
        var overrides = loadCategoryOverrides()
        overrides[key] = category
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        userDefaults.set(data, forKey: categoryOverrideDefaultsKey)
        notifyPluginsChanged()
    }

    // MARK: - Test History (persisted across launches)

    struct TestHistoryRecord: Codable, Equatable {
        let statusKind: String // "active" or "failed"
        let failureMessage: String?

        var status: PluginStatus {
            statusKind == "active" ? .active : .failed(failureMessage ?? "Unknown error")
        }
    }

    private let testHistoryDefaultsKey = "audiobunny.pluginTestHistory"

    /// Only plugins with a known version are tracked — without one we can't
    /// reliably tell "the same plugin, unchanged" from "a different install",
    /// so we'd rather re-test than silently misreport an untested plugin as OK.
    ///
    /// The key is also scoped to the current macOS build: a system update can
    /// change whether a plugin loads, so after one every plugin drops back to
    /// "untested" until it's re-tested on the new build.
    func testHistoryKey(for plugin: AudioPlugin) -> String? {
        guard let version = plugin.version else { return nil }
        return "\(currentOSBuild())|\(plugin.type.rawValue)|\(plugin.name.lowercased())|\(version)"
    }

    func loadTestHistory() -> [String: TestHistoryRecord] {
        guard let data = userDefaults.data(forKey: testHistoryDefaultsKey),
              let history = try? JSONDecoder().decode([String: TestHistoryRecord].self, from: data) else {
            return [:]
        }
        return history
    }

    func recordTestResult(for plugin: AudioPlugin) {
        guard let key = testHistoryKey(for: plugin) else { return }
        let record: TestHistoryRecord
        switch plugin.status {
        case .active:
            record = TestHistoryRecord(statusKind: "active", failureMessage: nil)
        case .failed(let message):
            record = TestHistoryRecord(statusKind: "failed", failureMessage: message)
        default:
            return
        }
        var history = loadTestHistory()
        // Drop results recorded against other macOS builds so the store doesn't
        // grow without bound and stale-build entries can never be consulted.
        let buildPrefix = "\(currentOSBuild())|"
        history = history.filter { $0.key.hasPrefix(buildPrefix) }
        history[key] = record
        guard let data = try? JSONEncoder().encode(history) else { return }
        userDefaults.set(data, forKey: testHistoryDefaultsKey)
    }

    // MARK: - Audio Unit Discovery

    nonisolated private func scanAudioUnits() -> [AudioPlugin] {
        let manager = AVAudioUnitComponentManager.shared()
        let allComponents = manager.components(passingTest: { _, _ in true })
        let bundleIndex = audioUnitBundleIndex()

        return allComponents.compactMap { component -> AudioPlugin? in
            let desc = component.audioComponentDescription

            // `auvw` ("Cocoa view" / editor) components are the plugin-GUI half of
            // a real AU, not independently loadable plugins — skip them.
            if auCodeString(desc.componentType) == "auvw" { return nil }

            // Resolve the bundle this component actually lives in by its 4-char
            // codes. We used to derive this from `component.iconURL`, but that is
            // empty or malformed for most plugins, so every AU collapsed onto the
            // same bogus path and all but a couple were lost to the dedup pass.
            let codeKey = AUCodeKey(
                type: auCodeString(desc.componentType),
                subtype: auCodeString(desc.componentSubType),
                manufacturer: auCodeString(desc.componentManufacturer)
            )
            // A synthesised path only if the lookup misses (Apple's built-in
            // speech/output units) — and it no longer affects dedup (see scan()).
            let fileURL = bundleIndex[codeKey]
                ?? URL(fileURLWithPath: "/Library/Audio/Plug-Ins/Components/\(component.name).component")

            return AudioPlugin(
                name: component.name,
                manufacturer: component.manufacturerName,
                type: .audioUnit,
                fileURL: fileURL,
                version: extractVersionFromBundle(fileURL),
                category: categoryForAUComponentType(desc.componentType),
                componentDescription: desc
            )
        }
    }

    /// Maps every installed Audio Unit (by the 4-char type/subtype/manufacturer
    /// codes it registers under) to the `.component` bundle on disk that provides
    /// it, read straight from each bundle's Info.plist `AudioComponents` array —
    /// the authoritative source, and one that needs no code execution.
    nonisolated private func audioUnitBundleIndex() -> [AUCodeKey: URL] {
        var index: [AUCodeKey: URL] = [:]
        let dirs = [
            systemAUPath, userAUPath,
            URL(fileURLWithPath: "/System/Library/Components"),
            disabledFolderURL,
        ]
        for dir in dirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for bundleURL in entries where bundleURL.pathExtension.lowercased() == "component" {
                guard let info = Bundle(url: bundleURL)?.infoDictionary,
                      let comps = info["AudioComponents"] as? [[String: Any]] else { continue }
                for comp in comps {
                    guard let type = comp["type"] as? String,
                          let subtype = comp["subtype"] as? String,
                          let manufacturer = comp["manufacturer"] as? String else { continue }
                    index[AUCodeKey(type: type, subtype: subtype, manufacturer: manufacturer)] = bundleURL
                }
            }
        }
        return index
    }

    // MARK: - VST Discovery

    nonisolated private func scanVSTDirectory(_ directory: URL, type: PluginType) -> [AudioPlugin] {
        guard let ext = type.fileExtension else { return [] }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            return contents
                .filter { $0.pathExtension.lowercased() == ext }
                .map { url in
                    let name = url.deletingPathExtension().lastPathComponent
                    let manufacturer = extractManufacturerFromBundle(url) ?? "Unknown"
                    return AudioPlugin(
                        name: name, manufacturer: manufacturer, type: type, fileURL: url,
                        version: extractVersionFromBundle(url),
                        category: detectVSTCategory(type: type, bundleURL: url, userDefaults: userDefaults)
                    )
                }
        } catch {
            return []
        }
    }

    nonisolated private func scanDisabledPlugins(extension ext: String, type: PluginType) -> [AudioPlugin] {
        guard FileManager.default.fileExists(atPath: disabledFolderURL.path) else { return [] }
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: disabledFolderURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            return contents
                .filter { $0.pathExtension.lowercased() == ext }
                .map { url in
                    let name = url.deletingPathExtension().lastPathComponent
                    let manufacturer = extractManufacturerFromBundle(url) ?? "Unknown"
                    return AudioPlugin(
                        name: name, manufacturer: manufacturer, type: type, fileURL: url,
                        version: extractVersionFromBundle(url),
                        category: detectVSTCategory(type: type, bundleURL: url, userDefaults: userDefaults)
                    )
                }
        } catch {
            return []
        }
    }

    nonisolated private func extractManufacturerFromBundle(_ url: URL) -> String? {
        guard url.isFileURL,
              let bundle = Bundle(url: url),
              let info = bundle.infoDictionary else { return nil }
        return info["CFBundleGetInfoString"] as? String
            ?? info["NSHumanReadableCopyright"] as? String
            ?? info["CFBundleIdentifier"] as? String
    }

    nonisolated private func extractVersionFromBundle(_ url: URL) -> String? {
        guard url.isFileURL,
              let bundle = Bundle(url: url),
              let info = bundle.infoDictionary else { return nil }
        return info["CFBundleShortVersionString"] as? String
            ?? info["CFBundleVersion"] as? String
    }

    // MARK: - Plugin Testing

    func testPlugin(_ plugin: AudioPlugin) {
        Task {
            await performTest(plugin)
        }
    }

    func testAllUntested() {
        Task {
            let untested = plugins.filter {
                if case .untested = $0.status { return true }
                return false
            }
            for plugin in untested {
                await performTest(plugin)
            }
        }
    }

    private func performTest(_ plugin: AudioPlugin) async {
        plugin.status = .testing
        notifyPluginsChanged()

        switch plugin.type {
        case .audioUnit:
            await testAudioUnit(plugin)
        case .vst2:
            testVSTBundle(plugin, expectedSymbol: "VSTPluginMain")
        case .vst3:
            testVSTBundle(plugin, expectedSymbol: "GetPluginFactory")
        }

        recordTestResult(for: plugin)
        notifyPluginsChanged()
    }

    /// AudioPlugin's status/category are @Published on the plugin instance
    /// itself, but PluginManager's own @Published `plugins` array only fires
    /// for other views (e.g. My Projects, which reads pluginManager.plugins
    /// via @EnvironmentObject) when the array is reassigned — an in-place
    /// mutation to one plugin's status doesn't trigger that. Call this after
    /// mutating any plugin's status/category outside of scan().
    private func notifyPluginsChanged() {
        plugins = plugins
    }

    private func testAudioUnit(_ plugin: AudioPlugin) async {
        guard let desc = plugin.audioComponentDescription else {
            plugin.status = .failed("No component description")
            return
        }

        return await withCheckedContinuation { continuation in
            AVAudioUnit.instantiate(with: desc, options: []) { avAudioUnit, error in
                Task { @MainActor in
                    if let error = error {
                        plugin.status = .failed(error.localizedDescription)
                    } else if avAudioUnit != nil {
                        plugin.status = .active
                    } else {
                        plugin.status = .failed("Could not instantiate")
                    }
                    continuation.resume()
                }
            }
        }
    }

    private func testVSTBundle(_ plugin: AudioPlugin, expectedSymbol: String) {
        let url = plugin.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            plugin.status = .failed("File not found")
            return
        }

        guard let bundle = Bundle(url: url),
              let executableURL = bundle.executableURL else {
            plugin.status = .failed("Cannot find bundle executable")
            return
        }

        // Use nm to inspect the symbol table without loading the plugin code,
        // avoiding crashes from buggy plugin initializers (EXC_BAD_ACCESS).
        guard let data = runProcessCapturingStdout(
            executable: "/usr/bin/nm",
            arguments: ["-g", "--defined-only", executableURL.path]
        ) else {
            plugin.status = .failed("Cannot inspect binary")
            return
        }
        let output = String(data: data, encoding: .utf8) ?? ""
        if output.contains(expectedSymbol) {
            plugin.status = .active
        } else {
            plugin.status = .failed("Missing entry point '\(expectedSymbol)'")
        }
    }

    // MARK: - Disable / Enable

    func disableAllFailing() {
        Task {
            let failing = plugins.filter {
                if case .failed = $0.status { return true }
                return false
            }
            for plugin in failing {
                await movePlugin(plugin, toDisabled: true)
            }
        }
    }

    func disablePlugin(_ plugin: AudioPlugin) {
        Task {
            await movePlugin(plugin, toDisabled: true)
        }
    }

    func enablePlugin(_ plugin: AudioPlugin) {
        Task {
            await movePlugin(plugin, toDisabled: false)
        }
    }

    private func movePlugin(_ plugin: AudioPlugin, toDisabled: Bool) async {
        let fm = FileManager.default
        let source = plugin.fileURL
        let verb = toDisabled ? "disable" : "re-enable"

        // Never move anything that isn't a plugin bundle sitting in a directory
        // AudioBunny manages. Historically an AU's fileURL could be garbage; a
        // privileged `mv` on a bad path is exactly what must never happen.
        guard fm.fileExists(atPath: source.path), isSafePluginPath(source) else {
            plugin.status = .failed("Couldn't \(verb) — \(source.lastPathComponent) isn't in a folder AudioBunny manages. Move it by hand instead.")
            notifyPluginsChanged()
            return
        }

        let destinationFolder: URL
        if toDisabled {
            destinationFolder = disabledFolderURL
        } else {
            // Put it back exactly where it came from — a plugin disabled out of
            // the system `/Library/…` must not reappear under `~/Library/…`.
            let origins = loadDisabledOrigins()
            destinationFolder = origins[source.lastPathComponent].map { URL(fileURLWithPath: $0) }
                ?? restoreDestination(for: plugin.type)
        }

        try? fm.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let destination = destinationFolder.appendingPathComponent(source.lastPathComponent)

        // If something is already parked at the destination, move it aside —
        // never delete it. A stale copy here is still someone's plugin.
        if fm.fileExists(atPath: destination.path) {
            let stale = destination.deletingLastPathComponent()
                .appendingPathComponent("\(destination.lastPathComponent).stale-\(Int(Date().timeIntervalSince1970))")
            try? fm.moveItem(at: destination, to: stale)
        }

        // Most plugins live under root-owned /Library/Audio/Plug-Ins/…, which a
        // plain move can't touch — fall back to an admin-privileged move (macOS
        // shows its standard auth prompt) rather than silently failing.
        let moved = await Task.detached(priority: .userInitiated) {
            moveItemElevatingIfNeeded(from: source, to: destination)
        }.value

        guard moved else {
            plugin.status = .failed("Couldn't \(verb) \(source.lastPathComponent) — the file move was denied. Approve the macOS permission prompt, or move it by hand.")
            notifyPluginsChanged()
            return
        }

        var origins = loadDisabledOrigins()
        if toDisabled {
            origins[source.lastPathComponent] = source.deletingLastPathComponent().path
            saveDisabledOrigins(origins)
            plugin.status = .disabled
            notifyPluginsChanged()
        } else {
            origins.removeValue(forKey: source.lastPathComponent)
            saveDisabledOrigins(origins)
            plugin.status = .untested
            await scan() // picks up the plugin's new location
        }
    }

    private func restoreDestination(for type: PluginType) -> URL {
        switch type {
        case .audioUnit: return userAUPath
        case .vst2: return userVST2Path
        case .vst3: return userVST3Path
        }
    }

    /// Where re-enabling would put this plugin back — its recorded origin if we
    /// have one, otherwise the user plug-ins folder for its format.
    func restorePath(for plugin: AudioPlugin) -> String {
        loadDisabledOrigins()[plugin.fileURL.lastPathComponent]
            ?? restoreDestination(for: plugin.type).path
    }

    /// True only for a real plugin bundle sitting directly inside one of the
    /// plug-in directories AudioBunny knows about — the guard before any move.
    nonisolated func isSafePluginPath(_ url: URL) -> Bool {
        guard ["component", "vst", "vst3"].contains(url.pathExtension.lowercased()) else { return false }
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        let allowed = [
            systemAUPath, userAUPath, systemVST2Path, userVST2Path,
            systemVST3Path, userVST3Path, disabledFolderURL,
            URL(fileURLWithPath: "/System/Library/Components"),
        ]
        return allowed.contains { $0.standardizedFileURL.path == parent }
    }

    // MARK: - Disabled-plugin origins (so re-enable restores the exact folder)

    /// filename → the directory it was disabled out of. Persisted in Application
    /// Support (not UserDefaults) so it survives even a defaults reset.
    nonisolated private var disabledOriginsFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioBunny", isDirectory: true)
        return dir.appendingPathComponent("disabled-origins.json")
    }

    nonisolated func loadDisabledOrigins() -> [String: String] {
        guard let data = try? Data(contentsOf: disabledOriginsFileURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    nonisolated private func saveDisabledOrigins(_ map: [String: String]) {
        let url = disabledOriginsFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Delete (Uninstall)

    func deletePlugin(_ plugin: AudioPlugin) {
        Task {
            let fm = FileManager.default
            do {
                try fm.removeItem(at: plugin.fileURL)
                plugins.removeAll { $0.id == plugin.id }
            } catch {
                print("Failed to delete \(plugin.name): \(error)")
            }
        }
    }
}

// MARK: - Audio Unit identity helpers

/// The literal 4-character codes an Audio Unit registers under, as written in a
/// `.component` bundle's Info.plist `AudioComponents` array. Used to pair an
/// `AVAudioUnitComponent` (which only hands us OSType integers) with its bundle.
struct AUCodeKey: Hashable {
    let type: String
    let subtype: String
    let manufacturer: String
}

/// An OSType as its raw 4-byte string, WITHOUT the whitespace trimming that
/// `AudioPlugin`'s display formatter applies — codes like `"appl"`, `"-NI-"` or
/// `"out "` must round-trip byte-for-byte to match Info.plist entries.
func auCodeString(_ value: OSType) -> String {
    let bytes: [UInt8] = [
        UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
    ]
    return String(bytes: bytes, encoding: .isoLatin1) ?? ""
}

/// The Mac's current OS build string (e.g. "24F74"). Plugin test results are
/// scoped to it — see `PluginManager.testHistoryKey`.
func currentOSBuild() -> String {
    if let dict = NSDictionary(contentsOfFile: "/System/Library/CoreServices/SystemVersion.plist"),
       let build = dict["ProductBuildVersion"] as? String {
        return build
    }
    return ProcessInfo.processInfo.operatingSystemVersionString
}

extension AudioPlugin {
    /// Stable across rescans and independent of file location, so it survives the
    /// plugin being moved in and out of the Disabled folder. AU: its 4-char codes
    /// (or name+manufacturer when we have no component description, e.g. a bundle
    /// found only in the Disabled folder). VST: the bundle path, which is real
    /// and unique. This is the dedup key in `PluginManager.scan()`.
    var identityKey: String {
        switch type {
        case .audioUnit:
            if let d = audioComponentDescription {
                return "au:\(auCodeString(d.componentType))/\(auCodeString(d.componentSubType))/\(auCodeString(d.componentManufacturer))"
            }
            return "au:\(name.lowercased())|\(manufacturer.lowercased())"
        case .vst2, .vst3:
            return "\(type.rawValue):\(fileURL.standardizedFileURL.path)"
        }
    }
}

// MARK: - Category Detection (free functions: not actor-isolated, unit-testable)

/// Maps an Audio Unit's component type to instrument/effect.
func categoryForAUComponentType(_ type: OSType) -> PluginCategory {
    switch type {
    case kAudioUnitType_MusicDevice, kAudioUnitType_Generator:
        return .instrument
    default:
        return .effect
    }
}

/// Best-effort: modern VST3 bundles ship Contents/Resources/moduleinfo.json
/// listing each class's category (e.g. "Instrument|Synth" or "Fx"). Not all
/// VST3 plugins include it, so this can return nil.
func categoryFromVST3ModuleInfo(_ bundleURL: URL) -> PluginCategory? {
    let infoURL = bundleURL.appendingPathComponent("Contents/Resources/moduleinfo.json")
    guard let data = try? Data(contentsOf: infoURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let classes = json["Classes"] as? [[String: Any]] else { return nil }
    for cls in classes {
        guard let category = cls["Category"] as? String else { continue }
        if category.localizedCaseInsensitiveContains("Instrument") { return .instrument }
        if category.localizedCaseInsensitiveContains("Fx") { return .effect }
    }
    return nil
}

/// Best-effort: some vendors (e.g. Native Instruments) encode the plugin kind
/// directly in the bundle identifier, like "Absynth 5.Synth.vst" (instrument)
/// vs "Guitar Rig 6.FX.vst" (effect). Not universal — plenty of vendors don't
/// follow this convention — but a real, useful signal when present, and safe:
/// it only reads Info.plist, never loads the plugin.
func categoryFromBundleIdentifier(_ bundleURL: URL) -> PluginCategory? {
    guard bundleURL.isFileURL,
          let bundle = Bundle(url: bundleURL),
          let identifier = bundle.bundleIdentifier else { return nil }
    let lower = identifier.lowercased()
    if lower.contains(".synth") { return .instrument }
    if lower.contains(".fx") { return .effect }
    return nil
}

/// Combines the available signals for a VST2/VST3 bundle, safest first:
/// VST3's moduleinfo.json (structured, no code execution) → the bundle
/// identifier naming convention (no code execution) → for VST2 only, as a
/// last resort, actually probing the plugin's entry point (runs real vendor
/// code in an isolated, timeout-guarded subprocess — can crash or hang, but
/// both are contained, and the outcome is cached forever either way so we
/// only ever pay that cost once per plugin — see categoryFromVST2Probe).
func detectVSTCategory(type: PluginType, bundleURL: URL, userDefaults: UserDefaults = .standard) -> PluginCategory? {
    if type == .vst3, let category = categoryFromVST3ModuleInfo(bundleURL) {
        return category
    }
    if let category = categoryFromBundleIdentifier(bundleURL) {
        return category
    }
    if type == .vst2 {
        return categoryFromVST2Probe(bundleURL, userDefaults: userDefaults)
    }
    return nil
}

/// True if the Mach-O binary at `url` has no arm64 slice — i.e. it needs
/// Rosetta translation (`arch -x86_64`) to run on Apple Silicon.
func isX86_64Only(_ url: URL) -> Bool {
    guard let data = runProcessCapturingStdout(executable: "/usr/bin/lipo", arguments: ["-info", url.path]),
          let output = String(data: data, encoding: .utf8) else { return false }
    return output.contains("x86_64") && !output.contains("arm64")
}

private let vst2ProbeCacheDefaultsKey = "audiobunny.vst2ProbeCache"

/// Last-resort VST2 detection: calls the plugin's real entry point (VSTPluginMain)
/// via the bundled VST2Prober helper to read AEffect.flags — the only place VST2
/// records instrument-vs-effect. Runs in an isolated, timeout-guarded subprocess
/// since this executes real vendor code, which can crash or hang. Requires
/// VST2Prober to sit next to the running app's executable (the Makefile copies
/// it there); if it's missing (e.g. running the raw `swift build` binary
/// directly, not the packaged .app), this simply returns nil.
///
/// The outcome — including "couldn't determine" — is cached permanently per
/// plugin path, exactly like a DAW's plugin database: real hosts pay this same
/// crash/hang risk once per plugin during their scan and then never touch that
/// plugin's entry point again. Without caching, an unresolved plugin (crashed
/// or timed out) would retry — and re-risk hanging for the full timeout — on
/// every single rescan.
func categoryFromVST2Probe(_ bundleURL: URL, userDefaults: UserDefaults = .standard) -> PluginCategory? {
    guard let bundle = Bundle(url: bundleURL), let executableURL = bundle.executableURL else { return nil }
    let cacheKey = executableURL.path

    var cache = (userDefaults.dictionary(forKey: vst2ProbeCacheDefaultsKey) as? [String: String]) ?? [:]
    if let cached = cache[cacheKey] {
        switch cached {
        case "instrument": return .instrument
        case "effect": return .effect
        default: return nil
        }
    }

    let result = probeVST2Category(executableURL: executableURL)
    cache[cacheKey] = result.map { $0 == .instrument ? "instrument" : "effect" } ?? "unknown"
    userDefaults.set(cache, forKey: vst2ProbeCacheDefaultsKey)
    return result
}

/// The actual (uncached) probe: locates the helper, picks native vs.
/// Rosetta-translated invocation based on the plugin's architecture, and runs
/// it with a timeout.
private func probeVST2Category(executableURL: URL) -> PluginCategory? {
    let proberURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("VST2Prober")
    guard let proberURL, FileManager.default.isExecutableFile(atPath: proberURL.path) else { return nil }

    let executable: String
    let arguments: [String]
    if isX86_64Only(executableURL) {
        executable = "/usr/bin/arch"
        arguments = ["-x86_64", proberURL.path, executableURL.path]
    } else {
        executable = proberURL.path
        arguments = [executableURL.path]
    }

    guard let data = runProcessWithTimeout(executable: executable, arguments: arguments, timeoutSeconds: 3),
          let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    else { return nil }

    switch output {
    case "instrument": return .instrument
    case "effect": return .effect
    default: return nil
    }
}

/// A plugin may exist as multiple format variants (AU/VST2/VST3) under the same
/// name. AU's category comes straight from its component type, so prefer it when
/// present; otherwise fall back to any other variant's best-effort category.
func preferredCategory(for group: [AudioPlugin]) -> PluginCategory? {
    if let au = group.first(where: { $0.type == .audioUnit })?.category { return au }
    return group.compactMap(\.category).first
}

// MARK: - Process Helper

/// Runs a process and returns its captured stdout, or nil if it couldn't be launched.
///
/// Reads stdout to EOF *before* calling `waitUntilExit()` — a process whose output
/// exceeds the pipe's kernel buffer (~64KB) will block writing more until it's
/// drained, so waiting on exit first deadlocks. Stderr is discarded via
/// `/dev/null` rather than an unread `Pipe()`, which has the same deadlock/fd-leak
/// problem. (This exact bug previously caused a hang/leak in VST symbol testing.)
func runProcessCapturingStdout(executable: String, arguments: [String]) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    try? pipe.fileHandleForReading.close()
    process.waitUntilExit()
    return data
}

/// Like `runProcessCapturingStdout`, but force-kills (SIGKILL) the process if
/// it doesn't finish within `timeoutSeconds`, returning nil in that case.
/// Reserved for probing untrusted plugin code that may hang, not just crash —
/// prefer `runProcessCapturingStdout` for trusted system tools.
func runProcessWithTimeout(executable: String, arguments: [String], timeoutSeconds: Double) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    let semaphore = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in semaphore.signal() }

    guard (try? process.run()) != nil else { return nil }

    if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        return nil
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    try? pipe.fileHandleForReading.close()
    return data
}

// MARK: - Privileged File Moves

/// Moves a file via `FileManager`, falling back to an admin-privileged move
/// (prompting the user for their password, the same way Finder would) when
/// the plain move fails. Most installed plugins live under the root-owned
/// `/Library/Audio/Plug-Ins/…`, not the user-writable `~/Library` copy, so a
/// plain `moveItem` there always fails with a permissions error.
func moveItemElevatingIfNeeded(from source: URL, to destination: URL) -> Bool {
    if (try? FileManager.default.moveItem(at: source, to: destination)) != nil {
        return true
    }
    return privilegedMove(from: source.path, to: destination.path)
}

/// Runs `mv <from> <to>` with administrator privileges via AppleScript's
/// `do shell script … with administrator privileges`, which triggers the
/// standard macOS authentication dialog. Reserved as a fallback for when a
/// plain move fails due to permissions — never used as the first attempt.
private func privilegedMove(from sourcePath: String, to destPath: String) -> Bool {
    let command = "mv \(shellQuoted(sourcePath)) \(shellQuoted(destPath))"
    let script = "do shell script \(appleScriptQuoted(command)) with administrator privileges"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

/// Wraps a path in single quotes for safe embedding in a shell command,
/// escaping any embedded single quotes.
private func shellQuoted(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Escapes a (already shell-quoted) string for embedding inside an
/// AppleScript double-quoted string literal.
private func appleScriptQuoted(_ command: String) -> String {
    let escaped = command
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

// MARK: - Async Timeout Helper

enum TimeoutResult<T> {
    case completed(T)
    case timedOut
}

/// Races `operation` against a `seconds`-long sleep and returns whichever
/// finishes first. Unlike `runProcessWithTimeout`, this doesn't kill anything
/// on timeout — it's for racing arbitrary async work (e.g. Ableton project
/// parsing), where "timed out" and "the operation itself returned normally"
/// need to stay distinguishable to the caller.
func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async -> T
) async -> TimeoutResult<T> {
    await withTaskGroup(of: TimeoutResult<T>.self) { group in
        group.addTask {
            .completed(await operation())
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return .timedOut
        }
        let first = await group.next()!
        group.cancelAll()
        return first
    }
}
