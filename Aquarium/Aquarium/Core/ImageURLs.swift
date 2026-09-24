//  Artwork URLs, and the BlurHash for the same picture.
//
//  Jellyfin's image endpoints don't need the access token, so these are plain
//  URLs the image loader can fetch directly — the one exception in the app is
//  trickplay, which does need it and goes through JellyfinClient instead.

import Foundation

extension URL {
    /// A URL from a string that a playlist wrote and nothing validated.
    ///
    /// `URL(string:)` implements the grammar, and a great many real logo
    /// addresses don't: a space in a filename ("BBC One.png"), an accent, a
    /// stray bracket. Strictly they are all illegal and every one of them is
    /// served happily by the host that wrote them, so a client that refuses
    /// them shows a blank tile where every other client shows a picture.
    /// Escaped on the second pass only, so an address that was already correct
    /// — percent-escapes and all — is never encoded twice.
    static func lenient(_ raw: String, relativeTo base: URL? = nil) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed, relativeTo: base) { return url.absoluteURL }
        guard let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
        else { return nil }
        return URL(string: escaped, relativeTo: base)?.absoluteURL
    }
}

enum Artwork {
    /// The widths artwork is asked for at, rounded up to one of a few steps.
    ///
    /// Every card size asked for its own width — 400 here, 480 there, 600 for
    /// the lock screen — and each width is a different URL: a different entry
    /// in the image cache, the URL cache and the server's resize cache, for the
    /// same picture. On a short ladder most of those land on the same step,
    /// and the image loader answers a narrower request from a wider copy it
    /// already holds. Never rounded down, so nothing gets softer.
    private static let steps = [160, 240, 320, 400, 480, 640, 800, 960, 1280, 1600, 1920, 2560]

    static func ladder(_ width: Int) -> Int {
        steps.first { $0 >= width } ?? width
    }

    /// Which item and which image tag a request for `type` actually resolves
    /// to. Split out because the BlurHash for an image is filed under the same
    /// tag: a placeholder that resolved the tag differently would be the blur of
    /// some other artwork.
    private static func resolve(_ item: BaseItem, type: String) -> (id: String, tag: String)? {
        var id = item.Id
        var tag = item.ImageTags?[type]
        if tag == nil, type == "Primary" {
            if let seriesTag = item.SeriesPrimaryImageTag, let seriesId = item.SeriesId {
                id = seriesId
                tag = seriesTag
            } else if let primary = item.PrimaryImageTag {
                tag = primary
            }
        }
        if tag == nil, type == "Backdrop" {
            if let backdrop = item.BackdropImageTags?.first {
                tag = backdrop
            } else if let parentTag = item.ParentBackdropImageTags?.first,
                      let parentId = item.ParentBackdropItemId {
                id = parentId
                tag = parentTag
            }
        }
        guard let tag, !tag.isEmpty else { return nil }
        return (id, tag)
    }

    static func url(_ item: BaseItem, type: String = "Primary", width: Int = 400) -> URL? {
        guard let server = Preferences.shared.session?.server,
              let found = resolve(item, type: type) else { return nil }
        let q = [
            URLQueryItem(name: "maxWidth", value: String(ladder(width))),
            URLQueryItem(name: "tag", value: found.tag),
            URLQueryItem(name: "quality", value: "90"),
        ]
        return URL(string: "\(server)/Items/\(JellyfinClient.pathId(found.id))/Images/\(type)?\(JellyfinClient.encode(q))")
    }

    /// The BlurHash for the same image `url` would return — a placeholder to
    /// paint while the real artwork is in flight. Nil whenever the server hasn't
    /// computed one (older Jellyfin, or an image added since the last scan).
    static func hash(_ item: BaseItem, type: String = "Primary") -> String? {
        guard let found = resolve(item, type: type),
              let byTag = item.ImageBlurHashes?[type],
              let hash = byTag[found.tag], hash.count > 5
        else { return nil }
        return hash
    }

    /// A Live TV channel's logo. A channel from a custom M3U/XMLTV source (see
    /// IPTVSource) carries its own logo as a plain external URL rather than a
    /// Jellyfin image tag, since there is no server behind it to resolve one
    /// against; a Jellyfin channel falls back to the ordinary `Primary` image.
    static func channelLogo(_ item: BaseItem, width: Int = 160) -> URL? {
        if let raw = item.ExternalLogoURL, let external = URL.lenient(raw) { return external }
        return url(item, type: "Primary", width: width)
    }

    /// The item's title art — the transparent wordmark studios ship with a film
    /// or show. Heroes use it in place of typeset text, which is what Apple TV,
    /// Infuse and Netflix all do: the title reads as part of the artwork rather
    /// than as a caption on top of it. Episodes and seasons carry their series'
    /// logo through the Parent* tags.
    static func logo(_ item: BaseItem, width: Int = 640) -> URL? {
        guard let server = Preferences.shared.session?.server else { return nil }
        var id = item.Id
        var tag = item.ImageTags?["Logo"]
        if tag == nil, let parentId = item.ParentLogoItemId, let parentTag = item.ParentLogoImageTag {
            id = parentId
            tag = parentTag
        }
        guard let tag, !tag.isEmpty, !id.isEmpty else { return nil }
        let q = [
            URLQueryItem(name: "maxWidth", value: String(ladder(width))),
            URLQueryItem(name: "tag", value: tag),
            URLQueryItem(name: "quality", value: "90"),
        ]
        return URL(string: "\(server)/Items/\(JellyfinClient.pathId(id))/Images/Logo?\(JellyfinClient.encode(q))")
    }

