//  What the music unit tests share: songs and books built in code, a stubbed
//  server that reads the query (the shared `StubURLProtocol` matches by path
//  alone, and every music list is `/Items`), and downloads put on the device
//  without a transfer.
//
//  The Apple TV has no music UI and no downloads, so none of the music tests
//  are built for it.

#if !os(tvOS)
import Foundation
import XCTest
@testable import Aquarium

// MARK: - Items

enum MusicFixture {
    /// A song as the server lists one.
    static func song(
        _ id: String, _ name: String? = nil, artist: String? = "Artist", artistId: String? = nil,
        album: String? = nil, albumId: String? = nil, genres: [String]? = nil, year: Int? = nil,
        plays: Int? = nil, favorite: Bool? = nil, lastPlayed: String? = nil, added: String? = nil,
        track: Int? = nil, disc: Int? = nil, seconds: Double = 200
    ) -> BaseItem {
        var item = BaseItem()
        item.Id = id
        item.Name = name ?? "Song \(id)"
        item.type = "Audio"
        item.MediaType = "Audio"
        item.AlbumArtist = artist
        if let artist {
            item.Artists = [artist]
            let pair = NameGuidPair(Id: artistId, Name: artist)
            item.ArtistItems = [pair]
            item.AlbumArtists = [pair]
        }
        item.Album = album
        item.AlbumId = albumId
        item.Genres = genres
        item.ProductionYear = year
        item.IndexNumber = track
        item.ParentIndexNumber = disc
        item.RunTimeTicks = Int64(seconds * 10_000_000)
        item.DateCreated = added
        if plays != nil || favorite != nil || lastPlayed != nil {
            var data = UserData()
            data.PlayCount = plays
            data.IsFavorite = favorite
            data.Played = (plays ?? 0) > 0
            data.LastPlayedDate = lastPlayed
            item.UserData = data
        }
        return item
    }

    static func songs(_ ids: [String]) -> [BaseItem] { ids.map { song($0) } }

    /// An audiobook of `seconds`, with chapters starting at these seconds.
    static func book(
        _ id: String, _ name: String = "Book", author: String? = "Author", seconds: Double = 3600,
        chapters: [Double]? = nil, positionSeconds: Double? = nil
    ) -> BaseItem {
        var item = BaseItem()
        item.Id = id
        item.Name = name
        item.type = "AudioBook"
        item.MediaType = "Audio"
        item.AlbumArtist = author
        if let author { item.Artists = [author] }
        item.RunTimeTicks = Int64(seconds * 10_000_000)
        item.Chapters = chapters.map { starts in
            starts.enumerated().map { ChapterInfo(Name: "Chapter \($0.offset + 1)", StartPositionTicks: Int64($0.element * 10_000_000)) }
        }
        if let positionSeconds {
            var data = UserData()
            data.PlaybackPositionTicks = Int64(positionSeconds * 10_000_000)
            item.UserData = data
        }
        return item
    }

    static func item(_ id: String, _ name: String, type: String) -> BaseItem {
        var item = BaseItem()
        item.Id = id
        item.Name = name
        item.type = type
        return item
    }

    static func artist(_ id: String, _ name: String) -> BaseItem { item(id, name, type: "MusicArtist") }
    static func album(_ id: String, _ name: String, year: Int? = nil) -> BaseItem {
        var album = item(id, name, type: "MusicAlbum")
        album.ProductionYear = year
        return album
    }
    static func genre(_ id: String, _ name: String) -> BaseItem { item(id, name, type: "MusicGenre") }
    static func playlist(_ id: String, _ name: String, count: Int? = nil) -> BaseItem {
        var list = item(id, name, type: "Playlist")
        list.MediaType = "Audio"
        list.ChildCount = count
        list.RecursiveItemCount = count
        return list
    }

    /// `{"Items":[…]}`, as every list route answers.
    static func list(_ items: [BaseItem]) -> Data {
        (try? JSONEncoder().encode(ItemsResponse(Items: items, TotalRecordCount: items.count))) ?? Data()
    }

    static func one(_ item: BaseItem) -> Data { (try? JSONEncoder().encode(item)) ?? Data() }

    /// An ISO date `days` ago, as the server writes one.
    static func daysAgo(_ days: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date().addingTimeInterval(-days * 86_400))
    }
}

// MARK: - The server

