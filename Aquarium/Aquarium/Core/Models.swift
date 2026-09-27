//  Jellyfin DTOs, in the shape this client actually reads them.
//
//  The Linux app passed raw JSON around and reached into it with optional
//  chaining. Swift wants types, so these are decoded structs — but they stay
//  deliberately permissive: every field is optional, because Jellyfin varies
//  what it returns by item type, by endpoint, and by server version, and an
//  episode missing `SeasonName` must not fail the decode of the whole season.

import Foundation

// MARK: - Item

struct UserData: Codable, Hashable, Sendable {
    var PlaybackPositionTicks: Int64?
    var PlayCount: Int?
    var IsFavorite: Bool?
    var Played: Bool?
    var PlayedPercentage: Double?
    var UnplayedItemCount: Int?
    /// When this was last played, as the server records it — what "recently
    /// played" in the music tab is sorted by.
    var LastPlayedDate: String?

    var positionTicks: Int64 { PlaybackPositionTicks ?? 0 }
    var played: Bool { Played ?? false }
    var isFavorite: Bool { IsFavorite ?? false }
}

struct MediaStream: Codable, Hashable, Sendable {
    // `Type` and `Protocol` are spelled out in JSON but can't be property names
    // in Swift, so those two get a CodingKey and everything else keeps the
    // server's own spelling.
    enum CodingKeys: String, CodingKey {
        case Index, Codec, Language, DisplayTitle, Title, Height, Width
        case Channels, ChannelLayout, IsDefault, IsForced, IsExternal, BitRate
        case BitDepth, Profile, RealFrameRate, AverageFrameRate, VideoRange
        case type = "Type"
    }
    var Index: Int?
    var type: String?
    var Codec: String?
    var Language: String?
    var DisplayTitle: String?
    var Title: String?
    var Height: Int?
    var Width: Int?
    var Channels: Int?
    var ChannelLayout: String?
    var IsDefault: Bool?
    var IsForced: Bool?
    var IsExternal: Bool?
    var BitRate: Int?
    /// Bits per sample. The one number that reliably separates the HEVC and
    /// H.264 profiles Apple silicon decodes from the ones it doesn't — see
    /// `DeviceProfile.canDirectPlay`.
    var BitDepth: Int?
    /// The codec profile as ffprobe named it: `High`, `Main 10`, `High 10`.
    var Profile: String?
    /// Frames a second, as ffprobe read them. `RealFrameRate` is the stream's
    /// declared rate and the one an Apple TV matches its display to; the
    /// average is only a fallback for files that don't declare one.
    var RealFrameRate: Double?
    var AverageFrameRate: Double?
    /// `SDR` or `HDR`, as the server read it off the stream's colour tags.
    /// Only ever trusted alongside the codec — see
    /// `JellyfinClient.claimsHDRItCannotCarry`.
    var VideoRange: String?

    var isForced: Bool { IsForced ?? false }

    /// A picture-based subtitle — PGS out of a Blu-ray remux, VOBSUB out of a
    /// DVD one. There is no text in these to hand a player, so the only way to
    /// show one is for the server to paint it into the video; see
    /// `DeviceProfile.subtitleProfiles`. Worth telling apart because it is the
    /// difference between a track this app can switch to in a frame and one
    /// that costs a new stream.
    var isImageSubtitle: Bool {
        ["pgssub", "pgs", "dvdsub", "dvd_subtitle", "dvbsub", "dvb_subtitle", "vobsub", "xsub"]
            .contains(Codec?.lowercased() ?? "")
    }

    /// What to call this track in a menu.
    ///
    /// The server's own `DisplayTitle` is what every other Jellyfin client
    /// shows — "English - Dolby Digital - 5.1 - Default" — and is far more use
    /// than anything reassembled from the parts. The rest is for the servers
    /// and the files that leave it empty.
    var menuLabel: String {
        if let title = DisplayTitle, !title.isEmpty { return title }
        var parts: [String] = []
        if let name = Title, !name.isEmpty {
            parts.append(name)
        } else if let language = Language, !language.isEmpty {
            parts.append(Languages.name(for: language))
        }
        if let codec = Codec, !codec.isEmpty { parts.append(codec.uppercased()) }
        if let layout = ChannelLayout, !layout.isEmpty {
            parts.append(layout)
        } else if let channels = Channels {
            parts.append("\(channels)ch")
        }
        if isForced { parts.append("Forced") }
        return parts.isEmpty ? "Track \(Index ?? 0)" : parts.joined(separator: " · ")
    }
}

