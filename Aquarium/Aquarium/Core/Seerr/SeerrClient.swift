//  The Seerr client: asking for films and shows the library doesn't have.
//
//  Seerr sits beside a Jellyfin server and takes requests for it. This is the
//  connection to it, held to the same rules as the one to Jellyfin
//  (`JellyfinClient`):
//
//  - No password is kept, and usually none is typed. The app is already
//    signed in to Jellyfin, so it signs in to Seerr with Quick Connect: Seerr
//    asks Jellyfin for a code, this device approves the code with its own
//    Jellyfin session, and Seerr answers with a session of its own. A typed
//    Jellyfin password is the fallback for a Seerr older than 3.4, and it is
//    sent once and forgotten.
//  - Seerr's administrator API key is never used. It is one key for the whole
//    server; a client holding it could approve, delete and reconfigure.
//  - What is kept is Seerr's session cookie, in the keychain beside the
//    Jellyfin token, one entry per Jellyfin account, under the same sync and
//    lock rules (it goes through `Keychain`).
//  - The cookie is put on requests by hand and only on requests to the Seerr
//    address it came from. The session keeps no cookie store, and a redirect
//    to anywhere else is not followed.
//  - https first, and a failed certificate is never retried over http.
//
//  Seerr's session runs out (thirty days) where Jellyfin's token does not, so
//  a refused request is followed by one quiet Quick Connect and one retry.

import Foundation
import Observation
import os

/// What went wrong, in words for whoever is holding the device.
enum SeerrError: LocalizedError, Sendable, Equatable {
    case notConnected
    case unreachable(String)
    /// The server has no Quick Connect to sign in with: an older Seerr, or
    /// Quick Connect turned off in Jellyfin. The password route still works.
    case quickConnectUnavailable
    /// The session ran out and could not be renewed without the user.
    case needsReconnect
    case refused(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Requests aren't set up"
        case .unreachable(let m): m
        case .quickConnectUnavailable: "This Seerr server can't sign in with Quick Connect. Use your Jellyfin user name and password instead."
        case .needsReconnect: "The connection to Seerr has run out. Reconnect in Settings."
        case .refused(let m): m
        case .message(let m): m
        }
    }
}

/// The Seerr server this Jellyfin account asks through, and the session on
/// it. The whole of it lives in the keychain: see `SeerrClient.store`.
struct SeerrConnection: Codable, Hashable, Sendable {
    /// Scheme, host and any base path; no trailing slash.
    var server: String
    /// The value of Seerr's `connect.sid` cookie.
    var cookie: String
    var userId: Int
    var userName: String
    var permissions: Int
    var settings: SeerrPublicSettings?

    var secure: Bool { server.hasPrefix("https://") }
    var rights: SeerrPermissions { SeerrPermissions(rawValue: permissions) }
    /// The address without its scheme, for a line in Settings.
    var host: String { server.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "") }
}

/// What an address turned out to be, before anything is sent to it.
struct SeerrProbe: Sendable, Hashable {
    var server: String
    var secure: Bool
    /// https was tried first and nothing answered there.
    var fellBackToHTTP: Bool
    var settings: SeerrPublicSettings
    var name: String { settings.applicationTitle ?? "Seerr" }
}

@MainActor
@Observable
final class SeerrClient {
    static let shared = SeerrClient()

    private let prefs = Preferences.shared
    private var jellyfin: JellyfinClient { JellyfinClient.shared }

    nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Aquarium", category: "seerr")

    // MARK: - The connection

    /// Bumped whenever the stored connection changes, so views that read
    /// `connection` are drawn again.
    private var revision = 0
    /// Bumped whenever a request is made or withdrawn, so lists and badges
    /// that show requests ask again.
    private(set) var requestsChanged = 0
    /// The session ran out and the quiet renewal failed. Settings offers to
    /// reconnect; everything else behaves as not connected.
    private(set) var needsReconnect = false

    @ObservationIgnored private var cachedKey: String?
    @ObservationIgnored private var cached: SeerrConnection?

    /// The connection for the Jellyfin account in use, or nil when that
    /// account has none. Read from the keychain once per account.
    var connection: SeerrConnection? {
        _ = revision
        guard let session = prefs.session else { return nil }
        if cachedKey != session.accountKey {
            cached = Self.read(for: session)
            cachedKey = session.accountKey
        }
        return cached
    }

    /// Whether the app should show anything of Seerr's at all.
    var isConnected: Bool { connection != nil && !needsReconnect }

