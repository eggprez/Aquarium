//  What the watch's unit tests share: a base case that puts every singleton
//  back to nothing, a stub network that can tell queries apart, and items
//  made to order.
//
//  The unit plan (TestPlans/WatchUnit.xctestplan) launches the watch app in
//  test mode, so the state touched here is test mode's own (a defaults
//  suite, an `AquariumUITest` folder) and never a real sign-in. Everything
//  here uses the DEBUG-only seams in Watch/*.swift (`testReset`,
//  `testOutbox`, `testSetPhone`, `testSetNetwork`, `testHoldsOwnTransfers`).
//
//  The watch's own transfers are held for every test: a background
//  URLSession can't be stubbed, and nothing here should reach a server.

import AVFoundation
import Foundation
import XCTest
@testable import AquariumWatch

// MARK: - Items made to order

enum WX {
    static let server = "http://stub.invalid"
    static let userId = "0123456789abcdef0123456789abcdef"
    static let token = "stub-token"
    static let accountKey = "\(server)|\(userId)"

    static var credentials: WatchCredentials {
        WatchCredentials(server: server, userId: userId, userName: "stub", serverId: "stub-server", token: token)
    }

    static func ticks(_ seconds: Double) -> Int64 { Int64(seconds * 10_000_000) }

    static func song(_ id: String, name: String? = nil, albumId: String? = "album-1", album: String? = "Album One",
                     artist: String = "FX Band", track: Int? = nil, disc: Int? = nil, seconds: Double = 30,
                     position: Double = 0, played: Bool = false, imageTag: String? = nil) -> BaseItem {
        var item = BaseItem()
        item.Id = id
        item.Name = name ?? "Song \(id)"
        item.type = "Audio"
        item.MediaType = "Audio"
        item.AlbumId = albumId
        item.Album = album
        item.Artists = [artist]
        item.AlbumArtist = artist
        item.IndexNumber = track
        item.ParentIndexNumber = disc
        item.RunTimeTicks = ticks(seconds)
        item.UserData = UserData(PlaybackPositionTicks: ticks(position), Played: played)
        if let imageTag { item.ImageTags = ["Primary": imageTag] }
        return item
    }

    static func book(_ id: String, name: String? = nil, author: String = "FX Author", seconds: Double = 900,
                     position: Double = 0, played: Bool = false, lastPlayed: String? = nil,
                     chapters: [Double] = []) -> BaseItem {
        var item = BaseItem()
        item.Id = id
        item.Name = name ?? "Book \(id)"
        item.type = "AudioBook"
        item.MediaType = "Audio"
        item.Album = item.Name
        item.Artists = [author]
        item.RunTimeTicks = ticks(seconds)
        item.UserData = UserData(PlaybackPositionTicks: ticks(position), Played: played, LastPlayedDate: lastPlayed)
        if !chapters.isEmpty {
            item.Chapters = chapters.enumerated().map { ChapterInfo(Name: "Chapter \($0.offset + 1)", StartPositionTicks: ticks($0.element)) }
        }
        return item
    }

    static func collection(_ id: String, type: String, name: String? = nil, artist: String? = nil) -> BaseItem {
        var item = BaseItem()
        item.Id = id
        item.Name = name ?? "\(type) \(id)"
        item.type = type
        if type == "Playlist" { item.MediaType = "Audio" }
        if let artist { item.AlbumArtist = artist }
        return item
    }

    static func album(_ id: String, name: String? = nil) -> BaseItem { collection(id, type: "MusicAlbum", name: name, artist: "FX Band") }
    static func playlist(_ id: String, name: String? = nil) -> BaseItem { collection(id, type: "Playlist", name: name) }
    static func artist(_ id: String, name: String? = nil) -> BaseItem { collection(id, type: "MusicArtist", name: name) }
    static func genre(_ id: String, name: String? = nil) -> BaseItem { collection(id, type: "MusicGenre", name: name) }

