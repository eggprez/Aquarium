//  The little that `Core/Models.swift` and `Core/Formatting.swift` lean on
//  from files the watch does not compile.
//
//  The watch shares the DTOs with the phone — a `BaseItem` decoded here is
//  the same shape the server sent the phone — but not the client behind them:
//  the phone's `JellyfinClient` is two thousand lines of video, live TV and
//  download plumbing a watch has no use for. So the model file's three
//  outward references are answered here, and the watch's own client takes
//  the same name so `JellyfinClient.pathId` means the same thing in both.

import Foundation

/// A language tag's readable name — `Models.swift` uses it for a track's menu
/// label, which the watch never draws. Kept minimal.
enum Languages {
    static func name(for tag: String) -> String { tag.uppercased() }
}

extension Array where Element == BaseItem {
    /// Disc, then track, then name — the order a sleeve lists them in. The
    /// phone's copy lives in `JellyfinClient+Music.swift`, which the watch
    /// does not compile.
    func sortedByTrack() -> [BaseItem] {
        sorted {
            let a = ($0.ParentIndexNumber ?? 1, $0.IndexNumber ?? Int.max)
            let b = ($1.ParentIndexNumber ?? 1, $1.IndexNumber ?? Int.max)
            if a != b { return a < b }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// The albums these songs belong to, one entry each, in the order the
    /// songs were given.
    func albumsInOrder() -> [BaseItem] {
        var seen = Set<String>()
        var out: [BaseItem] = []
        for song in self {
            guard let albumId = song.AlbumId, !albumId.isEmpty, !seen.contains(albumId) else { continue }
            seen.insert(albumId)
            var album = BaseItem()
            album.Id = albumId
            album.Name = song.Album
            album.type = "MusicAlbum"
            album.AlbumArtist = song.AlbumArtist
            album.AlbumArtists = song.AlbumArtists
            album.Artists = song.AlbumArtists?.compactMap(\.Name) ?? song.Artists
            album.ProductionYear = song.ProductionYear
            if let tag = song.AlbumPrimaryImageTag { album.ImageTags = ["Primary": tag] }
            album.ImageBlurHashes = song.ImageBlurHashes
            out.append(album)
        }
        return out
    }
}
