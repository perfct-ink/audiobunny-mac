import AppKit
import AVFoundation
import CoreAudioKit  // AUAudioUnit.requestViewController(completionHandler:)

/// Shows an Audio Unit's own UI in a plain window — no `AVAudioEngine`, no
/// input/output busses connected, nothing rendering. Just instantiate the unit
/// and ask it for its view controller, so you can look at (and click around) a
/// plugin `auval` refuses to clear or times out on, without trusting the
/// automated verdict alone.
///
/// Kept alive via `open`, since neither the window nor the `AVAudioUnit` is
/// retained by anything else — closing the window releases both.
@MainActor
final class AudioUnitPreviewWindowController: NSObject, NSWindowDelegate {
    private static var open: [AudioUnitPreviewWindowController] = []

    private let audioUnit: AVAudioUnit
    private var window: NSWindow?

    private init(audioUnit: AVAudioUnit) {
        self.audioUnit = audioUnit
    }

    /// Instantiates `desc` and opens its view. Reports a failure via
    /// `onError` (called on the main actor) instead of throwing, since the
    /// underlying AVFoundation callback isn't structured-concurrency-friendly.
    static func present(_ desc: AudioComponentDescription, pluginName: String, onError: @escaping (String) -> Void) {
        // Ask the system to host it in a separate process when the plugin
        // supports that — the same isolation "Test All" uses, so a plugin
        // that's merely ugly to look at can't take AudioBunny down with it.
        AVAudioUnit.instantiate(with: desc, options: [.loadOutOfProcess]) { avAudioUnit, error in
            Task { @MainActor in
                guard let avAudioUnit, error == nil else {
                    onError(error?.localizedDescription ?? "Couldn't open \(pluginName).")
                    return
                }
                let controller = AudioUnitPreviewWindowController(audioUnit: avAudioUnit)
                open.append(controller)
                controller.show(pluginName: pluginName)
            }
        }
    }

    private func show(pluginName: String) {
        // Deliberately not calling allocateRenderResources() or connecting any
        // bus — this is a look-at-it preview, not a functioning audio path.
        audioUnit.auAudioUnit.requestViewController { [weak self] viewController in
            DispatchQueue.main.async {
                guard let self else { return }
                let content = viewController ?? Self.noViewFallback(for: pluginName)
                let window = NSWindow(contentViewController: content)
                window.title = pluginName
                window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
                window.isReleasedWhenClosed = false
                window.delegate = self
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.window = window
            }
        }
    }

    private static func noViewFallback(for pluginName: String) -> NSViewController {
        let label = NSTextField(wrappingLabelWithString: "\(pluginName) doesn't provide a custom view.")
        label.alignment = .center
        label.frame = NSRect(x: 20, y: 20, width: 320, height: 60)
        let vc = NSViewController()
        vc.view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 100))
        vc.view.addSubview(label)
        return vc
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            Self.open.removeAll { $0 === self }
        }
    }
}