    /// A server's `LastPlayedDate`, written the way Jellyfin writes it.
    static func serverDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date).replacingOccurrences(of: "Z", with: "0000Z")
    }

    static func itemsJSON(_ items: [BaseItem]) -> Data {
        (try? JSONEncoder().encode(ItemsResponse(Items: items, TotalRecordCount: items.count))) ?? Data()
    }

    static func itemJSON(_ item: BaseItem) -> Data { (try? JSONEncoder().encode(item)) ?? Data() }

    /// A real audio file of this length (silent 8 kHz mono WAV), in `folder`.
    static func audioFile(seconds: Double, in folder: URL, name: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name ?? "audio-\(UUID().uuidString).wav")
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8000.0, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = AVAudioFrameCount(seconds * 8000)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
                throw URLError(.cannotCreateFile)
            }
            buffer.frameLength = frames
            try file.write(from: buffer)
        }
        return url
    }
}

// MARK: - A network that answers by path and query

/// Like `StubURLProtocol`, but a route can also name query items it needs,
/// and it answers through the client's `testTransport` (every method) as
/// well as being a `URLProtocol` (GETs only on the watchOS 27 simulator),
/// so `/Items?ParentId=a` and `/Items?Ids=b` answer differently. The route
/// added last wins. Anything unrouted answers 404 and is still recorded.
final class WatchStub: URLProtocol {
    struct Route {
        var method: String?
        var path: String
        var query: [String: String]
        var status: Int
        var body: Data
        var error: URLError.Code?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [Route] = []
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    /// Every request so far, in order. The host app's home page asks for
    /// books in progress (`/UserItems/Resume`) whenever the sign-in changes;
    /// those are left out unless the test routed that path itself.
    static var requests: [URLRequest] {
        lock.withLock {
            let wantsResume = routes.contains { $0.path == "/UserItems/Resume" }
            return recorded.filter { wantsResume || $0.url?.path != "/UserItems/Resume" }
        }
    }

    static func reset() { lock.withLock { routes = []; recorded = [] } }

    static func on(_ path: String, method: String? = nil, query: [String: String] = [:], status: Int = 200, body: Data = Data()) {
        lock.withLock { routes.append(Route(method: method, path: path, query: query, status: status, body: body, error: nil)) }
    }

    static func on(_ path: String, method: String? = nil, query: [String: String] = [:], status: Int = 200, json: String) {
        on(path, method: method, query: query, status: status, body: Data(json.utf8))
    }

    static func on(_ path: String, method: String? = nil, query: [String: String] = [:], items: [BaseItem]) {
        on(path, method: method, query: query, body: WX.itemsJSON(items))
    }

    static func fail(_ path: String, method: String? = nil, _ code: URLError.Code = .cannotConnectToHost) {
        lock.withLock { routes.append(Route(method: method, path: path, query: [:], status: 0, body: Data(), error: code)) }
    }

    /// The query of a request, by name. Repeated names keep the last.
    static func query(_ request: URLRequest) -> [String: String] {
        let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
        var out: [String: String] = [:]
        for item in items { out[item.name] = item.value ?? "" }
        return out
    }

    /// The paths asked, in order (see `requests`).
    static var paths: [String?] { requests.map(\.url?.path) }

    static func requests(_ method: String? = nil, path: String) -> [URLRequest] {
        requests.filter { $0.url?.path == path && (method == nil || $0.httpMethod == method) }
    }

