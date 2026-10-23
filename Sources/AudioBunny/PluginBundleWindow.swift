import AppKit
import AVFoundation
import AudioToolbox
import CoreAudioKit  // AUAudioUnit.requestViewController(completionHandler:)
import SwiftUI

// MARK: - Window

/// The window a `.component` / `.vst` / `.vst3` opened from Finder gets: the
/// plugin loaded (its own UI, for Audio Units) under a header that offers to
/// install it, or says it's already installed.
///
/// Kept alive via `open`, like AudioUnitPreviewWindowController — closing the
/// window releases it and the loaded Audio Unit.
@MainActor
final class PluginBundleWindowController: NSObject, NSWindowDelegate {
    private static var open: [PluginBundleWindowController] = []

    private let preview: PluginBundlePreview
    private var window: NSWindow?

    private init(preview: PluginBundlePreview) {
        self.preview = preview
    }

    static func present(url: URL, type: PluginType, manager: PluginManager) {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if let existing = open.first(where: { $0.preview.url.resolvingSymlinksInPath().standardizedFileURL.path == path }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = PluginBundleWindowController(
            preview: PluginBundlePreview(url: url, type: type, manager: manager))
        open.append(controller)
        controller.show()
        controller.preview.load()
    }

    private func show() {
        let hosting = NSHostingController(rootView: PluginBundleView(preview: preview))
        // Let the window follow the content — it grows once the plugin's own
        // view arrives.
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = preview.name
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            Self.open.removeAll { $0 === self }
        }
    }
}

// MARK: - Model

@MainActor
final class PluginBundlePreview: ObservableObject {
    enum Phase {
        case loading
        /// Loaded; nil when the plugin has no custom view of its own.
        case loaded(NSViewController?)
        case unavailable(String)
    }

    enum InstallState {
        case notInstalled
        case installing
        /// The plugin as listed in My Plugins — nil when the bundle is in a
        /// plug-ins folder but the scan didn't list it.
        case installed(AudioPlugin?)
        case failed(String)
    }

    let url: URL
    let type: PluginType
    let name: String
    let version: String?
    @Published var phase: Phase = .loading
    @Published var installState: InstallState
    private weak var manager: PluginManager?
    private var audioUnit: AVAudioUnit?

    init(url: URL, type: PluginType, manager: PluginManager) {
        self.url = url
        self.type = type
        self.manager = manager
        let info = Bundle(url: url)?.infoDictionary
        name = url.deletingPathExtension().lastPathComponent
        version = info?["CFBundleShortVersionString"] as? String ?? info?["CFBundleVersion"] as? String
        if let plugin = manager.installedPlugin(atBundle: url) {
            installState = .installed(plugin)
        } else if manager.isSafePluginPath(url) {
            installState = .installed(nil)
        } else {
            installState = .notInstalled
        }
    }

    var installOffer: PluginInstallOffer? {
        manager?.installOffer(for: url, type: type)
    }

