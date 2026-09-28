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
/// `fallbackRefs` are tried in order when `ref` is missing or won't load,
/// normally frames from the video. If none of them loads, a title card is
/// generated so nothing is left blank.
struct ArtworkImage: View {
    let ref: String?
    var fallbackRefs: [String?] = []
    var fallbackTitle: String?
    var fallbackSubtitle: String?
    var fallbackSymbol = "film"

    @Environment(AppSettings.self) private var settings
    @State private var image: UIImage?
    @State private var exhausted = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if exhausted {
                GeneratedArtwork(title: fallbackTitle, subtitle: fallbackSubtitle, symbol: fallbackSymbol)
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
        .task(id: [ref] + fallbackRefs) {
            exhausted = false
            var loaded: UIImage?
            for candidate in [ref] + fallbackRefs where loaded == nil {
                guard !Task.isCancelled else { return }
                loaded = await ArtworkStore.shared.image(for: candidate, config: settings.smbConfig)
            }
            // A superseded load mustn't blank what its replacement shows.
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                image = loaded
                exhausted = loaded == nil
            }
        }
    }
}

/// A title card for things with no artwork anywhere, not even a readable
/// frame. The colour comes from the title, so a show keeps the same one.
struct GeneratedArtwork: View {
    var title: String?
    var subtitle: String?
    var symbol = "film"

    var body: some View {
        let hue = Self.hue(for: title ?? "")
        ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.5, brightness: 0.5),
                                    Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.2)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { geo in
                Image(systemName: symbol)
                    .font(.system(size: min(geo.size.width, geo.size.height) * 0.6))
                    .foregroundStyle(.white.opacity(0.08))
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomTrailing)
                    .offset(x: geo.size.width * 0.12, y: geo.size.height * 0.08)
            }
            if title != nil || subtitle != nil {
                VStack(spacing: 4) {
                    if let title {
                        Text(title)
                            .font(.subheadline.weight(.bold))
                            .lineLimit(4)
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2.weight(.semibold))
                            .opacity(0.75)
                            .lineLimit(1)
                    }
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .padding(8)
            }
        }
    }

    /// Stable across launches, unlike `hashValue`.
    private static func hue(for title: String) -> Double {
        let seed = title.unicodeScalars.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ $1.value }
        return Double(seed % 360) / 360
    }
}

/// A fixed-aspect frame that crops artwork to fit. `.scaledToFill` alone
/// overflows its frame in a grid.
struct ArtworkFrame: View {
    let ref: String?
    var fallbackRefs: [String?] = []
    var aspectRatio: CGFloat = 2.0 / 3.0
    var fallbackTitle: String?
    var fallbackSubtitle: String?
    var fallbackSymbol = "film"
    var cornerRadius: CGFloat = 8

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                ArtworkImage(ref: ref, fallbackRefs: fallbackRefs, fallbackTitle: fallbackTitle,
                             fallbackSubtitle: fallbackSubtitle, fallbackSymbol: fallbackSymbol)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
