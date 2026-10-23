import Foundation

// MARK: - Plugins presets can be matched against

/// One installed plugin (all of its formats folded together) as preset
/// detection sees it: its name, who makes it, and the codes its preset files
/// can carry in their headers.
struct PresetPluginCandidate: Hashable, Sendable, Identifiable {
    let name: String
    /// Used for the standard `~/Library/Audio/Presets/<manufacturer>/<name>` folder.
    let manufacturer: String
    /// Audio Unit 4-char subtype codes. JUCE (and most vendors) reuse the AU
    /// subtype as the VST2 unique ID, so these also match `.fxp` headers.
    var auSubtypes: Set<String> = []
    /// "type|subtype|manufacturer" 4-char AU codes, as an `.aupreset` records them.
    var auComponents: Set<String> = []
    /// VST3 class IDs (32 uppercase hex chars) from the bundle's moduleinfo.json.
    var vst3ClassIDs: Set<String> = []

    var id: String { matchKey }
    var matchKey: String { presetMatchKey(name) }
}

/// Lowercase letters and digits only, so "Pro-Q 3", "Pro Q3" and "pro-q-3" all compare equal.
func presetMatchKey(_ name: String) -> String {
    String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
}

/// Folds the scanned plugins (one entry per format) into one candidate per
/// plugin name. The AU's manufacturer name wins for the preset folder, since
/// VST bundles only offer a copyright string; then the VST3 moduleinfo vendor.
func presetCandidates(from plugins: [(name: String, manufacturer: String, type: PluginType,
                                      fileURL: URL, auCodes: AUCodeKey?)]) -> [PresetPluginCandidate] {
    var byKey: [String: (name: String, auMaker: String?, vendor: String?,
                         subtypes: Set<String>, components: Set<String>, cids: Set<String>)] = [:]
    var order: [String] = []
    for plugin in plugins {
        let key = presetMatchKey(plugin.name)
        guard !key.isEmpty else { continue }
        if byKey[key] == nil {
            byKey[key] = (plugin.name, nil, nil, [], [], [])
            order.append(key)
        }
        switch plugin.type {
        case .audioUnit:
            if let codes = plugin.auCodes {
                byKey[key]!.subtypes.insert(codes.subtype)
                byKey[key]!.components.insert("\(codes.type)|\(codes.subtype)|\(codes.manufacturer)")
            }
            if byKey[key]!.auMaker == nil, !plugin.manufacturer.isEmpty { byKey[key]!.auMaker = plugin.manufacturer }
        case .vst3:
            let info = vst3ModuleInfo(plugin.fileURL)
            byKey[key]!.cids.formUnion(info.classIDs)
            if byKey[key]!.vendor == nil { byKey[key]!.vendor = info.vendor }
        case .vst2:
            break
        }
    }
    return order.map { key in
        let entry = byKey[key]!
        return PresetPluginCandidate(name: entry.name,
                                     manufacturer: entry.auMaker ?? entry.vendor ?? entry.name,
                                     auSubtypes: entry.subtypes, auComponents: entry.components,
                                     vst3ClassIDs: entry.cids)
    }
}

/// Class IDs and vendor from a VST3 bundle's Contents/Resources/moduleinfo.json
/// (which is JSON5: trailing commas are common). Empty when the bundle has none.
func vst3ModuleInfo(_ bundleURL: URL) -> (classIDs: Set<String>, vendor: String?) {
    let infoURL = bundleURL.appendingPathComponent("Contents/Resources/moduleinfo.json")
    guard let data = try? Data(contentsOf: infoURL),
          let json = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any]
    else { return ([], nil) }
    let classes = json["Classes"] as? [[String: Any]] ?? []
    let ids = Set(classes.compactMap { ($0["CID"] as? String)?.uppercased() })
    let vendor = (json["Factory Info"] as? [String: Any])?["Vendor"] as? String
    return (ids, vendor?.isEmpty == false ? vendor : nil)
}

// MARK: - Recognising preset files

/// Extensions treated as presets when dropped (compared lowercased).
let presetFileExtensions: Set<String> = [
    "fxp", "fxb",          // VST2 program / bank (Serum 1 and most VST2 synths)
    "aupreset",            // Audio Unit
    "vstpreset",           // VST3
    "vital",               // Vital
    "serumpreset",         // Serum 2
    "h2p",                 // u-he (Diva, Zebra, Repro, Hive, …)
    "ngrr",                // Guitar Rig
    "nmsv",                // Massive
]

func isPresetFile(_ url: URL) -> Bool {
    presetFileExtensions.contains(url.pathExtension.lowercased())
}

/// VST2 unique IDs of plugins whose AU subtype differs (or that have no AU),
/// mapped to the plugin name they belong to.
private let knownVST2IDs: [String: String] = [
    "XfsX": "Serum",
]