struct MediaSource: Codable, Hashable, Sendable {
    var Id: String?
    var Name: String?
    var Container: String?
    var Size: Int64?
    var ETag: String?
    var LiveStreamId: String?
    var TranscodingUrl: String?
    var SupportsDirectPlay: Bool?
    var SupportsDirectStream: Bool?
    var SupportsTranscoding: Bool?
    var RunTimeTicks: Int64?
    var MediaStreams: [MediaStream]?
    /// Which track the server will send when nothing is asked for.
    ///
    /// The track menus need this to put a tick somewhere on the first stream of
    /// an item: a transcode arrives carrying exactly one audio track, so there
    /// is nothing in the stream itself to say *which* of the file's tracks it
    /// was made from. See `PlayerModel.audioOptions`.
    var DefaultAudioStreamIndex: Int?
    var DefaultSubtitleStreamIndex: Int?
    /// The whole file's bitrate. For a song this is the number that decides
    /// whether it is worth sending over a cellular link untouched.
    var Bitrate: Int?

    var streams: [MediaStream] { MediaStreams ?? [] }

    /// The file's own audio and subtitle tracks, as the server read them, in
    /// the order the server lists them.
    ///
    /// This is the only complete list there is. What AVFoundation can see is
    /// whatever arrived — the whole file on a direct play, and on a transcode a
    /// single audio track the server chose, so a menu built from the stream
    /// alone would offer one track for a film that has four.
    var audioStreams: [MediaStream] { streams.filter { $0.type == "Audio" } }
    var subtitleStreams: [MediaStream] { streams.filter { $0.type == "Subtitle" } }
}

struct Person: Codable, Hashable, Sendable, Identifiable {
    enum CodingKeys: String, CodingKey {
        case Id, Name, Role, PrimaryImageTag
        case type = "Type"
    }
    var Id: String?
    var Name: String?
    var Role: String?
    var type: String?
    var PrimaryImageTag: String?

    var id: String { Id ?? (Name ?? UUID().uuidString) }
}

/// A named address: one of an item's `RemoteTrailers`.
struct MediaUrl: Codable, Hashable, Sendable {
    var Url: String?
    var Name: String?
}

struct NameGuidPair: Codable, Hashable, Sendable, Identifiable {
    var Id: String?
    var Name: String?
    var id: String { Id ?? (Name ?? UUID().uuidString) }
}

/// One row in any list the app draws: a movie, a series, a season, an episode,
/// a library, a live channel. Jellyfin returns them all through the same DTO.
struct BaseItem: Codable, Hashable, Sendable, Identifiable {
    enum CodingKeys: String, CodingKey {
        case Id, Name, OriginalTitle, CollectionType, Overview, Genres, Taglines
        case ProductionYear, PremiereDate, RunTimeTicks, OfficialRating
        case CommunityRating, ParentId, IndexNumber, ParentIndexNumber
        case ChildCount, RecursiveItemCount, SeriesId, SeriesName, SeasonId
        case SeasonName, PrimaryImageAspectRatio, ImageTags, BackdropImageTags
        case ImageBlurHashes, PrimaryImageTag, SeriesPrimaryImageTag
        case ParentLogoItemId, ParentLogoImageTag, ParentBackdropItemId
        case ParentBackdropImageTags, UserData, MediaSources, People, Studios
        case Container, ChannelNumber, CurrentProgram, SortName, DateCreated
        case StartDate, EndDate, ChannelId, ChannelName, IsLive, EpisodeTitle
        case Album, AlbumId, AlbumPrimaryImageTag, AlbumArtist, AlbumArtists
        case ArtistItems, Artists, MediaType, HasLyrics, NormalizationGain
        case GenreItems, Chapters, PlaylistItemId, Trickplay
        case RemoteTrailers, LocalTrailerCount, ProductionLocations
        case type = "Type"
    }
    var Id: String = ""
    var Name: String?
    /// What the server sorts by — "Long Winter, The". Asked for only where the
    /// library copy has to sort the way the server would; see `LibraryIndex`.
    var SortName: String?
    var DateCreated: String?
    var OriginalTitle: String?
    var type: String?
    var CollectionType: String?
    var Overview: String?
    var Genres: [String]?
    var Taglines: [String]?
    var ProductionYear: Int?
    var PremiereDate: String?
    var RunTimeTicks: Int64?
    var OfficialRating: String?
    var CommunityRating: Double?
    var ParentId: String?

