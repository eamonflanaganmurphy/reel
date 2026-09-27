import SwiftUI
import UIKit

/// What's playing: the video plus the rest of its season, for autoplay.
@Observable
final class PlaybackCenter {
    struct Session: Identifiable {
        let id = UUID()
        let queue: [Video]
        let index: Int
        let startAt: Double
    }

    var session: Session?

    /// Plays from `start`, or resumes if the video is part-watched and no
    /// start is given.
    func play(_ video: Video, from start: Double? = nil) {
        var queue = [video]
        var index = 0
        if let show = video.show {
            let eps = show.sortedEpisodes
            if let i = eps.firstIndex(where: { $0.path == video.path }) {
                queue = eps
                index = i
            }
        }
        let resume = video.isInProgress ? video.positionSeconds : 0
        session = Session(queue: queue, index: index, startAt: start ?? resume)
    }
}

struct PlayerScreen: View {
    let session: PlaybackCenter.Session

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = PlayerController()

    @State private var index = 0
    @State private var showControls = true
    @State private var scrubPosition: Double?
    @State private var hideTask: Task<Void, Never>?
    @State private var lastSaved = Date.distantPast
    @State private var started = false

    private var video: Video { session.queue[index] }
    private var nextVideo: Video? { session.queue.indices.contains(index + 1) ? session.queue[index + 1] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(view: controller.videoView).ignoresSafeArea()

            if controller.isBuffering, controller.errorMessage == nil {
                ProgressView().controlSize(.large).tint(.white)
            }

            if showControls || controller.errorMessage != nil {
                controls.transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
            scheduleHide()
        }
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear {
            guard !started else { return }
            started = true
            index = session.index
            UIApplication.shared.isIdleTimerDisabled = true
            Orientation.request(.landscape)
            controller.onEnded = { playNextOrClose() }
            start(at: session.startAt)
        }
        .onDisappear {
            saveProgress()
            controller.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            Orientation.request(.portrait)
        }
        .onReceive(controller.$currentTime) { _ in
            if Date().timeIntervalSince(lastSaved) > 10 { saveProgress() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { saveProgress() }
        }
    }

    // MARK: Controls

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.7), .clear, .clear, .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack {
                topBar
                Spacer()
                if let error = controller.errorMessage {
                    VStack(spacing: 12) {
                        Text(error).multilineTextAlignment(.center)
                        Button("Try Again") { start(at: controller.currentTime) }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    transport
                }
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Button { close() } label: {
                Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(video.displayTitle).font(.headline).lineLimit(1)
                if !video.isMovie {
                    Text("\(video.episodeCode) · \(video.title)").font(.subheadline).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
            }
            Spacer()
            if controller.audioTracks.count > 1 {
                Menu {
                    Picker("Audio", selection: Binding(get: { controller.currentAudio }, set: { controller.selectAudio($0) })) {
                        ForEach(controller.audioTracks) { Text($0.name).tag($0.id) }
                    }
                } label: {
                    Image(systemName: "waveform.circle").font(.title2).frame(width: 44, height: 44)
                }
            }
            if !controller.subtitleTracks.isEmpty {
                Menu {
                    Picker("Subtitles", selection: Binding(get: { controller.currentSubtitle }, set: { controller.selectSubtitle($0) })) {
                        ForEach(controller.subtitleTracks) { Text($0.name).tag($0.id) }
                    }
                } label: {
                    Image(systemName: controller.currentSubtitle >= 0 ? "captions.bubble.fill" : "captions.bubble")
                        .font(.title2).frame(width: 44, height: 44)
                }
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 56) {
            Button { controller.skip(-10); scheduleHide() } label: {
                Image(systemName: "gobackward.10").font(.system(size: 34))
            }
            Button { controller.togglePlay(); scheduleHide() } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 50))
                    .frame(width: 64)
            }
            Button { controller.skip(30); scheduleHide() } label: {
                Image(systemName: "goforward.30").font(.system(size: 34))
            }
        }
        .opacity(controller.isBuffering ? 0 : 1)
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(get: { scrubPosition ?? controller.currentTime }, set: { scrubPosition = $0 }),
                in: 0...max(controller.duration, 1),
                onEditingChanged: { editing in
                    if !editing, let target = scrubPosition {
                        controller.seek(to: target)
                        scrubPosition = nil
                    }
                    scheduleHide(after: editing ? 3600 : 4)
                }
            )
            .tint(.white)
            HStack {
                Text(Self.format(scrubPosition ?? controller.currentTime))
                Spacer()
                if let nextVideo {
                    Button { advance(to: index + 1, markWatched: true) } label: {
                        Label("Next: \(nextVideo.episodeCode)", systemImage: "forward.end.fill")
                    }
                    .font(.footnote.weight(.semibold))
                    Spacer()
                }
                Text("-" + Self.format(max(0, controller.duration - (scrubPosition ?? controller.currentTime))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
        }
    }

    // MARK: Playback

    private func start(at seconds: Double) {
        guard let url = settings.smbConfig.playbackURL(for: video.path) else { return }
        controller.load(url, startAt: seconds)
        lastSaved = Date()
        scheduleHide()

        let current = index
        let subtitles = video.subtitles
        let config = settings.smbConfig
        guard !subtitles.isEmpty else { return }
        Task {
            var local: [URL] = []
            for s in subtitles {
                if let url = try? await ServerConnection.shared.download(s.path, config: config) { local.append(url) }
            }
            // The user may have skipped ahead while these downloaded.
            if current == index { controller.addSubtitles(local) }
        }
    }

    private func saveProgress() {
        guard started, controller.duration > 0 else { return }
        video.recordProgress(position: controller.currentTime, duration: controller.duration)
        lastSaved = Date()
    }

    private func playNextOrClose() {
        video.setWatched(true)
        if nextVideo != nil {
            advance(to: index + 1, markWatched: false)
        } else {
            close()
        }
    }

    private func advance(to newIndex: Int, markWatched: Bool) {
        if markWatched { video.setWatched(true) } else { saveProgress() }
        index = newIndex
        start(at: video.isInProgress ? video.positionSeconds : 0)
    }

    private func close() {
        saveProgress()
        controller.stop()
        dismiss()
    }

    private func scheduleHide(after seconds: Double = 4) {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, controller.isPlaying, scrubPosition == nil else { return }
            withAnimation(.easeInOut(duration: 0.3)) { showControls = false }
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// Hosts VLC's drawable UIView.
private struct VideoSurface: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

enum Orientation {
    static func request(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
