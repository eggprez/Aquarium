//  What the core-logic unit tests share: a web server on this machine's own
//  loopback address, a stub for `JellyfinClient` that answers by query as well
//  as by path, a signed-in account no other test has used, and small builders
//  for Jellyfin items and pictures.
//
//  Why a loopback server: `StreamResolver`, `StreamDiagnosis`, `IPTVSource`,
//  `ArtworkProbe` and `ImageLoader` each make a `URLSession` of their own, so
//  the `URLProtocol` seam `JellyfinClient` has does not reach them. A listener
//  on 127.0.0.1 answers them over real HTTP (redirects, HEAD, Range and all)
//  without the network: nothing here leaves the machine.

import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers
import XCTest
@testable import Aquarium

// MARK: - Loopback HTTP server

final class LoopbackServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        /// Path and query, as written on the request line.
        var target: String
        var headers: [String: String]

        var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }
        var query: String? {
            let parts = target.split(separator: "?", maxSplits: 1)
            return parts.count == 2 ? String(parts[1]) : nil
        }
    }

    struct Response: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// False leaves `Content-Length` out, so the body ends when the
        /// connection closes and the client can't know its size beforehand.
        var sendsLength = true

        static func text(_ text: String, type: String = "text/plain", status: Int = 200) -> Response {
            Response(status: status, headers: ["Content-Type": type], body: Data(text.utf8))
        }

        static func data(_ data: Data, type: String, status: Int = 200) -> Response {
            Response(status: status, headers: ["Content-Type": type], body: data)
        }

        static func redirect(to location: String, status: Int = 302) -> Response {
            Response(status: status, headers: ["Location": location])
        }

        static func status(_ status: Int) -> Response { Response(status: status) }
    }

    typealias Handler = @Sendable (Request) -> Response

    let port: UInt16
    var base: String { "http://127.0.0.1:\(port)" }
    func url(_ target: String) -> URL { URL(string: base + target)! }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "aquarium.tests.loopback")
    private let lock = NSLock()
    private var handler: Handler
    private var seen: [Request] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Every request received so far, in order.
    var requests: [Request] { lock.withLock { seen } }
    func requests(to path: String) -> [Request] { requests.filter { $0.path == path } }

    /// Swap what the server answers with, mid-test.
    func setHandler(_ handler: @escaping Handler) { lock.withLock { self.handler = handler } }

    init(_ handler: @escaping Handler = { _ in .status(404) }) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        // `self` is not yet whole, so the accept handler goes through a box.
        let box = Box()
        listener.newConnectionHandler = { connection in box.server?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue, port != 0 else {
            listener.cancel()
            throw XCTSkip("the loopback test server could not start")
        }
        self.port = port
        box.server = self
    }

    private final class Box: @unchecked Sendable { weak var server: LoopbackServer? }

    func stop() {
        listener.cancel()
        let open = lock.withLock { () -> [NWConnection] in
            defer { connections = [:] }
            return Array(connections.values)
        }
        for connection in open { connection.cancel() }
    }

    deinit { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections[ObjectIdentifier(connection)] = connection }
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        lock.withLock { connections[ObjectIdentifier(connection)] = nil }
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.answer(connection, head: buffer[buffer.startIndex..<end.lowerBound])
            } else if isComplete || error != nil || buffer.count > 1 << 20 {
                self.close(connection)
            } else {
                self.read(connection, buffer: buffer)
            }
        }
    }

    private func answer(_ connection: NWConnection, head: Data) {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count >= 2 else { return close(connection) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let request = Request(method: String(first[0]), target: String(first[1]), headers: headers)
        let handler = lock.withLock { () -> Handler in
            seen.append(request)
            return self.handler
        }
        let response = handler(request)

        var text = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Status")\r\n"
        var out = response.headers
        out["Connection"] = "close"
        // Never from a cache: a test changes what an address answers.
        if out["Cache-Control"] == nil { out["Cache-Control"] = "no-store" }
        if response.sendsLength { out["Content-Length"] = String(response.body.count) }
        for (name, value) in out.sorted(by: { $0.key < $1.key }) { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        var bytes = Data(text.utf8)
        if request.method != "HEAD" { bytes.append(response.body) }
        connection.send(content: bytes, completion: .contentProcessed { [weak self] _ in
            self?.close(connection)
        })
    }
}

// MARK: - JellyfinClient, answered by a closure

/// `StubURLProtocol` matches by path alone, and the library copy asks `/Items`
/// four different questions. This one hands the whole request to a closure.
/// While no closure is set it declines every request, so the plain stub (or
/// nothing) answers as before.
final class RoutedStub: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (status: Int, body: Data)?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static var requests: [URLRequest] { lock.withLock { recorded } }

    static func route(_ handler: Handler?) {
        lock.withLock {
            self.handler = handler
            recorded = []
        }
    }

    /// The value of one query item of a recorded or incoming request.
    static func query(_ request: URLRequest, _ name: String) -> String? {
        guard let url = request.url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    /// While true, every request the client makes fails as an unreachable
    /// host does. Every one, not only the probe: the app the tests are hosted
    /// in is running, and any answer to any of its own requests would tell the
    /// client the server is back.
    static var unreachable: Bool {
        get { lock.withLock { isUnreachable } }
        set { lock.withLock { isUnreachable = newValue } }
    }
    nonisolated(unsafe) private static var isUnreachable = false

    /// The connectivity probe is otherwise left to `StubURLProtocol`.
    override class func canInit(with request: URLRequest) -> Bool {
        lock.withLock {
            if isUnreachable { return true }
            guard request.url?.path != "/System/Info/Public" else { return false }
            return handler != nil
        }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (handler, down) = Self.lock.withLock { () -> (Handler?, Bool) in
            if !Self.isUnreachable { Self.recorded.append(request) }
            return (Self.handler, Self.isUnreachable)
        }
        if down {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let answer = handler?(request) ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - An account of the test's own

/// `ClientStub`, signed in as a user no other test has been. The library copy
/// is kept per account and deleted in the background, so a test that shared a
/// user id with the one before it could read that test's copy off the disk.
@MainActor
enum CoreAccount {
    private static var current: (server: String, userId: String)?

    /// `server` is where artwork addresses point; requests through the client
    /// are answered by the stubs whatever it is.
    @discardableResult
    static func signIn(server address: String? = nil) -> String {
        let server = address ?? ClientStub.server
        ClientStub.install()
        let userId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let prefs = JellyfinClient.shared.prefs
        _ = Keychain.store(token: ClientStub.token, server: server, userId: userId)
        prefs.session = SavedSession(server: server, userId: userId, userName: "core",
                                     deviceId: prefs.deviceId, serverId: nil)
        JellyfinClient.testProtocolClasses = [RoutedStub.self, StubURLProtocol.self]
        JellyfinClient.shared.resetConnections()
        current = (server, userId)
        return userId
    }

    /// Leaves the client believing the server is there, as it found it: the
    /// offline flag outlives a sign-out, and the next test may not expect it.
    static func signOut() async {
        await goOnline()
        signOutNow()
    }

    private static func signOutNow() {
        if let current { Keychain.delete(server: current.server, userId: current.userId) }
        current = nil
        RoutedStub.route(nil)
        RoutedStub.unreachable = false
        ClientStub.remove()
    }

    /// Put the client's "is the server there" back to yes, whatever a test did.
    static func goOnline() async {
        RoutedStub.unreachable = false
        StubURLProtocol.stub("/System/Info/Public", json: #"{"Id":"stub-server","ServerName":"Stub","Version":"10.11.0"}"#)
        guard JellyfinClient.shared.isSignedIn else { return }
        _ = await JellyfinClient.shared.checkOnline()
        JellyfinClient.shared.endRecheck()
        _ = await CoreWait.until { !JellyfinClient.shared.showsOffline }
    }

    /// Take the server away: every request fails until `goOnline`.
    static func goOffline() async {
        RoutedStub.unreachable = true
        _ = await JellyfinClient.shared.checkOnline()
        // The verdict is held back seven seconds for a stray failure; this is
        // what the launch probe calls to bring it forward.
        JellyfinClient.shared.confirmOffline()
        // What the shell shows trails the fact while a probe the hosting app
        // started is still out. This probe has answered: the wait is over.
        JellyfinClient.shared.endRecheck()
        _ = await CoreWait.until { JellyfinClient.shared.showsOffline }
    }
}

// MARK: - The library copy

@MainActor
enum CoreLibrary {
    /// `LibraryIndex.wipe()` deletes its folder, and tells the image loader,
    /// from a background task it does not wait for. Left running, that lands
    /// in whichever test comes next and takes its saved artwork with it.
    /// Turn the copy on and sync it against a server holding one library with
    /// these items in it. Leaves nothing routed afterwards.
    static func fill(_ items: [BaseItem], library: BaseItem) async {
        Preferences.shared.keepsLibraryCopy = true
        let views = CoreItem.json([library])
        let all = CoreItem.json(items)
        let none = CoreItem.json([])
        let libraryId = library.Id
        RoutedStub.route { request in
            switch request.url?.path {
            case "/UserViews": (200, views)
            case "/Items":
                RoutedStub.query(request, "ParentId") == libraryId && RoutedStub.query(request, "StartIndex") == "0"
                    ? (200, all) : (200, none)
            default: nil
            }
        }
        await LibraryIndex.shared.sync(force: true)
        RoutedStub.route(nil)
    }

    /// The app the tests are hosted in is running, and loads the libraries of
    /// whichever stubbed account it last saw. The Siri lookups prefer that
    /// list to asking the server, so a test of the asking has the app load an
    /// empty one first, the way it does on a server with no libraries.
    static func forgetAppLibraries() async {
        StubURLProtocol.stub("/UserViews", json: #"{"Items":[],"TotalRecordCount":0}"#)
        await AppModel.shared.loadLibraries()
    }

    /// Wipe the copy and switch the setting back off.
    static func empty() async {
        await wipeAndSettle()
        Preferences.shared.keepsLibraryCopy = false
        await ImageLoader.shared.setDiskEnabled(false)
    }

    static func wipeAndSettle() async {
        LibraryIndex.shared.wipe()
        _ = await CoreWait.until(1) { !FileManager.default.fileExists(atPath: LibraryIndex.directory.path) }
        try? await Task.sleep(for: .milliseconds(50))
        _ = await ImageLoader.shared.diskUsage()
    }
}

// MARK: - Items

enum CoreItem {
    static func make(_ id: String, _ type: String, name: String? = nil, _ edit: (inout BaseItem) -> Void = { _ in }) -> BaseItem {
        var item = BaseItem()
        item.Id = id
        item.type = type
        item.Name = name ?? id
        edit(&item)
        return item
    }

    static func movie(_ id: String, name: String? = nil, _ edit: (inout BaseItem) -> Void = { _ in }) -> BaseItem {
        make(id, "Movie", name: name, edit)
    }

    static func series(_ id: String, name: String? = nil, _ edit: (inout BaseItem) -> Void = { _ in }) -> BaseItem {
        make(id, "Series", name: name, edit)
    }

    static func season(_ id: String, series: String, number: Int?, name: String? = nil) -> BaseItem {
        make(id, "Season", name: name ?? "Season \(number ?? 0)") {
            $0.SeriesId = series
            $0.IndexNumber = number
        }
    }

    static func episode(_ id: String, series: String, season: String?, s: Int?, e: Int?, name: String? = nil,
                        seriesName: String = "Show", _ edit: (inout BaseItem) -> Void = { _ in }) -> BaseItem {
        make(id, "Episode", name: name ?? "Episode \(e ?? 0)") {
            $0.SeriesId = series
            $0.SeriesName = seriesName
            $0.SeasonId = season
            $0.ParentIndexNumber = s
            $0.IndexNumber = e
            edit(&$0)
        }
    }

    static func library(_ id: String, name: String, type: String?) -> BaseItem {
        make(id, "CollectionFolder", name: name) { $0.CollectionType = type }
    }

    static func userData(played: Bool? = nil, favorite: Bool? = nil, position: Int64? = nil, unplayed: Int? = nil) -> UserData {
        var data = UserData()
        data.Played = played
        data.IsFavorite = favorite
        data.PlaybackPositionTicks = position
        data.UnplayedItemCount = unplayed
        return data
    }

    static func json(_ items: [BaseItem], total: Int? = nil) -> Data {
        (try? JSONEncoder().encode(ItemsResponse(Items: items, TotalRecordCount: total ?? items.count))) ?? Data()
    }
}

// MARK: - Pictures

enum CorePicture {
    /// A real PNG of one flat colour, `width` by `height` pixels.
    static func png(width: Int, height: Int) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    /// The longest side of a decoded picture, in pixels.
    static func longestSide(_ image: PlatformImage) -> Int {
        #if canImport(UIKit)
        return Int(max(image.size.width, image.size.height) * image.scale)
        #else
        return Int(max(image.size.width, image.size.height))
        #endif
    }
}

// MARK: - Waiting

enum CoreWait {
    /// Poll for something another task is about to make true. Returns whether
    /// it became true within `timeout` seconds.
    @MainActor
    static func until(_ timeout: TimeInterval = 5, _ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }
}
