import CryptoKit
import Foundation
import ReelCore
import SwiftUI
import UIKit

/// One SMB connection for the whole app, rebuilt when the settings change.
final class ServerConnection: @unchecked Sendable {
    static let shared = ServerConnection()

    private let lock = NSLock()
    private var config: SMBConfig?
    private var source: SMBFileSource?

    func source(for config: SMBConfig) throws -> SMBFileSource {
        try lock.withLock {
            if let source, self.config == config { return source }
            let new = try SMBFileSource(config: config)
            source = new
            self.config = config
            return new
        }
    }

    /// Copies a file from the share into Caches, e.g. a subtitle for VLC.
    func download(_ path: String, config: SMBConfig) async throws -> URL {
        let data = try await source(for: config).read(path)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("subs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent((path as NSString).lastPathComponent)
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// Posters, backdrops and thumbnails, from TMDB, the share, or a frame of the
/// video itself. Kept on disk in Caches so the library still looks right when
/// the router is out of reach.
actor ArtworkStore {
    static let shared = ArtworkStore()

    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let directory: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 300
    }

    func image(for ref: String?, config: SMBConfig) async -> UIImage? {
        guard let ref, !ref.isEmpty else { return nil }
        if let hit = memory.object(forKey: ref as NSString) { return hit }
        if let running = inFlight[ref] { return await running.value }

        let file = directory.appendingPathComponent(Self.fileName(for: ref))
        let task = Task<UIImage?, Never> {
            if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
                return await image.byPreparingForDisplay() ?? image
            }
            guard let data = await Self.fetch(ref, config: config), let image = UIImage(data: data) else { return nil }
            try? data.write(to: file, options: .atomic)
            return await image.byPreparingForDisplay() ?? image
        }
        inFlight[ref] = task
        // Scrolling past stops the fetch, which for a video frame means VLC
        // never opens the file.
        let image = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        inFlight[ref] = nil
        if let image { memory.setObject(image, forKey: ref as NSString) }
        return image
    }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func fetch(_ ref: String, config: SMBConfig) async -> Data? {
        if ref.hasPrefix("frame:") {
            return await FrameGrabber.shared.jpeg(for: String(ref.dropFirst(6)), config: config)
        }
        if ref.hasPrefix("smb:") {
            let path = String(ref.dropFirst(4))
            return try? await ServerConnection.shared.source(for: config).read(path, maxBytes: 5_000_000)
        }
        guard let url = URL(string: ref) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private static func fileName(for ref: String) -> String {
        SHA256.hash(data: Data(ref.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// An image from a posterRef/backdropRef, filling whatever frame it's given.
/// `fallbackRef` is tried when `ref` is missing or won't load, normally a
/// frame from the video.
struct ArtworkImage: View {
    let ref: String?
    var fallbackRef: String?
    var fallbackTitle: String?
    var fallbackSymbol = "film"

    @Environment(AppSettings.self) private var settings
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 6) {
                    Image(systemName: fallbackSymbol).font(.title2).foregroundStyle(.secondary)
                    if let fallbackTitle {
                        Text(fallbackTitle)
                            .font(.caption.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .padding(.horizontal, 6)
                    }
                }
            }
        }
        .task(id: [ref, fallbackRef]) {
            var loaded = await ArtworkStore.shared.image(for: ref, config: settings.smbConfig)
            if loaded == nil, !Task.isCancelled {
                loaded = await ArtworkStore.shared.image(for: fallbackRef, config: settings.smbConfig)
            }
            // A superseded load mustn't blank what its replacement shows.
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}

/// A fixed-aspect frame that crops artwork to fit. `.scaledToFill` alone
/// overflows its frame in a grid.
struct ArtworkFrame: View {
    let ref: String?
    var fallbackRef: String?
    var aspectRatio: CGFloat = 2.0 / 3.0
    var fallbackTitle: String?
    var fallbackSymbol = "film"
    var cornerRadius: CGFloat = 8

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay { ArtworkImage(ref: ref, fallbackRef: fallbackRef, fallbackTitle: fallbackTitle, fallbackSymbol: fallbackSymbol) }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
