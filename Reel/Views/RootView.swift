import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibrarySync.self) private var sync
    @Environment(PlaybackCenter.self) private var playback
    @Environment(ProgressSync.self) private var progress
    @Environment(CollectionSync.self) private var collections
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab = "home"
    @State private var showingSettings = false

    var body: some View {
        @Bindable var playback = playback
        TabView(selection: $tab) {
            NavigationStack { HomeView(openSettings: { showingSettings = true }) }
                .tabItem { Label("Home", systemImage: "house") }
                .tag("home")

            // Next to Home, so an iPhone's tab bar keeps them out of More.
            ForEach(settings.collections.filter { settings.showsTab($0.id) }) { collection in
                NavigationStack { CollectionView(collection: collection) }
                    .tabItem { Label(collection.name, systemImage: "square.stack") }
                    .tag(collection.id.uuidString)
            }

            ForEach(settings.libraries.filter { settings.showsTab($0.id) }) { library in
                NavigationStack { LibraryView(library: library) }
                    .tabItem { Label(library.name, systemImage: library.systemImage) }
                    .tag(library.id.uuidString)
            }
        }
        .fullScreenCover(item: $playback.session) { session in
            PlayerScreen(session: session)
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSettings = false } }
                    }
            }
        }
        .task {
            if !settings.isConfigured { showingSettings = true }
        }
        // A tab hidden or deleted while open leaves nothing selected.
        .onChange(of: visibleTabs) { _, tabs in
            if !tabs.contains(tab) { tab = "home" }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            progress.start(settings: settings, context: context)
            collections.start(settings: settings)
            if phase == .background {
                progress.pushNow()
                collections.pushNow()
            }
            guard phase == .active else { return }
            // iOS reclaims a suspended app's sockets, so check the session
            // before trusting it again.
            ServerConnection.shared.invalidate()
            catchUp()
        }
        .onChange(of: sync.isRunning) { wasRunning, running in
            // After a scan, which may have added videos other installs have
            // progress for. Waiting also keeps the two off the router at once.
            if wasRunning, !running { Task { await pullShared() } }
        }
        .onChange(of: playback.session != nil) { _, playing in
            progress.playing = playing
            collections.playing = playing
            // A scan skipped while the video played.
            if !playing, scenePhase == .active { catchUp() }
        }
        // Frames are read from the files, so they wait while a scan or a
        // video is already reading from the router.
        .onChange(of: sync.isRunning || playback.session != nil, initial: true) { _, busy in
            FrameGrabber.shared.paused = busy
        }
        // Frames for everything without a poster or still, taken while the
        // app is open and the router is otherwise idle. Restarted after each
        // scan, which may have added videos.
        .task(id: settings.isConfigured && scenePhase == .active && !sync.isRunning && playback.session == nil) {
            guard settings.isConfigured, scenePhase == .active, !sync.isRunning, playback.session == nil else { return }
            await FrameBackfill.run(settings: settings, context: context)
        }
    }

    private var visibleTabs: [String] {
        ["home"] + (settings.collections.map(\.id) + settings.libraries.map(\.id))
            .filter(settings.showsTab).map(\.uuidString)
    }

    /// Watch progress and collections from the other installs, one after
    /// the other to keep the router to one thing at a time.
    private func pullShared() async {
        await progress.pull()
        await collections.pull()
    }

    /// Picks up new downloads, at most every 15 minutes, and otherwise
    /// anything watched on another install. Never while a video plays: the
    /// router struggles with a scan and a stream at once, and a scan can
    /// delete a replaced file's Video out from under the player's queue.
    private func catchUp() {
        guard settings.isConfigured, playback.session == nil else { return }
        if let last = sync.lastSync, Date().timeIntervalSince(last) < 15 * 60 {
            Task { await pullShared() }
        } else {
            Task { await sync.run(settings: settings, context: context) }
        }
    }
}