    static func body(_ request: URLRequest) -> [String: Any] {
        guard let data = request.httpBody else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// What the stub server says to a request, recorded as it arrives.
    private static func answer(to request: URLRequest) -> Result<(Int, Data), URLError> {
        var seen = request
        if seen.httpBody == nil, let stream = seen.httpBodyStream { seen.httpBody = read(stream) }
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        let query = query(request)
        let route: Route? = lock.withLock {
            recorded.append(seen)
            return routes.last { r in
                r.path == path && (r.method == nil || r.method == method)
                    && r.query.allSatisfy { query[$0.key] == $0.value }
            }
        }
        guard let route else { return .success((404, Data())) }
        if let code = route.error { return .failure(URLError(code)) }
        return .success((route.status, route.body))
    }

    /// The client's `testTransport`: every method, no network. (On the
    /// watchOS 27 simulator a session's protocol classes see GETs only.)
    static func transport(_ request: URLRequest) async throws -> (Data, URLResponse) {
        switch answer(to: request) {
        case .failure(let error): throw error
        case .success(let (status, body)):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            return (body, response)
        }
    }

    override func startLoading() {
        switch Self.answer(to: request) {
        case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
        case .success(let (status, body)):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

// MARK: - The base case

/// Every watch unit test starts from nothing: signed in to a stub server
/// (unless `signsIn` is false), no records, no plan, no queue, the phone
/// away and without the app, no network of the watch's own, and every
/// message that would go to the phone kept in `sent` instead.
@MainActor
class WatchUnitTestCase: XCTestCase {
    var client: JellyfinClient { .shared }
    var downloads: WatchDownloads { .shared }
    var link: WatchLink { .shared }
    var player: WatchPlayer { .shared }
    var sync: WatchSyncQueue { .shared }

    class var signsIn: Bool { true }

    override func setUp() async throws {
        try XCTSkipUnless(TestRuntime.isUITest, "run with TestPlans/WatchUnit.xctestplan (the host must be in test mode)")
        continueAfterFailure = true
        WatchStub.reset()
        StubURLProtocol.reset()
        client.useTestProtocols(nil)
        client.testTransport = WatchStub.transport
        player.testReset()
        downloads.testReset()
        downloads.testSetNetwork(up: false, wifi: false)
        downloads.testHoldsOwnTransfers = true
        link.testOutbox = []
        link.testEventReply = nil
        link.testSetPhone(reachable: false, companion: false)
        sync.testReset()
        WatchMode.shared.source = .watch
        if Self.signsIn { client.install(WX.credentials) } else { client.signOut() }
    }

    override func tearDown() async throws {
        // Let whatever the test set off finish against the stub first.
        await settle(0.2)
        player.testReset()
        downloads.testReset()
        sync.testReset()
        link.testOutbox = nil
        link.testEventReply = nil
        client.signOut()
        client.testTransport = nil
        client.useTestProtocols(nil)
        WatchStub.reset()
        StubURLProtocol.reset()
        WatchDownloads.testFreeBytes = nil
    }

    /// Give the main actor's queued tasks a moment.
    func settle(_ seconds: Double = 0.3) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Wait (on the main actor) until `condition` holds, or `timeout` passes.
    @discardableResult
    func eventually(_ timeout: Double = 5, _ condition: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// The messages that would have gone to the phone, as short strings:
    /// `fetch:a`, `fetchMany:a,b`, `cancelFetch:a`, `wantRemoved:album:x`,
    /// `playlistRemoved:p`.
    var sent: [String] { (link.testOutbox ?? []).map(Self.describe) }

    nonisolated static func describe(_ m: WatchMessage) -> String {
        switch m {
        case .fetch(let id): "fetch:\(id)"
        case .fetchMany(let ids): "fetchMany:\(ids.joined(separator: ","))"
        case .cancelFetch(let id): "cancelFetch:\(id)"
        case .wantRemoved(let key): "wantRemoved:\(key)"
        case .playlistRemoved(let id): "playlistRemoved:\(id)"
        case .progress(let events): "progress:\(events.count)"
        case .requestContext: "requestContext"
        case .requestPlayback: "requestPlayback"
        case .remote(let c): "remote:\(c)"
        case .logs: "logs"
        case .deleteGroup(let kind, let id): "deleteGroup:\(kind.rawValue):\(id)"
        case .deleteAll: "deleteAll"
        case .download(let r): "download:\(r.key)"
        case .requestInventory: "requestInventory"
        case .requestLogs: "requestLogs"
        case .fetchProgress(let id, let f): "fetchProgress:\(id):\(f)"
        case .fetchFailed(let id, _): "fetchFailed:\(id)"
        case .deleteWant(let r): "deleteWant:\(r.key)"
        case .cancelled(let id): "cancelled:\(id)"
        case .phonePlayback(let s): "phonePlayback:\(s?.itemId ?? "nil")"
        }
    }

    /// Every item asked of the phone so far, one id each, in order.
    var askedOfPhone: [String] {
        (link.testOutbox ?? []).flatMap { m -> [String] in
            switch m {
            case .fetch(let id): [id]
            case .fetchMany(let ids): ids
            default: []
            }
        }
    }

    func status(_ id: String) -> WatchRecord.Status? { downloads.record(for: id)?.status }
}
