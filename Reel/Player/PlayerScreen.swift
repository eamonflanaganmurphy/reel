import ReelCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    @Environment(DownloadCenter.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = PlayerController()

    @State private var index = 0
    @State private var showControls = true
    @State private var scrubPosition: Double?
    @State private var isScrubbing = false
    @State private var hideTask: Task<Void, Never>?
    @State private var lastSaved = Date.distantPast
    @State private var started = false
    @State private var locked = false
    @State private var lockBadgeVisible = false
    @State private var lockBadgeTask: Task<Void, Never>?
    @State private var unlockProgress: Double = 0
    @State private var pickingShareSubtitle = false
    @State private var pickingFilesSubtitle = false
    /// Playback pauses while a subtitle is being picked, and carries on after.
    @State private var resumeAfterPicking = false
    @State private var addedSubtitleCount = 0
    @State private var subtitleError: String?

    /// How long the lock badge has to be held to unlock.
    private static let unlockHold: Double = 1

    private var video: Video { session.queue[index] }
    private var nextVideo: Video? { session.queue.indices.contains(index + 1) ? session.queue[index + 1] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // VLC's view would otherwise swallow taps, so the controls could
            // never be brought back once hidden.
            VideoSurface(view: controller.videoView).ignoresSafeArea().allowsHitTesting(false)

            if controller.isBuffering, controller.errorMessage == nil {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large).tint(.white)
                    if controller.isReconnecting {
                        Text("Reconnecting to the share…")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.55), in: Capsule())
                    }
                }
                .allowsHitTesting(false)
            }

            if locked {
                if let error = controller.errorMessage { errorBox(error).foregroundStyle(.white) }
                if lockBadgeVisible {
                    lockBadge
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 16)
                        .transition(.opacity)
                }
            } else if showControls || controller.errorMessage != nil {
                controls.transition(.opacity)
            }

            if !locked, !pickingShareSubtitle, !pickingFilesSubtitle {
                keyboardShortcuts
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if locked {
                revealLockBadge()
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                scheduleHide()
            }
        }
        // Swipe down to close, like the system player.
        .simultaneousGesture(
            DragGesture(minimumDistance: 40).onEnded { drag in
                let t = drag.translation
                if t.height > 120, t.height > abs(t.width) * 2, !isScrubbing, !locked { close() }
            }
        )
        .statusBarHidden(locked || !showControls)
        .persistentSystemOverlays(.hidden)
        // While locked, a swipe in from an edge (home, Control Center,
        // notifications) needs a second swipe before the system acts on it.
        .defersSystemGestures(on: locked ? .all : [])
        .sensoryFeedback(.impact, trigger: locked)
        .preferredColorScheme(.dark)
        .onAppear {
            guard !started else { return }
            started = true
            index = session.index
            UIApplication.shared.isIdleTimerDisabled = true
            Orientation.request(.landscape)
            controller.onEnded = { playNextOrClose() }
            controller.enableSystemControls()
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
        // The first hide timer usually fires while the video is still
        // buffering, so try again once it's actually playing.
        .onChange(of: controller.isPlaying) { _, playing in
            if playing, showControls { scheduleHide() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { saveProgress() }
        }
        .sheet(isPresented: $pickingShareSubtitle, onDismiss: resumeAfterPicker) {
            ShareSubtitlePicker(videoPath: video.path) { addFromShare($0) }
        }
        .fileImporter(isPresented: $pickingFilesSubtitle, allowedContentTypes: [.data]) { addFromFiles($0) }
        // Not every way of closing the Files picker calls its completion.
        .onChange(of: pickingFilesSubtitle) { _, picking in
            if !picking { resumeAfterPicker() }
        }
        .alert("Couldn't Add Subtitles", isPresented: Binding(get: { subtitleError != nil }, set: { if !$0 { subtitleError = nil } })) {
            Button("OK") { subtitleError = nil }
        } message: {
            Text(subtitleError ?? "")
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
                    errorBox(error)
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

    private func errorBox(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message).multilineTextAlignment(.center)
            Button("Try Again") { start(at: controller.currentTime) }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24)
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
            Button { lock() } label: {
                Image(systemName: "lock").font(.title2).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Lock Screen")
            if controller.audioTracks.count > 1 {
                Menu {
                    Picker("Audio", selection: Binding(get: { controller.currentAudio }, set: { controller.selectAudio($0) })) {
                        ForEach(controller.audioTracks) { Text($0.name).tag($0.id) }
                    }
                } label: {
                    Image(systemName: "waveform.circle").font(.title2).frame(width: 44, height: 44)
                }
            }
            Menu {
                Picker("Subtitles", selection: Binding(get: { controller.currentSubtitle }, set: { controller.selectSubtitle($0) })) {
                    ForEach(controller.subtitleTracks) { Text($0.name).tag($0.id) }
                }
                Section {
                    Button { startPicking { pickingShareSubtitle = true } } label: {
                        Label("Add from Share…", systemImage: "externaldrive.connected.to.line.below")
                    }
                    Button { startPicking { pickingFilesSubtitle = true } } label: {
                        Label("Add from Files…", systemImage: "folder")
                    }
                    if addedSubtitleCount > 0 {
                        Button(role: .destructive) { removeAddedSubtitles() } label: {
                            Label("Remove Added Subtitles", systemImage: "trash")
                        }
                    }
                }
            } label: {
                Image(systemName: controller.currentSubtitle >= 0 ? "captions.bubble.fill" : "captions.bubble")
                    .font(.title2).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Subtitles")
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
                value: Binding(get: { scrubPosition ?? controller.currentTime }, set: { if isScrubbing { scrubPosition = $0 } }),
                in: 0...max(controller.duration, 1),
                // Only the user's drag moves the thumb: the slider also writes
                // back when it clamps (e.g. resuming before the length is known),
                // which used to look like a scrub that never ended.
                onEditingChanged: { editing in
                    isScrubbing = editing
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

    /// For an iPad keyboard: space plays and pauses, the arrows skip, Escape
    /// closes. Shortcuts belong to buttons, so these are buttons nobody sees.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("Play or Pause") { controller.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
            Button("Back 10 Seconds") { controller.skip(-10) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Forward 30 Seconds") { controller.skip(30) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Close") { close() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(width: 0, height: 0)
        .clipped()
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: Child lock

    /// Only appears after a tap, and has to be held, so a toddler tapping or
    /// mashing the screen doesn't unlock it.
    private var lockBadge: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(.black.opacity(0.55))
                Circle()
                    .trim(from: 0, to: unlockProgress)
                    .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(2)
                Image(systemName: "lock.fill").font(.title2)
            }
            .frame(width: 64, height: 64)
            .contentShape(Circle())
            .onLongPressGesture(minimumDuration: Self.unlockHold, maximumDistance: 24) {
                unlock()
            } onPressingChanged: { pressing in
                guard locked else { return }
                if pressing {
                    lockBadgeTask?.cancel()
                    withAnimation(.linear(duration: Self.unlockHold)) { unlockProgress = 1 }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { unlockProgress = 0 }
                    revealLockBadge()
                }
            }
            .accessibilityLabel("Unlock")
            .accessibilityAction { unlock() }

            Text("Hold to unlock")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
        }
        .foregroundStyle(.white)
    }

    private func lock() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            locked = true
            showControls = false
        }
        // Show where to unlock once, so it isn't a mystery later.
        revealLockBadge()
    }

    private func unlock() {
        lockBadgeTask?.cancel()
        unlockProgress = 0
        withAnimation(.easeInOut(duration: 0.2)) {
            locked = false
            lockBadgeVisible = false
            showControls = true
        }
        scheduleHide()
    }

    private func revealLockBadge() {
        withAnimation(.easeInOut(duration: 0.2)) { lockBadgeVisible = true }
        lockBadgeTask?.cancel()
        lockBadgeTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { lockBadgeVisible = false }
        }
    }

    // MARK: Playback

    private func start(at seconds: Double) {
        // A downloaded copy plays with or without the share.
        let downloaded = downloads.localURL(for: video.path)
        guard let url = downloaded ?? settings.shareConfig.playbackURL(for: video.path) else {
            // Otherwise it's a spinner that never ends.
            controller.fail(settings.isConfigured
                ? "Couldn't make a link to this file on the share."
                : "Set up the share in Settings to play videos that aren't downloaded.")
            return
        }
        let playing = video
        controller.onChooseTracks = { TrackMemory.save($0, for: playing) }
        controller.load(url, startAt: seconds, tracks: TrackMemory.choice(for: playing))
        lastSaved = Date()
        scheduleHide()
        showOnLockScreen()

        let current = index
        let videoPath = video.path
        let added = AddedSubtitles.files(for: videoPath)
        addedSubtitleCount = added.count
        // Ones already on the phone go on straight away. Waiting for the rest
        // to come from the share held them all up, for a minute with no share.
        var onPhone: [PlayerController.Sidecar] = []
        var onShare: [SubtitleFile] = []
        for s in video.subtitles {
            if let saved = downloads.localSubtitle(s, of: videoPath) {
                onPhone.append(.init(url: saved, label: s.label))
            } else {
                onShare.append(s)
            }
        }
        onPhone += added.map { .init(url: $0, label: AddedSubtitles.label(for: $0, videoPath: videoPath)) }
        controller.addSubtitles(onPhone)
        guard !onShare.isEmpty else { return }
        let config = settings.shareConfig
        Task {
            var fetched: [PlayerController.Sidecar] = []
            for s in onShare {
                if let url = try? await ServerConnection.shared.download(s.path, config: config) {
                    fetched.append(.init(url: url, label: s.label))
                }
            }
            // The user may have skipped ahead while these downloaded.
            if current == index { controller.addSubtitles(fetched) }
        }
    }

    /// The title and artwork on the lock screen and in Control Center.
    private func showOnLockScreen() {
        let current = index
        controller.nowPlaying = .init(title: video.displayTitle,
                                      subtitle: video.isMovie ? nil : "\(video.episodeCode) · \(video.title)")
        let ref = video.show?.posterRef ?? video.posterRef
        let config = settings.shareConfig
        Task {
            guard let ref, let image = await ArtworkStore.shared.image(for: ref, config: config),
                  current == index else { return }
            controller.nowPlaying?.artwork = image
        }
    }

    // MARK: Adding subtitles

    private func startPicking(_ present: () -> Void) {
        resumeAfterPicking = controller.isPlaying
        if resumeAfterPicking { controller.pause() }
        hideTask?.cancel()
        present()
    }

    private func resumeAfterPicker() {
        guard !pickingShareSubtitle, !pickingFilesSubtitle, resumeAfterPicking else { return }
        resumeAfterPicking = false
        controller.play()
        scheduleHide()
    }

    private func addFromShare(_ entry: FileEntry) {
        let current = index
        let videoPath = video.path
        let config = settings.shareConfig
        Task {
            do {
                let download = try await ServerConnection.shared.download(entry.path, config: config)
                attachAdded(try AddedSubtitles.add(download, for: videoPath), videoPath: videoPath, index: current)
            } catch {
                subtitleError = "\(entry.name) couldn't be copied from the share. \(LibrarySync.describe(error))"
            }
        }
    }

    private func addFromFiles(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        guard AddedSubtitles.isSubtitle(url.lastPathComponent) else {
            subtitleError = "\(url.lastPathComponent) isn't a subtitle file. Reel can add SRT, ASS, SSA and WebVTT files."
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            attachAdded(try AddedSubtitles.add(url, for: video.path), videoPath: video.path, index: index)
        } catch {
            subtitleError = "\(url.lastPathComponent) couldn't be copied. \(error.localizedDescription)"
        }
    }

    /// Saved for next time, and switched on now if the same video is still playing.
    private func attachAdded(_ file: URL, videoPath: String, index added: Int) {
        guard added == index else { return }
        addedSubtitleCount = AddedSubtitles.files(for: videoPath).count
        controller.addSubtitles([.init(url: file, label: AddedSubtitles.label(for: file, videoPath: videoPath), select: true)])
    }

    /// VLC can't drop a track from a file that's open, so they're turned off
    /// now and are gone the next time the video plays.
    private func removeAddedSubtitles() {
        AddedSubtitles.removeAll(for: video.path)
        addedSubtitleCount = 0
        controller.selectSubtitle(-1)
    }

    private func saveProgress() {
        guard started, controller.duration > 0 else { return }
        video.recordProgress(position: controller.currentTime, duration: controller.duration)
        lastSaved = Date()
    }

    private func playNextOrClose() {
        video.setWatched(true)
        guard let nextVideo else { return endOfQueue() }
        // Played from a download, maybe somewhere with no share (on a plane):
        // if the next episode isn't downloaded and the share can't be
        // reached, the next one that is downloaded plays instead of a
        // spinner that ends in an error.
        guard downloads.localURL(for: video.path) != nil, downloads.localURL(for: nextVideo.path) == nil else {
            return advance(to: index + 1, markWatched: false)
        }
        let current = index
        let queue = session.queue
        let config = settings.shareConfig
        Task {
            let reachable = await ServerConnection.shared.isReachable(config, within: 5)
            // Closed, or moved on by hand, meanwhile.
            guard !controller.isStopped, current == index else { return }
            if reachable { return advance(to: current + 1, markWatched: false) }
            if let downloaded = queue.indices.dropFirst(current + 1).first(where: { downloads.localURL(for: queue[$0].path) != nil }) {
                advance(to: downloaded, markWatched: false)
            } else {
                endOfQueue()
            }
        }
    }

    /// Locked, the player stays up at the end rather than dropping a child
    /// into the library. Unlocking brings the controls back.
    private func endOfQueue() {
        if !locked { close() }
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
            guard !Task.isCancelled, controller.isPlaying, !isScrubbing else { return }
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

/// Turns the phone for the player and back. An iPad is left as it's held:
/// the video letterboxes, and a window in Split View or Stage Manager can't
/// rotate on its own anyway.
enum Orientation {
    static func request(_ mask: UIInterfaceOrientationMask) {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
