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
            guard phase == .active else { return }
            // iOS reclaims a suspended app's sockets, so check the session
            // before trusting it again.
            ServerConnection.shared.invalidate()
            catchUp()
        }
        .onChange(of: sync.isRunning) { wasRunning, running in
            // After a scan, which may have added videos other installs have
            // progress for. Waiting also keeps the two off the router at once.
            if wasRunning, !running { Task { await progress.pull() } }
        }
        .onChange(of: playback.session != nil) { _, playing in
            progress.playing = playing
            // A scan skipped while the video played.
            if !playing, scenePhase == .active { catchUp() }
        }
        // Frames are read from the files, so they wait while a scan or a
        // video is already reading from the router.
        .onChange(of: sync.isRunning || playback.session != nil, initial: true) { _, busy in
            FrameGrabber.shared.paused = busy
        }
    }

    /// Picks up new downloads, at most every 15 minutes, and otherwise
    /// anything watched on another install. Never while a video plays: the
    /// router struggles with a scan and a stream at once, and a scan can
    /// delete a replaced file's Video out from under the player's queue.
    private func catchUp() {
        guard settings.isConfigured, playback.session == nil else { return }
        if let last = sync.lastSync, Date().timeIntervalSince(last) < 15 * 60 {
            Task { await progress.pull() }
        } else {
            Task { await sync.run(settings: settings, context: context) }
        }
    }
}
