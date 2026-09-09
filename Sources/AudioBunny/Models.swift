import Foundation
import AVFoundation
import AudioToolbox

// MARK: - Plugin Types

enum PluginType: String, CaseIterable {
    case audioUnit = "Audio Unit"
    case vst2 = "VST 2"
    case vst3 = "VST 3"

    var fileExtension: String? {
        switch self {
        case .audioUnit: return "component"
        case .vst2: return "vst"
        case .vst3: return "vst3"
        }
    }
}

enum PluginStatus: Sendable {
    case untested
    case testing
    case active
    case failed(String)
    case disabled
}

extension PluginStatus: Equatable {
    static func == (lhs: PluginStatus, rhs: PluginStatus) -> Bool {
        switch (lhs, rhs) {
        case (.untested, .untested), (.testing, .testing), (.active, .active), (.disabled, .disabled): return true
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }

    var label: String {
        switch self {
        case .untested: return "Untested"
        case .testing: return "Testing..."
        case .active: return "Active"
        case .failed(let msg): return "Failed: \(msg)"
        case .disabled: return "Disabled"
        }
    }

    var color: String {
        switch self {
        case .untested: return "gray"
        case .testing: return "orange"
        case .active: return "green"
        case .failed: return "red"
        case .disabled: return "secondary"
        }
    }
}

// MARK: - Plugin Model

class AudioPlugin: ObservableObject, Identifiable, Hashable, @unchecked Sendable {
    let id = UUID()
    let name: String
    let manufacturer: String
    let type: PluginType
    let fileURL: URL
    let version: String?
    @Published var category: PluginCategory?
    @Published var status: PluginStatus = .untested

    // Audio Unit specific
    var audioComponentDescription: AudioComponentDescription?

    init(name: String, manufacturer: String, type: PluginType, fileURL: URL, version: String? = nil, category: PluginCategory? = nil, componentDescription: AudioComponentDescription? = nil) {
        self.name = name
        self.manufacturer = manufacturer
        self.type = type
        self.fileURL = fileURL
        self.version = version
        self.category = category
        self.audioComponentDescription = componentDescription
    }

    var isDisabled: Bool { status == .disabled }
    var canTest: Bool { status != .testing && status != .disabled }

    var subtypeString: String? {
        guard let desc = audioComponentDescription else { return nil }
        return fourCCToString(desc.componentSubType)
    }

    var manufacturerCodeString: String? {
        guard let desc = audioComponentDescription else { return nil }
        return fourCCToString(desc.componentManufacturer)
    }

    private func fourCCToString(_ value: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        return String(bytes: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespaces) ?? String(format: "%08X", value)
    }

    static func == (lhs: AudioPlugin, rhs: AudioPlugin) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Live Project Models

struct LiveProjectPlugin: Identifiable {
    let id = UUID()
    let name: String
    let manufacturer: String?
    let type: PluginType?

    func isInstalled(in plugins: [AudioPlugin]) -> Bool {
        let nameLower = name.lowercased()
        let nameNorm = nameLower.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        return plugins.contains { installed in
            let iLower = installed.name.lowercased()
            let iNorm = iLower.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
            return iLower == nameLower || iNorm == nameNorm
        }
    }
}

struct LiveProject: Identifiable {
    let id = UUID()
    let url: URL
    var name: String { url.deletingPathExtension().lastPathComponent }
    var plugins: [LiveProjectPlugin]
    /// True if parsing this project timed out (see LiveProjectManager.rescan) —
    /// it's still listed so it isn't silently missing, just with no plugin data.
    var timedOut: Bool = false
    /// True from the moment a folder scan discovers this file until parsing
    /// finishes — all discovered projects appear in the list immediately
    /// (see LiveProjectManager.rescan), filling in as each one is scanned.
    var pending: Bool = false
    /// True when the `.als` lives in iCloud / a File Provider and hasn't been
    /// downloaded to this Mac. It's listed but not parsed (reading it would pull
    /// down the whole file) until the user chooses to fetch it.
    var notDownloaded: Bool = false
}