    var IndexNumber: Int?
    var ParentIndexNumber: Int?
    var ChildCount: Int?
    var RecursiveItemCount: Int?

    var SeriesId: String?
    var SeriesName: String?
    var SeasonId: String?
    var SeasonName: String?

    var PrimaryImageAspectRatio: Double?
    var ImageTags: [String: String]?
    var BackdropImageTags: [String]?
    var ImageBlurHashes: [String: [String: String]]?
    var PrimaryImageTag: String?
    var SeriesPrimaryImageTag: String?
    var ParentLogoItemId: String?
    var ParentLogoImageTag: String?
    var ParentBackdropItemId: String?
    var ParentBackdropImageTags: [String]?

    var UserData: UserData?
    var MediaSources: [MediaSource]?
    var People: [Person]?
    var Studios: [NameGuidPair]?
    var Container: String?

    // Live TV — present on a channel (ChannelNumber, CurrentProgram) or on a
    // programme returned by the guide (the rest): a programme is a BaseItem
    // like any other, just one Jellyfin files under a channel and a time.
    var ChannelNumber: String?
    var CurrentProgram: CurrentProgram?
    var StartDate: String?
    var EndDate: String?
    var ChannelId: String?
    var ChannelName: String?
    var IsLive: Bool?
    var EpisodeTitle: String?

    // Music — present on a song (most of these), an album (the artists) and
    // an audiobook (which Jellyfin files as a song whose album is the book and
    // whose artist is the author).
    var Album: String?
    var AlbumId: String?
    var AlbumPrimaryImageTag: String?
    var AlbumArtist: String?
    var AlbumArtists: [NameGuidPair]?
    var ArtistItems: [NameGuidPair]?
    var Artists: [String]?
    var GenreItems: [NameGuidPair]?
    /// "Audio", "Video", "Photo", "Book" — what a playlist holds, and what a
    /// song is.
    var MediaType: String?
    var HasLyrics: Bool?
    /// ReplayGain-style level, in dB, as the server measured it.
    var NormalizationGain: Double?
    /// An audiobook's chapters, when the file carries them. Asked for by name
    /// (`Fields=Chapters`), so nil on every list query.
    var Chapters: [ChapterInfo]?
    /// This song's slot in a playlist, as `/Playlists/{id}/Items` numbers it.
    /// What removing and moving are addressed by — the same song can be in a
    /// playlist twice, and this tells the two apart.
    var PlaylistItemId: String?
    /// The scrubbing thumbnails' description, by media source and then by
    /// width. Asked for only by the detail endpoint; see
    /// `JellyfinClient.trickplayInfo(for:)`.
    var Trickplay: [String: [String: TrickplayTileInfo]]?
    /// Trailers the metadata provider found on the web — almost always
    /// YouTube addresses — and how many trailer files sit beside the film on
    /// the server. Detail endpoint only; see `JellyfinClient.trailers(for:)`.
    var RemoteTrailers: [MediaUrl]?
    var LocalTrailerCount: Int?
    /// On a person, where they were born — the one thing Jellyfin files here
    /// for them. Detail endpoint only.
    var ProductionLocations: [String]?

    // A channel or programme that came from a custom M3U/XMLTV source rather
    // than Jellyfin — see IPTVSource. Never decoded from server JSON, so
    // absent from CodingKeys; a channel built this way carries its own
    // stream and logo instead of a Jellyfin item id and image tag.
    var ExternalStreamURL: String?
    var ExternalLogoURL: String?
    /// A custom-guide programme's airtime, as the dates the guide was parsed
    /// into. `programStart` and `programEnd` read these first: the strings
    /// beside them went through a formatter and back — a locked cache lookup
    /// on every read, and the guide reads them several times per cell per
    /// redraw. Not coded, like the two above; the strings are still written
    /// for anything that saves an item and reads it back.
    var ExternalStart: Date?
    var ExternalEnd: Date?

    var id: String { Id }

    /// When this item is a guide programme, the parsed edges of its airtime.
    var programStart: Date? { ExternalStart ?? Format.parseDate(StartDate) }
    var programEnd: Date? { ExternalEnd ?? Format.parseDate(EndDate) }

