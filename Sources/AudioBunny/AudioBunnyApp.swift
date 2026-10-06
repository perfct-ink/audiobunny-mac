import SwiftUI
import AVFoundation
import AppKit

let appVersion = "1.0.0"

@main
struct AudioBunnyApp: App {
    @StateObject private var pluginManager = PluginManager()
    @StateObject private var catalogManager = CatalogManager()
    @StateObject private var downloadManager = DownloadManager()
    @StateObject private var presetManager = PresetManager()
    @StateObject private var presetSyncManager = PresetSyncManager()
    @StateObject private var appSettingsSyncManager = AppSettingsSyncManager()
    @StateObject private var liveProjectManager = LiveProjectManager()
    @StateObject private var sampleManager = SampleManager()
    @StateObject private var computerSyncManager = ComputerSyncManager()

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
                .environmentObject(presetSyncManager)
                .environmentObject(appSettingsSyncManager)
                .environmentObject(liveProjectManager)
                .environmentObject(sampleManager)
                .environmentObject(computerSyncManager)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    downloadManager.pluginManager = pluginManager
                    pluginManager.refresh()
                }
                // The web app's "Open in Mac App" button on /computers links
                // here (audiobunny://sync — or bare audiobunny:// to just
                // bring the app forward). Distinct from the OAuth sign-in
                // callback on the same "audiobunny" scheme
                // (audiobunny://oauth-callback/...) — that one's captured
                // directly by ASWebAuthenticationSession and never reaches
                // this handler at all, so there's no overlap to guard against.
                .onOpenURL { url in
                    guard url.scheme == "audiobunny" else { return }
                    NSApp.activate(ignoringOtherApps: true)
                    guard url.host == "sync", presetManager.currentUser != nil else { return }
                    Task {
                        await computerSyncManager.syncNow(pluginManager: pluginManager, liveProjectManager: liveProjectManager)
                    }
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
