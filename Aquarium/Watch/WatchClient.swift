//  The watch's own Jellyfin client.
//
//  Small on purpose. It signs in with what the phone hands over (see
//  `WatchLink`), keeps the token in this device's keychain, and asks the
//  server the handful of questions a music-and-audiobooks screen has: what is
//  part-way through, the albums, the playlists, the songs of one of them, a
//  stream address, a download address, a picture. It reports listening back
//  the same way the phone's offline sync does — a stopped report for a
//  position, the played-items route for a play.
//
//  It shares the DTOs with the phone (`Core/Models.swift`) and nothing else,
//  which is why it carries the phone client's name: the model file reaches
//  for `JellyfinClient.pathId` and `.nonVideoTypes`, and they mean the same
//  here.

import Foundation
import Observation
import Security
import WatchKit
import os

enum APIError: LocalizedError, Sendable {
    case notConfigured
    case offline(String)
    case server(status: Int, path: String)
    case auth(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Open Aquarium on your iPhone to sign the watch in."
        case .offline(let s): s
        case .server(let status, _): "Server error \(status)"
        case .auth(let s): s
        case .message(let s): s
        }
    }
}

/// Who the watch is signed in as. The token is not part of it — that lives
/// in the keychain, as on the phone.
struct WatchAccount: Codable, Hashable, Sendable {
    var server: String
    var userId: String
    var userName: String
    var serverId: String?
}

/// Where a song comes from when it is streamed.
struct WatchStream: Sendable {
    var url: URL
    var headers: [String: String]
    var isTranscode: Bool
    var mediaSourceId: String
    var playSessionId: String
}

@MainActor
@Observable
final class JellyfinClient {
    static let shared = JellyfinClient()

    nonisolated static let clientName = "Aquarium"
    nonisolated static let clientVersion = "1.0.0"
    nonisolated static let nonVideoTypes = "Audio,AudioBook,Book,MusicAlbum,MusicArtist,Photo,PhotoAlbum"
    nonisolated static let log = Logger(subsystem: "scottai.FellyJin.watchkitapp", category: "client")

    /// What a list of songs, albums or books needs; the detail shape adds the
    /// file and, for a book, its chapters.
    nonisolated static let listFields =
        "PrimaryImageAspectRatio,Genres,UserData,ChildCount,ProductionYear,RunTimeTicks,DateCreated,ParentId,SortName,AlbumArtists,ArtistItems,MediaType"
    nonisolated static let detailFields = listFields + ",Overview,MediaSources,Chapters"

    private(set) var account: WatchAccount?
    /// The saved server did not answer the last time it was asked.
    private(set) var isOffline = false
    private(set) var lastCheckedAt: Date?

    var isSignedIn: Bool { account != nil }

    /// This watch's own device id: Jellyfin keys a session by it, and a watch
    /// sharing the phone's would be the phone as far as the server could tell.
    let deviceId: String

    private let defaults = UserDefaults.standard
    private var tokenCache: String?
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private init() {
        if let id = defaults.string(forKey: "watch_device_id") {
            deviceId = id
        } else {
            let id = UUID().uuidString
            defaults.set(id, forKey: "watch_device_id")
            deviceId = id
        }
        if let data = defaults.data(forKey: "watch_account") {
            account = try? JSONDecoder().decode(WatchAccount.self, from: data)
        }
    }

    // MARK: - Sign in, from the phone

    /// Take the phone's sign-in. Same account again is a no-op except for the
    /// token, which is written every time in case it was refreshed.
    func install(_ credentials: WatchCredentials) {
        let next = WatchAccount(
            server: credentials.server, userId: credentials.userId,
            userName: credentials.userName, serverId: credentials.serverId
        )
        WatchKeychain.store(token: credentials.token, account: Self.keychainAccount(next))
        tokenCache = nil
        if account != next {
            account = next
            defaults.set(try? JSONEncoder().encode(next), forKey: "watch_account")
            isOffline = false
        }
    }

    func signOut() {
        if let account { WatchKeychain.delete(account: Self.keychainAccount(account)) }
        account = nil
        tokenCache = nil
        defaults.removeObject(forKey: "watch_account")
    }

    private nonisolated static func keychainAccount(_ a: WatchAccount) -> String { "\(a.server)|\(a.userId)" }