/// A server that answers from a closure, so a test can tell `/Items?Ids=`
/// from `/Items?IncludeItemTypes=Playlist`. Anything the closure passes on is
/// a 404, as with `StubURLProtocol`.
final class MusicServer: URLProtocol {
    struct Call {
        var method: String
        var path: String
        var query: [String: String]
        var body: [String: Any]?
    }
    struct Answer {
        var status = 200
        var body = Data()
        var error: URLError.Code?
        static func json(_ text: String) -> Answer { Answer(body: Data(text.utf8)) }
        static func items(_ items: [BaseItem]) -> Answer { Answer(body: MusicFixture.list(items)) }
        static func item(_ item: BaseItem) -> Answer { Answer(body: MusicFixture.one(item)) }
        static func status(_ code: Int) -> Answer { Answer(status: code) }
        static let ok = Answer(status: 204)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responder: (@Sendable (Call) -> Answer?)?
    nonisolated(unsafe) private static var seen: [Call] = []

    static var calls: [Call] { lock.lock(); defer { lock.unlock() }; return seen }
    static func calls(to path: String, method: String? = nil) -> [Call] {
        calls.filter { $0.path == path && (method == nil || $0.method == method) }
    }

    static func answer(_ responder: @escaping @Sendable (Call) -> Answer?) {
        lock.lock(); defer { lock.unlock() }
        self.responder = responder
    }

    /// Sign the made-up account in and put this class in front of the network.
    @MainActor
    static func install() {
        ClientStub.install()
        lock.lock()
        responder = nil
        heldResponder = nil
        isCut = false
        seen = []
        lock.unlock()
        JellyfinClient.testProtocolClasses = [MusicServer.self]
        JellyfinClient.shared.resetConnections()
    }

    /// Makes the client say there is no server, or that there is one again.
    /// Offline, every request fails as a server that isn't there fails: one
    /// answered request of any kind is enough for the client to call itself
    /// online again, and the app makes requests of its own.
    /// False when the client would not be moved (the app is in the background).
    @MainActor
    static func setOffline(_ offline: Bool) async -> Bool {
        let client = JellyfinClient.shared
        lock.lock()
        if offline, !isCut {
            heldResponder = responder
            responder = { _ in Answer(error: .cannotConnectToHost) }
            isCut = true
        } else if !offline, isCut {
            responder = heldResponder
            heldResponder = nil
            isCut = false
        }
        lock.unlock()
        _ = await client.checkOnline()
        if offline { client.confirmOffline() }
        return client.isOffline == offline
    }

    nonisolated(unsafe) private static var heldResponder: (@Sendable (Call) -> Answer?)?
    nonisolated(unsafe) private static var isCut = false

