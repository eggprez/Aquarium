//  Pictures on the watch: fetched with the token in a header, kept in
//  memory, and read from beside a download when there is a copy there.

import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor
final class WatchImages {
    static let shared = WatchImages()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 200
    }

    /// Where an item's cover is: the file beside its download, else the server.
    static func url(for item: BaseItem, width: Int = 200) -> URL? {
        if let raw = item.ExternalLogoURL, let local = URL(string: raw), local.isFileURL { return local }
        let art = WatchDownloads.artFile(item.Id)
        if FileManager.default.fileExists(atPath: art.path) { return art }
        if let albumId = item.AlbumId, item.isSong {
            let albumArt = WatchDownloads.artFile(albumId)
            if FileManager.default.fileExists(atPath: albumArt.path) { return albumArt }
        }
        return JellyfinClient.shared.imageURL(for: item, width: width)
    }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url.absoluteString as NSString) }

    func load(_ url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        if let running = inFlight[url] { return await running.value }
        let task = Task<UIImage?, Never> {
            if url.isFileURL {
                return (try? Data(contentsOf: url)).flatMap(UIImage.init(data:))
            }
            var req = URLRequest(url: url)
            req.setValue("image/*", forHTTPHeaderField: "Accept")
            for (k, v) in JellyfinClient.shared.authHeaders() { req.setValue(v, forHTTPHeaderField: k) }
            guard let (data, response) = try? await URLSession.shared.data(for: req),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
            else { return nil }
            return UIImage(data: data)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { cache.setObject(image, forKey: url.absoluteString as NSString) }
        return image
    }

    /// The copy beside a download changed or went.
    nonisolated static func forget(_ itemId: String) {
        let url = WatchDownloads.artFile(itemId)
        Task { @MainActor in shared.cache.removeObject(forKey: url.absoluteString as NSString) }
    }
}

/// A square cover with a placeholder that says what kind of thing it is.
struct Artwork: View {
    let item: BaseItem
    var size: CGFloat = 40
    var corner: CGFloat = 6

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x3B2A6B), Color(hex: 0x1B2A5B)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: item.isAudiobook ? "book.fill" : (item.isPlaylist ? "music.note.list" : "music.note"))
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .task(id: WatchImages.url(for: item, width: Int(size * 2))) {
            guard let url = WatchImages.url(for: item, width: Int(size * 2)) else { image = nil; return }
            if let hit = WatchImages.shared.cached(url) { image = hit; return }
            image = await WatchImages.shared.load(url)
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// The app's purple, restated for the watch.
enum WatchTheme {
    static let accent = Color(hex: 0x8B5CF6)
    static let link = Color(hex: 0xA78BFA)
    static let dim = Color.white.opacity(0.6)
}