    /// Loads the plugin and asks for its view. An installed AU is already
    /// registered with macOS, so it's hosted out of process like "Open Plugin".
    /// One that isn't installed has to be registered from its bundle in this
    /// process first — see registerComponentBundleInProcess.
    func load() {
        guard type == .audioUnit else {
            phase = .unavailable("AudioBunny can only show Audio Unit windows for now — there's no safe way to host a \(type.rawValue) plugin's UI without a full plugin host. Install it and open it in your DAW.")
            return
        }
        let desc: AudioComponentDescription
        let options: AudioComponentInstantiationOptions
        if case .installed(let plugin?) = installState, let installedDesc = plugin.audioComponentDescription {
            desc = installedDesc
            options = [.loadOutOfProcess]
        } else {
            do {
                desc = try registerComponentBundleInProcess(url)
                options = []
            } catch {
                phase = .unavailable(error.localizedDescription)
                return
            }
        }
        AVAudioUnit.instantiate(with: desc, options: options) { avAudioUnit, error in
            Task { @MainActor in
                guard let avAudioUnit, error == nil else {
                    self.phase = .unavailable("Couldn't load \(self.name): \(error?.localizedDescription ?? "the plugin didn't start").")
                    return
                }
                // As in AudioUnitPreviewWindowController: no engine, no busses,
                // nothing rendering — just the plugin and its view.
                self.audioUnit = avAudioUnit
                avAudioUnit.auAudioUnit.requestViewController { viewController in
                    DispatchQueue.main.async {
                        self.phase = .loaded(viewController)
                    }
                }
            }
        }
    }

    func install() {
        guard let manager, let offer = installOffer else { return }
        installState = .installing
        Task {
            do {
                installState = .installed(try await manager.install(offer))
            } catch {
                installState = .failed("Couldn't install: \(error.localizedDescription)")
            }
        }
    }

    func showInMyPlugins(_ plugin: AudioPlugin) {
        manager?.pluginToReveal = plugin
        // Bring the main window forward, not this one.
        NSApp.windows
            .first { !($0.delegate is PluginBundleWindowController) && $0.canBecomeMain && $0.isVisible }?
            .makeKeyAndOrderFront(nil)
    }
}

// MARK: - View

struct PluginBundleView: View {
    @ObservedObject var preview: PluginBundlePreview

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.name)
                        .font(.headline)
                    Text([preview.type.rawValue, preview.version.map { "v\($0)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 24)
                installControls
            }
            .padding(12)
            .background(.bar)

            Divider()

            pluginContent
        }
    }