    /// Whether the clock is inside this programme's airtime right now.
    var isAiringNow: Bool {
        guard let start = programStart, let end = programEnd else { return false }
        let now = Date()
        return start <= now && now < end
    }

    var title: String { Name ?? "Untitled" }
    var kind: String { type ?? "" }
    var isEpisode: Bool { kind == "Episode" }
    var isSong: Bool { kind == "Audio" }
    var isAlbum: Bool { kind == "MusicAlbum" }
    var isArtist: Bool { kind == "MusicArtist" }
    var isMusicGenre: Bool { kind == "MusicGenre" }
    var isPlaylist: Bool { kind == "Playlist" }
    var isAudiobook: Bool { kind == "AudioBook" }
    /// Anything the music player, rather than the video player, opens.
    var isAudio: Bool { isSong || isAudiobook || MediaType == "Audio" }
    /// Something a video screen should leave out: audio of any kind, and
    /// the e-books and music folders that share a mixed library with films.
    var isNotVideo: Bool {
        isAudio || JellyfinClient.nonVideoTypes.split(separator: ",").contains { $0 == kind }
    }
    /// The line under a song's or an album's name: who made it.
    var artistLine: String {
        if let names = Artists, !names.isEmpty { return names.joined(separator: ", ") }
        if let album = AlbumArtist, !album.isEmpty { return album }
        if let names = AlbumArtists?.compactMap(\.Name), !names.isEmpty { return names.joined(separator: ", ") }
        return ""
    }
    var isSeries: Bool { kind == "Series" }
    var isSeason: Bool { kind == "Season" }
    var isFolderLike: Bool { ["Series", "Season", "BoxSet", "Folder", "CollectionFolder"].contains(kind) }
    var userData: UserData { UserData ?? .init() }
    var runtimeSeconds: Double { Double(RunTimeTicks ?? 0) / 10_000_000 }

    /// "Season 2: Episode 4" — spelled out, because "S02E04" is a filename
    /// convention rather than a thing anyone says. Every screen that shows this
    /// gives it a line of its own; it is too long to sit beside a title.
    ///
    /// Season 0 is where Jellyfin files specials, which is what it calls them.
    var episodeLabel: String? {
        guard let e = IndexNumber else { return nil }
        guard let s = ParentIndexNumber else { return "Episode \(e)" }
        return s == 0 ? "Specials: Episode \(e)" : "Season \(s): Episode \(e)"
    }

    /// How far through the item the user is, 0...1, or nil when it hasn't been
    /// started. The bar under a card is drawn from this.
    var progressFraction: Double? {
        let ticks = userData.positionTicks
        guard ticks > 0, let total = RunTimeTicks, total > 0 else { return nil }
        let f = Double(ticks) / Double(total)
        return f > 0.001 && f < 0.999 ? f : nil
    }
}

/// One chapter marker in an audiobook (or a film — Jellyfin keeps them the
/// same way), as the server lists them.
struct ChapterInfo: Codable, Hashable, Sendable {
    var Name: String?
    var StartPositionTicks: Int64?
    var startSeconds: Double { Double(StartPositionTicks ?? 0) / 10_000_000 }
}

/// The programme a live channel is showing right now.
struct CurrentProgram: Codable, Hashable, Sendable {
    var Id: String?
    var Name: String?
    var Overview: String?
    var StartDate: String?
    var EndDate: String?
    var EpisodeTitle: String?
}

// MARK: - Envelopes

struct ItemsResponse: Codable, Sendable {
    var Items: [BaseItem]?
    var TotalRecordCount: Int?

    var items: [BaseItem] { Items ?? [] }
    var total: Int { TotalRecordCount ?? (Items?.count ?? 0) }
}

struct FiltersResponse: Codable, Sendable {
    var Genres: [String]?
}

struct AuthResponse: Codable, Sendable {
    var AccessToken: String?
    var ServerId: String?
    var User: AuthUser?
}

struct AuthUser: Codable, Sendable {
    var Id: String?
    var Name: String?
}

struct PublicSystemInfo: Codable, Sendable {
    var Id: String?
    var ServerName: String?
    var Version: String?
    var StartupWizardCompleted: Bool?
}

struct PlaybackInfoResponse: Codable, Sendable {
    var MediaSources: [MediaSource]?
    var PlaySessionId: String?
    var ErrorCode: String?
}