    /// The item's own Primary image and nothing borrowed. `url` falls back to
    /// the series poster when an item has no Primary tag of its own, which is
    /// right for a card standing in for a show and wrong for anything that has
    /// to be *this* episode's thumbnail — a downloads list where every row shows
    /// the same series poster tells you nothing about which episode it is.
    static func ownPrimary(_ item: BaseItem, width: Int = 400) -> URL? {
        guard let server = Preferences.shared.session?.server,
              let tag = item.ImageTags?["Primary"], !tag.isEmpty
        else { return nil }
        let q = [
            URLQueryItem(name: "maxWidth", value: String(ladder(width))),
            URLQueryItem(name: "tag", value: tag),
            URLQueryItem(name: "quality", value: "90"),
        ]
        return URL(string: "\(server)/Items/\(JellyfinClient.pathId(item.Id))/Images/Primary?\(JellyfinClient.encode(q))")
    }

    /// The poster of the season an episode belongs to.
    ///
    /// Unlike every other URL here this one carries no tag: an episode is never
    /// told its season's image tag, only the season's id. Jellyfin serves the
    /// current image without one — the tag is a cache key, not a credential —
    /// and a season with no poster of its own 404s, which is why callers pass a
    /// series poster as the fallback.
    static func seasonPoster(_ item: BaseItem, width: Int = 400) -> URL? {
        guard let server = Preferences.shared.session?.server,
              let seasonId = item.SeasonId, !seasonId.isEmpty
        else { return nil }
        let q = [
            URLQueryItem(name: "maxWidth", value: String(ladder(width))),
            URLQueryItem(name: "quality", value: "90"),
        ]
        return URL(string: "\(server)/Items/\(JellyfinClient.pathId(seasonId))/Images/Primary?\(JellyfinClient.encode(q))")
    }

    /// The portrait series poster for an episode. Its own Primary image is the
    /// 16:9 episode still, which looks wrong on a show card.
    static func seriesPoster(_ item: BaseItem, width: Int = 400) -> URL? {
        guard let server = Preferences.shared.session?.server,
              let seriesId = item.SeriesId, let tag = item.SeriesPrimaryImageTag
        else { return nil }
        let q = [
            URLQueryItem(name: "maxWidth", value: String(ladder(width))),
            URLQueryItem(name: "tag", value: tag),
            URLQueryItem(name: "quality", value: "90"),
        ]
        return URL(string: "\(server)/Items/\(JellyfinClient.pathId(seriesId))/Images/Primary?\(JellyfinClient.encode(q))")
    }

    /// A cast member's headshot.
    static func person(_ person: Person, width: Int = 240) -> URL? {
        guard let server = Preferences.shared.session?.server,
              let id = person.Id, let tag = person.PrimaryImageTag
        else { return nil }
        let q = [
            URLQueryItem(name: "maxWidth", value: String(ladder(width))),
            URLQueryItem(name: "tag", value: tag),
            URLQueryItem(name: "quality", value: "90"),
        ]
        return URL(string: "\(server)/Items/\(JellyfinClient.pathId(id))/Images/Primary?\(JellyfinClient.encode(q))")
    }

    /// The 16:9 artwork a wide card shows.
    ///
    /// Almost always the item's own Primary image. A channel from a custom
    /// playlist is the exception: its logo is an address the playlist wrote,
    /// with no Jellyfin item and no image tag behind it, so asking the server
    /// for one gets nothing — which is what left every playlist channel on the
    /// home screen's On Now row as an empty tile. See `channelLogo`, which is
    /// the same rule the guide's own column follows.
    ///
    /// A film is the other exception. Its Primary image is a portrait poster,
    /// and a poster centre-cropped to 16:9 shows the middle of somebody's face
    /// with the title's top edge peeking in at the bottom. The backdrop is the
    /// picture that was made for this shape, so a film uses it when it has one.
    static func still(for item: BaseItem, width: Int = 400) -> URL? {
        if let raw = item.ExternalLogoURL, let external = URL.lenient(raw) { return external }
        return url(item, type: stillType(for: item), width: width)
    }

    /// Which image `still(for:)` resolves to, so the BlurHash painted while it
    /// loads is the blur of the same picture.
    static func stillType(for item: BaseItem) -> String {
        item.kind == "Movie" && item.BackdropImageTags?.isEmpty == false ? "Backdrop" : "Primary"
    }

    /// The artwork a card should show, given the shape it is drawn in.
    /// Episodes in a portrait grid borrow their series poster; everywhere else
    /// the item's own Primary image is right.
    static func poster(for item: BaseItem, width: Int = 400) -> URL? {
        if item.isEpisode, let series = seriesPoster(item, width: width) { return series }
        return url(item, type: "Primary", width: width)
    }

    /// The season an episode belongs to, drawn as a poster — what Next Up
    /// shows.
    ///
    /// A show's seasons are the one thing its artwork is actually made to tell
    /// apart, and an episode still cannot: two rows of 16:9 frames from the
    /// middle of an episode look like screenshots of something rather than like
    /// the thing you are three episodes into. The season poster says which show
    /// *and* which season at a glance, which is exactly the question Next Up
    /// answers.
    ///
    /// Not every season has one, so this is a pair: the season's own poster and
    /// what to fall back to when the server 404s it — the series poster, then
    /// the item's own image. See `RemoteImage.fallbackURL`.
    static func seasonArt(for item: BaseItem, width: Int = 400) -> (url: URL?, fallback: URL?) {
        let backstop = poster(for: item, width: width)
        guard item.isEpisode || item.isSeason else { return (backstop, nil) }
        if item.isSeason { return (url(item, type: "Primary", width: width) ?? backstop, backstop) }
        return (seasonPoster(item, width: width) ?? backstop, backstop)
    }
}