    @ViewBuilder
    private var installControls: some View {
        switch preview.installState {
        case .notInstalled:
            if let offer = preview.installOffer {
                VStack(alignment: .trailing, spacing: 4) {
                    Button(offer.replacesExisting ? "Replace Installed Copy" : "Install") {
                        preview.install()
                    }
                    .buttonStyle(.borderedProminent)
                    Text(offer.replacesExisting
                         ? "Moves the copy in \(abbreviated(offer.destination.deletingLastPathComponent())) to the Trash"
                         : "Copies it to \(abbreviated(offer.destination.deletingLastPathComponent()))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installing…").foregroundStyle(.secondary)
            }
        case .installed(let plugin):
            HStack(spacing: 10) {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let plugin {
                    Button("Show in My Plugins") { preview.showInMyPlugins(plugin) }
                }
            }
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 4) {
                Button("Try Again") { preview.install() }
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var pluginContent: some View {
        switch preview.phase {
        case .loading:
            ProgressView("Loading \(preview.name)…")
                .frame(width: 520, height: 260)
        case .loaded(let viewController?):
            AudioUnitViewHost(viewController: viewController)
        case .loaded(nil):
            placeholder("\(preview.name) doesn't provide a custom view.")
        case .unavailable(let message):
            placeholder(message)
        }
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(24)
            .frame(width: 520, height: 200)
    }

    private func abbreviated(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// An Audio Unit's own view controller, at the size the plugin asks for.
private struct AudioUnitViewHost: NSViewControllerRepresentable {
    let viewController: NSViewController

    func makeNSViewController(context: Context) -> NSViewController { viewController }
    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: NSViewController, context: Context) -> CGSize? {
        let preferred = nsViewController.preferredContentSize
        if preferred.width > 0, preferred.height > 0 { return preferred }
        let frame = nsViewController.view.frame.size
        if frame.width > 0, frame.height > 0 { return frame }
        return CGSize(width: 600, height: 400)
    }
}

// MARK: - Loading a .component that isn't installed

enum ComponentBundleError: LocalizedError {
    case noAudioComponents
    case intelOnly
    case noFactoryFunction
    case loadFailed
    case factoryNotFound(String)

    var errorDescription: String? {
        switch self {
        case .noAudioComponents:
            return "This bundle doesn't declare any Audio Units, so there's nothing to load."
        case .intelOnly:
            return "This plugin is Intel-only, so it can't be loaded here. It may still work in a DAW running under Rosetta."
        case .noFactoryFunction:
            return "This is an older Audio Unit that macOS only loads once it's installed. Install it, then open it again to see its window."
        case .loadFailed:
            return "macOS couldn't load the plugin's code. It may be damaged, or blocked by Gatekeeper until it's installed."
        case .factoryNotFound(let name):
            return "The plugin's entry point (\(name)) is missing, so it can't be loaded."
        }
    }
}

/// Bundles already registered in this process, by path → the description
/// they registered under. Registering one twice would add a duplicate.
@MainActor private var inProcessComponentRegistrations: [String: AudioComponentDescription] = [:]

/// Registers the first Audio Unit in a `.component` bundle with this process
/// only, so one that isn't installed (in Downloads, on an installer DMG) can
/// still be instantiated: load the bundle's code, look up the factory function
/// its Info.plist names, and hand it to AudioComponentRegister. The plugin
/// runs in-process — there's no out-of-process hosting for a component macOS
/// hasn't registered itself.
@MainActor
func registerComponentBundleInProcess(_ url: URL) throws -> AudioComponentDescription {
    let key = url.resolvingSymlinksInPath().standardizedFileURL.path
    if let desc = inProcessComponentRegistrations[key] { return desc }

    guard let bundle = Bundle(url: url),
          let components = bundle.infoDictionary?["AudioComponents"] as? [[String: Any]],
          let entry = components.first(where: { ($0["type"] as? String) != "auvw" }),
          let type = (entry["type"] as? String).flatMap(osType(fromFourCC:)),
          let subtype = (entry["subtype"] as? String).flatMap(osType(fromFourCC:)),
          let manufacturer = (entry["manufacturer"] as? String).flatMap(osType(fromFourCC:))
    else { throw ComponentBundleError.noAudioComponents }

    #if arch(arm64)
    if let executable = bundle.executableURL, isX86_64Only(executable) {
        throw ComponentBundleError.intelOnly
    }
    #endif

    guard let factoryName = entry["factoryFunction"] as? String else {
        throw ComponentBundleError.noFactoryFunction
    }
    guard let cfBundle = CFBundleCreate(kCFAllocatorDefault, url as CFURL),
          CFBundleLoadExecutable(cfBundle) else {
        throw ComponentBundleError.loadFailed
    }
    // Some Info.plists name the symbol with its C-level leading underscore.
    let symbol = CFBundleGetFunctionPointerForName(cfBundle, factoryName as CFString)
        ?? (factoryName.hasPrefix("_")
            ? CFBundleGetFunctionPointerForName(cfBundle, String(factoryName.dropFirst()) as CFString)
            : nil)
    guard let symbol else { throw ComponentBundleError.factoryNotFound(factoryName) }
    let factory = unsafeBitCast(symbol, to: AudioComponentFactoryFunction.self)

    var desc = AudioComponentDescription(
        componentType: type, componentSubType: subtype, componentManufacturer: manufacturer,
        componentFlags: 0, componentFlagsMask: 0)
    let name = entry["name"] as? String ?? url.deletingPathExtension().lastPathComponent
    let version = (entry["version"] as? NSNumber)?.uint32Value
        ?? (entry["version"] as? String).flatMap { UInt32($0) }
        ?? 0
    _ = AudioComponentRegister(&desc, name as CFString, version, factory)

    inProcessComponentRegistrations[key] = desc
    return desc
}

/// A 4-character code as written in an Info.plist (`"aumu"`, `"-NI-"`) →
/// its OSType. MacRoman, since that's what these codes are defined in.
func osType(fromFourCC code: String) -> OSType? {
    guard let data = code.data(using: .macOSRoman), data.count == 4 else { return nil }
    return data.reduce(0) { ($0 << 8) | OSType($1) }
}