// MARK: - Trickplay

/// One resolution of trickplay tiles, as the server describes them.
struct TrickplayInfo: Hashable, Sendable {
    /// Item the tiles belong to — not always the item being played.
    var itemId: String
    /// Pixel size of a single thumbnail.
    var width: Int
    var height: Int
    /// Thumbnails per tile sheet.
    var tileWidth: Int
    var tileHeight: Int
    /// Milliseconds between thumbnails.
    var interval: Int
    var thumbnailCount: Int
}

struct TrickplayTileInfo: Codable, Hashable, Sendable {
    var Width: Int?
    var Height: Int?
    var TileWidth: Int?
    var TileHeight: Int?
    var Interval: Int?
    var ThumbnailCount: Int?
}

/// `Trickplay` is keyed by media-source id, then by tile width.
struct TrickplayEnvelope: Codable, Sendable {
    var Trickplay: [String: [String: TrickplayTileInfo]]?
    var MediaSources: [MediaSource]?
}

// MARK: - Media segments

/// A skippable stretch of an item — an opening title sequence, closing credits.
struct MediaSegment: Hashable, Sendable, Identifiable {
    var type: String
    var start: Double
    var end: Double
    var id: String { "\(type)-\(start)" }

    var isOutro: Bool { type.caseInsensitiveCompare("Outro") == .orderedSame }
}

struct MediaSegmentsResponse: Codable, Sendable {
    struct Segment: Codable, Sendable {
        enum CodingKeys: String, CodingKey {
            case StartTicks, EndTicks
            case type = "Type"
        }
        var type: String?
        var StartTicks: Int64?
        var EndTicks: Int64?
    }
    var Items: [Segment]?
}

// MARK: - Home sections

/// One row of the Jellyfin home screen, as the server names it.
///
/// Jellyfin stores the home layout as seven slots of loose strings, and its
/// clients agree on what those strings mean. This is that vocabulary, minus the
/// kinds this app has no screen for — music and books, which are out of scope
/// here as they were on Linux — so an account with `resumeaudio` in slot 2 gets
/// the row silently left out rather than an empty heading.
enum HomeSection: String, Hashable, Sendable, CaseIterable {
    /// Every library on the server as a row of tiles. Jellyfin has two spellings
    /// of this — big buttons and small tiles — and draws them differently; here
    /// they are the same row, because a television has one sensible size for a
    /// tile and it isn't two.
    case libraries
    /// What you started and haven't finished.
    case resume
    /// The next episode of each show you're partway through.
    case nextUp
    /// The newest additions to each library, one row per library.
    case latest
    /// What's on right now, where the server has a tuner or a playlist.
    case liveTV

    /// Maps the string in the account's display preferences to a row, or `nil`
    /// where this app has nothing to draw for it.
    init?(serverName: String) {
        switch serverName.lowercased() {
        case "librarybuttons", "smalllibrarytiles", "librarytiles": self = .libraries
        case "resume", "resumevideo": self = .resume
        case "nextup": self = .nextUp
        case "latestmedia": self = .latest
        case "livetv": self = .liveTV
        // "none" and the rows this client has no library for — music, books,
        // and the recording list a DVR-less server can never fill.
        default: return nil
        }
    }

    /// What Jellyfin itself puts in a slot the account has never set, copied
    /// from the web client so an untouched account looks the same in both.
    static func jellyfinDefault(_ slot: Int) -> String {
        switch slot {
        case 0: "smalllibrarytiles"
        case 1: "resume"
        case 2: "resumeaudio"
        case 3: "livetv"
        case 4: "nextup"
        case 5: "latestmedia"
        default: "none"
        }
    }

    /// The order used when the server can't be asked: Jellyfin's own defaults,
    /// with the rows this client can't draw already dropped.
    static let fallback: [HomeSection] = (0..<7).compactMap {
        HomeSection(serverName: jellyfinDefault($0))
    }
}

extension Array where Element == BaseItem {
    /// Where this item is in the list — the same answer `firstIndex(of:)`
    /// gives, without comparing every field of every item on the way. The
    /// playlist entry is compared too: a playlist can hold one song twice,
    /// and the copy tapped is the one to start from.
    func position(of item: BaseItem) -> Int? {
        firstIndex { $0.Id == item.Id && $0.PlaylistItemId == item.PlaylistItemId }
    }
}