/// Formats only one plugin writes, keyed by extension → plugin name keys that
/// may claim it (first installed one wins).
private let extensionOwners: [String: [String]] = [
    "vital": ["vital"],
    "serumpreset": ["serum2", "serum"],
    "ngrr": ["guitarrig7", "guitarrig6", "guitarrig5", "guitarrig"],
    "nmsv": ["massive"],
]

/// Which installed plugin a preset file belongs to: first from what the file
/// itself records (AU codes, VST2 ID, VST3 class ID or plugin name, u-he's
/// product line), then from formats only one plugin uses, then from a plugin
/// name in the file or folder names. `contextNames` are the enclosing folder
/// names, innermost first, up to the folder that was dropped.
func detectPresetPlugin(at url: URL, contextNames: [String] = [],
                        plugins: [PresetPluginCandidate]) -> PresetPluginCandidate? {
    let ext = url.pathExtension.lowercased()
    switch ext {
    case "aupreset":
        if let codes = auPresetCodes(url) {
            let full = "\(codes.type)|\(codes.subtype)|\(codes.manufacturer)"
            if let match = plugins.first(where: { $0.auComponents.contains(full) }) { return match }
            let partial = "|\(codes.subtype)|\(codes.manufacturer)"
            if let match = plugins.first(where: { plugin in plugin.auComponents.contains { $0.hasSuffix(partial) } }) { return match }
        }
    case "fxp", "fxb":
        if let id = fxpPluginID(url) {
            if let match = plugins.first(where: { $0.auSubtypes.contains(id) }) { return match }
            if let name = knownVST2IDs[id], let match = pluginNamed(name, in: plugins) { return match }
        }
    case "vstpreset":
        if let header = vstPresetHeader(url) {
            if let match = plugins.first(where: { $0.vst3ClassIDs.contains(header.classID) }) { return match }
            if let name = header.pluginName, let match = pluginNamed(name, in: plugins) { return match }
        }
    case "h2p":
        if let name = h2pProductName(url), let match = pluginNamed(name, in: plugins) { return match }
    default:
        break
    }
    if let owners = extensionOwners[ext] {
        for key in owners {
            if let match = plugins.first(where: { $0.matchKey == key }) { return match }
        }
        // e.g. "Guitar Rig 8" when only older versions are listed above.
        if let prefix = owners.last,
           let match = plugins.filter({ $0.matchKey.hasPrefix(prefix) }).max(by: { $0.matchKey < $1.matchKey }) {
            return match
        }
    }
    for name in [url.deletingPathExtension().lastPathComponent] + contextNames {
        if let match = pluginMentioned(in: name, plugins: plugins) { return match }
    }
    return nil
}

/// The plugin whose name is `name` (ignoring case and punctuation).
func pluginNamed(_ name: String, in plugins: [PresetPluginCandidate]) -> PresetPluginCandidate? {
    let key = presetMatchKey(name)
    guard !key.isEmpty else { return nil }
    return plugins.first { $0.matchKey == key }
}

/// The plugin whose name appears inside `text` — the longest such name, so
/// "Serum 2 Basses" picks Serum 2 over Serum. Names under 4 characters are too
/// likely to be accidental hits and never match this way.
func pluginMentioned(in text: String, plugins: [PresetPluginCandidate]) -> PresetPluginCandidate? {
    let haystack = presetMatchKey(text)
    return plugins
        .filter { $0.matchKey.count >= 4 && haystack.contains($0.matchKey) }
        .max { $0.matchKey.count < $1.matchKey.count }
}

/// An OSType integer as its 4-char code.
func fourCharCode(_ value: UInt32) -> String {
    let bytes = [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    return String(bytes: bytes, encoding: .isoLatin1) ?? ""
}

/// The AU type/subtype/manufacturer codes an `.aupreset` (a property list) was saved from.
func auPresetCodes(_ url: URL) -> AUCodeKey? {
    guard let data = try? Data(contentsOf: url),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return nil }
    func code(_ key: String) -> String? {
        guard let number = plist[key] as? NSNumber else { return nil }
        return fourCharCode(UInt32(truncatingIfNeeded: number.int64Value))
    }
    guard let type = code("type"), let subtype = code("subtype"), let manufacturer = code("manufacturer") else { return nil }
    return AUCodeKey(type: type, subtype: subtype, manufacturer: manufacturer)
}

