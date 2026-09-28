import Foundation
import Observation
import ReelCore
import SwiftData
import UIKit

/// Keeps watch progress in step with the share (see `SharedProgress`), so
/// every copy of the app picks up where any of them left off.
///
/// Pulls when the app comes forward and after a scan. Pushes a few seconds
/// after a change, but never mid-video: the router's Samba copes badly with
/// a second connection working while VLC streams, so changes made while
/// playing go when the player closes or the app is put away.
@MainActor
@Observable
final class ProgressSync {
    enum Status: Equatable {
        case idle
        case synced(Date)
        case failed(String)
    }

    private(set) var status: Status = .idle

    /// Set while a video is playing.
    var playing = false {
        didSet { if !playing, dirty { schedulePush(after: 1) } }
    }

    /// This install's file on the share. Kept for good, so it keeps writing
    /// the same file rather than leaving a new one per launch.
    private let device: String = {
        let key = "progressDeviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    private var dirty = false
    private var pending: Task<Void, Never>?
    private var busy = false
    private var observer: NSObjectProtocol?
    private weak var settings: AppSettings?
    private var context: ModelContext?

    func start(settings: AppSettings, context: ModelContext) {
        self.settings = settings
        self.context = context
        guard observer == nil else { return }
        backfill(context: context)
        observer = NotificationCenter.default.addObserver(forName: .watchProgressChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dirty = true
                if !self.playing { self.schedulePush(after: 3) }
            }
        }
    }

    /// Reads every install's progress from the share and takes whatever is
    /// newer than what's here.
    func pull() async {
        guard let settings, let context, settings.isConfigured, !busy, !playing else { return }
        busy = true
        defer { busy = false }
        do {
            let source = try ServerConnection.shared.source(for: settings.smbConfig)
            let remote = try await SharedProgress.load(from: source)
            guard !remote.isEmpty else { return }
            let videos = (try? context.fetch(FetchDescriptor<Video>())) ?? []
            for video in videos {
                if let entry = remote[video.path] { video.adopt(entry) }
            }
            try? context.save()
            status = .synced(.now)
        } catch {
            status = .failed(LibrarySync.describe(error))
        }
    }

    /// Writes this install's progress now, e.g. as the app goes to the
    /// background. iOS allows a few seconds for it.
    func pushNow() {
        guard dirty else { return }
        pending?.cancel()
        let background = BackgroundTask(name: "Save watch progress")
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
        guard let settings, let context, settings.isConfigured, dirty else { return }
        // A pull in progress finishes first, so its results go out too.
        while busy {
            try? await Task.sleep(for: .milliseconds(200))
            // Superseded by a newer push, which will send this change too.
            // (A cancelled sleep returns at once, so this would spin.)
            if Task.isCancelled { return }
        }
        busy = true
        defer { busy = false }
        dirty = false
        try? context.save()
        let videos = (try? context.fetch(FetchDescriptor<Video>(predicate: #Predicate { $0.progressUpdatedAt != nil }))) ?? []
        let entries = Dictionary(videos.compactMap { v in v.watchProgress.map { (v.path, $0) } }, uniquingKeysWith: { a, _ in a })
        do {
            let source = try ServerConnection.shared.source(for: settings.smbConfig)
            try await SharedProgress.save(entries, device: device, to: source)
            status = .synced(.now)
        } catch {
            // Try again with the next change or the next time the app is put away.
            dirty = true
            status = .failed(LibrarySync.describe(error))
        }
    }

    /// Progress recorded before syncing existed has no timestamp; its last
    /// play time stands in, so it's shared too and competes fairly.
    private func backfill(context: ModelContext) {
        let old = (try? context.fetch(FetchDescriptor<Video>(predicate: #Predicate {
            $0.progressUpdatedAt == nil && $0.lastPlayedAt != nil
        }))) ?? []
        guard !old.isEmpty else { return }
        for video in old { video.progressUpdatedAt = video.lastPlayedAt }
        try? context.save()
        dirty = true
        schedulePush(after: 5)
    }
}

/// Extra time in the background, handed back when the work is done or, if
/// the share is too slow to answer, when iOS says time is up. Holding on past
/// that gets the app killed.
@MainActor
private final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [self] in end() }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
