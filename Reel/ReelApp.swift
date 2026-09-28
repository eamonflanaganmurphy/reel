import AVFoundation
import SwiftData
import SwiftUI

@main
struct ReelApp: App {
    @State private var settings = AppSettings()
    @State private var sync = LibrarySync()
    @State private var playback = PlaybackCenter()
    @State private var progress = ProgressSync()

    init() {
        // Plays through the silent switch, like any video app.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(sync)
                .environment(playback)
                .environment(progress)
                .preferredColorScheme(.dark)
        }
        .modelContainer(for: [Show.self, Video.self])
    }
}
