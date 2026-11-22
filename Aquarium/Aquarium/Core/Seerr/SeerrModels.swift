//  What Seerr says, in the shapes its API sends.
//
//  Seerr (the request manager that Jellyseerr and Overseerr became) describes
//  titles by their TMDB ids, not Jellyfin's, and says of each whether it is in
//  the library, asked for, or neither. Every field is optional: the API has
//  grown across three projects and a missing key is never worth a failed page.

import Foundation

/// What `/settings/public` says before anyone has signed in.
struct SeerrPublicSettings: Codable, Sendable, Hashable {
    var initialized: Bool?
    var applicationTitle: String?
    /// 1 Plex, 2 Jellyfin, 3 Emby, 4 not set up.
    var mediaServerType: Int?
    var movie4kEnabled: Bool?
    var series4kEnabled: Bool?
    /// Whether a show can be asked for a season at a time.
    var partialRequestsEnabled: Bool?
    /// Seerr keeps its own copies of posters and serves them itself.
    var cacheImages: Bool?
    var mediaServerLogin: Bool?

    var usesJellyfin: Bool { mediaServerType == 2 }
}

/// What a Seerr account may do: a bit mask, the way Seerr stores it.
struct SeerrPermissions: OptionSet, Sendable, Hashable, Codable {
    let rawValue: Int
    static let admin = SeerrPermissions(rawValue: 2)
    static let manageRequests = SeerrPermissions(rawValue: 16)
    static let request = SeerrPermissions(rawValue: 32)
    static let autoApprove = SeerrPermissions(rawValue: 128)
    static let request4K = SeerrPermissions(rawValue: 1024)
    static let request4KMovie = SeerrPermissions(rawValue: 2048)
    static let request4KTV = SeerrPermissions(rawValue: 4096)
    static let requestMovie = SeerrPermissions(rawValue: 262_144)
    static let requestTV = SeerrPermissions(rawValue: 524_288)

    func canRequest(_ kind: SeerrMediaKind) -> Bool {
        if contains(.admin) || contains(.request) { return true }
        return contains(kind == .movie ? .requestMovie : .requestTV)
    }

    func canRequest4K(_ kind: SeerrMediaKind) -> Bool {
        if contains(.admin) || contains(.request4K) { return true }
        return contains(kind == .movie ? .request4KMovie : .request4KTV)
    }
}

struct SeerrUser: Codable, Sendable, Hashable {
    var id: Int?
    var displayName: String?
    var username: String?
    var jellyfinUsername: String?
    var email: String?
    var permissions: Int?
    var jellyfinUserId: String?

    var name: String {
        for candidate in [displayName, username, jellyfinUsername, email] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return ""
    }
}

/// A film or a show. Seerr's other result kinds (people, collections) are
/// read as `nil` and left out.
enum SeerrMediaKind: String, Codable, Sendable, Hashable {
    case movie, tv

    var noun: String { self == .movie ? "film" : "show" }
}

/// Where a title stands in the library, as Seerr numbers it.
enum SeerrAvailability: Int, Sendable {
    case unknown = 1, pending, processing, partiallyAvailable, available

    init(_ raw: Int?) {
        self = raw.flatMap(SeerrAvailability.init(rawValue:)) ?? .unknown
    }
}

/// Where one request stands.
enum SeerrRequestStatus: Int, Sendable {
    case pending = 1, approved, declined, failed, completed

    init(_ raw: Int?) {
        self = raw.flatMap(SeerrRequestStatus.init(rawValue:)) ?? .pending
    }
}

struct SeerrSeasonState: Codable, Sendable, Hashable {
    var seasonNumber: Int?
    var status: Int?
}

/// What Seerr knows about a title it has met: whether it is in the library,
/// and who has asked for it.
struct SeerrMediaInfo: Codable, Sendable, Hashable {
    var id: Int?
    var mediaType: String?
    var tmdbId: Int?
    var tvdbId: Int?
    var status: Int?
    var status4k: Int?
    /// The title's id on the Jellyfin server, once it is there.
    var jellyfinMediaId: String?
    var jellyfinMediaId4k: String?
    var seasons: [SeerrSeasonState]?
    var requests: [SeerrRequest]?

    var availability: SeerrAvailability { SeerrAvailability(status) }
    var libraryItemId: String? {
        for candidate in [jellyfinMediaId, jellyfinMediaId4k] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }
}