/// The plugin's unique ID from a VST2 `.fxp`/`.fxb` header: big-endian, starting
/// "CcnK", then size, then the chunk magic ("FxCk", "FPCh", "FxBk", "FBCh"),
/// version, and the 4-char plugin ID at byte 16.
func fxpPluginID(_ url: URL) -> String? {
    guard let header = readPrefix(of: url, count: 20), header.count == 20,
          String(bytes: header[0..<4], encoding: .isoLatin1) == "CcnK",
          let magic = String(bytes: header[8..<12], encoding: .isoLatin1),
          ["FxCk", "FPCh", "FxBk", "FBCh"].contains(magic)
    else { return nil }
    return String(bytes: header[16..<20], encoding: .isoLatin1)
}

/// A VST3 `.vstpreset`: "VST3", a 4-byte version, then the plugin's class ID as
/// 32 ASCII hex chars. Most hosts also append an XML metadata chunk naming the
/// plugin (`<Attribute id="PlugInName" value="…"/>`), used when the class ID
/// doesn't match anything installed.
func vstPresetHeader(_ url: URL) -> (classID: String, pluginName: String?)? {
    guard let data = readPrefix(of: url, count: 8 * 1024 * 1024), data.count >= 40,
          String(bytes: data[0..<4], encoding: .isoLatin1) == "VST3",
          let classID = String(bytes: data[8..<40], encoding: .isoLatin1)?.uppercased()
    else { return nil }
    var name: String?
    if let text = String(data: data, encoding: .isoLatin1),
       let range = text.range(of: #"id="PlugInName"[^>]*?value="([^"]+)""#, options: .regularExpression) {
        let match = String(text[range])
        if let valueStart = match.range(of: "value=\"") {
            name = String(match[valueStart.upperBound...].dropLast())
        }
    }
    return (classID, name)
}

/// The u-he product an `.h2p` was saved from — its `#AM=` line (e.g. "#AM=Diva").
func h2pProductName(_ url: URL) -> String? {
    guard let data = readPrefix(of: url, count: 64 * 1024),
          let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    else { return nil }
    for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("#AM=") {
        let value = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
    return nil
}

private func readPrefix(of url: URL, count: Int) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    return try? handle.read(upToCount: count)
}

// MARK: - Where presets go

/// The folder a plugin reads user presets from. Vendor layouts we know first;
/// everything else uses the standard macOS preset location hosts and most
/// plugins scan, `~/Library/Audio/Presets/<manufacturer>/<plugin>`.
func presetInstallFolder(for plugin: PresetPluginCandidate, fileExtension: String, home: URL) -> URL {
    let key = plugin.matchKey
    let ext = fileExtension.lowercased()
    let relative: String
    if key == "serum2" || ext == "serumpreset" {
        relative = "Documents/Xfer/Serum 2 Presets/Presets/User"
    } else if key == "serum" {
        relative = "Documents/Xfer/Serum Presets/Presets/User"
    } else if key == "vital" {
        relative = "Music/Vital/User/Presets"
    } else if ext == "h2p" {
        relative = "Library/Audio/Presets/u-he/\(safePathComponent(plugin.name))"
    } else if key.hasPrefix("guitarrig") {
        relative = "Documents/Native Instruments/\(safePathComponent(plugin.name))/Presets"
    } else {
        relative = "Library/Audio/Presets/\(safePathComponent(plugin.manufacturer))/\(safePathComponent(plugin.name))"
    }
    return home.appendingPathComponent(relative, isDirectory: true)
}

/// A name usable as one folder name: no path separators, never "." or "..".
func safePathComponent(_ name: String) -> String {
    let cleaned = name.replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Unknown" : cleaned
}

// MARK: - Collecting what was dropped

/// One preset file waiting to be installed.
struct PresetInstallItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let source: URL
    /// Folders between the dropped folder (included, so a dropped pack keeps its
    /// name) and the file, recreated under the plugin's preset folder. Empty
    /// for a file dropped on its own.
    let relativeFolder: [String]
    var plugin: PresetPluginCandidate?
}

/// What a drop contained.
struct DroppedFiles: Sendable {
    var presets: [PresetInstallItem] = []
    /// `.component` / `.vst` / `.vst3` bundles, for the plugin installer.
    var pluginBundles: [URL] = []
    /// Files that are neither (left alone).
    var ignored: [URL] = []
}

