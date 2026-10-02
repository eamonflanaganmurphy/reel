import AVFoundation
import SwiftData
import SwiftUI

@main
struct ReelApp: App {
    @State private var settings = AppSettings()
    @State private var sync = LibrarySync()
    @State private var playback = PlaybackCenter()
    @State private var progress = ProgressSync()
    @State private var collections = CollectionSync()
    @State private var downloads = DownloadCenter()

    init() {
        // Plays through the silent switch, like any video app.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        Self.restrictAV1DecoderToPlainNEON()
    }

    /// VLCKit 3.6 bundles dav1d 1.4.2, whose arm64 DotProd/I8MM motion
    /// filters read just past a picture buffer. On chips that have them (A17
    /// Pro, A18 and later) VLC crashes in `put_8tap_neon_i8mm` decoding AV1,
    /// e.g. the YouTube downloads. Plain NEON is fine and still fast; dav1d
    /// reads the mask each time it sets up a decoder, so this must run before
    /// any AV1 is opened. Looked up at runtime so a VLCKit without the symbol
    /// just skips it.
    private static func restrictAV1DecoderToPlainNEON() {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(rtldDefault, "dav1d_set_cpu_flags_mask") else { return }
        typealias SetMask = @convention(c) (UInt32) -> Void
        let neonOnly: UInt32 = 1 << 0  // DAV1D_ARM_CPU_FLAG_NEON
        unsafeBitCast(symbol, to: SetMask.self)(neonOnly)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(sync)
                .environment(playback)
                .environment(progress)
                .environment(collections)
                .environment(downloads)
                .preferredColorScheme(.dark)
        }
        .modelContainer(for: [Show.self, Video.self])
    }
}