/// One request: who asked, for what, and how far it has got.
struct SeerrRequest: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var status: Int?
    var createdAt: String?
    var type: String?
    var is4k: Bool?
    var media: SeerrMediaInfo?
    var seasons: [SeerrSeasonState]?
    var requestedBy: SeerrUser?

    var kind: SeerrMediaKind? { (type ?? media?.mediaType).flatMap(SeerrMediaKind.init(rawValue:)) }
    var requestStatus: SeerrRequestStatus { SeerrRequestStatus(status) }

    /// Seerr's own nesting is circular (a request's media lists its requests),
    /// and nothing here reads the inner list.
    enum CodingKeys: String, CodingKey { case id, status, createdAt, type, is4k, media, seasons, requestedBy }
}

struct SeerrRequestPage: Codable, Sendable {
    struct PageInfo: Codable, Sendable {
        var pages: Int?
        var results: Int?
        var page: Int?
    }
    var pageInfo: PageInfo?
    var results: [SeerrRequest]?
}

/// A title in a list: search, the browse rows, a collection, someone's credits.
struct SeerrResult: Codable, Sendable, Hashable, Identifiable {
    var tmdbId: Int
    var mediaType: String?
    var title: String?
    var name: String?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var releaseDate: String?
    var firstAirDate: String?
    var voteAverage: Double?
    var mediaInfo: SeerrMediaInfo?

    enum CodingKeys: String, CodingKey {
        case tmdbId = "id"
        case mediaType, title, name, overview, posterPath, backdropPath
        case releaseDate, firstAirDate, voteAverage, mediaInfo
    }

    var kind: SeerrMediaKind? { mediaType.flatMap(SeerrMediaKind.init(rawValue:)) }
    var id: String { "\(mediaType ?? "?")-\(tmdbId)" }
    var displayTitle: String { title ?? name ?? "" }
    var year: String? { SeerrDates.year(releaseDate ?? firstAirDate) }
    var availability: SeerrAvailability { mediaInfo?.availability ?? .unknown }
    /// Worth offering among things the library lacks: a film or a show none
    /// of which is here. A show that is partly here is not a stranger; its
    /// own library page says which seasons are missing (`SeerrItemHooks`).
    var isRequestable: Bool {
        kind != nil && availability != .available && availability != .partiallyAvailable
    }
}

struct SeerrPage: Codable, Sendable {
    var page: Int?
    var totalPages: Int?
    var totalResults: Int?
    var results: [SeerrResult]?
}

struct SeerrGenre: Codable, Sendable, Hashable {
    var id: Int?
    var name: String?
}

struct SeerrCastMember: Codable, Sendable, Hashable {
    var id: Int?
    var name: String?
    var character: String?
    var profilePath: String?
}

struct SeerrCredits: Codable, Sendable, Hashable {
    var cast: [SeerrCastMember]?
}

struct SeerrSeason: Codable, Sendable, Hashable, Identifiable {
    var seasonNumber: Int
    var name: String?
    var episodeCount: Int?
    var airDate: String?
    var id: Int { seasonNumber }
}

/// A film's or a show's own page. One type for both: the fields a film lacks
/// (seasons) and the ones a show lacks (runtime) are simply absent.
struct SeerrTitle: Codable, Sendable, Hashable {
    var tmdbId: Int
    var title: String?
    var name: String?
    var overview: String?
    var tagline: String?
    var posterPath: String?
    var backdropPath: String?
    var releaseDate: String?
    var firstAirDate: String?
    var runtime: Int?
    var voteAverage: Double?
    var genres: [SeerrGenre]?
    var credits: SeerrCredits?
    var seasons: [SeerrSeason]?
    var mediaInfo: SeerrMediaInfo?

    enum CodingKeys: String, CodingKey {
        case tmdbId = "id"
        case title, name, overview, tagline, posterPath, backdropPath, releaseDate
        case firstAirDate, runtime, voteAverage, genres, credits, seasons, mediaInfo
    }

    var displayTitle: String { title ?? name ?? "" }
    var year: String? { SeerrDates.year(releaseDate ?? firstAirDate) }
    /// The numbered seasons. Season 0 is "Specials", which Seerr's own page
    /// leaves out unless an administrator turns it on.
    var realSeasons: [SeerrSeason] { (seasons ?? []).filter { $0.seasonNumber > 0 } }
}

struct SeerrCollection: Codable, Sendable, Hashable {
    var id: Int?
    var name: String?
    var parts: [SeerrResult]?
}

struct SeerrPersonCredits: Codable, Sendable {
    var cast: [SeerrResult]?
    var crew: [SeerrResult]?
}

struct SeerrQuota: Codable, Sendable, Hashable {
    struct Allowance: Codable, Sendable, Hashable {
        var days: Int?
        var limit: Int?
        var used: Int?
        var remaining: Int?
        var restricted: Bool?