    private static func slot(_ session: SavedSession) -> String { "seerr|" + session.server }

    private static func read(for session: SavedSession) -> SeerrConnection? {
        guard let raw = Keychain.token(server: slot(session), userId: session.userId) else { return nil }
        return try? JSONDecoder().decode(SeerrConnection.self, from: Data(raw.utf8))
    }

    /// The keychain is the only place this goes. The address travels with the
    /// cookie so a second device on the same iCloud Keychain gets both or
    /// neither.
    @discardableResult
    private func store(_ connection: SeerrConnection) -> Bool {
        guard let session = prefs.session,
              let data = try? JSONEncoder().encode(connection),
              let raw = String(data: data, encoding: .utf8),
              Keychain.store(token: raw, server: Self.slot(session), userId: session.userId)
        else { return false }
        cached = connection
        cachedKey = session.accountKey
        needsReconnect = false
        revision += 1
        return true
    }

    /// Forget an account's Seerr session on this device. For the Jellyfin
    /// sign-out paths, which may be dropping an account that isn't in use.
    static func forget(_ session: SavedSession) {
        Keychain.delete(server: slot(session), userId: session.userId)
        let client = SeerrClient.shared
        if client.cachedKey == session.accountKey {
            client.cachedKey = nil
            client.cached = nil
            client.titles = [:]
            client.collections = [:]
            client.credits = [:]
            client.needsReconnect = false
            client.revision += 1
        }
    }

    /// Sign out of Seerr and forget it. The server is told, so the session
    /// stops working there too; if it can't be reached the cookie is still
    /// gone from here.
    func disconnect() async {
        guard let session = prefs.session else { return }
        if let connection {
            _ = try? await send("/auth/logout", method: "POST", base: connection.server, cookie: connection.cookie)
        }
        Self.forget(session)
        csrf = nil
    }

    // MARK: - Transport

