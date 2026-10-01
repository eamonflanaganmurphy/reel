import Foundation
import Observation
import ReelCore

/// Keeps collections in step with the share (see `SharedCollections`), so
/// every phone has the same ones.
///
/// Pulls alongside watch progress: when the app comes forward and after a
/// scan. Pushes a few seconds after a change here, but never mid-video, for
/// the same reason as `ProgressSync`.
@MainActor
@Observable
final class CollectionSync {
    private(set) var failure: String?

    /// Set while a video is playing.
    var playing = false {
        didSet { if !playing, dirty { schedulePush(after: 1) } }
    }

    private let device = InstallID.value
    private var dirty = false
    private var pending: Task<Void, Never>?
    private var busy = false
    private var observer: NSObjectProtocol?
    private weak var settings: AppSettings?

    func start(settings: AppSettings) {
        self.settings = settings
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .collectionsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dirty = true
                if !self.playing { self.schedulePush(after: 3) }
            }
        }
    }

    /// Merges every phone's collections into this one's, and writes the
    /// result back if this phone knew something the share didn't, e.g.
    /// collections made before syncing existed.
    func pull() async {
        guard let settings, settings.isConfigured, !busy, !playing else { return }
        busy = true
        defer { busy = false }
        do {
            let source = try ServerConnection.shared.source(for: settings.shareConfig)
            let files = try await SharedCollections.load(from: source)
            // Read after the share, so anything changed here meanwhile is in it.
            let mine = settings.collectionsFile(device: device)
            let merged = SharedCollections.merge([mine] + files.filter { $0.device != device })
            settings.adopt(merged)
            let onShare = files.first { $0.device == device }
            if onShare?.collections != merged.collections || onShare?.deleted != merged.deleted {
                try await SharedCollections.save(settings.collectionsFile(device: device), to: source)
            }
            failure = nil
        } catch {
            failure = LibrarySync.describe(error)
        }
    }

    /// Writes now, e.g. as the app goes to the background.
    func pushNow() {
        guard dirty else { return }
        pending?.cancel()
        let background = BackgroundTask(name: "Save collections")
        pending = Task {
            await push()
            background.end()
        }
    }

    private func schedulePush(after seconds: Double) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await push()
        }
    }

    private func push() async {
        guard let settings, settings.isConfigured, dirty else { return }
        while busy {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
        }
        busy = true
        defer { busy = false }
        dirty = false
        do {
            let source = try ServerConnection.shared.source(for: settings.shareConfig)
            try await SharedCollections.save(settings.collectionsFile(device: device), to: source)
            failure = nil
        } catch {
            // Try again with the next change or the next time the app is put away.
            dirty = true
            failure = LibrarySync.describe(error)
        }
    }
}