        /// "2 of 5 requests left this week", or nil when there is no limit.
        var summary: String? {
            guard let limit, limit > 0, let remaining else { return nil }
            let span: String
            switch days ?? 0 {
            case 1: span = "today"
            case 7: span = "this week"
            case let d where d > 1: span = "in \(d) days"
            default: span = ""
            }
            let left = max(0, remaining)
            return "\(left) of \(limit) request\(limit == 1 ? "" : "s") left \(span)".trimmingCharacters(in: .whitespaces)
        }
    }
    var movie: Allowance?
    var tv: Allowance?

    func allowance(for kind: SeerrMediaKind) -> Allowance? { kind == .movie ? movie : tv }
}

enum SeerrDates {
    /// "2024" from "2024-03-01".
    static func year(_ date: String?) -> String? {
        guard let date, date.count >= 4 else { return nil }
        let year = String(date.prefix(4))
        return year.allSatisfy(\.isNumber) ? year : nil
    }
}

// MARK: - What a person sees

/// Where a title stands, in the words the app uses. Worked out in one place so
/// a card's badge, the page's button and the Requests list never disagree.
enum SeerrStanding: Equatable, Sendable {
    /// Not in the library and not asked for.
    case requestable
    /// Asked for; an administrator has not said yes yet.
    case awaitingApproval
    /// Approved and being fetched.
    case onItsWay
    /// A show with some seasons in the library and others not.
    case partlyAvailable
    case available
    case declined
    case failed

    var label: String {
        switch self {
        case .requestable: "Not in your library"
        case .awaitingApproval: "Waiting for approval"
        case .onItsWay: "On its way"
        case .partlyAvailable: "Some seasons available"
        case .available: "In your library"
        case .declined: "Declined"
        case .failed: "Couldn't be fetched"
        }
    }

    /// The short form, for a badge on a poster. Nil draws none.
    var badge: String? {
        switch self {
        case .requestable: nil
        case .awaitingApproval: "Requested"
        case .onItsWay: "On its way"
        case .partlyAvailable: "Partly here"
        case .available: "In library"
        case .declined: "Declined"
        case .failed: "Failed"
        }
    }

    var symbol: String {
        switch self {
        case .requestable: "plus.circle"
        case .awaitingApproval: "clock"
        case .onItsWay: "arrow.down.circle"
        case .partlyAvailable: "circle.lefthalf.filled"
        case .available: "checkmark.circle.fill"
        case .declined: "xmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    /// From what Seerr says about the title as a whole.
    init(media: SeerrMediaInfo?) {
        switch media?.availability ?? .unknown {
        case .available: self = .available
        case .partiallyAvailable: self = .partlyAvailable
        case .processing: self = .onItsWay
        case .pending: self = .awaitingApproval
        case .unknown: self = .requestable
        }
    }

    /// From one request, which knows more than its title does: a declined
    /// request leaves the title "unknown".
    init(request: SeerrRequest) {
        switch request.requestStatus {
        case .declined: self = .declined
        case .failed: self = .failed
        case .pending: self = .awaitingApproval
        case .completed: self = .available
        case .approved:
            switch request.media?.availability ?? .unknown {
            case .available: self = .available
            case .partiallyAvailable: self = .partlyAvailable
            default: self = .onItsWay
            }
        }
    }
}

extension SeerrTitle {
    /// The seasons that can still be asked for: not in the library, and not
    /// already covered by a request that is pending or approved.
    var requestableSeasons: [SeerrSeason] {
        var taken = Set<Int>()
        for season in mediaInfo?.seasons ?? [] {
            let state = SeerrAvailability(season.status)
            if state != .unknown, let number = season.seasonNumber { taken.insert(number) }
        }
        for request in mediaInfo?.requests ?? [] {
            let status = request.requestStatus
            guard status == .pending || status == .approved else { continue }
            for season in request.seasons ?? [] {
                if let number = season.seasonNumber { taken.insert(number) }
            }
        }
        return realSeasons.filter { !taken.contains($0.seasonNumber) }
    }

    /// What one season's row says.
    func standing(ofSeason number: Int) -> SeerrStanding {
        if let state = mediaInfo?.seasons?.first(where: { $0.seasonNumber == number }) {
            switch SeerrAvailability(state.status) {
            case .available: return .available
            case .partiallyAvailable: return .partlyAvailable
            case .processing: return .onItsWay
            case .pending: return .awaitingApproval
            case .unknown: break
            }
        }
        for request in mediaInfo?.requests ?? [] where request.seasons?.contains(where: { $0.seasonNumber == number }) == true {
            switch request.requestStatus {
            case .pending: return .awaitingApproval
            case .approved: return .onItsWay
            default: continue
            }
        }
        return .requestable
    }
}