    /// Follows a redirect only to where the request was already going. The
    /// cookie is a header set by hand, and URLSession carries such headers
    /// along to wherever a redirect points.
    private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            let from = task.originalRequest?.url
            let to = request.url
            let same = from?.scheme == to?.scheme && from?.host == to?.host && from?.port == to?.port
            completionHandler(same ? request : nil)
        }
    }

    @ObservationIgnored private lazy var urlSession: URLSession = Self.makeSession()

    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = JellyfinClient.requestTimeout
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        // No cookie store: the one cookie that matters is kept in the
        // keychain and attached by hand, to one origin.
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCredentialStorage = nil
        #if DEBUG
        if let stubs = JellyfinClient.testProtocolClasses { cfg.protocolClasses = stubs + (cfg.protocolClasses ?? []) }
        #endif
        return URLSession(configuration: cfg, delegate: SameOriginRedirects(), delegateQueue: nil)
    }

    #if DEBUG
    /// Unit tests: rebuild the session (after `JellyfinClient.testProtocolClasses`
    /// changes) and drop everything held in memory.
    func resetForTests() {
        urlSession.invalidateAndCancel()
        urlSession = Self.makeSession()
        cachedKey = nil
        cached = nil
        titles = [:]
        csrf = nil
        renewal = nil
        needsReconnect = false
        revision += 1
    }
    #endif

    /// Seerr's optional cross-site protection: with it on, every write has to
    /// echo a token the server handed out in a cookie. Kept in memory only;
    /// any read brings a fresh one.
    private struct CSRF { var secret: String?; var token: String? }
    @ObservationIgnored private var csrf: CSRF?

    private struct Answer {
        var data: Data
        var status: Int
        var cookies: [String: String]
    }

    private enum Transport: Error { case failed(URLError.Code?) }

    private static let tlsFailures: Set<URLError.Code> = [
        .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
        .clientCertificateRejected, .clientCertificateRequired,
    ]

    /// The one place a request to Seerr is made. `path` is below `/api/v1`
    /// and already query-encoded.
    private func send(
        _ path: String, method: String = "GET", body: (any Encodable)? = nil, base: String, cookie: String?
    ) async throws -> Answer {
        guard let url = URL(string: base + "/api/v1" + path) else { throw SeerrError.message("That isn't a usable address") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        var jar: [String] = []
        if let cookie, !cookie.isEmpty { jar.append("connect.sid=\(cookie)") }
        if method != "GET", let csrf {
            if let secret = csrf.secret { jar.append("_csrf=\(secret)") }
            if let token = csrf.token {
                jar.append("XSRF-TOKEN=\(token)")
                req.setValue(token.removingPercentEncoding ?? token, forHTTPHeaderField: "X-XSRF-TOKEN")
            }
        }
        if !jar.isEmpty { req.setValue(jar.joined(separator: "; "), forHTTPHeaderField: "Cookie") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(Wrapped(body))
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw Transport.failed((error as? URLError)?.code)
        }
        guard let http = response as? HTTPURLResponse else { throw SeerrError.message("Seerr sent something this app couldn't read") }
        var cookies: [String: String] = [:]
        if let fields = http.allHeaderFields as? [String: String] {
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) { cookies[cookie.name] = cookie.value }
        }
        if cookies["_csrf"] != nil || cookies["XSRF-TOKEN"] != nil {
            var next = csrf ?? CSRF()
            if let secret = cookies["_csrf"] { next.secret = secret }
            if let token = cookies["XSRF-TOKEN"] { next.token = token }
            csrf = next
        }
        if !(200..<300).contains(http.statusCode) {
            Self.log.notice("Seerr \(http.statusCode) on \(path.components(separatedBy: "?")[0], privacy: .public)")
        }
        return Answer(data: data, status: http.statusCode, cookies: cookies)
    }

    private struct Wrapped: Encodable {
        private let encodeTo: (Encoder) throws -> Void
        init(_ wrapped: any Encodable) { encodeTo = { try wrapped.encode(to: $0) } }
        func encode(to encoder: Encoder) throws { try encodeTo(encoder) }
    }

    /// A request as the connected account. A refusal is checked before it is
    /// believed: Seerr answers 403 both to "you may not" and to "who are
    /// you", and only the second is a session to renew.
    private func call(_ path: String, method: String = "GET", body: (any Encodable)? = nil) async throws -> Data {
        guard var current = connection else { throw SeerrError.notConnected }
        var answer: Answer
        do {
            answer = try await send(path, method: method, body: body, base: current.server, cookie: current.cookie)
        } catch is Transport {
            throw SeerrError.unreachable("Can't reach Seerr at \(current.host)")
        }
        if answer.status == 401 || answer.status == 403, await sessionIsGone(current) {
            guard await renew(), let fresh = connection else {
                needsReconnect = true
                throw SeerrError.needsReconnect
            }
            current = fresh
            do {
                answer = try await send(path, method: method, body: body, base: current.server, cookie: current.cookie)
            } catch is Transport {
                throw SeerrError.unreachable("Can't reach Seerr at \(current.host)")
            }
        }
        guard (200..<300).contains(answer.status) else {
            throw SeerrError.refused(Self.plainWords(status: answer.status, body: answer.data))
        }
        return answer.data
    }

    private func get<T: Decodable & Sendable>(_ type: T.Type, _ path: String) async throws -> T {
        let data = try await call(path)
        do {
            return try await JellyfinClient.decode(T.self, from: data)
        } catch {
            throw SeerrError.message("Seerr sent something this app couldn't read")
        }
    }

    /// Whether Seerr, asked who this cookie belongs to, says nobody.
    private func sessionIsGone(_ connection: SeerrConnection) async -> Bool {
        guard let answer = try? await send("/auth/me", base: connection.server, cookie: connection.cookie) else { return false }
        return answer.status == 401 || answer.status == 403
    }

    /// A refusal in words. Seerr's own message is used when it has one worth
    /// reading; the common ones are reworded.
    nonisolated static func plainWords(status: Int, body: Data) -> String {
        struct Message: Decodable { var message: String?; var error: String? }
        let said = (try? JSONDecoder().decode(Message.self, from: body)).flatMap { $0.message ?? $0.error } ?? ""
        let lower = said.lowercased()
        if lower.contains("quota") { return "You've used all your requests for now. More open up as the oldest ones age out." }
        if lower.contains("already exists") || status == 409 { return "That has already been requested." }
        if lower.contains("4k") { return "This account can't request 4K versions." }
        if lower.contains("blocklist") || lower.contains("blacklist") { return "The server's administrator has blocked that title from being requested." }
        if lower.contains("no seasons available") || status == 202 { return "Every season of that is already in the library or requested." }
        switch status {
        case 401, 403: return "This account isn't allowed to do that on Seerr."
        case 404: return "Seerr doesn't know that title."
        case 500...: return "Seerr ran into a problem. Try again in a moment."
        default: return said.isEmpty || said.count > 140 ? "Seerr turned that down." : said
        }
    }

    // MARK: - Connecting

    /// Find out what is at an address before anything is sent to it. A bare
    /// host is tried over https, then http; a certificate that fails stops
    /// the search rather than dropping to http (the rule `JellyfinClient.probe`
    /// keeps).
    func probe(address raw: String) async throws -> SeerrProbe {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { throw SeerrError.message("Enter the Seerr server's address") }
        let lower = trimmed.lowercased()
        let typedScheme = lower.hasPrefix("http://") || lower.hasPrefix("https://")
        let candidates = typedScheme ? [trimmed] : ["https://\(trimmed)", "http://\(trimmed)"]
        var answeredAsSomethingElse = false
        for candidate in candidates {
            do {
                let answer = try await send("/settings/public", base: candidate, cookie: nil)
                guard answer.status == 200,
                      let settings = try? JSONDecoder().decode(SeerrPublicSettings.self, from: answer.data),
                      settings.initialized != nil
                else {
                    answeredAsSomethingElse = true
                    continue
                }
                guard settings.initialized == true, settings.mediaServerType != 4 else {
                    throw SeerrError.message("That Seerr server hasn't finished its own setup yet.")
                }
                guard settings.usesJellyfin else {
                    throw SeerrError.message("That Seerr server is set up for \(settings.mediaServerType == 1 ? "Plex" : "Emby"), not Jellyfin.")
                }
                return SeerrProbe(
                    server: candidate,
                    secure: candidate.lowercased().hasPrefix("https://"),
                    fellBackToHTTP: candidates.count > 1 && candidate.hasPrefix("http://"),
                    settings: settings
                )
            } catch Transport.failed(let code) {
                if candidates.count > 1, candidate.hasPrefix("https://"), let code, Self.tlsFailures.contains(code) {
                    throw SeerrError.message("That server's certificate couldn't be verified, so no secure connection was made. To use it without encryption anyway, type the address with http:// in front.")
                }
            }
        }
        throw SeerrError.message(answeredAsSomethingElse
            ? "That address answered, but not as a Seerr server."
            : "Couldn't reach a Seerr server at that address.")
    }

    /// Whether signing in without a password is on offer: the Jellyfin server
    /// has Quick Connect on. (Whether Seerr is new enough is found by trying.)
    func canQuickConnect() async -> Bool {
        guard let session = prefs.session else { return false }
        return await jellyfin.quickConnectEnabled(server: session.server)
    }

    /// Sign in to Seerr as the Jellyfin user this app is signed in as, with
    /// no password: Seerr asks Jellyfin for a Quick Connect code and this
    /// device approves it.
    ///
    /// Approving the code gives the Seerr server a Jellyfin session for this
    /// user, which is what signing in to Seerr with a password does too. The
    /// code can only have come from the Jellyfin server this app is signed in
    /// to: any other server's code is one ours has never heard of.
    @discardableResult
    func connectWithQuickConnect(to server: String) async throws -> SeerrConnection {
        try keep(await quickConnect(server: server))
    }

    private func quickConnect(server: String) async throws -> SeerrConnection {
        guard let session = prefs.session else { throw SeerrError.message("Sign in to Jellyfin first") }
        struct Start: Decodable {
            var code: String
            var secret: String
            enum CodingKeys: String, CodingKey { case code, secret }
            init(from decoder: Decoder) throws {
                let box = try decoder.container(keyedBy: CodingKeys.self)
                secret = try box.decode(String.self, forKey: .secret)
                // Jellyfin's code is digits in a string; be ready for a number.
                if let text = try? box.decode(String.self, forKey: .code) { code = text }
                else { code = String(try box.decode(Int.self, forKey: .code)) }
            }
        }
        struct Finish: Encodable { let secret: String }
        do {
            let asked = try await send("/auth/jellyfin/quickconnect/initiate", method: "POST", base: server, cookie: nil)
            guard asked.status == 200, let start = try? JSONDecoder().decode(Start.self, from: asked.data) else {
                throw SeerrError.quickConnectUnavailable
            }
            let approved: Bool
            do {
                approved = try await jellyfin.authorizeQuickConnect(code: start.code)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SeerrError.quickConnectUnavailable
            }
            guard approved else {
                throw SeerrError.message("That Seerr server belongs to a different Jellyfin server than the one you're signed in to.")
            }
            let done = try await send(
                "/auth/jellyfin/quickconnect/authenticate", method: "POST", body: Finish(secret: start.secret), base: server, cookie: nil
            )
            return try connection(from: done, server: server, session: session)
        } catch is Transport {
            throw SeerrError.unreachable("Can't reach Seerr at that address")
        }
    }

    /// The fallback: the Jellyfin user name and password, sent to Seerr once
    /// over this connection and kept nowhere.
    @discardableResult
    func connectWithPassword(to server: String, username: String, password: String) async throws -> SeerrConnection {
        guard let session = prefs.session else { throw SeerrError.message("Sign in to Jellyfin first") }
        struct Body: Encodable { let username: String; let password: String }
        do {
            let done = try await send(
                "/auth/jellyfin", method: "POST", body: Body(username: username, password: password), base: server, cookie: nil
            )
            if done.status == 401 { throw SeerrError.message("That user name or password isn't right.") }
            return try keep(connection(from: done, server: server, session: session))
        } catch is Transport {
            throw SeerrError.unreachable("Can't reach Seerr at that address")
        }
    }

    private func keep(_ connection: SeerrConnection) throws -> SeerrConnection {
        guard store(connection) else {
            throw SeerrError.message("Connected, but the keychain would not store the session. Try again.")
        }
        titles = [:]
        requestsChanged += 1
        return connection
    }

    /// Turn Seerr's answer to a sign-in into a connection, or say why not.
    private func connection(from answer: Answer, server: String, session: SavedSession) throws -> SeerrConnection {
        guard answer.status == 200 else {
            if answer.status == 403 {
                throw SeerrError.message("Your Jellyfin account hasn't been let in to this Seerr server. Ask whoever runs it to add you.")
            }
            if answer.status == 404 { throw SeerrError.quickConnectUnavailable }
            throw SeerrError.message("Seerr couldn't sign you in. Try again in a moment.")
        }
        guard let cookie = answer.cookies["connect.sid"], !cookie.isEmpty else {
            throw SeerrError.message("Seerr accepted the sign-in but returned no session.")
        }
        let user = (try? JSONDecoder().decode(SeerrUser.self, from: answer.data)) ?? SeerrUser()
        // The session has to be this Jellyfin user's. Seerr names the user it
        // signed in; anyone else's is thrown back.
        if let theirs = user.jellyfinUserId, !theirs.isEmpty, Self.bare(theirs) != Self.bare(session.userId) {
            Task { _ = try? await self.send("/auth/logout", method: "POST", base: server, cookie: cookie) }
            throw SeerrError.message("Seerr signed in a different Jellyfin user than the one this app is using.")
        }
        return SeerrConnection(
            server: server,
            cookie: cookie,
            userId: user.id ?? 0,
            userName: user.name.isEmpty ? session.userName : user.name,
            permissions: user.permissions ?? 0,
            settings: connection?.server == server ? connection?.settings : nil
        )
    }

    private static func bare(_ id: String) -> String { id.lowercased().replacingOccurrences(of: "-", with: "") }

    @ObservationIgnored private var renewal: Task<Bool, Never>?

    /// One quiet Quick Connect for however many requests found the session
    /// gone at once.
    private func renew() async -> Bool {
        if let renewal { return await renewal.value }
        guard let current = connection else { return false }
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            guard var fresh = try? await self.quickConnect(server: current.server) else { return false }
            fresh.settings = current.settings
            return self.store(fresh)
        }
        renewal = task
        let renewed = await task.value
        renewal = nil
        return renewed
    }

    /// Reconnect after `needsReconnect`, from Settings.
    func reconnect() async throws {
        guard let current = connection else { throw SeerrError.notConnected }
        try await connectWithQuickConnect(to: current.server)
    }

    /// Bring what is remembered about the account and the server up to date:
    /// permissions change, and so does whether 4K is on offer. Quiet; called
    /// when a Seerr page opens.
    func refreshAccount() async {
        guard var current = connection else { return }
        if let settings = try? await get(SeerrPublicSettings.self, "/settings/public") { current.settings = settings }
        if let user = try? await get(SeerrUser.self, "/auth/me") {
            current.permissions = user.permissions ?? current.permissions
            if let id = user.id { current.userId = id }
            if !user.name.isEmpty { current.userName = user.name }
        }
        // Renewed in between? Keep the newer cookie.
        if let latest = connection { current.cookie = latest.cookie }
        let postersCameOn = connection?.settings?.cacheImages != true && current.settings?.cacheImages == true
        if current != connection { store(current) }
        if postersCameOn { await postersTurnedOn(server: current.server) }
    }

    /// Bumped when Seerr starts serving posters it refused before, so cards
    /// already on screen ask again (`RequestPoster` is keyed on it).
    private(set) var posterEpoch = 0

    /// Cache Images has just been turned on. Every poster asked for while it
    /// was off got a 404, which `ImageLoader` remembers for ten minutes: the
    /// titles already seen (every one of your requests) stayed blank while
    /// new ones filled in.
    private func postersTurnedOn(server: String) async {
        await ImageLoader.shared.forgetAbsent(under: server + "/imageproxy/")
        posterEpoch += 1
    }

    // MARK: - Titles

    /// Seerr's search: films, shows, and (left out here) people and
    /// collections. The query is escaped down to unreserved characters; Seerr
    /// refuses anything looser.
    func search(_ term: String, page: Int = 1) async throws -> SeerrPage {
        let query = term.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? ""
        return try await get(SeerrPage.self, "/search?query=\(query)&page=\(page)")
    }

    private static let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))

    /// The rows of the Browse page.
    enum BrowseRow: String, CaseIterable, Identifiable, Sendable {
        case trending, popularMovies, popularTV, upcomingMovies, upcomingTV
        var id: String { rawValue }
        var title: String {
            switch self {
            case .trending: "Trending"
            case .popularMovies: "Popular Films"
            case .popularTV: "Popular Shows"
            case .upcomingMovies: "Upcoming Films"
            case .upcomingTV: "Upcoming Shows"
            }
        }
        var path: String {
            switch self {
            case .trending: "/discover/trending"
            case .popularMovies: "/discover/movies"
            case .popularTV: "/discover/tv"
            case .upcomingMovies: "/discover/movies/upcoming"
            case .upcomingTV: "/discover/tv/upcoming"
            }
        }
        /// The discover lists for one kind leave `mediaType` off each entry.
        var kind: SeerrMediaKind? {
            switch self {
            case .trending: nil
            case .popularMovies, .upcomingMovies: .movie
            case .popularTV, .upcomingTV: .tv
            }
        }
    }

    func browse(_ row: BrowseRow, page: Int = 1) async throws -> SeerrPage {
        var result = try await get(SeerrPage.self, "\(row.path)?page=\(page)")
        if let kind = row.kind {
            result.results = result.results?.map { entry in
                var entry = entry
                if entry.mediaType == nil { entry.mediaType = kind.rawValue }
                return entry
            }
        }
        return result
    }

    /// Observed, so a library page that asked about its own title (`warm`)
    /// is drawn again when the answer lands.
    private var titles: [String: SeerrTitle] = [:]
    private var collections: [Int: SeerrCollection] = [:]
    private var credits: [Int: [SeerrResult]] = [:]
    @ObservationIgnored private var warming = Set<String>()

    /// What is already known, without asking.
    func knownTitle(_ kind: SeerrMediaKind, tmdbId: Int) -> SeerrTitle? { titles["\(kind.rawValue)-\(tmdbId)"] }
    func knownCollection(tmdbId: Int) -> SeerrCollection? { collections[tmdbId] }
    func knownCredits(personTmdbId: Int) -> [SeerrResult]? { credits[personTmdbId] }

    /// A library page is being shown: find out, quietly, what Seerr has to
    /// add to it. A show's missing seasons, a collection's missing films,
    /// the rest of what someone has made. Nothing when Seerr isn't connected
    /// or the item has no TMDB id.
    func warm(for item: BaseItem) {
        guard isConnected, let id = item.tmdbId else { return }
        let key = "\(item.kind)-\(id)"
        guard warming.insert(key).inserted else { return }
        Task {
            defer { warming.remove(key) }
            switch item.kind {
            case "Series": _ = try? await title(.tv, tmdbId: id, fresh: true)
            case "BoxSet": if let found = try? await collection(tmdbId: id) { collections[id] = found }
            case "Person": if let found = try? await credits(personTmdbId: id) { credits[id] = found }
            default: break
            }
        }
    }

    /// A title's own page. Remembered for the session, because the Requests
    /// list asks for each of its rows; `fresh` asks again.
    func title(_ kind: SeerrMediaKind, tmdbId: Int, fresh: Bool = false) async throws -> SeerrTitle {
        let key = "\(kind.rawValue)-\(tmdbId)"
        if !fresh, let known = titles[key] { return known }
        let title = try await get(SeerrTitle.self, "/\(kind.rawValue)/\(tmdbId)")
        titles[key] = title
        return title
    }

    func collection(tmdbId: Int) async throws -> SeerrCollection {
        var collection = try await get(SeerrCollection.self, "/collection/\(tmdbId)")
        collection.parts = collection.parts?.map { part in
            var part = part
            if part.mediaType == nil { part.mediaType = SeerrMediaKind.movie.rawValue }
            return part
        }
        return collection
    }

    /// Everything someone has been in or made, newest first, each title once.
    func credits(personTmdbId: Int) async throws -> [SeerrResult] {
        let credits = try await get(SeerrPersonCredits.self, "/person/\(personTmdbId)/combined_credits")
        var seen = Set<String>()
        return ((credits.cast ?? []) + (credits.crew ?? []))
            .filter { $0.kind != nil && seen.insert($0.id).inserted }
            .sorted { ($0.releaseDate ?? $0.firstAirDate ?? "") > ($1.releaseDate ?? $1.firstAirDate ?? "") }
    }

    // MARK: - Requests

    private struct NewRequest: Encodable {
        let mediaType: String
        let mediaId: Int
        let seasons: [Int]?
        let is4k: Bool
    }

    /// Ask for a film, or for seasons of a show.
    @discardableResult
    func request(_ kind: SeerrMediaKind, tmdbId: Int, seasons: [Int]? = nil, is4K: Bool = false) async throws -> SeerrRequest {
        let body = NewRequest(mediaType: kind.rawValue, mediaId: tmdbId, seasons: kind == .tv ? seasons : nil, is4k: is4K)
        let data = try await call("/request", method: "POST", body: body)
        titles["\(kind.rawValue)-\(tmdbId)"] = nil
        requestsChanged += 1
        guard let made = try? JSONDecoder().decode(SeerrRequest.self, from: data) else {
            throw SeerrError.message("Seerr took the request but sent back something this app couldn't read")
        }
        return made
    }

    /// This account's requests, newest first.
    func myRequests(take: Int = 40, skip: Int = 0) async throws -> SeerrRequestPage {
        guard let connection else { throw SeerrError.notConnected }
        return try await get(
            SeerrRequestPage.self,
            "/request?take=\(take)&skip=\(skip)&sort=added&requestedBy=\(connection.userId)"
        )
    }

    /// Withdraw a request. Seerr lets an account remove its own while they
    /// are still waiting for approval.
    func cancel(_ request: SeerrRequest) async throws {
        _ = try await call("/request/\(request.id)", method: "DELETE")
        if let kind = request.kind, let id = request.media?.tmdbId { titles["\(kind.rawValue)-\(id)"] = nil }
        requestsChanged += 1
    }

    func quota() async throws -> SeerrQuota {
        guard let connection else { throw SeerrError.notConnected }
        return try await get(SeerrQuota.self, "/user/\(connection.userId)/quota")
    }

    // MARK: - Pictures

    enum ImageSize: String, Sendable {
        case poster = "w342", posterLarge = "w500", backdrop = "w1280", face = "w185"
    }

    /// Where a TMDB picture is fetched from: always through the Seerr server
    /// itself (its `/imageproxy`, which it serves to anyone and without a
    /// cookie), never from TMDB's own image host. Seerr's web pages send a
    /// browser to TMDB unless image caching is turned on; this app doesn't,
    /// so that nothing outside the user's own servers ever sees the device.
    /// The request carries no cookie: pictures are loaded by `ImageLoader`.
    ///
    /// Seerr answers `/imageproxy` with a 404 unless "Cache Images" is on in
    /// its General settings, and it is off by default. The address is still
    /// handed out then (the setting may have been turned on since it was
    /// last read); `postersOff` is what tells the person why there are none.
    func imageURL(_ path: String?, size: ImageSize) -> URL? {
        guard let path, path.hasPrefix("/"), let connection else { return nil }
        return URL(string: "\(connection.server)/imageproxy/tmdb/t/p/\(size.rawValue)\(path)")
    }

    /// The server says "Cache Images" is off, so its image proxy refuses every
    /// poster. Only a definite `false`: a server that didn't say is given the
    /// benefit of the doubt.
    var postersOff: Bool { connection?.settings?.cacheImages == false }
}