    @MainActor
    static func remove() {
        ClientStub.remove()
        lock.lock()
        responder = nil
        heldResponder = nil
        isCut = false
        seen = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var read = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                read.append(buffer, count: n)
            }
            stream.close()
            data = read
        }
        var query: [String: String] = [:]
        if let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for q in parts.queryItems ?? [] { query[q.name] = q.value ?? "" }
        }
        let call = Call(
            method: request.httpMethod ?? "GET", path: request.url?.path ?? "", query: query,
            body: data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        )
        Self.lock.lock()
        Self.seen.append(call)
        let responder = Self.responder
        Self.lock.unlock()
        // The online probe is answered unless a test says otherwise, so a
        // probe the app makes by itself mid-test doesn't read as no server.
        let answer = responder?(call)
            ?? (call.path == "/System/Info/Public" ? .json(#"{"Id":"stub-server","ServerName":"Stub"}"#) : Answer(status: 404))
        if let code = answer.error {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - A music library on the stubbed server

/// What the server has, by the question it is asked: enough of a library
/// for the station builder and the mixes to be answered from.
struct MusicLibraryStub: Sendable {
    /// `/Items/{id}/InstantMix`, by id.
    var mixes: [String: [BaseItem]] = [:]
    /// `/Items/{id}/Similar`, by artist id.
    var similar: [String: [BaseItem]] = [:]
    /// Songs by `ArtistIds`, as sent ("a,b").
    var byArtists: [String: [BaseItem]] = [:]
    /// The same question with "never played" on it.
    var unplayedByArtists: [String: [BaseItem]] = [:]
    /// Songs by `GenreIds`, as sent.
    var byGenreIds: [String: [BaseItem]] = [:]
    /// Songs by `Genres` (names), as sent.
    var byGenreNames: [String: [BaseItem]] = [:]
    /// Songs by `ParentId`: an album's tracks.
    var byParent: [String: [BaseItem]] = [:]
    var favorites: [BaseItem] = []
    var mostPlayed: [BaseItem] = []
    var starredArtists: [BaseItem] = []
    /// Any songs at all, for Shuffle All.
    var anySongs: [BaseItem] = []

    /// The genres every test's server has. The app reads them once and keeps
    /// them for an hour, so they are the same whichever test asks first.
    static let genres: [BaseItem] = [
        MusicFixture.genre("g-rock", "Rock"), MusicFixture.genre("g-rockmusik", "Rockmusik"),
        MusicFixture.genre("g-pop", "Pop"), MusicFixture.genre("g-jazz", "Jazz"),
    ]

    func install() {
        let lib = self
        MusicServer.answer { call in lib.answer(call) }
    }

    func answer(_ call: MusicServer.Call) -> MusicServer.Answer? {
        guard call.method == "GET" else { return nil }
        let parts = call.path.split(separator: "/").map(String.init)
        if parts.count == 3, parts[0] == "Items", parts[2] == "InstantMix" {
            return mixes[parts[1]].map { .items($0) }
        }
        if parts.count == 3, parts[0] == "Items", parts[2] == "Similar" {
            return similar[parts[1]].map { .items($0) }
        }
        if call.path == "/MusicGenres" { return .items(Self.genres) }
        if call.path == "/Artists/AlbumArtists" { return .items(starredArtists) }
        guard call.path == "/Items", call.query["IncludeItemTypes"] == "Audio" else { return nil }
        let q = call.query
        let filters = q["Filters"] ?? ""
        if let ids = q["GenreIds"] { return .items(byGenreIds[ids] ?? []) }
        if let names = q["Genres"] { return .items(byGenreNames[names] ?? []) }
        if let parent = q["ParentId"] { return .items(byParent[parent] ?? []) }
        if let artists = q["ArtistIds"] {
            return .items((filters.contains("IsUnplayed") ? unplayedByArtists[artists] : byArtists[artists]) ?? [])
        }
        if filters == "IsFavorite" { return .items(favorites) }
        if filters == "IsPlayed", (q["SortBy"] ?? "").hasPrefix("PlayCount") { return .items(mostPlayed) }
        return .items(anySongs)
    }
}

// MARK: - Downloads on the device

/// Finished downloads without a transfer: a record through the manager's
/// test door, and a file of silence where the record says its file is.
@MainActor
enum MusicOnDevice {
    private static var installed: [String] = []

    @discardableResult
    static func add(
        _ item: BaseItem, created: Date = Date(), played: Bool = false, positionSeconds: Double = 0,
        fileSeconds: Double = 120, status: DownloadRecord.Status = .complete
    ) -> DownloadRecord {
        var record = DownloadRecord(itemId: item.Id, title: item.title, name: item.title)
        record.type = item.type
        record.runTimeTicks = item.RunTimeTicks ?? 0
        record.year = item.ProductionYear
        record.album = item.Album
        record.albumId = item.AlbumId
        record.artist = item.AlbumArtist
        record.track = item.IndexNumber
        record.disc = item.ParentIndexNumber
        record.fileName = "audio.wav"
        record.status = status
        record.createdAt = created
        record.played = played
        record.positionTicks = Int64(positionSeconds * 10_000_000)
        record.ownerUserId = ClientStub.userId
        let file = DownloadManager.folder(for: item.Id).appendingPathComponent(record.fileName)
        try? silence(seconds: fileSeconds).write(to: file)
        DownloadManager.shared.installForTesting(record)
        installed.append(item.Id)
        return record
    }

    static func add(_ items: [BaseItem]) { for item in items { add(item) } }

    /// Take away everything `add` put there.
    static func removeAll() {
        for id in installed { DownloadManager.shared.delete(id) }
        installed = []
    }

    /// Take the downloads away and have the index forget what it was told
    /// about them and about the server's playlists, so the next test starts
    /// from nothing. Needs `MusicServer` still installed: forgetting is the
    /// index's own refresh, against a server with no playlists.
    static func forgetEverything() async {
        removeAll()
        MusicServer.answer { call in
            if call.path.hasPrefix("/UserFavoriteItems/") { return .ok }
            if call.path == "/Items", call.query["IncludeItemTypes"] == "Playlist" { return .items([]) }
            return nil
        }
        await OfflineMusicIndex.shared.refresh(force: true)
    }

    /// A WAV of nothing: 8-bit mono, 8 kHz.
    static func silence(seconds: Double) -> Data {
        let rate: UInt32 = 8000
        let count = UInt32(Double(rate) * seconds)
        var data = Data()
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + count))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); le(UInt32(16)); le(UInt16(1)); le(UInt16(1))
        le(rate); le(rate); le(UInt16(1)); le(UInt16(8))
        data.append(contentsOf: Array("data".utf8)); le(count)
        data.append(Data(repeating: 0x80, count: Int(count)))
        return data
    }
}

// MARK: - Waiting for the main actor's own tasks

extension XCTestCase {
    /// Polls until `condition` holds, a hundredth of a second at a time. The
    /// ceiling is only how long a failure takes to be called one.
    @MainActor
    func eventually(
        _ what: String, within seconds: Double = 5, file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline {
                XCTFail("never happened: \(what)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Lets tasks already queued on the main actor run.
    @MainActor
    func settle(_ turns: Int = 5) async {
        for _ in 0..<turns { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }
}
#endif