    private var token: String? {
        if let tokenCache { return tokenCache }
        guard let account else { return nil }
        tokenCache = WatchKeychain.token(account: Self.keychainAccount(account))
        return tokenCache
    }

    // MARK: - Plumbing

    nonisolated static func pathId(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        if id.unicodeScalars.allSatisfy(allowed.contains) { return id }
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    nonisolated static func encode(_ items: [URLQueryItem]) -> String {
        var c = URLComponents()
        c.queryItems = items
        return (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    }

    private func authorizationHeader(token: String?) -> String {
        var parts = [
            "Client=\"\(Self.clientName)\"",
            "Device=\"Apple Watch\"",
            "DeviceId=\"\(deviceId)\"",
            "Version=\"\(Self.clientVersion)\"",
        ]
        if let token, !token.isEmpty { parts.append("Token=\"\(token)\"") }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    /// The header a download or a stream carries to be let in.
    func authHeaders() -> [String: String] {
        ["Authorization": authorizationHeader(token: token)]
    }

    /// The token as a query parameter, for HLS segments, whose requests
    /// AVFoundation makes itself without our headers. `ApiKey`, the spelling
    /// every server since 10.9 reads — see the phone's `authorized`.
    func authorized(_ url: URL) -> URL {
        guard let token, !token.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        var items = components.queryItems ?? []
        guard !items.contains(where: { $0.name == "ApiKey" || $0.name == "api_key" }) else { return url }
        items.append(URLQueryItem(name: "ApiKey", value: token))
        components.queryItems = items
        return components.url ?? url
    }

    @discardableResult
    func request(
        _ path: String, method: String = "GET", body: (any Encodable)? = nil,
        countsForOffline: Bool = true, timeout: TimeInterval? = nil
    ) async throws -> Data {
        guard let account else { throw APIError.notConfigured }
        guard let url = URL(string: account.server + path) else { throw APIError.message("Bad server address") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let timeout { req.timeoutInterval = timeout }
        req.setValue(authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            if (error as? URLError)?.code == .cancelled || error is CancellationError { throw CancellationError() }
            WatchLog.error("client", "\(method) \(path.components(separatedBy: "?")[0]) failed: \(error.localizedDescription)\(countsForOffline ? " — now offline" : "")")
            if countsForOffline { isOffline = true }
            throw APIError.offline("Can't reach the server")
        }
        if countsForOffline { isOffline = false }
        guard let http = response as? HTTPURLResponse else { throw APIError.message("Malformed response") }
        if http.statusCode == 401 {
            WatchLog.error("client", "\(method) \(path.components(separatedBy: "?")[0]): 401, sign-in refused")
            tokenCache = nil
            throw APIError.auth("The watch's sign-in has expired. Open Aquarium on your iPhone to send it again.")
        }
        guard (200..<300).contains(http.statusCode) else {
            WatchLog.error("client", "\(method) \(path.components(separatedBy: "?")[0]): HTTP \(http.statusCode)")
            throw APIError.server(status: http.statusCode, path: path.components(separatedBy: "?")[0])
        }
        return data
    }

    func get<T: Decodable & Sendable>(_ type: T.Type, _ path: String, countsForOffline: Bool = true) async throws -> T {
        let data = try await request(path, countsForOffline: countsForOffline)
        if data.isEmpty, T.self == ItemsResponse.self { return ItemsResponse(Items: [], TotalRecordCount: 0) as! T }
        do {
            return try await Self.decode(T.self, from: data)
        } catch {
            throw APIError.message("The server sent something this client couldn't read")
        }
    }

    @concurrent
    nonisolated static func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data) async throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }

    /// Is the server there. A short probe against the public endpoint.
    @discardableResult
    func checkOnline() async -> Bool {
        guard account != nil else { return false }
        lastCheckedAt = Date()
        do {
            _ = try await request("/System/Info/Public", timeout: 6)
            return true
        } catch is CancellationError {
            return !isOffline
        } catch {
            isOffline = true
            return false
        }
    }

    // MARK: - Lists

    struct Query: Sendable {
        var types: String
        var parentId: String?
        var sortBy = "SortName"
        var descending = false
        var startIndex = 0
        var limit = 200
        var albumArtistIds: [String] = []
        var artistIds: [String] = []
        var genreIds: [String] = []
        var searchTerm: String?
        var fields = JellyfinClient.listFields
        var ids: [String] = []
        var played: Bool?
    }

    func items(_ q: Query) async throws -> ItemsResponse {
        guard let account else { throw APIError.notConfigured }
        var items: [URLQueryItem] = [
            .init(name: "userId", value: account.userId),
            .init(name: "IncludeItemTypes", value: q.types),
            .init(name: "Recursive", value: "true"),
            .init(name: "SortBy", value: q.sortBy),
            .init(name: "SortOrder", value: q.descending ? "Descending" : "Ascending"),
            .init(name: "Fields", value: q.fields),
            .init(name: "StartIndex", value: String(q.startIndex)),
            .init(name: "Limit", value: String(q.limit)),
            .init(name: "EnableImageTypes", value: "Primary"),
            .init(name: "ImageTypeLimit", value: "1"),
        ]
        if let parent = q.parentId { items.append(.init(name: "ParentId", value: parent)) }
        if !q.albumArtistIds.isEmpty { items.append(.init(name: "AlbumArtistIds", value: q.albumArtistIds.joined(separator: ","))) }
        if !q.artistIds.isEmpty { items.append(.init(name: "ArtistIds", value: q.artistIds.joined(separator: ","))) }
        if !q.genreIds.isEmpty { items.append(.init(name: "GenreIds", value: q.genreIds.joined(separator: ","))) }
        if !q.ids.isEmpty { items.append(.init(name: "Ids", value: q.ids.joined(separator: ","))) }
        if let term = q.searchTerm, !term.isEmpty { items.append(.init(name: "SearchTerm", value: term)) }
        if let played = q.played { items.append(.init(name: "Filters", value: played ? "IsPlayed" : "IsUnplayed")) }
        return try await get(ItemsResponse.self, "/Items?\(Self.encode(items))")
    }

    /// One item with everything a page or a download needs.
    func item(_ id: String) async throws -> BaseItem {
        guard let account else { throw APIError.notConfigured }
        return try await get(BaseItem.self, "/Items/\(Self.pathId(id))?userId=\(account.userId)&Fields=\(Self.detailFields)")
    }

    /// These items by id, fifty to a request.
    func items(ids: [String], detail: Bool = false) async throws -> [BaseItem] {
        var out: [BaseItem] = []
        for start in stride(from: 0, to: ids.count, by: 50) {
            var q = Query(types: "Audio,AudioBook,MusicAlbum,Playlist", limit: 50)
            q.ids = Array(ids[start..<min(start + 50, ids.count)])
            q.fields = detail ? Self.detailFields : Self.listFields
            out += try await items(q).items
        }
        return out
    }

    /// Songs and books stopped part-way. Books are what this is for.
    func resumeAudio(limit: Int = 20) async throws -> [BaseItem] {
        guard let account else { throw APIError.notConfigured }
        let q: [URLQueryItem] = [
            .init(name: "userId", value: account.userId),
            .init(name: "MediaTypes", value: "Audio"),
            .init(name: "Limit", value: String(limit)),
            .init(name: "Fields", value: Self.listFields),
            .init(name: "EnableImageTypes", value: "Primary"),
            .init(name: "ImageTypeLimit", value: "1"),
        ]
        return try await get(ItemsResponse.self, "/UserItems/Resume?\(Self.encode(q))").items
    }

    func recentlyPlayedSongs(limit: Int = 30) async throws -> [BaseItem] {
        var q = Query(types: "Audio", sortBy: "DatePlayed,SortName", descending: true, limit: limit)
        q.played = true
        return try await items(q).items
    }

    func albums(startIndex: Int = 0, limit: Int = 200, sortBy: String = "SortName", descending: Bool = false) async throws -> ItemsResponse {
        try await items(Query(types: "MusicAlbum", sortBy: sortBy, descending: descending, startIndex: startIndex, limit: limit))
    }

    func albumTracks(albumId: String) async throws -> [BaseItem] {
        try await items(Query(types: "Audio", parentId: albumId, limit: 500)).items.sortedByTrack()
    }

    func albumArtists(startIndex: Int = 0, limit: Int = 300) async throws -> ItemsResponse {
        guard let account else { throw APIError.notConfigured }
        let q: [URLQueryItem] = [
            .init(name: "userId", value: account.userId),
            .init(name: "SortBy", value: "SortName"),
            .init(name: "SortOrder", value: "Ascending"),
            .init(name: "Fields", value: Self.listFields),
            .init(name: "StartIndex", value: String(startIndex)),
            .init(name: "Limit", value: String(limit)),
            .init(name: "EnableImageTypes", value: "Primary"),
            .init(name: "ImageTypeLimit", value: "1"),
        ]
        return try await get(ItemsResponse.self, "/Artists/AlbumArtists?\(Self.encode(q))")
    }

    func albums(artistId: String) async throws -> [BaseItem] {
        var q = Query(types: "MusicAlbum", sortBy: "ProductionYear,SortName", limit: 300)
        q.albumArtistIds = [artistId]
        return try await items(q).items
    }

    func songs(artistId: String) async throws -> [BaseItem] {
        var q = Query(types: "Audio", sortBy: "AlbumArtist,SortName", limit: 1000)
        q.artistIds = [artistId]
        return try await items(q).items
    }

    func genres() async throws -> [BaseItem] {
        guard let account else { throw APIError.notConfigured }
        let q: [URLQueryItem] = [
            .init(name: "userId", value: account.userId),
            .init(name: "SortBy", value: "SortName"),
            .init(name: "SortOrder", value: "Ascending"),
            .init(name: "Limit", value: "300"),
            .init(name: "EnableImageTypes", value: "Primary"),
            .init(name: "ImageTypeLimit", value: "1"),
        ]
        return try await get(ItemsResponse.self, "/MusicGenres?\(Self.encode(q))").items
    }

    func songs(genreId: String, limit: Int = 200) async throws -> [BaseItem] {
        var q = Query(types: "Audio", sortBy: "Random", limit: limit)
        q.genreIds = [genreId]
        return try await items(q).items
    }

    func songs(startIndex: Int = 0, limit: Int = 200, searchTerm: String? = nil) async throws -> ItemsResponse {
        var q = Query(types: "Audio", startIndex: startIndex, limit: limit)
        q.searchTerm = searchTerm
        return try await items(q)
    }

    func randomSongs(limit: Int = 200) async throws -> [BaseItem] {
        try await items(Query(types: "Audio", sortBy: "Random", limit: limit)).items
    }

    func playlists() async throws -> [BaseItem] {
        // A playlist's media type is the server's guess from its first item —
        // "Unknown" on some, and on Jellyfin 12 not always set at all — so
        // only the ones that plainly aren't music are left out.
        try await items(Query(types: "Playlist", limit: 500)).items.filter { !["Video", "Photo", "Book"].contains($0.MediaType ?? "") }
    }

    /// A playlist's songs in its own order — the strict route first, the
    /// web client's fallback second; see the phone's `playlistItems`.
    func playlistItems(playlistId: String) async throws -> [BaseItem] {
        guard let account else { throw APIError.notConfigured }
        let q: [URLQueryItem] = [
            .init(name: "userId", value: account.userId),
            .init(name: "Fields", value: Self.listFields),
            .init(name: "EnableImageTypes", value: "Primary"),
            .init(name: "ImageTypeLimit", value: "1"),
        ]
        var failure: Error?
        do {
            let items = try await get(ItemsResponse.self, "/Playlists/\(Self.pathId(playlistId))/Items?\(Self.encode(q))").items
            if !items.isEmpty { return items }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError {
            if case .offline = error { throw error }
            failure = error
        }
        let byParent = q + [.init(name: "ParentId", value: playlistId)]
        do {
            return try await get(ItemsResponse.self, "/Items?\(Self.encode(byParent))").items
        } catch {
            throw failure ?? error
        }
    }

    func audiobooks(startIndex: Int = 0, limit: Int = 300, sortBy: String = "SortName", descending: Bool = false, searchTerm: String? = nil) async throws -> ItemsResponse {
        var q = Query(types: "AudioBook", sortBy: sortBy, descending: descending, startIndex: startIndex, limit: limit)
        q.searchTerm = searchTerm
        return try await items(q)
    }

    struct SearchResults: Sendable {
        var songs: [BaseItem] = []
        var albums: [BaseItem] = []
        var books: [BaseItem] = []
        var playlists: [BaseItem] = []
        var isEmpty: Bool { songs.isEmpty && albums.isEmpty && books.isEmpty && playlists.isEmpty }
    }

    func search(_ term: String, limit: Int = 12) async throws -> SearchResults {
        func query(_ types: String) -> Query {
            var q = Query(types: types, limit: limit)
            q.searchTerm = term
            return q
        }
        let songQ = query("Audio"), albumQ = query("MusicAlbum"), bookQ = query("AudioBook"), listQ = query("Playlist")
        async let songs = items(songQ)
        async let albums = items(albumQ)
        async let books = items(bookQ)
        async let lists = items(listQ)
        var out = SearchResults()
        out.songs = try await songs.items
        out.albums = (try? await albums.items) ?? []
        out.books = (try? await books.items) ?? []
        out.playlists = ((try? await lists.items) ?? []).filter { ($0.MediaType ?? "Audio") == "Audio" }
        return out
    }

    // MARK: - Pictures

    /// A song's cover is its album's; a book's and an album's is its own.
    func imageURL(for item: BaseItem, width: Int = 200) -> URL? {
        guard let account else { return nil }
        let w = Self.ladder(width)
        if let tag = item.ImageTags?["Primary"], !tag.isEmpty {
            return URL(string: "\(account.server)/Items/\(Self.pathId(item.Id))/Images/Primary?maxWidth=\(w)&tag=\(tag)&quality=85")
        }
        if let albumId = item.AlbumId, let tag = item.AlbumPrimaryImageTag, !tag.isEmpty {
            return URL(string: "\(account.server)/Items/\(Self.pathId(albumId))/Images/Primary?maxWidth=\(w)&tag=\(tag)&quality=85")
        }
        if let tag = item.PrimaryImageTag, !tag.isEmpty {
            return URL(string: "\(account.server)/Items/\(Self.pathId(item.Id))/Images/Primary?maxWidth=\(w)&tag=\(tag)&quality=85")
        }
        return nil
    }

    private nonisolated static func ladder(_ width: Int) -> Int {
        [120, 200, 320, 480].first { $0 >= width } ?? width
    }

    // MARK: - Playing

    /// A streaming profile a watch can honour: MP3, AAC and ALAC files as
    /// they are, everything else as an AAC transcode over HLS, and nothing
    /// above a sensible bitrate — a FLAC over a watch's radio is not a kind
    /// thing to ask of either.
    private struct Profile: Encodable {
        struct Direct: Encodable { let Container: String; let AudioCodec: String; let `Type` = "Audio" }
        struct Transcoding: Encodable {
            let Container: String; let AudioCodec: String; let `Type` = "Audio"
            let `Protocol`: String; let Context = "Streaming"; let MaxAudioChannels = "2"; let MinSegments = 1
        }
        let Name = "Aquarium Watch"
        let MaxStreamingBitrate: Int
        let MaxStaticBitrate = 320_000
        let MusicStreamingTranscodingBitrate: Int
        let DirectPlayProfiles: [Direct]
        let TranscodingProfiles: [Transcoding]
        let CodecProfiles: [String] = []
        let SubtitleProfiles: [String] = []
    }

    private struct PlaybackInfoBody: Encodable {
        let UserId: String
        let StartTimeTicks: Int64 = 0
        let IsPlayback = true
        let AutoOpenLiveStream = false
        let MaxStreamingBitrate: Int
        let DeviceProfile: Profile
        let EnableDirectPlay = true
        let EnableDirectStream = true
        let EnableTranscoding = true
    }

    nonisolated static let streamBitrate = 192_000

    func stream(for item: BaseItem) async throws -> WatchStream {
        guard let account else { throw APIError.notConfigured }
        let cap = 320_000
        let profile = Profile(
            MaxStreamingBitrate: cap,
            MusicStreamingTranscodingBitrate: Self.streamBitrate,
            DirectPlayProfiles: [
                .init(Container: "mp3", AudioCodec: "mp3"),
                .init(Container: "m4a,m4b,mp4,aac", AudioCodec: "aac,alac"),
            ],
            TranscodingProfiles: [
                .init(Container: "ts", AudioCodec: "aac", Protocol: "hls"),
            ]
        )
        let body = PlaybackInfoBody(UserId: account.userId, MaxStreamingBitrate: cap, DeviceProfile: profile)
        let data = try await request("/Items/\(Self.pathId(item.Id))/PlaybackInfo", method: "POST", body: body)
        let info = try await Self.decode(PlaybackInfoResponse.self, from: data)
        guard let ms = info.MediaSources?.first else { throw APIError.message("The server offered nothing to play") }
        let playSessionId = info.PlaySessionId ?? UUID().uuidString
        if let transcodingUrl = ms.TranscodingUrl, ms.SupportsDirectPlay != true, ms.SupportsDirectStream != true {
            guard transcodingUrl.hasPrefix("/"), let url = URL(string: account.server + transcodingUrl) else {
                throw APIError.message("The server returned a stream address this client couldn't read")
            }
            return WatchStream(url: authorized(url), headers: [:], isTranscode: true, mediaSourceId: ms.Id ?? "", playSessionId: playSessionId)
        }
        let container = ms.Container ?? "mp3"
        var q = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "mediaSourceId", value: ms.Id ?? ""),
            URLQueryItem(name: "playSessionId", value: playSessionId),
            URLQueryItem(name: "deviceId", value: deviceId),
        ]
        if let tag = ms.ETag { q.append(.init(name: "Tag", value: tag)) }
        guard let url = URL(string: "\(account.server)/Audio/\(Self.pathId(item.Id))/stream.\(container)?\(Self.encode(q))") else {
            throw APIError.message("Couldn't build a stream address")
        }
        return WatchStream(url: url, headers: authHeaders(), isTranscode: false, mediaSourceId: ms.Id ?? "", playSessionId: playSessionId)
    }

    func stopTranscode(playSessionId: String) async {
        let q = [URLQueryItem(name: "deviceId", value: deviceId), URLQueryItem(name: "playSessionId", value: playSessionId)]
        _ = try? await request("/Videos/ActiveEncodings?\(Self.encode(q))", method: "DELETE", countsForOffline: false)
    }

    // MARK: - Downloading

    /// The bitrate every watch download is made at. Fixed: a watch has a few
    /// gigabytes, and 128 kbps AAC is where a ten-hour book is half a
    /// gigabyte and an album sixty megabytes.
    nonisolated static let downloadBitrate = 128_000

    /// The request that fetches an item as one AAC file in an MP4 wrapper. A
    /// source already in AAC at or under the rate is rewrapped rather than
    /// re-encoded — the server decides. The token goes in a header, never
    /// the address.
    func downloadRequest(for item: BaseItem) -> (request: URLRequest, fileExtension: String)? {
        guard let account else { return nil }
        if let ext = WatchDownloadSource.originalExtension(for: item, encodedBytes: Self.estimatedBytes(for: item)) {
            let q = WatchDownloadSource.originalQuery(for: item, deviceId: deviceId)
            guard let url = URL(string: "\(account.server)/Audio/\(Self.pathId(item.Id))/stream.\(ext)?\(Self.encode(q))") else { return nil }
            var req = URLRequest(url: url)
            req.timeoutInterval = 120
            for (k, v) in authHeaders() { req.setValue(v, forHTTPHeaderField: k) }
            return (req, ext)
        }
        var q = [
            URLQueryItem(name: "static", value: "false"),
            URLQueryItem(name: "deviceId", value: deviceId),
            URLQueryItem(name: "Context", value: "Static"),
            URLQueryItem(name: "audioCodec", value: "aac"),
            URLQueryItem(name: "audioBitRate", value: String(Self.downloadBitrate)),
            URLQueryItem(name: "maxAudioChannels", value: "2"),
        ]
        if let id = item.MediaSources?.first?.Id { q.append(URLQueryItem(name: "mediaSourceId", value: id)) }
        guard let url = URL(string: "\(account.server)/Audio/\(Self.pathId(item.Id))/stream.m4a?\(Self.encode(q))") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 120
        for (k, v) in authHeaders() { req.setValue(v, forHTTPHeaderField: k) }
        return (req, "m4a")
    }

    /// About what a download will weigh, from its runtime.
    nonisolated static func estimatedBytes(for item: BaseItem) -> Int64 {
        let seconds = item.runtimeSeconds
        guard seconds > 0 else { return 0 }
        return Int64(seconds * Double(downloadBitrate) / 8 * 1.03)
    }

    // MARK: - Telling the server what was heard

    private struct StoppedReport: Encodable {
        let ItemId: String
        let PositionTicks: Int64
        let IsPaused = true
        let IsMuted = false
        let PlayMethod = "DirectStream"
        let CanSeek = true
        let MediaSourceId: String?
        let PlaySessionId: String?
    }

    /// A position, as a stopped report — the one way the server records a
    /// resume point. Throws so the caller knows whether it landed.
    func reportStopped(itemId: String, positionTicks: Int64, mediaSourceId: String? = nil, playSessionId: String? = nil) async throws {
        try await request(
            "/Sessions/Playing/Stopped", method: "POST",
            body: StoppedReport(ItemId: itemId, PositionTicks: positionTicks, MediaSourceId: mediaSourceId, PlaySessionId: playSessionId)
        )
    }

    private struct ProgressReport: Encodable {
        let ItemId: String
        let PositionTicks: Int64
        let IsPaused: Bool
        let IsMuted = false
        let PlayMethod: String
        let CanSeek = true
        let MediaSourceId: String?
        let PlaySessionId: String?
        let PlaybackRate: Double
    }

    /// The live session's start and progress, so the server's dashboard shows
    /// the watch playing and the transcode is kept alive. Best effort.
    func reportPlaying(started: Bool, itemId: String, positionTicks: Int64, paused: Bool, stream: WatchStream?, rate: Double) async {
        let body = ProgressReport(
            ItemId: itemId, PositionTicks: positionTicks, IsPaused: paused,
            PlayMethod: stream?.isTranscode == true ? "Transcode" : "DirectStream",
            MediaSourceId: stream?.mediaSourceId, PlaySessionId: stream?.playSessionId, PlaybackRate: rate
        )
        _ = try? await request(started ? "/Sessions/Playing" : "/Sessions/Playing/Progress", method: "POST", body: body, countsForOffline: false)
    }

    /// A play, counted: the played-items route with a date makes the server
    /// add one to the count and set "last played" to then.
    func markPlayed(itemId: String, at date: Date) async throws {
        guard let account else { throw APIError.notConfigured }
        let stamp = ISO8601DateFormatter().string(from: date)
        try await request("/Users/\(account.userId)/PlayedItems/\(Self.pathId(itemId))?datePlayed=\(stamp)", method: "POST")
    }

    func markUnplayed(itemId: String) async throws {
        guard let account else { throw APIError.notConfigured }
        try await request("/Users/\(account.userId)/PlayedItems/\(Self.pathId(itemId))", method: "DELETE")
    }

    /// Send one listening event straight to the server — what the phone does
    /// with the same event when it is the one in reach; see its `deliver`.
    ///
    /// A book's event is weighed against the server first: one heard before
    /// the book was last started anywhere else is dropped, since the newer
    /// listening wins. A position for a book the server has as finished is
    /// someone starting it again, and says so first — a stopped report
    /// leaves the tick where it is. A play the watch streamed was counted
    /// when the stream began, so it goes as a stopped report at its end.
    func send(_ event: WatchProgressEvent) async throws {
        var server: UserData?
        var runTimeTicks: Int64 = 0
        if event.isAudiobook {
            let item = try await items(ids: [event.itemId]).first
            server = item?.UserData
            runTimeTicks = item?.RunTimeTicks ?? 0
            if BookProgress.isStale(eventAt: event.at, serverLastPlayed: BookProgress.date(fromServer: server?.LastPlayedDate)) {
                WatchLog.note("client", "not sending \(event.itemId): played elsewhere since")
                return
            }
        }
        if event.played, !event.streamed {
            try await markPlayed(itemId: event.itemId, at: event.at)
        } else {
            if event.isAudiobook, !event.played, server?.played == true,
               !BookProgress.isFinished(positionTicks: event.positionTicks, runTimeTicks: runTimeTicks) {
                try await markUnplayed(itemId: event.itemId)
            }
            try await reportStopped(itemId: event.itemId, positionTicks: max(0, event.positionTicks))
        }
    }
}

// MARK: - Encoding shim

private struct AnyEncodable: Encodable {
    private let encodeTo: (Encoder) throws -> Void
    init(_ wrapped: any Encodable) { encodeTo = { try wrapped.encode(to: $0) } }
    func encode(to encoder: Encoder) throws { try encodeTo(encoder) }
}

// MARK: - Keychain

/// The token, in this watch's keychain and nowhere else: not synchronised
/// (the phone is where sign-ins live) and not in a backup.
enum WatchKeychain {
    private static let service = "FellyJin.watch"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func store(token: String, account: String) {
        var q = query(account)
        SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func token(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