/// Sorts dropped files and folders into presets (matched to `plugins`) and
/// plugin bundles. Folders are searched recursively; `.zip` archives are
/// extracted into `extractionRoot` and searched the same way.
func collectDroppedFiles(_ urls: [URL], plugins: [PresetPluginCandidate],
                         extractionRoot: URL? = nil) -> DroppedFiles {
    var result = DroppedFiles()
    let fm = FileManager.default

    func addPreset(_ url: URL, folders: [String]) {
        let item = PresetInstallItem(
            source: url, relativeFolder: folders,
            plugin: detectPresetPlugin(at: url, contextNames: folders.reversed(), plugins: plugins))
        result.presets.append(item)
    }

    func walk(_ root: URL, rootName: String) {
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        let rootComponents = root.standardizedFileURL.pathComponents.count
        for case let url as URL in enumerator {
            if PluginType(bundleExtension: url.pathExtension) != nil {
                result.pluginBundles.append(url)
                enumerator.skipDescendants()
                continue
            }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                // Finder's zip metadata, not part of the pack.
                if url.lastPathComponent == "__MACOSX" { enumerator.skipDescendants() }
                continue
            }
            let parents = Array(url.deletingLastPathComponent().standardizedFileURL.pathComponents.dropFirst(rootComponents))
            if isPresetFile(url) {
                addPreset(url, folders: [rootName] + parents)
            } else {
                result.ignored.append(url)
            }
        }
    }

    for url in urls {
        if PluginType(bundleExtension: url.pathExtension) != nil {
            result.pluginBundles.append(url)
            continue
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
        if isDir.boolValue {
            walk(url, rootName: url.lastPathComponent)
        } else if isPresetFile(url) {
            addPreset(url, folders: [])
        } else if url.pathExtension.lowercased() == "zip", let extractionRoot,
                  let extracted = extractZip(url, into: extractionRoot) {
            // Most packs zip a single top folder; use it (and its name) as the
            // pack rather than nesting it under the archive's name.
            let top = (try? fm.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles]))?
                .filter { $0.lastPathComponent != "__MACOSX" } ?? []
            var topIsDir: ObjCBool = false
            if top.count == 1, fm.fileExists(atPath: top[0].path, isDirectory: &topIsDir), topIsDir.boolValue,
               PluginType(bundleExtension: top[0].pathExtension) == nil {
                walk(top[0], rootName: top[0].lastPathComponent)
            } else {
                walk(extracted, rootName: url.deletingPathExtension().lastPathComponent)
            }
        } else {
            result.ignored.append(url)
        }
    }
    return result
}

/// Unzips with `ditto` (handles Finder-made archives and resource forks) into a
/// fresh folder under `root`. Nil if extraction fails or takes over two minutes.
func extractZip(_ zip: URL, into root: URL) -> URL? {
    let dest = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    guard (try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)) != nil,
          runProcessWithTimeout(executable: "/usr/bin/ditto", arguments: ["-x", "-k", zip.path, dest.path],
                                timeoutSeconds: 120) != nil
    else { return nil }
    return dest
}

// MARK: - Installing

enum PresetInstallOutcome: Equatable, Sendable {
    case installed(URL)
    /// An identical file was already there; nothing was copied.
    case alreadyInstalled(URL)
}

enum PresetInstallError: LocalizedError, Equatable {
    case noPlugin
    case unsafePath

    var errorDescription: String? {
        switch self {
        case .noPlugin: return "No plugin chosen for this preset."
        case .unsafePath: return "That folder isn't somewhere AudioBunny will touch."
        }
    }
}

/// Where `item` will be copied: the plugin's preset folder plus the dropped
/// folder structure, never outside the home folder.
func presetDestination(for item: PresetInstallItem, home: URL) throws -> URL {
    guard let plugin = item.plugin else { throw PresetInstallError.noPlugin }
    var folder = presetInstallFolder(for: plugin, fileExtension: item.source.pathExtension, home: home)
    for component in item.relativeFolder { folder.appendPathComponent(safePathComponent(component), isDirectory: true) }
    let homePath = home.standardizedFileURL.path
    guard folder.standardizedFileURL.path.hasPrefix(homePath + "/") else { throw PresetInstallError.unsafePath }
    return folder.appendingPathComponent(item.source.lastPathComponent)
}

/// Copies the preset into place, creating folders as needed. Never overwrites:
/// an identical file already there is left as is, and a different file with
/// the same name gets a numbered copy ("Bass 2.fxp") beside it.
func installPresetFile(_ item: PresetInstallItem, home: URL) throws -> PresetInstallOutcome {
    let fm = FileManager.default
    let dest = try presetDestination(for: item, home: home)
    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard fm.fileExists(atPath: dest.path) else {
        try fm.copyItem(at: item.source, to: dest)
        return .installed(dest)
    }
    if fm.contentsEqual(atPath: dest.path, andPath: item.source.path) { return .alreadyInstalled(dest) }
    let base = dest.deletingPathExtension().lastPathComponent
    let ext = dest.pathExtension
    var n = 2
    while true {
        let candidate = dest.deletingLastPathComponent()
            .appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        if !fm.fileExists(atPath: candidate.path) {
            try fm.copyItem(at: item.source, to: candidate)
            return .installed(candidate)
        }
        if fm.contentsEqual(atPath: candidate.path, andPath: item.source.path) { return .alreadyInstalled(candidate) }
        n += 1
    }
}
