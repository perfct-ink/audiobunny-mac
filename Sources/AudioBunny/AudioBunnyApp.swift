import SwiftUI
import AVFoundation

let appVersion = "1.0.0"

@main
struct AudioBunnyApp: App {
    @StateObject private var pluginManager = PluginManager()
    @StateObject private var catalogManager = CatalogManager()
    @StateObject private var downloadManager = DownloadManager()
    @StateObject private var presetManager = PresetManager()
    @StateObject private var liveProjectManager = LiveProjectManager()
    @StateObject private var sampleManager = SampleManager()
    @StateObject private var machineSyncManager = MachineSyncManager()

    var body: some Scene {
        // Empty title + .unifiedCompact: shrinks the real title bar down to
        // just the traffic lights, with no text taking up space, so the
        // custom nav bar directly below it (MainTabBar) reads as occupying
        // more of that vertical area instead of it going to an unused title.
        WindowGroup("") {
            ContentView()
                .environmentObject(pluginManager)
                .environmentObject(catalogManager)
                .environmentObject(downloadManager)
                .environmentObject(presetManager)
                .environmentObject(liveProjectManager)
                .environmentObject(sampleManager)
                .environmentObject(machineSyncManager)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    downloadManager.pluginManager = pluginManager
                    pluginManager.refresh()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Plugins") {
                    pluginManager.refresh()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
