import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibrarySync.self) private var sync
    @Environment(PlaybackCenter.self) private var playback
    @Environment(ProgressSync.self) private var progress
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab = "home"

    var body: some View {
        @Bindable var playback = playback
        TabView(selection: $tab) {
            NavigationStack { HomeView(openSettings: { tab = "settings" }) }
                .tabItem { Label("Home", systemImage: "house") }
                .tag("home")

            ForEach(settings.libraries) { library in
                NavigationStack { LibraryView(library: library) }
                    .tabItem { Label(library.name, systemImage: library.systemImage) }
                    .tag(library.id.uuidString)
            }

            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag("settings")
        }
        .fullScreenCover(item: $playback.session) { session in
            PlayerScreen(session: session)
        }
        .task {
            if !settings.isConfigured { tab = "settings" }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            progress.start(settings: settings, context: context)
            if phase == .background { progress.pushNow() }
            // Pick up new downloads when the app comes back, at most every 15 minutes.
            guard phase == .active, settings.isConfigured else { return }
            if let last = sync.lastSync, Date().timeIntervalSince(last) < 15 * 60 {
                // Still catch up on anything watched on another install.
                Task { await progress.pull() }
                return
            }
            Task { await sync.run(settings: settings, context: context) }
        }
        .onChange(of: sync.isRunning) { wasRunning, running in
            // After a scan, which may have added videos other installs have
            // progress for. Waiting also keeps the two off the router at once.
            if wasRunning, !running { Task { await progress.pull() } }
        }
        .onChange(of: playback.session != nil) { _, playing in
            progress.playing = playing
        }
        // Frames are read from the files, so they wait while a scan or a
        // video is already reading from the router.
        .onChange(of: sync.isRunning || playback.session != nil, initial: true) { _, busy in
            FrameGrabber.shared.paused = busy
        }
    }
}
