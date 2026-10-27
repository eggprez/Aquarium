//  The Jellyfin API client.
//
//  This is the Swift side of what was split across `api.ts` and `server.rs` on
//  Linux: it builds the request, attaches the token from the keychain, checks
//  the server is still the one we signed in to, and turns the answer into the
//  types in Models.swift. The token is read here and nowhere else, and it is
//  kept out of URLs — Jellyfin's own access log would keep it otherwise — with
//  the single exception of a stream download (`authorized`).

import Foundation
import Network
import Observation
import os

/// The kinds of failure that have to be told apart upstream: "the network is
/// down" reads as offline mode, "that is not the server you signed in to" stops
/// the app, and an expired token drops to the sign-in screen.
enum APIError: LocalizedError, Sendable {
    case offline(String)
    case identity(String)
    case auth(String)
    case notConfigured
    case server(status: Int, path: String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .offline(let m): m
        case .identity(let m): m
        case .auth(let m): m
        case .notConfigured: "Not signed in"
        case .server(let status, let path): "Server error \(status) on \(path)"
        case .message(let m): m
        }
    }
}

/// A Quick Connect request in flight: the secret this device polls with, and
/// the code the user reads off the screen.
struct QuickConnectStart: Sendable, Hashable {
    var secret: String
    var code: String
}

/// What `/QuickConnect/Initiate` and `/QuickConnect/Connect` answer.
struct QuickConnectResult: Codable, Sendable {
    var Authenticated: Bool?
    var Secret: String?
    var Code: String?
}

/// What a server said about itself when probed, before any credential is sent.
struct ServerProbe: Sendable {
    var server: String
    var secure: Bool
    var serverId: String?
    var serverName: String?
    var version: String?
    /// No scheme was typed, https was tried first and did not answer, and this
    /// is the plain-http address that did. Ordinary for a server on the home
    /// network; for one out on the internet it is also exactly what someone
    /// on the path blocking port 443 produces, so the sign-in screen asks
    /// before it sends a password over it.
    var fellBackToHTTP = false
}

/// Where a stream is going to come from, and how.
struct PlaybackSource: Sendable {
    var url: URL
    var isTranscode: Bool
    var mediaSourceId: String
    var playSessionId: String
    var live: Bool
    /// The source the server picked, so the player can list its tracks and the
    /// detail line can describe what is actually being sent.
    var mediaSource: MediaSource
}

@MainActor
@Observable
final class JellyfinClient {
    static let shared = JellyfinClient()

    static let clientName = "Aquarium"
    static let clientVersion = "1.0.0"

    let prefs = Preferences.shared

    /// A saved session with an unreachable server is "offline", not "logged
    /// out". This is the fact — what downloads, progress sync and the status
    /// pill in Settings read. What the *shell* swaps its tabs over for is
    /// `showsOffline` below, which is this plus a grace period.
    private(set) var isOffline = false

    /// True while a connectivity probe started by the app coming to the
    /// foreground hasn't answered yet.
    ///
    /// `isOffline` survives the app being suspended, so a phone that lost the
    /// network overnight comes back to the foreground already offline and the
    /// offline screen is on show in the first frame — before a single request
    /// has been made, and usually a second before the one that would have
    /// proved otherwise. The debounce below can't help with that: it only
    /// delays *becoming* offline, and this session was offline before it
    /// started. Holding the screen back until the probe answers, or until the
    /// hold runs out, is what gives the answer time to arrive.
    private(set) var isRechecking = false

    /// The answer `showsOffline` was giving when the current probe started.
    @ObservationIgnored
    private var offlineBeforeRecheck = false

    /// What the shell shows the offline screen for.
    ///
    /// While a probe is outstanding this holds the answer it was giving when
    /// the probe started, rather than tracking `isOffline` as it changes. That
    /// it holds *the previous answer* — and not simply "online" — is the whole
    /// point: an app that was working must not flash the offline screen
    /// because a request that died at suspension landed a frame before the
    /// probe could say otherwise, and an app that really is offline must not
    /// flash the content it cannot load every time Try again is pressed.
    var showsOffline: Bool { isRechecking ? offlineBeforeRecheck : isOffline }

    /// How long the app will keep saying it is online while it finds out
    /// otherwise, after a request has failed.
    static let offlineGrace: Duration = .seconds(7)

    /// The longest the shell will hold its previous answer waiting on a
    /// foreground probe. Matched to the request timeout, so the hold can never
    /// expire before the probe it exists to wait for: a probe against a server
    /// that has genuinely gone fails in well under a second and ends the hold
    /// itself, and the only thing this covers is one that hangs.
    static let recheckHold: Duration = .seconds(20)

    /// Whether the app is the active scene.
    ///
    /// The grace below is a *foreground* grace, and has to be enforced as one.
    /// `Task.sleep` counts the time the process spends suspended, so a debounce
    /// started as the app was being put away has already expired by the time it
    /// comes back: it fires in the first frame after resume, and the delay
    /// written to prevent a flash of the offline screen becomes the thing that
    /// causes one. The evidence behind it is worthless too — a request in
    /// flight at suspension fails because iOS took the network away, which says
    /// nothing at all about the server.
    @ObservationIgnored
    private var isForeground = true

    /// Set when the saved address answers as a different Jellyfin install. That
    /// is either a moved server or someone pointing the client — and its token
    /// — somewhere else, so the app stops rather than degrading to offline.
    private(set) var identityProblem: String?

    /// Raised when the server stops honouring the token, so the shell can show
    /// the sign-in screen instead of leaving every page failing on its own.
    private(set) var authExpired = false

    var session: SavedSession? { prefs.session }

    /// How far the server's clock is ahead of this device's, from the `Date`
    /// header of the last answer. The library copy asks "what changed since"
    /// in the server's own time, where a device clock that is a few minutes
    /// out would otherwise miss changes. See `LibraryIndex`.
    @ObservationIgnored
    private var serverClockOffset: TimeInterval = 0
    @ObservationIgnored private var clockReadAt = Date.distantPast

    var serverNow: Date { Date().addingTimeInterval(serverClockOffset) }

    private static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()
    var isSignedIn: Bool { prefs.session != nil }

    @ObservationIgnored
    private var urlSession = JellyfinClient.makeURLSession(timeout: requestTimeout)
    /// For the few requests the server is entitled to take its time over — see
    /// `patientTimeout`. A session of its own rather than a per-request
    /// `timeoutInterval`, which the configuration's value is not documented to
    /// yield to.
    @ObservationIgnored
    private var patientSession = JellyfinClient.makeURLSession(timeout: patientTimeout)

    /// How long an ordinary request may go without data. Short, because the
    /// shell reads a request that hangs as the server being gone, and it
    /// shouldn't take half a minute to say so.
    static let requestTimeout: TimeInterval = 20
    /// How long a request that opens a live channel may take.
    ///
    /// `PlaybackInfo` with `AutoOpenLiveStream` is not a lookup: the server
    /// opens the tuner (or the connection behind an M3U channel), waits for
    /// bytes, runs ffprobe over them, and only then answers. Twenty seconds is
    /// routine for that and forty is not unusual, and the ordinary timeout was
    /// cutting it off — which the app then reported as a failed start, or
    /// before that, as nothing at all: a channel that showed its spinner and
    /// went back to the guide. Meanwhile the server, none the wiser, went on
    /// opening the tuner for a client that had already hung up, and held it
    /// against the next attempt.
    static let patientTimeout: TimeInterval = 75

    private static func makeURLSession(timeout: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeout
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }

    private let decoder = JSONDecoder()

    @ObservationIgnored
    private let pathMonitor = NWPathMonitor()
    @ObservationIgnored
    private var lastPathWasSatisfied: Bool?

    @ObservationIgnored
    private var offlineDebounceTask: Task<Void, Never>?

    @ObservationIgnored
    private var recheckTask: Task<Void, Never>?

    private init() {
        // tvOS suspends networking the moment the app leaves the foreground —
        // the screensaver, a Siri Remote press to Home, the system putting the
        // device to sleep — and the connections pooled in `urlSession` can come
        // back dead on the other side of that: PlaybackInfo hangs until its
        // timeout instead of failing cleanly, over and over, because the same
        // poisoned session keeps answering every retry. A force quit fixes it
        // only because a fresh process makes a fresh session. Watching the path
        // for "the network just came back" and throwing the pool away then does
        // the same thing without the restart.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            // The inner `Task` gets its own `weak self` rather than reading
            // the outer closure's: that outer capture is read from a
            // background queue (wherever `pathMonitor` calls this from) and
            // written to by ARC as the object deallocates, and Swift 6 flags
            // reading it from the concurrently-executing `Task` body as a
            // potential race on that shared capture. A fresh weak capture on
            // the `Task` closure resolves its own reference once, right there
            // on the actor, instead of reaching back across the boundary.
            Task { @MainActor [weak self] in self?.handlePathUpdate(path) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "aquarium.pathmonitor"))
    }

    private func handlePathUpdate(_ path: NWPath) {
        let satisfied = path.status == .satisfied
        let interface = [NWInterface.InterfaceType.wifi, .wiredEthernet, .cellular].first { path.usesInterfaceType($0) }
        defer {
            // Lost, back, or moved from one network to another (Wi-Fi at home
            // to cellular on the street, which never passes through "down"):
            // each is a question for the server, asked now rather than when a
            // page next happens to fail. Not the first callback after launch —
            // the launch probe is already asking.
            if let was = lastPathWasSatisfied, was != satisfied || (satisfied && interface != lastInterface) {
                onNetworkChanged?()
            }
            lastPathWasSatisfied = satisfied
            lastInterface = interface
        }
        // Only on a genuine recovery — down, then back up. The first callback
        // after launch is skipped by requiring `false` rather than just "not
        // true": the session made at init is already clean, and reacting to
        // every update would tear a request down mid-flight on the noise these
        // callbacks fire for (signal strength, interface ranking) even while
        // the path never actually dropped.
        guard satisfied, lastPathWasSatisfied == false else { return }
        resetConnections()
    }

    @ObservationIgnored
    private var lastInterface: NWInterface.InterfaceType?

    /// The device's network went down, came back, or changed; `AppModel`
    /// probes the server on it.
    @ObservationIgnored
    var onNetworkChanged: (@MainActor () -> Void)?

    /// An ordinary request got no answer at all; `AppModel` probes the server
    /// on it, so a page load finding the server gone is judged by the same
    /// probe as a launch — rather than only by the grace below running out.
    @ObservationIgnored
    var onRequestUnreachable: (@MainActor () -> Void)?

    /// How long the connectivity probe waits. Short, because it decides
    /// whether the whole shell is offline: a server at a home LAN address,
    /// asked from anywhere else, never refuses — it just never answers, and
    /// at the ordinary 20 s timeout (asked twice) an app opened away from home
    /// sat on its online tabs for most of a minute.
    static let probeTimeout: TimeInterval = 5

    /// Stop reusing the pooled connections, so the next request opens a fresh
    /// one — for when the sockets this session is holding are likely to be dead
    /// on the far end (coming back from the background, a network path
    /// recovering).
    ///
    /// `finishTasksAndInvalidate`, never `invalidateAndCancel`. Cancelling took
    /// down every request that happened to be in flight at the time, and at
    /// launch that is most of the app: Home asks for Continue Watching, Next Up
    /// and a Latest row per library at the same moment the shell is probing the
    /// server. Killed mid-flight, the two `try` calls failed the whole page into
    /// "This page didn't load" and each `try?` row quietly dropped its shelf —
    /// which is exactly what a server that is answering perfectly well looked
    /// like. Letting the outstanding tasks finish costs nothing: what this is
    /// for is the *next* request, not the ones already on the wire.
    func resetConnections() {
        urlSession.finishTasksAndInvalidate()
        urlSession = Self.makeURLSession(timeout: Self.requestTimeout)
        patientSession.finishTasksAndInvalidate()
        patientSession = Self.makeURLSession(timeout: Self.patientTimeout)
    }

    // MARK: - Auth header

    /// Jellyfin's own scheme. The token goes in the header, not the query
    /// (but see `authorized`, the one exception).
    /// An item id as one URL path segment. Jellyfin's are 32 hex characters
    /// and never need touching; anything else the server (or a deep link)
    /// hands over is escaped so it cannot add segments or a query of its own.
    nonisolated static func pathId(_ id: String) -> String {
        let allowed = pathIdAllowed
        if id.unicodeScalars.allSatisfy(allowed.contains) { return id }
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// Built once: this runs for every path the app builds.
    private nonisolated static let pathIdAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))

    private func authorizationHeader(token: String?) -> String {
        var parts = [
            "Client=\"\(Self.clientName)\"",
            "Device=\"\(Self.headerSafe(Self.deviceName))\"",
            "DeviceId=\"\(prefs.deviceId)\"",
            "Version=\"\(Self.clientVersion)\"",
        ]
        if let token, !token.isEmpty { parts.append("Token=\"\(token)\"") }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    /// A value for inside one of the header's quoted fields. The device name
    /// is whatever its owner typed, and a double quote in it ended the field
    /// early and left the rest of the header unreadable to the server.
    ///
    /// It also has to be ASCII. macOS names a Mac "Scott’s MacBook Pro" with
    /// a typographic apostrophe, and URLSession does not send a non-ASCII
    /// header value in a form Jellyfin accepts: every sign-in from such a Mac
    /// was answered 400 before the password was even looked at. Curly quotes
    /// become straight ones, accents are dropped, and anything still outside
    /// printable ASCII goes.
    private static func headerSafe(_ value: String) -> String {
        let folded = value
            .replacingOccurrences(of: "[‘’‛′]", with: "'", options: .regularExpression)
            .replacingOccurrences(of: "[“”„″]", with: "", options: .regularExpression)
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? value
        return String(folded.unicodeScalars.filter {
            $0.isASCII && $0 != "\"" && $0 != "\\" && !CharacterSet.controlCharacters.contains($0)
        }.map(Character.init))
    }

    static var deviceName: String {
        #if os(tvOS)
        return "Apple TV"
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return UIDeviceName.current
        #endif
    }

    /// The access token, read from the Keychain once per account rather than
    /// on every request.
    ///
    /// Each read is a round trip to securityd — two when the token lives in the
    /// synchronised copy — made on the main actor, and every request needed
    /// one: Home's half-dozen, every library page, a progress report every ten
    /// seconds. Keyed by account, so a different session simply misses; cleared
    /// wherever the Keychain entry is written or removed; and re-read before a
    /// 401 is believed, in case another device replaced the shared copy.
    private var token: String? {
        guard let s = prefs.session else { return nil }
        if let cached = tokenCache, cached.server == s.server, cached.userId == s.userId {
            return cached.token
        }
        let read = Keychain.token(server: s.server, userId: s.userId)
        // Nothing found is not remembered: a token that arrives later, from
        // iCloud Keychain, has to be picked up by the next request.
        tokenCache = read.map { (s.server, s.userId, $0) }
        return read
    }

    @ObservationIgnored
    private var tokenCache: (server: String, userId: String, token: String)?

    /// Why the last request that never got an answer didn't. `probe` reads it
    /// to tell a failed TLS handshake from a port nobody is listening on.
    @ObservationIgnored
    private var lastTransportFailure: URLError.Code?

    private nonisolated static let tlsFailures: Set<URLError.Code> = [
        .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
        .clientCertificateRejected, .clientCertificateRequired,
    ]

    // MARK: - Request plumbing

    /// A failed request flips this to `true` only after a grace period, not the
    /// instant it happens: the very first request after launch (or after the
    /// app comes back from the background) can lose a race with the network
    /// interface actually being up, and without the delay that single
    /// transient failure is enough to flash the whole app into the offline
    /// screen for the moment before the very next request succeeds. A slow
    /// server answering a heavy page of a library is the same shape of thing
    /// and the same wrong answer. Coming back online is never delayed — only
    /// the pessimistic direction needs debouncing.
    private func setOffline(_ v: Bool) {
        if v {
            guard !isOffline else { return }
            offlineDebounceTask?.cancel()
            offlineDebounceTask = Task { [weak self] in
                try? await Task.sleep(for: Self.offlineGrace)
                guard let self, !Task.isCancelled, self.isForeground else { return }
                self.isOffline = true
            }
        } else {
            offlineDebounceTask?.cancel()
            offlineDebounceTask = nil
            if isOffline != false { isOffline = false }
        }
    }

    /// Brings a pending offline verdict forward instead of serving out the
    /// grace. For the launch probe only, asked twice and failed twice: the
    /// grace exists so that one stray failure doesn't swap the shell, and at
    /// a cold launch with no server it was seven more seconds of cached pages
    /// looking like a working app. Does nothing unless a failure is already
    /// waiting — a probe that was merely cancelled has decided nothing.
    func confirmOffline() {
        guard offlineDebounceTask != nil, isForeground else { return }
        offlineDebounceTask?.cancel()
        offlineDebounceTask = nil
        if !isOffline { isOffline = true }
    }

    /// Whether a failed request failed because someone stopped it, rather than
    /// because there was nothing on the other end.
    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    /// Opens the same grace period from the other end: the app has just been
    /// brought to the foreground and is about to ask the server whether it is
    /// there. Until that answers — or the grace runs out, so a genuinely dead
    /// server still gets its screen — the shell keeps drawing what it drew
    /// before rather than the offline state it woke up holding.
    ///
    /// Held for every foreground probe, not only the ones that start offline.
    /// An app that went away online can still come back holding a flag set by
    /// the request iOS killed on its way out, and that is the case with no
    /// other defence: the debounce only delays *becoming* offline, and this one
    /// became offline before the app was awake to draw anything about it.
    func beginRecheck() {
        // Latched once per window. A second caller extends the hold but must
        // not re-read `isOffline`: by the time the connectivity refresh gets
        // its turn, the flag this exists to hide may already have flipped.
        if !isRechecking { offlineBeforeRecheck = isOffline }
        recheckTask?.cancel()
        isRechecking = true
        recheckTask = Task { [weak self] in
            try? await Task.sleep(for: Self.recheckHold)
            guard let self, !Task.isCancelled else { return }
            self.isRechecking = false
        }
    }

    /// The app has stopped being the active scene.
    ///
    /// Whatever was serving out its grace is thrown away rather than allowed to
    /// land on the way back in — see `isForeground`. Nothing already decided is
    /// undone: a session that was offline before the app was put away is still
    /// offline, and the probe on the way back is what settles it either way.
    func enterBackground() {
        isForeground = false
        offlineDebounceTask?.cancel()
        offlineDebounceTask = nil
    }

    func enterForeground() {
        isForeground = true
    }

    /// The probe answered, either way; there is nothing left to wait for.
    func endRecheck() {
        recheckTask?.cancel()
        recheckTask = nil
        if isRechecking { isRechecking = false }
    }

    /// The one place a request is made. `path` is server-relative and already
    /// query-encoded by the caller.
    ///
    /// `countsForOffline` is false for calls that are allowed to fail on
    /// their own without the shell dropping the whole app into offline mode
    /// — the Live TV guide's programme fetch, chiefly: it asks for every
    /// channel's schedule over several hours in one request, which a real
    /// server can genuinely be slow to answer, and a client-side timeout on
    /// that one call is not "the server is unreachable." Set true, it used
    /// to make Live TV self-defeating: the guide would time out, that flipped
    /// `isOffline`, the shell replaced every tab with the offline screen, and
    /// retrying reloaded the same channels — which remounts the guide, which
    /// asks the same slow question again and flips it straight back.
    @discardableResult
    func request(
        _ path: String,
        method: String = "GET",
        body: (any Encodable)? = nil,
        server overrideServer: String? = nil,
        token overrideToken: String? = nil,
        countsForOffline: Bool = true,
        patient: Bool = false,
        isRetry: Bool = false,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        guard let base = overrideServer ?? prefs.session?.server else {
            throw APIError.notConfigured
        }
        // Once the saved address has answered as some other Jellyfin install,
        // nothing else goes out with the token until the user signs out. The
        // pin used to be advisory — it raised an alert and every other request
        // carried on regardless, which is not what "the app stops" means.
        if overrideServer == nil, let problem = identityProblem {
            throw APIError.identity(problem)
        }
        guard let url = URL(string: base + path) else {
            throw APIError.message("Bad server address")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let timeout { req.timeoutInterval = timeout }
        let sentToken = overrideToken ?? token
        req.setValue(authorizationHeader(token: sentToken), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await perform(req, patient: patient)
        } catch {
            // A cancelled request says nothing about the server. It is what
            // `resetConnections()` does to everything still in flight, and what
            // a `.task` being torn down does to the call inside it — neither of
            // which is the network being down. Counted as evidence, a routine
            // teardown at launch was enough to drop the whole shell into the
            // offline screen.
            //
            // And it is not reported as one either: a cancelled request throws
            // `CancellationError`, which callers drop silently, rather than a
            // "Can't reach" for a page to put on screen.
            if Self.isCancellation(error) { throw CancellationError() }
            lastTransportFailure = (error as? URLError)?.code
            if countsForOffline {
                setOffline(true)
                onRequestUnreachable?()
            }
            throw APIError.offline("Can't reach \(base)")
        }
        setOffline(false)

        guard let http = response as? HTTPURLResponse else {
            throw APIError.message("Malformed response")
        }
        // The server's clock, read at most once a minute. A clock offset
        // doesn't move between one request and the next, and parsing the
        // header with a formatter on every response, on the main actor, was
        // work repeated for the same answer.
        if overrideServer == nil, Date().timeIntervalSince(clockReadAt) >= 60,
           let stamp = http.value(forHTTPHeaderField: "Date"),
           let serverDate = Self.httpDate.date(from: stamp) {
            serverClockOffset = serverDate.timeIntervalSinceNow
            clockReadAt = Date()
        }
        // A revoked or expired token answers 401 on every endpoint, so without
        // this branch the whole app reads as broken — each page failing with its
        // own "Server error 401" and no route back to the sign-in screen.
        if http.statusCode == 401, prefs.session != nil, overrideToken == nil {
            // The token is cached (see `token`). Before a 401 signs anyone out,
            // the Keychain is asked again: if another device replaced the
            // shared copy, the request is worth one more try with that.
            tokenCache = nil
            if !isRetry, let fresh = token, fresh != sentToken {
                return try await request(
                    path, method: method, body: body, server: overrideServer, token: nil,
                    countsForOffline: countsForOffline, patient: patient, isRetry: true
                )
            }
            // And before the token is thrown away, a second opinion. Expiring
            // deletes the keychain entry, and the synchronised one with it —
            // which signs every device on the iCloud account out. One 401 is
            // too little to hang that on: a reverse proxy having a bad moment
            // sends them, and over plain http so can anyone on the path.
            guard await tokenIsRefused(sentToken, server: base) else {
                throw APIError.server(status: 401, path: path.components(separatedBy: "?")[0])
            }
            expireSession()
            throw APIError.auth("Your session has expired — please sign in again")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(status: http.statusCode, path: path.components(separatedBy: "?")[0])
        }
        return data
    }

    /// Whether the server, asked who this token belongs to, says nobody. Any
    /// other outcome — an answer, an error, no reply — is not a refusal.
    private func tokenIsRefused(_ sent: String?, server base: String) async -> Bool {
        guard let url = URL(string: base + "/Users/Me") else { return false }
        var req = URLRequest(url: url)
        req.setValue(authorizationHeader(token: sent), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (_, response) = try? await perform(req, patient: false) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 401
    }

    /// Make the request on the session as it is *right now*.
    ///
    /// Not `URLSession.data(for:)`. That call hops off this actor before it
    /// creates its task, and in that gap `resetConnections()` — on this actor,
    /// from the connectivity probe or a network path recovering — can
    /// invalidate the very session it was handed. Creating a task on an
    /// invalidated session is not an error that comes back through `throws`;
    /// it is an Objective-C exception, and the process dies. Seen on a cold
    /// launch from the top shelf's Play, whose first request raced the
    /// launch-time probe's reset (Sept 2026, in the Simulator).
    ///
    /// So the task is made here, synchronously, on this actor — the closure a
    /// continuation is given runs before anything suspends — and the reset,
    /// being on the same actor, can only run before the session is read or
    /// after the task exists. A task already made is one
    /// `finishTasksAndInvalidate` lets finish.
    private func perform(_ req: URLRequest, patient: Bool) async throws -> (Data, URLResponse) {
        let session = patient ? patientSession : urlSession
        let handle = TaskHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: req) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, let response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: URLError(.unknown))
                    }
                }
                handle.attach(task)
                task.resume()
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// The task behind `perform`, reachable from the cancellation handler,
    /// which can run on any thread and before the task exists.
    private final class TaskHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false

        func attach(_ task: URLSessionDataTask) {
            lock.lock(); defer { lock.unlock() }
            self.task = task
            if cancelled { task.cancel() }
        }

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            task?.cancel()
        }
    }

    func get<T: Decodable & Sendable>(_ type: T.Type, _ path: String, countsForOffline: Bool = true) async throws -> T {
        let data = try await request(path, countsForOffline: countsForOffline)
        if data.isEmpty, let empty = EmptyFallback<T>.value { return empty }
        do {
            return try await Self.decode(T.self, from: data)
        } catch {
            throw APIError.message("The server sent something this client couldn't read")
        }
    }

    /// JSON decoded off the main actor.
    ///
    /// This client is main-actor, and decoding used to happen here with it: a
    /// guide page of five thousand programmes, or a library page whose items
    /// each carry a list of streams, is a few hundred milliseconds of the main
    /// thread doing nothing a person can see. `@concurrent` because under this
    /// project's approachable-concurrency setting a plain nonisolated async
    /// function would run on the caller's actor — which is the main one.
    @concurrent
    nonisolated static func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data) async throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Connectivity

    /// Probe the saved server. Updates the offline flag; true when reachable.
    @discardableResult
    func checkOnline() async -> Bool {
        guard let s = prefs.session else { return false }
        do {
            // The endpoint is public, and the whole point of the probe is to
            // find out who is answering before trusting them with anything.
            let data = try await request("/System/Info/Public", server: s.server, token: "", timeout: Self.probeTimeout)
            let info = try? decoder.decode(PublicSystemInfo.self, from: data)
            if let pinned = s.serverId, let actual = info?.Id, !actual.isEmpty, pinned != actual {
                identityProblem = "\(s.server) is answering as a different Jellyfin server than the one you signed in to."
                return false
            }
            // First successful contact after sign-in records the identity.
            if s.serverId == nil, let actual = info?.Id, !actual.isEmpty {
                var updated = s
                updated.serverId = actual
                prefs.session = updated
            }
            setOffline(false)
            return true
        } catch is CancellationError {
            // The probe was called off, which says nothing either way; the
            // flag stays where it was.
            return false
        } catch {
            setOffline(true)
            return false
        }
    }

    func clearIdentityProblem() { identityProblem = nil }
    func clearAuthExpired() { authExpired = false }

    // MARK: - Sign in / out

    /// Find out what is at an address, before any credential is sent to it. A
    /// bare hostname is tried over https first, then http — the same order the
    /// Linux build uses, so a LAN server on plain HTTP still resolves but a
    /// server that offers TLS is never downgraded to it: a failed handshake
    /// stops the search, and a fallback is marked as one (`fellBackToHTTP`).
    func probe(server raw: String) async throws -> ServerProbe {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { throw APIError.message("Enter a server address") }

        var candidates: [String] = []
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            candidates = [trimmed]
        } else {
            candidates = ["https://\(trimmed)", "http://\(trimmed)"]
        }

        var lastError: Error?
        for candidate in candidates {
            do {
                lastTransportFailure = nil
                let data = try await request("/System/Info/Public", server: candidate, token: "")
                let info = try decoder.decode(PublicSystemInfo.self, from: data)
                setOffline(false)
                return ServerProbe(
                    server: candidate,
                    secure: candidate.hasPrefix("https://"),
                    serverId: info.Id,
                    serverName: info.ServerName,
                    version: info.Version,
                    fellBackToHTTP: candidates.count > 1 && candidate.hasPrefix("http://")
                )
            } catch {
                lastError = error
                // Something answered on the TLS port and the handshake failed:
                // a certificate that doesn't check out. That is not "no https
                // here", and quietly trying plain http next would hand the
                // password to whoever presented it.
                if candidates.count > 1, candidate.hasPrefix("https://"),
                   let code = lastTransportFailure, Self.tlsFailures.contains(code) {
                    setOffline(false)
                    throw APIError.message("That server's certificate couldn't be verified, so no secure connection was made. To use it without encryption anyway, type the address with http:// in front.")
                }
            }
        }
        setOffline(false)
        if let lastError = lastError as? APIError, case .server = lastError {
            throw APIError.message("That address answered, but not as a Jellyfin server")
        }
        throw APIError.message("Couldn't reach a Jellyfin server at that address")
    }

    /// Sign in. The password goes out once, over this connection, and the token
    /// that comes back goes straight into the keychain.
    @discardableResult
    func login(server: String, username: String, password: String) async throws -> SavedSession {
        struct Body: Encodable { let Username: String; let Pw: String }
        let data = try await request(
            "/Users/AuthenticateByName",
            method: "POST",
            body: Body(Username: username, Pw: password),
            server: server,
            token: ""
        )
        return try install(authResponse: data, server: server, fallbackName: username)
    }

    /// The far end of both sign-in routes: the token into the keychain, the
    /// session into preferences, and every "the server is wrong" flag cleared.
    private func install(authResponse data: Data, server: String, fallbackName: String) throws -> SavedSession {
        let auth = try decoder.decode(AuthResponse.self, from: data)
        guard let accessToken = auth.AccessToken, !accessToken.isEmpty,
              let userId = auth.User?.Id, !userId.isEmpty
        else {
            throw APIError.message("The server accepted the request but returned no session")
        }
        let saved = SavedSession(
            server: server,
            userId: userId,
            userName: auth.User?.Name ?? fallbackName,
            deviceId: prefs.deviceId,
            serverId: auth.ServerId
        )
        guard Keychain.store(token: accessToken, server: server, userId: userId) else {
            throw APIError.message("Signed in, but the keychain would not store the session. Try again.")
        }
        tokenCache = nil
        // A different server is a different clock.
        clockReadAt = .distantPast
        prefs.session = saved
        setOffline(false)
        authExpired = false
        identityProblem = nil
        return saved
    }

    // MARK: - Quick Connect

    /// Whether the server will hand out Quick Connect codes at all. Off by
    /// default on a fresh Jellyfin install; an administrator turns it on
    /// under Dashboard → General. Answered false on any failure, since the
    /// only thing that changes is whether the code panel is offered.
    func quickConnectEnabled(server: String) async -> Bool {
        guard let data = try? await request("/QuickConnect/Enabled", server: server, token: "", countsForOffline: false)
        else { return false }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Ask for a code. The server files the request under this device's name
    /// and id (from the Authorization header, which is why the header goes
    /// out with no token in it) and the code is what the user types into a
    /// client that is already signed in. Jellyfin 10.9 made this a POST; the
    /// GET is kept for a 10.8 server, which answers 405 to the POST.
    func quickConnectInitiate(server: String) async throws -> QuickConnectStart {
        let data: Data
        do {
            data = try await request("/QuickConnect/Initiate", method: "POST", server: server, token: "", countsForOffline: false)
        } catch APIError.server(let status, _) where status == 405 || status == 404 {
            data = try await request("/QuickConnect/Initiate", server: server, token: "", countsForOffline: false)
        } catch APIError.server(let status, _) where status == 401 {
            throw APIError.message("Quick Connect is turned off on this server")
        }
        let result = try decoder.decode(QuickConnectResult.self, from: data)
        guard let secret = result.Secret, !secret.isEmpty, let code = result.Code, !code.isEmpty else {
            throw APIError.message("The server didn't hand out a Quick Connect code")
        }
        return QuickConnectStart(secret: secret, code: code)
    }

    /// Has someone approved this code yet? `nil` means the request has
    /// expired on the server — Jellyfin forgets a code after ten minutes —
    /// and a fresh one is needed.
    func quickConnectState(server: String, secret: String) async throws -> Bool? {
        var comps = URLComponents()
        comps.queryItems = [URLQueryItem(name: "secret", value: secret)]
        let query = comps.percentEncodedQuery ?? ""
        do {
            let data = try await request("/QuickConnect/Connect?\(query)", server: server, token: "", countsForOffline: false)
            let result = try decoder.decode(QuickConnectResult.self, from: data)
            return result.Authenticated ?? false
        } catch APIError.server(let status, _) where status == 404 {
            return nil
        }
    }

    /// Turn an approved code into a session. Only sensible once
    /// `quickConnectState` has answered true; before that the server refuses.
    @discardableResult
    func loginWithQuickConnect(server: String, secret: String) async throws -> SavedSession {
        struct Body: Encodable { let Secret: String }
        let data = try await request(
            "/Users/AuthenticateWithQuickConnect",
            method: "POST",
            body: Body(Secret: secret),
            server: server,
            token: ""
        )
        return try install(authResponse: data, server: server, fallbackName: "")
    }

    /// The other side of the exchange: this signed-in device approving a code
    /// shown on another. True when the server recognised the code; false when
    /// it didn't (mistyped, or already expired).
    func authorizeQuickConnect(code: String) async throws -> Bool {
        let digits = code.filter(\.isNumber)
        guard !digits.isEmpty else { return false }
        do {
            let data = try await request("/QuickConnect/Authorize?code=\(digits)", method: "POST")
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        } catch APIError.server(let status, _) where status == 404 || status == 400 {
            return false
        } catch APIError.server(let status, _) where status == 403 {
            throw APIError.message("This account isn't allowed to approve Quick Connect requests")
        }
    }

    // MARK: - More than one account

    /// The accounts this device can become without a password.
    var accounts: [SavedSession] { prefs.accounts }

    /// The same, signed in under another of this Apple TV's users. Empty
    /// everywhere else.
    var householdAccounts: [SavedSession] {
        #if os(tvOS)
        prefs.householdAccounts
        #else
        []
        #endif
    }

    /// A user the server will name to somebody who hasn't signed in: the
    /// faces on Jellyfin's own sign-in page. An administrator can hide any of
    /// them, or all of them, so the list is an offer and the username field
    /// stays.
    struct PublicUser: Decodable, Hashable, Sendable, Identifiable {
        var Id: String
        var Name: String?
        var HasPassword: Bool?
        var id: String { Id }
        var name: String { Name ?? "" }
    }

    /// Who can sign in to the server at `server`, as far as it will say.
    /// Empty on any failure: the only thing it changes is whether names are
    /// offered above the form.
    func publicUsers(server: String) async -> [PublicUser] {
        guard let data = try? await request("/Users/Public", server: server, token: "", countsForOffline: false),
              let users = try? decoder.decode([PublicUser].self, from: data)
        else { return [] }
        return users.filter { !$0.name.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Become another of this device's accounts. Nothing is revoked: the one
    /// being left keeps its token in the keychain, which is the whole of what
    /// makes coming back to it a tap.
    ///
    /// False when that account's token has gone — signed out from another
    /// device sharing this iCloud Keychain, most likely — and the account is
    /// dropped from the list, since the only way back into it is to sign in.
    /// The caller owns the rest of the handover; see `AppModel.switchAccount`.
    /// `dryRun` answers the same question — can this be switched to? — and
    /// drops a dead account the same way, without switching.
    @discardableResult
    func switchAccount(to account: SavedSession, dryRun: Bool = false) -> Bool {
        guard account.accountKey != prefs.session?.accountKey else { return true }
        guard Keychain.token(server: account.server, userId: account.userId) != nil else {
            prefs.forgetAccount(account)
            return false
        }
        if dryRun { return true }
        tokenCache = nil
        clockReadAt = .distantPast
        // The copy is one account's view of one server. `prepare` would
        // refuse to show it to anyone else, but there is only room on disk
        // for one, so it goes now rather than being read and thrown away.
        LibraryIndex.shared.wipe()
        var next = account
        next.deviceId = prefs.deviceId
        prefs.session = next
        setOffline(false)
        authExpired = false
        identityProblem = nil
        #if os(tvOS)
        TopShelf.clear()
        #endif
        #if os(iOS)
        QuickActions.clear()
        #endif
        return true
    }

    /// Sign one of the *other* accounts out: its token revoked on its own
    /// server, with its own token, and gone from the keychain and the list.
    /// The account in use is signed out with `logout()` instead.
    func forget(_ account: SavedSession) async {
        guard account.accountKey != prefs.session?.accountKey else { return }
        if let token = Keychain.token(server: account.server, userId: account.userId) {
            _ = try? await request("/Sessions/Logout", method: "POST", server: account.server, token: token, countsForOffline: false)
        }
        Keychain.delete(server: account.server, userId: account.userId)
        prefs.forgetAccount(account)
    }

    /// A user's picture, for the account lists. Served without a token, so it
    /// can be drawn for an account that is not the one signed in. `/UserImage`
    /// (10.9 and later) rather than `/Users/{id}/Images/Primary`, which 12.x has
    /// dropped from its API description along with the rest of `/Users/{id}/…`.
    static func avatarURL(for account: SavedSession, width: Int = 160) -> URL? {
        URL(string: "\(account.server)/UserImage?userId=\(account.userId)&maxWidth=\(width)&quality=90")
    }

    /// Sign out. Returns whether the server confirmed the token was revoked;
    /// when it didn't, the caller should say so rather than let the user believe
    /// the session is dead.
    @discardableResult
    func logout() async -> Bool {
        var revoked = false
        if let s = prefs.session {
            do {
                _ = try await request("/Sessions/Logout", method: "POST")
                revoked = true
            } catch APIError.auth {
                // An already-dead token answers 401, which is still "revoked".
                revoked = true
            } catch {
                revoked = false
            }
            Keychain.delete(server: s.server, userId: s.userId)
            tokenCache = nil
            prefs.forgetAccount(s)
        }
        LibraryIndex.shared.wipe()
        prefs.session = nil
        authExpired = false
        identityProblem = nil
        #if os(tvOS)
        TopShelf.clear()
        #endif
        #if os(iOS)
        QuickActions.clear()
        #endif
        return revoked
    }

    /// Drop a session the server has stopped honouring: same teardown as a
    /// sign-out minus the Logout call, since the token it would authenticate
    /// with is exactly the one that just failed.
    private func expireSession() {
        guard let s = prefs.session else { return }
        Keychain.delete(server: s.server, userId: s.userId)
        tokenCache = nil
        prefs.forgetAccount(s)
        LibraryIndex.shared.wipe()
        prefs.session = nil
        authExpired = true
        #if os(tvOS)
        TopShelf.clear()
        #endif
    }

    // MARK: - Fields

    private static let itemFields =
        "PrimaryImageAspectRatio,Overview,Genres,MediaSources,UserData,SeriesPrimaryImage,ChildCount,RecursiveItemCount,ProductionYear,RunTimeTicks,OfficialRating,CommunityRating,ParentId"

    /// `itemFields` plus what the library copy needs to sort the way the server
    /// does. See `LibraryIndex`.
    static let indexFields = itemFields + ",SortName,DateCreated"

    /// `itemFields` plus the ones only the detail page draws. `People` is a long
    /// list on a feature film, so it isn't asked for on every grid query.
    ///
    /// `Trickplay` too, so the player can take the scrubbing thumbnails'
    /// description from the item it already fetched instead of asking for the
    /// whole item a second time. See `trickplayInfo(for:)`.
    private static let detailFields = itemFields + ",People,Studios,Taglines,Trickplay,RemoteTrailers,LocalTrailerCount,ProductionLocations"

    /// `itemFields` without `MediaSources`, for queries that only fill grids
    /// and shelves.
    ///
    /// A media source carries every stream in the file, twenty-odd fields
    /// each, and a remux with a dozen subtitle tracks is a long list — so a
    /// sixty-film page was hundreds of kilobytes that no card reads. What does
    /// need it asks for the item itself: the player (see `loadExtras`), the
    /// detail page, and a download started from a card's menu (see
    /// `ItemContextMenu.download`). Kept on the shelves whose items are
    /// started straight from Home — Continue Watching, Next Up, Latest — and
    /// on season episode lists, which the detail page downloads from as they
    /// are.
    private static let listFields = itemFields.replacingOccurrences(of: "MediaSources,", with: "") + ",SortName"

    // MARK: - Browse

    func views() async throws -> [BaseItem] {
        guard let s = prefs.session else { throw APIError.notConfigured }
        return try await get(ItemsResponse.self, "/UserViews?userId=\(s.userId)").items
    }

    /// The home screen the user has already arranged, read from the server.
    ///
    /// Jellyfin keeps the order and the choice of home rows in the account's
    /// display preferences, under the `usersettings` id and the `emby` client
    /// name — seven numbered slots, each naming a kind of row. Every Jellyfin
    /// client reads the same seven, which is why the web home screen and the
    /// Android one agree with each other; this app was the odd one out, with a
    /// layout of its own invention that happened to resemble the default.
    ///
    /// Best-effort: a server that won't answer, an account that has never
    /// touched the setting, or a payload in a shape this doesn't recognise all
    /// come back as `HomeSection.fallback`, which is Jellyfin's own default
    /// order — the same rows in the same places the web client would put them.
    ///
    /// Kept for ten minutes per account. Home reloads on every return to it,
    /// and the layout is something a person changes a few times a year, in
    /// another client; one request per visit for it was pure overhead. Home's
    /// Refresh button passes `fresh` and asks regardless. A fallback is never
    /// kept, so a server that didn't answer is asked again next time.
    func homeSections(fresh: Bool = false) async -> [HomeSection] {
        guard let s = prefs.session else { return HomeSection.fallback }
        let account = s.server + "|" + s.userId
        if !fresh, let kept = sectionsCache, kept.account == account,
           Date().timeIntervalSince(kept.at) < Self.sectionsLifetime {
            return kept.sections
        }
        guard let sections = await fetchHomeSections(s) else { return HomeSection.fallback }
        sectionsCache = (account, Date(), sections)
        return sections
    }

    @ObservationIgnored
    private var sectionsCache: (account: String, at: Date, sections: [HomeSection])?
    private static let sectionsLifetime: TimeInterval = 600

    /// Nil for anything that should come out as the fallback.
    private func fetchHomeSections(_ s: SavedSession) async -> [HomeSection]? {
        let q = [
            URLQueryItem(name: "userId", value: s.userId),
            URLQueryItem(name: "client", value: "emby"),
        ]
        guard let prefsPayload = try? await get(
            DisplayPreferencesPayload.self,
            "/DisplayPreferences/usersettings?\(Self.encode(q))",
            countsForOffline: false
        ) else { return nil }

        // The keys are written lower-cased by the web client and camel-cased by
        // some others, so the lookup is done case-insensitively rather than
        // betting on one of them.
        let custom = prefsPayload.CustomPrefs ?? [:]
        var byLowerKey: [String: String] = [:]
        for (key, value) in custom {
            if let value { byLowerKey[key.lowercased()] = value }
        }

        var out: [HomeSection] = []
        for slot in 0..<7 {
            // An unset slot is not "nothing": Jellyfin fills it in from its own
            // defaults, and a user who has only ever moved row 2 leaves the
            // rest to that. Matching it is what makes an untouched account look
            // the same here as it does in a browser.
            let raw = byLowerKey["homesection\(slot)"] ?? HomeSection.jellyfinDefault(slot)
            guard let section = HomeSection(serverName: raw) else { continue }
            // Two slots can name the same row — Jellyfin's own settings screen
            // won't produce that, but the preferences are loose strings and
            // nothing stops it. A repeat would give `ForEach` two children with
            // one identity, which SwiftUI resolves by dropping views at random.
            guard !out.contains(section) else { continue }
            out.append(section)
        }
        // Every slot set to "none" is a home screen with nothing on it, which is
        // a setting nobody chose on purpose — far likelier a server that
        // answered with something unexpected.
        return out.isEmpty ? nil : out
    }

    private struct DisplayPreferencesPayload: Decodable, Sendable {
        /// Values can be JSON null, and one null used to fail the whole
        /// decode and drop the user's layout for the fallback.
        var CustomPrefs: [String: String?]?
    }

    func resume() async throws -> [BaseItem] {
        guard let s = prefs.session else { throw APIError.notConfigured }
        return try await get(
            ItemsResponse.self,
            "/UserItems/Resume?userId=\(s.userId)&Limit=16&Fields=\(Self.itemFields)&MediaTypes=Video&EnableImageTypes=Primary,Backdrop,Thumb,Logo"
        ).items
    }

    /// The Next Up row, as the account's Next Up settings shape it. Every
    /// place that shows the row asks through here, so the settings — which
    /// travel between devices — are the whole of what makes the list, and an
    /// iPhone, an Apple TV and a Mac signed in to one account get one list.
    ///
    /// With a day limit set (`Preferences.nextUpDays`), the app is what
    /// enforces it: the row is the server's Next Up cut at the limit, and a
    /// show the server still has past it is taken off Next Up *on the
    /// server* (`removeFromNextUp`), so Jellyfin's own apps and the Linux
    /// one stop offering it too. Both questions go out with the same
    /// settings, so the only thing between their answers is the limit. The
    /// wider one failing, or a server that ignores the cutoff, leaves
    /// nothing to remove — this never takes off a show it hasn't seen
    /// fall outside the limit.
    func nextUp() async throws -> [BaseItem] {
        let days = prefs.nextUpDays
        // At the server's most rather than the row's 16: a show started over
        // from its first episode is at the end of the server's answer, and
        // is brought to the front (`HomeRows.newStartsFirst`).
        guard days > 0 else { return Array(HomeRows.newStartsFirst(try await nextUpQuery(limit: 100, cutoff: nil)).prefix(16)) }
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        // Both at the server's own most, not the row's 16: a show inside the
        // limit but past the 16th is not one to remove.
        async let within = nextUpQuery(limit: 100, cutoff: cutoff)
        async let everything = try? nextUpQuery(limit: 100, cutoff: nil, light: true)
        let kept = try await within
        if let everything = await everything {
            reportExpired(HomeRows.expiredFromNextUp(everything: everything, kept: kept))
        }
        return Array(HomeRows.newStartsFirst(kept).prefix(16))
    }

    /// `light` asks for the ids alone — what the wider question above needs.
    private func nextUpQuery(limit: Int, cutoff: Date?, light: Bool = false) async throws -> [BaseItem] {
        guard let s = prefs.session else { throw APIError.notConfigured }
        var query: [URLQueryItem] = [
            .init(name: "userId", value: s.userId),
            .init(name: "Limit", value: String(limit)),
            .init(name: "enableResumable", value: prefs.nextUpIncludesInProgress ? "true" : "false"),
            .init(name: "enableRewatching", value: prefs.nextUpRewatching ? "true" : "false"),
        ]
        if light {
            query += [.init(name: "enableImages", value: "false"), .init(name: "enableUserData", value: "false")]
        } else {
            query += [
                .init(name: "Fields", value: Self.itemFields),
                .init(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb,Logo"),
            ]
        }
        if let cutoff {
            query.append(.init(name: "nextUpDateCutoff", value: ISO8601DateFormatter().string(from: cutoff)))
        }
        return try await get(ItemsResponse.self, "/Shows/NextUp?\(Self.encode(query))").items
    }

    /// Shows being taken off Next Up for having run past the day limit, so
    /// that two surfaces asking at once — Home and the top shelf, say — don't
    /// both write the same dates.
    @ObservationIgnored private var expiring: Set<String> = []

    /// Take the shows past the day limit off Next Up on the server, one after
    /// another and without holding up the row, which already leaves them out.
    /// A failure is left for the next time the row is asked for.
    private func reportExpired(_ seriesIds: [String]) {
        let fresh = seriesIds.filter { !expiring.contains($0) }
        guard !fresh.isEmpty else { return }
        expiring.formUnion(fresh)
        Task {
            for id in fresh {
                do {
                    try await removeFromNextUp(seriesId: id)
                } catch {
                    Self.nextUpLog.error("Couldn't take \(id, privacy: .public) off Next Up: \(error.localizedDescription, privacy: .public)")
                }
                expiring.remove(id)
            }
        }
    }

    nonisolated static let nextUpLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Aquarium", category: "nextup")

    /// Take a show off Next Up, on the server, without touching what has been
    /// watched. Next Up is built from the episodes with a last-played date;
    /// Jellyfin reads the earliest date there is as none, so each of the
    /// show's dated episodes is given that one (`HomeRows.notPlayedDate`).
    /// Watched marks, play counts and positions stay as they were — an
    /// episode left partway is still in Continue Watching, at the end of it.
    ///
    /// The show comes back when an episode of it is played, or when it is
    /// added to Next Up again. Not for a new episode — nothing of it counts
    /// as watched lately — and not for an episode marked watched by hand,
    /// which keeps the date it had.
    ///
    /// Servers before 10.9 have no way to write a date on its own and answer
    /// 404, which is thrown.
    func removeFromNextUp(seriesId: String) async throws {
        guard let s = prefs.session else { throw APIError.notConfigured }
        let episodes = try await get(
            ItemsResponse.self,
            "/Shows/\(Self.pathId(seriesId))/Episodes?userId=\(s.userId)&Fields=\(Self.itemFields)"
        ).items
        for episode in episodes where HomeRows.hasPlayedDate(episode) {
            try await request(
                "/UserItems/\(Self.pathId(episode.Id))/UserData?userId=\(s.userId)", method: "POST",
                body: ["LastPlayedDate": HomeRows.notPlayedDate]
            )
            LibraryIndex.shared.patchUserData(episode.Id) { $0.LastPlayedDate = HomeRows.notPlayedDate }
        }
    }

    /// Where "Add to Next Up" picks a show up: after what has been watched,
    /// or from its first episode with everything watched before forgotten.
    enum NextUpStart: Sendable {
        case lastWatched, firstEpisode
    }

    /// Put a show on Next Up, on the server, so every app signed in to the
    /// account — this one on other devices, Jellyfin's own, the Linux one —
    /// shows it there. Returns the episode it will be offered at, or nil when
    /// every episode has been watched and there is nothing to offer.
    ///
    /// Jellyfin has no call for this. It builds Next Up from the shows with
    /// an episode that has a last-played date — played or not — offers the
    /// first unwatched episode after the last one *watched*, and orders the
    /// row by when that last watched episode was played. So:
    ///
    /// - `.lastWatched` gives today as the last-played date to the last
    ///   watched episode. The show goes to the front of the row everywhere,
    ///   and back inside the day limit (`Preferences.nextUpDays`). Writing
    ///   the date on the episode to be offered instead, as this used to, got
    ///   the show onto Next Up at wherever its old date put it — often past
    ///   the row's 16 cards, so the add looked like it did nothing.
    /// - `.firstEpisode` marks the whole show unwatched — play counts, saved
    ///   positions and dates all go — and gives the first episode today. A
    ///   show with nothing watched is one Jellyfin puts at the *end* of Next
    ///   Up; `HomeRows.newStartsFirst` brings it to the front of this app's.
    ///
    /// Nothing is marked watched and nothing goes into Continue Watching: a
    /// few seconds of progress would have, and Next Up leaves in-progress
    /// episodes out unless asked for them.
    ///
    /// Servers before 10.9 have no way to write a date on its own and answer
    /// 404, which is thrown.
    private struct NextUpDating: Encodable {
        var LastPlayedDate: String
        var Played: Bool
        var PlayCount: Int
        var PlaybackPositionTicks: Int64
    }

    func addToNextUp(seriesId: String, from start: NextUpStart) async throws -> BaseItem? {
        guard let s = prefs.session else { throw APIError.notConfigured }
        // From the server, not the library copy: which episodes are watched
        // is the whole question, and the copy can be behind on it.
        let all = try await get(
            ItemsResponse.self,
            "/Shows/\(Self.pathId(seriesId))/Episodes?userId=\(s.userId)&Fields=\(Self.itemFields)"
        ).items
        let target: BaseItem
        let dated: BaseItem
        switch start {
        case .lastWatched:
            guard let next = HomeRows.nextUpTarget(all) else { return nil }
            target = next
            dated = HomeRows.lastWatched(all) ?? next
        case .firstEpisode:
            guard let first = HomeRows.firstEpisode(all) else { return nil }
            try await request("/UserPlayedItems/\(Self.pathId(seriesId))?userId=\(s.userId)", method: "DELETE")
            for episode in all {
                LibraryIndex.shared.patchUserData(episode.Id) {
                    $0.Played = false
                    $0.PlaybackPositionTicks = 0
                    $0.LastPlayedDate = nil
                }
            }
            target = first
            dated = first
        }
        // The episode's whole state goes with the date. Sent alone, the date
        // is written over what the server last remembered of the episode —
        // after the show was marked unwatched, that is the watched mark and
        // play count it had a moment before.
        let started = start == .lastWatched
        let state = NextUpDating(
            LastPlayedDate: ISO8601DateFormatter().string(from: Date()),
            Played: started && dated.userData.played,
            PlayCount: started ? dated.UserData?.PlayCount ?? 0 : 0,
            PlaybackPositionTicks: started ? dated.userData.positionTicks : 0
        )
        try await request(
            "/UserItems/\(Self.pathId(dated.Id))/UserData?userId=\(s.userId)", method: "POST",
            body: state
        )
        LibraryIndex.shared.patchUserData(dated.Id) { $0.LastPlayedDate = state.LastPlayedDate }
        prefs.unhideFromNextUp(seriesId: seriesId)
        return target
    }

    /// The one episode the user should watch next in a series — the in-progress
    /// one, else the first unwatched. Nil when the server has nothing queued.
    ///
    /// The in-progress episode is asked of Resume, not left to Next Up. Next Up
    /// works forward from the last episode marked *watched*, so someone who
    /// joined a show at its latest season — half-way through S29E3, nothing
    /// before it played — was offered S1E1, and Play started the show over.
    func seriesNextUp(seriesId: String) async throws -> BaseItem? {
        guard let s = prefs.session else { throw APIError.notConfigured }
        let resumeQuery: [URLQueryItem] = [
            .init(name: "userId", value: s.userId),
            .init(name: "parentId", value: seriesId),
            .init(name: "Limit", value: "1"),
            .init(name: "MediaTypes", value: "Video"),
            .init(name: "Fields", value: Self.itemFields),
            .init(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb,Logo"),
        ]
        let nextQuery: [URLQueryItem] = [
            .init(name: "userId", value: s.userId),
            .init(name: "seriesId", value: seriesId),
            .init(name: "Limit", value: "1"),
            .init(name: "Fields", value: Self.itemFields),
            .init(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb,Logo"),
        ]
        async let resumed = try? get(ItemsResponse.self, "/UserItems/Resume?\(Self.encode(resumeQuery))").items
        async let next = get(ItemsResponse.self, "/Shows/NextUp?\(Self.encode(nextQuery))").items.first
        // Only an episode of this series: an older server ignoring parentId
        // would hand back whatever was last left part-way, film or show.
        if let inProgress = await resumed?.first(where: { $0.isEpisode && $0.SeriesId == seriesId }) {
            return inProgress
        }
        return try await next
    }

    /// A handful of films and shows from the whole library, drawn at random —
    /// what the media bar at the top of Home rotates through.
    ///
    /// The server re-rolls `SortBy=Random` on every call, which is the point:
    /// the top of Home is a different set of things each time you arrive at it,
    /// rather than the same Continue Watching entry with a picture on top.
    ///
    /// Only titles the server has a backdrop for — a portrait poster stretched
    /// across a 16:9 band is worse than not being featured at all. `ImageTypes`
    /// asks the server to filter, but an older one ignores the parameter, so the
    /// answer is filtered again here and over-fetched to cover what that drops.
    func spotlight(limit: Int = 6) async throws -> [BaseItem] {
        guard let s = prefs.session else { throw APIError.notConfigured }
        let q = [
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "Random"),
            URLQueryItem(name: "Limit", value: String(limit * 2)),
            URLQueryItem(name: "ImageTypes", value: "Backdrop"),
            URLQueryItem(name: "Fields", value: Self.listFields),
            URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb,Logo"),
        ]
        let items = try await get(ItemsResponse.self, "/Items?userId=\(s.userId)&\(Self.encode(q))").items
        return Array(items.filter { Artwork.url($0, type: "Backdrop") != nil }.prefix(limit))
    }

    /// Newest additions to a library, with every episode folded into its series
    /// so a TV row reads as "shows with something new" rather than mixing shows
    /// and bare episodes — the server's own grouping only does half of this.
    func latest(parentId: String, limit: Int = 16) async throws -> [BaseItem] {
        guard let s = prefs.session else { throw APIError.notConfigured }
        let items = try await get(
            [BaseItem].self,
            "/Items/Latest?userId=\(s.userId)&parentId=\(Self.pathId(parentId))&Limit=\(limit)&Fields=\(Self.itemFields)"
        )
        return try await foldEpisodesIntoSeries(items.filter { !$0.isNotVideo })
    }

    /// Whether a library Jellyfin hasn't typed holds audio (audiobooks,
    /// songs, e-books) and no video at all — a books folder in all but name,
    /// which the video Library has no business listing. False whenever the
    /// server can't be asked, so a library is never hidden on a guess.
    func isAudioOnlyLibrary(_ libraryId: String) async -> Bool {
        guard let s = prefs.session else { return false }
        @Sendable func count(_ name: String, _ value: String) async -> Int? {
            let q = [
                URLQueryItem(name: "ParentId", value: libraryId),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: name, value: value),
                URLQueryItem(name: "Limit", value: "0"),
            ]
            return try? await get(ItemsResponse.self, "/Items?userId=\(s.userId)&\(Self.encode(q))", countsForOffline: false).total
        }
        async let video = count("MediaTypes", "Video")
        async let other = count("IncludeItemTypes", "Audio,AudioBook,Book")
        guard let v = await video, let o = await other else { return false }
        return v == 0 && o > 0
    }

    /// The kinds a video screen never lists. A library Jellyfin hasn't typed
    /// ("mixed content") can hold audiobooks, songs or e-books beside the
    /// films, and its Latest row and grid used to show them — on the
    /// television, where nothing can play them.
    nonisolated static let nonVideoTypes = "Audio,AudioBook,Book,MusicAlbum,MusicArtist,Photo,PhotoAlbum"

    /// Replace every episode with its series, keeping the row's order and
    /// dropping the duplicates that leaves behind.
    private func foldEpisodesIntoSeries(_ items: [BaseItem]) async throws -> [BaseItem] {
        let episodes = items.filter { $0.isEpisode && $0.SeriesId != nil }
        guard !episodes.isEmpty else { return items }

        var series: [String: BaseItem] = [:]
        for i in items where i.isSeries { series[i.Id] = i }
        let missing = Array(Set(episodes.compactMap(\.SeriesId))).filter { series[$0] == nil }
        if !missing.isEmpty {
            // A failed lookup leaves the episode where it was: a row with one
            // odd card is better than a row that quietly lost a title.
            let fetched = (try? await itemsByIds(missing, fields: Self.itemFields)) ?? []
            for s in fetched { series[s.Id] = s }
        }

        var seen = Set<String>()
        var out: [BaseItem] = []
        for item in items {
            let card = (item.isEpisode ? item.SeriesId.flatMap { series[$0] } : nil) ?? item
            if !card.Id.isEmpty {
                if seen.contains(card.Id) { continue }
                seen.insert(card.Id)
            }
            out.append(card)
        }
        return out
    }

    struct LibraryQuery: Sendable {
        var startIndex: Int = 0
        var limit: Int = 60
        var includeTypes: String?
        var sortBy: String = "SortName"
        var sortOrder: String = "Ascending"
        /// Only items with something left to watch.
        var unwatched: Bool = false
        var favorites: Bool = false
        var genre: String?
        /// Only names that sort before this, lowercased: with `limit` 1 the
        /// answer's total is where a letter starts in the name order. See
        /// `LetterIndex`.
        var nameLessThan: String?
    }

    func libraryItems(parentId: String, query: LibraryQuery = .init()) async throws -> ItemsResponse {
        guard let s = prefs.session else { throw APIError.notConfigured }
        if let local = LibraryIndex.shared.libraryItems(parentId: parentId, query: query) { return local }
        var q = [
            URLQueryItem(name: "ParentId", value: parentId),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: query.sortBy),
            URLQueryItem(name: "SortOrder", value: query.sortOrder),
            URLQueryItem(name: "Fields", value: Self.listFields),
            URLQueryItem(name: "StartIndex", value: String(query.startIndex)),
            URLQueryItem(name: "Limit", value: String(query.limit)),
        ]
        if let t = query.includeTypes {
            q.append(.init(name: "IncludeItemTypes", value: t))
        } else {
            q.append(.init(name: "ExcludeItemTypes", value: Self.nonVideoTypes))
        }
        if query.unwatched { q.append(.init(name: "Filters", value: "IsUnplayed")) }
        if query.favorites { q.append(.init(name: "IsFavorite", value: "true")) }
        if let g = query.genre { q.append(.init(name: "Genres", value: g)) }
        if let letter = query.nameLessThan { q.append(.init(name: "NameLessThan", value: letter.lowercased())) }
        return try await get(ItemsResponse.self, "/Items?userId=\(s.userId)&\(Self.encode(q))")
    }

    /// Everything the user has starred, across every library.
    func favorites(
        startIndex: Int = 0,
        limit: Int = 60,
        includeTypes: String = "Movie,Series,Episode",
        sortBy: String = "SortName",
        sortOrder: String = "Ascending"
    ) async throws -> ItemsResponse {
        guard let s = prefs.session else { throw APIError.notConfigured }
        if let local = LibraryIndex.shared.favorites(
            startIndex: startIndex, limit: limit, includeTypes: includeTypes, sortBy: sortBy, sortOrder: sortOrder
        ) { return local }
        let q = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Filters", value: "IsFavorite"),
            URLQueryItem(name: "IncludeItemTypes", value: includeTypes),
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: sortOrder),
            URLQueryItem(name: "Fields", value: Self.listFields),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit)),
        ]
        return try await get(ItemsResponse.self, "/Items?userId=\(s.userId)&\(Self.encode(q))")
    }

    /// Genre names present in one library, for the filter bar. Empty on servers
    /// that don't answer the filters endpoint — the control is then hidden.
    func genres(parentId: String, includeTypes: String?) async throws -> [String] {
        guard let s = prefs.session else { throw APIError.notConfigured }
        var q = [
            URLQueryItem(name: "userId", value: s.userId),
            URLQueryItem(name: "parentId", value: parentId),
        ]
        if let includeTypes, !includeTypes.isEmpty {
            q.append(.init(name: "IncludeItemTypes", value: includeTypes))
        }
        let r = try await get(FiltersResponse.self, "/Items/Filters?\(Self.encode(q))")
        return (r.Genres ?? []).filter { !$0.isEmpty }.sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    func item(_ itemId: String) async throws -> BaseItem {
        guard let s = prefs.session else { throw APIError.notConfigured }
        // Asked of the server whenever it can be, for the cast and studios the
        // copy doesn't keep; the copy answers when it can't.
        do {
            return try await get(BaseItem.self, "/Items/\(Self.pathId(itemId))?userId=\(s.userId)&Fields=\(Self.detailFields)")
        } catch APIError.offline(let message) {
            if let local = LibraryIndex.shared.item(itemId) { return local }
            throw APIError.offline(message)
        }
    }

    /// Everything in the library a person had a part in, newest first. Films
    /// and shows only: an actor in a long-running series is otherwise three
    /// hundred episode tiles with the films lost somewhere among them.
    func items(withPerson personId: String, types: String = "Movie,Series", limit: Int = 200) async throws -> [BaseItem] {
        guard let s = prefs.session else { throw APIError.notConfigured }
        let q = [
            URLQueryItem(name: "PersonIds", value: personId),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: types),
            URLQueryItem(name: "SortBy", value: "PremiereDate,ProductionYear,SortName"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Fields", value: Self.listFields),
            URLQueryItem(name: "Limit", value: String(limit)),
        ]
        return try await get(ItemsResponse.self, "/Items?userId=\(s.userId)&\(Self.encode(q))").items
    }

    /// The trailer files kept beside a title on the server. Playable like any
    /// other item. Empty on any failure — a trailer is never worth an error.
    func localTrailers(for itemId: String) async -> [BaseItem] {
        guard let s = prefs.session else { return [] }
        return (try? await get([BaseItem].self, "/Items/\(Self.pathId(itemId))/LocalTrailers?userId=\(s.userId)")) ?? []
    }

    /// "More like this" — the server's own recommendation. Purely additive to
    /// the detail page, so callers treat a failure as an empty list.
    func similar(to itemId: String, limit: Int = 12) async throws -> [BaseItem] {
        guard let s = prefs.session else { throw APIError.notConfigured }
        return try await get(
            ItemsResponse.self,
            "/Items/\(Self.pathId(itemId))/Similar?userId=\(s.userId)&limit=\(limit)&Fields=\(Self.listFields)"
        ).items
    }

    func seasons(seriesId: String) async throws -> [BaseItem] {
        guard let s = prefs.session else { throw APIError.notConfigured }
        if let local = LibraryIndex.shared.seasons(seriesId: seriesId) { return local }
        return try await get(
            ItemsResponse.self,
            "/Shows/\(Self.pathId(seriesId))/Seasons?userId=\(s.userId)&Fields=\(Self.listFields)"
        ).items
    }

    func episodes(seriesId: String, seasonId: String?) async throws -> [BaseItem] {
        guard let s = prefs.session else { throw APIError.notConfigured }
        if let local = LibraryIndex.shared.episodes(seriesId: seriesId, seasonId: seasonId) { return local }
        var path = "/Shows/\(Self.pathId(seriesId))/Episodes?userId=\(s.userId)&Fields=\(Self.itemFields)"
        if let seasonId { path += "&seasonId=\(seasonId)" }
        return try await get(ItemsResponse.self, path).items
    }

    func search(
        _ term: String,
        startIndex: Int = 0,
        limit: Int = 48,
        types: String = "Movie,Series,Episode"
    ) async throws -> ItemsResponse {
        guard let s = prefs.session else { throw APIError.notConfigured }
        let q = [
            URLQueryItem(name: "searchTerm", value: term),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: types),
            URLQueryItem(name: "Fields", value: Self.listFields),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit)),
        ]
        return try await get(ItemsResponse.self, "/Items?userId=\(s.userId)&\(Self.encode(q))")
    }

    /// Every channel, a page at a time. One request capped at 500 used to be
    /// the whole of it, and a lineup bigger than that — an IPTV source behind
    /// the server's own tuner list easily is — simply ended at channel 500.
    func channels() async throws -> [BaseItem] {
        guard let s = prefs.session else { throw APIError.notConfigured }
        let pageSize = 500
        var all: [BaseItem] = []
        while true {
            let page = try await get(
                ItemsResponse.self,
                "/LiveTv/Channels?userId=\(s.userId)&AddCurrentProgram=true&EnableImageTypes=Primary"
                    + "&StartIndex=\(all.count)&Limit=\(pageSize)"
            )
            all += page.items
            // A page short of full is the last, and so is a total reached; a
            // server that sends no total is read by the first rule alone. The
            // ceiling is for one that ignores StartIndex and never runs out.
            guard page.items.count == pageSize, all.count < 10_000,
                  all.count < page.total || page.TotalRecordCount == nil
            else { break }
        }
        return all
    }

    /// The guide: every programme airing on the given channels that overlaps
    /// `start...end`, for the TV Guide grid. `MinEndDate`/`MaxStartDate`
    /// rather than a plain start/end match is what pulls in the programme
    /// already playing when the window opens, not just ones that start inside it.
    private static let programsISO: ISO8601DateFormatter = {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso
    }()

    func programs(channelIds: [String], start: Date, end: Date) async throws -> [BaseItem] {
        guard let s = prefs.session, !channelIds.isEmpty else { return [] }
        let iso = Self.programsISO
        let q = [
            URLQueryItem(name: "UserId", value: s.userId),
            URLQueryItem(name: "ChannelIds", value: channelIds.joined(separator: ",")),
            URLQueryItem(name: "MinEndDate", value: iso.string(from: start)),
            URLQueryItem(name: "MaxStartDate", value: iso.string(from: end)),
            URLQueryItem(name: "SortBy", value: "StartDate"),
            URLQueryItem(name: "EnableTotalRecordCount", value: "false"),
            URLQueryItem(name: "EnableImages", value: "false"),
            URLQueryItem(name: "Limit", value: "5000"),
        ]
        return try await get(
            ItemsResponse.self, "/LiveTv/Programs?\(Self.encode(q))", countsForOffline: false
        ).items
    }

    /// Items for a batch of ids, 50 per request.
    func itemsByIds(_ ids: [String], fields: String = "", countsForOffline: Bool = true) async throws -> [BaseItem] {
        guard let s = prefs.session else { throw APIError.notConfigured }
        var out: [BaseItem] = []
        for chunk in stride(from: 0, to: ids.count, by: 50) {
            let slice = ids[chunk..<min(chunk + 50, ids.count)].joined(separator: ",")
            var path = "/Items?userId=\(s.userId)&Ids=\(slice)"
            if !fields.isEmpty { path += "&Fields=\(fields)" }
            out += try await get(ItemsResponse.self, path, countsForOffline: countsForOffline).items
        }
        return out
    }

    // MARK: - Watch state

    func markPlayed(_ itemId: String, played: Bool) async throws {
        try await markPlayed(itemId, played: played, at: nil)
    }

    /// The same, with a date: given one, the server adds a play to the
    /// count and sets "last played" to it, which is how a song heard on the
    /// Apple Watch from the watch's own copy gets counted. Without one it
    /// only marks the item played.
    func markPlayed(_ itemId: String, played: Bool, at date: Date?) async throws {
        guard let s = prefs.session else { throw APIError.notConfigured }
        var path = "/UserPlayedItems/\(Self.pathId(itemId))?userId=\(s.userId)"
        if played, let date {
            path += "&datePlayed=\(ISO8601DateFormatter().string(from: date))"
        }
        try await request(path, method: played ? "POST" : "DELETE")
        LibraryIndex.shared.patchUserData(itemId) {
            $0.Played = played
            $0.PlaybackPositionTicks = 0
        }
    }

    /// Forget where an item was left: its saved position goes to zero, so it
    /// drops out of Continue Watching everywhere, while its played state,
    /// play count and last-played date are left as they were. Nothing here
    /// counts as a play, so a show's Next Up is not moved by it — which is
    /// why the stale episodes Home tidies (see `HomeRows.abandoned`) are
    /// cleared rather than marked played.
    ///
    /// Servers from 10.9 take the position straight into the item's user
    /// data. An older one has no such call and answers 404, and is instead
    /// told the item was stopped at the very start, which it records the
    /// same way — below its minimum resume point, the position is dropped
    /// and nothing is marked played. That fallback keeps the old
    /// `/Users/{id}/…` spelling on purpose: it is only ever reached by a
    /// server from before the routes everything else here now uses.
    func clearProgress(_ itemId: String) async throws {
        guard let s = prefs.session else { throw APIError.notConfigured }
        let id = Self.pathId(itemId)
        do {
            try await request(
                "/UserItems/\(id)/UserData?userId=\(s.userId)", method: "POST",
                body: ["PlaybackPositionTicks": 0]
            )
        } catch APIError.server(let status, _) where status == 404 {
            try await request("/Users/\(s.userId)/PlayingItems/\(id)?positionTicks=0", method: "DELETE")
        }
        LibraryIndex.shared.patchUserData(itemId) { $0.PlaybackPositionTicks = 0 }
    }

    func setFavorite(_ itemId: String, favorite: Bool) async throws {
        guard let s = prefs.session else { throw APIError.notConfigured }
        try await request("/UserFavoriteItems/\(Self.pathId(itemId))?userId=\(s.userId)", method: favorite ? "POST" : "DELETE")
        LibraryIndex.shared.patchUserData(itemId) { $0.IsFavorite = favorite }
    }

    // MARK: - Trickplay

    /// Trickplay metadata for an item, or nil when the server has none — which
    /// is the common case: tiles come from a scheduled task many installs never
    /// run. Callers fall back to a plain time readout.
    func trickplay(itemId: String) async throws -> TrickplayInfo? {
        guard let s = prefs.session else { return nil }
        guard let env = try? await get(
            TrickplayEnvelope.self,
            "/Items/\(Self.pathId(itemId))?userId=\(s.userId)&Fields=Trickplay"
        ) else { return nil }
        return Self.trickplayInfo(env.Trickplay, sourceId: env.MediaSources?.first?.Id, itemId: itemId)
    }

    /// Trickplay from an item fetched through the detail endpoint, which asks
    /// for it — nil when the server has none.
    nonisolated static func trickplayInfo(for item: BaseItem) -> TrickplayInfo? {
        trickplayInfo(item.Trickplay, sourceId: item.MediaSources?.first?.Id, itemId: item.Id)
    }

    private nonisolated static func trickplayInfo(
        _ tiles: [String: [String: TrickplayTileInfo]]?, sourceId: String?, itemId: String
    ) -> TrickplayInfo? {
        let byWidth = (sourceId.flatMap { tiles?[$0] }) ?? tiles?.values.first
        guard let byWidth else { return nil }
        // Several resolutions may exist; the widest still fits in a bubble.
        let widths = byWidth.keys.compactMap(Int.init).filter { $0 > 0 }.sorted(by: >)
        guard let widest = widths.first, let info = byWidth[String(widest)],
              let w = info.Width, let interval = info.Interval, interval > 0
        else { return nil }
        return TrickplayInfo(
            itemId: itemId,
            width: w,
            height: info.Height ?? Int(Double(w) * 0.5625),
            tileWidth: info.TileWidth ?? 1,
            tileHeight: info.TileHeight ?? 1,
            interval: interval,
            thumbnailCount: info.ThumbnailCount ?? 0
        )
    }

    /// One trickplay tile sheet. These need the access token, so unlike every
    /// other image in the app they are fetched through this client.
    func trickplayTile(_ info: TrickplayInfo, tileIndex: Int) async throws -> Data {
        try await request("/Videos/\(Self.pathId(info.itemId))/Trickplay/\(info.width)/\(tileIndex).jpg")
    }

    // MARK: - Media segments

    /// Skippable stretches of an item. Jellyfin 10.10 and up, and only for
    /// items some plugin has analysed; everything else answers 404 or an empty
    /// list, and the skip button never appears.
    func mediaSegments(itemId: String) async throws -> [MediaSegment] {
        guard let r = try? await get(
            MediaSegmentsResponse.self,
            "/MediaSegments/\(Self.pathId(itemId))?includeSegmentTypes=Intro,Outro"
        ) else { return [] }
        return (r.Items ?? []).map {
            MediaSegment(
                type: $0.type ?? "",
                start: Double($0.StartTicks ?? 0) / 10_000_000,
                end: Double($0.EndTicks ?? 0) / 10_000_000
            )
        }.filter { $0.end > $0.start }
    }

    // MARK: - Playback resolution

    /// Ask the server how this item should be played, given what AVFoundation
    /// can actually open. Everything the profile can't direct-play comes back as
    /// an HLS transcode URL instead.
    ///
    /// `fullEncode` is the sync repair: it strips the server's freedom to copy
    /// one bitstream through while re-encoding the other. See `withoutStreamCopy`.
    ///
    /// `audioStreamIndex` and `subtitleStreamIndex` are the file's own track
    /// numbers, as the server numbers them. They are how a track that isn't in
    /// the stream gets into it: a transcode carries one audio track and the
    /// subtitles the request asked for, so choosing another of either is a
    /// question for the server rather than something `AVPlayerItem` can be told.
    /// `nil` leaves the choice to the server's own defaults; `-1` for the
    /// subtitle means none, which is Jellyfin's own spelling of off.
    func resolvePlayback(
        itemId: String,
        maxBitrate: Int? = nil,
        forceTranscode: Bool = false,
        live: Bool = false,
        startTicks: Int64 = 0,
        fullEncode: Bool = false,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil,
        audio: Bool = false,
        engine: PlaybackEngineKind = .platformDefault
    ) async throws -> PlaybackSource {
        guard let s = prefs.session else { throw APIError.notConfigured }
        // A song is asked about with the music profile — a different set of
        // containers, no subtitles, an audio-only transcode — and answered
        // from the audio route. See `DeviceProfile.buildMusic`.
        //
        // Video is asked about with the profile of the engine that will play
        // it, which `EnginePolicy` chose before this call: mpv opens what
        // AVFoundation can't — see `DeviceProfile.buildMPV`.
        let profile: DeviceProfile
        if audio {
            profile = DeviceProfile.buildMusic(maxBitrate: maxBitrate)
        } else {
            switch engine {
            case .mpv:
                profile = DeviceProfile.buildMPV(
                    forceTranscode: forceTranscode,
                    maxBitrate: maxBitrate,
                    stereoOnly: prefs.stereoDownmix
                )
            case .apple:
                profile = DeviceProfile.build(
                    forceTranscode: forceTranscode,
                    maxBitrate: maxBitrate,
                    stereoOnly: prefs.stereoDownmix,
                    decodeAudioLocally: prefs.decodeAudioLocally,
                    subtitlesInManifest: (subtitleStreamIndex ?? -1) >= 0
                )
            }
        }
        let body = PlaybackInfoBody(
            UserId: s.userId,
            StartTimeTicks: startTicks,
            IsPlayback: true,
            AutoOpenLiveStream: !audio,
            MaxStreamingBitrate: maxBitrate,
            DeviceProfile: profile,
            EnableDirectPlay: !forceTranscode,
            EnableDirectStream: !forceTranscode,
            EnableTranscoding: true,
            AudioStreamIndex: audioStreamIndex,
            SubtitleStreamIndex: subtitleStreamIndex
        )
        // A live channel is given the time it takes — see `patientTimeout`.
        // And a slow tuner is not the server being gone, so it is not counted
        // toward the offline flag either.
        let data = try await request(
            "/Items/\(Self.pathId(itemId))/PlaybackInfo", method: "POST", body: body,
            countsForOffline: !live, patient: live
        )
        let info = try await Self.decode(PlaybackInfoResponse.self, from: data)
        guard let ms = info.MediaSources?.first else {
            throw APIError.message("No playable media source returned by the server")
        }
        let playSessionId = info.PlaySessionId ?? UUID().uuidString

        // Anything the profile refused goes down the HLS path.
        //
        // Live channels used to be sent down it unconditionally — `live` sat in
        // the condition below and short-circuited the direct-stream check. That
        // is what made every single Live TV channel a real-time ffmpeg encode,
        // including the H.264/AAC ones this device could have remuxed or read
        // untouched. A live transcode has no slack in it: the encoder is racing
        // the broadcast, and the moment it falls behind, the playlist stops
        // growing and the client stalls. Which is the freeze, not the network.
        // So live is decided the same way everything else is, by what the
        // source supports and what `DeviceProfile` says this client can open.
        //
        // The URL is taken as the server wrote it, with one exception below.
        // In particular `CopyTimestamps` is not added: Jellyfin leaves it off,
        // which is right for this client, because the offset a stream starts at
        // is seeked to *here* once the playlist is readable — see
        // `PlayerModel.attach`. Turning it on hands ffmpeg the source's own
        // timestamps, and the client-side seek then lands somewhere other than
        // where it was asked to. It is a plausible-looking fix for a desync and
        // it makes the resume position wrong instead.
        //
        // The rule itself is `StreamPlan.decide`, written down once so it can
        // be tested: mpv opens whatever the server offers untouched, so only
        // a song, and video on AVPlayer, still go through `DeviceProfile`'s
        // check of what this client can open.
        let engineCanOpen: Bool = {
            if audio { return DeviceProfile.canDirectPlayAudio(ms) }
            switch engine {
            case .mpv: return true
            case .apple: return DeviceProfile.canDirectPlay(ms)
            }
        }()
        let plan = StreamPlan.decide(source: ms, forceTranscode: forceTranscode, live: live, engineCanOpen: engineCanOpen)
        if plan == .transcode, let transcodingUrl = ms.TranscodingUrl {
            // A path, and one that still leads to this server once joined to
            // its address: "@elsewhere/…" parses as a different host with the
            // server's own name as the user part, and the auth header would
            // follow it there.
            guard transcodingUrl.hasPrefix("/"),
                  let url = URL(string: s.server + transcodingUrl), isSessionOrigin(url)
            else {
                throw APIError.message("The server returned a stream URL this client couldn't parse")
            }
            var stream = fullEncode ? Self.withoutStreamCopy(url) : url
            stream = Self.carrying(
                audioStreamIndex: audioStreamIndex,
                subtitleStreamIndex: subtitleStreamIndex,
                in: stream
            )
            if engine == .apple {
                stream = Self.subtitleTimedSegments(stream, source: ms, audioStreamIndex: audioStreamIndex)
            }
            if Self.claimsHDRItCannotCarry(ms) {
                stream = await variantPlaylist(of: stream) ?? stream
            }
            return PlaybackSource(
                url: stream,
                isTranscode: true, mediaSourceId: ms.Id ?? "",
                playSessionId: playSessionId, live: live, mediaSource: ms
            )
        }

        // The server is offering the original file. Before taking it, check
        // that this client can actually open what's inside — the server is not
        // always right about that, and every way it can be wrong ends with a
        // black screen instead of a picture. Where the two disagree, ask again
        // with direct play and direct stream switched off, which leaves the
        // server nothing to answer with but a transcode.
        //
        // Once only, and guarded on `forceTranscode` so the second call can't
        // start a third. If that call still comes back with a direct source —
        // an old server that ignores the flags, a source it genuinely cannot
        // transcode — the original is used after all: a stream that probably
        // won't play beats no stream at all, and the player escalates again
        // from the other end if it turns out we were right. See
        // `PlayerModel.escalateToTranscode`.
        // Live included, now that a live channel can reach here at all. Without
        // this, dropping `live` from the condition above would trade one fault
        // for a worse one: a channel carrying a codec AVFoundation can't decode
        // would be direct-played into a black screen rather than transcoded.
        //
        // The empty-container clause is live's alone, and it is the hole the
        // change above would otherwise have opened. `canDirectPlay` skips the
        // container test when the server names no container, which is fine for
        // a library file — there is one on disk and ffprobe read it — and not
        // fine for a tuner, where "no container" is the normal answer and the
        // bytes are very often MPEG-TS. The direct URL below would then be
        // built as `stream.mp4`, `static=true` would send the transport stream
        // underneath it unchanged, and AVFoundation would open a file it cannot
        // read. A live source that won't say what it is gets transcoded.
        if plan == .escalate {
            if let escalated = try? await resolvePlayback(
                itemId: itemId,
                maxBitrate: maxBitrate,
                forceTranscode: true,
                live: live,
                startTicks: startTicks,
                fullEncode: fullEncode,
                audioStreamIndex: audioStreamIndex,
                subtitleStreamIndex: subtitleStreamIndex,
                audio: audio,
                engine: engine
            ), escalated.isTranscode {
                return escalated
            }
        }

        // Direct stream of the original file. No `api_key` in the URL: the token
        // goes on the request as a header instead (see AVAssetLoader), which
        // keeps it out of Jellyfin's access log.
        let container = ms.Container ?? "mp4"
        var q = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "mediaSourceId", value: ms.Id ?? ""),
            URLQueryItem(name: "playSessionId", value: playSessionId),
            URLQueryItem(name: "deviceId", value: s.deviceId),
        ]
        if let live = ms.LiveStreamId { q.append(.init(name: "liveStreamId", value: live)) }
        if let tag = ms.ETag { q.append(.init(name: "Tag", value: tag)) }
        // A song comes from the audio route. The video one happens to serve
        // it too, today, but the audio one is the documented door.
        let route = audio ? "Audio" : "Videos"
        guard let url = URL(string: "\(s.server)/\(route)/\(Self.pathId(itemId))/stream.\(container)?\(Self.encode(q))") else {
            throw APIError.message("Couldn't build a stream URL for this item")
        }
        return PlaybackSource(
            url: url, isTranscode: false, mediaSourceId: ms.Id ?? "",
            playSessionId: playSessionId, live: live, mediaSource: ms
        )
    }

    /// An H.264 picture tagged as HDR: a thing that does not exist as far as
    /// AVFoundation's HLS reader goes, and that a Tunarr channel made from a
    /// UHD film produces every time. Tunarr re-encodes the film to 8-bit H.264
    /// and leaves the source's PQ / BT.2020 colour tags in the bitstream;
    /// Jellyfin copies that bitstream through, so the tags arrive here intact.
    ///
    /// Behind a master playlist that picture is refused outright —
    /// `CoreMediaErrorDomain -12927`, a spinner and then the error card, on
    /// exactly the channels built from 4K films and none of the others (Sept
    /// 2026: the Harry Potter and Star Wars channels, with every cartoon
    /// channel beside them playing). It is not what the master *says*: tried
    /// against a segment saved from the channel, a master claiming
    /// `VIDEO-RANGE=PQ`, one claiming `SDR`, one claiming nothing and one with
    /// a bare `BANDWIDTH` all failed the same way, and the same master over a
    /// BT.709 segment played. The media playlist opened by itself plays the
    /// very same segment, PQ tags and all. So the way through is to not have a
    /// master — see `variantPlaylist`.
    static func claimsHDRItCannotCarry(_ ms: MediaSource) -> Bool {
        guard let video = ms.streams.first(where: { $0.type == "Video" }) else { return false }
        return video.Codec?.lowercased() == "h264" && video.VideoRange?.uppercased() == "HDR"
    }

    /// The first variant inside a master playlist, as an absolute URL.
    ///
    /// The way round the refusal above: the variant a master points at is an
    /// ordinary media playlist over the same stream, and opened by itself it
    /// plays. The first variant is the stream-copied one — the second is the
    /// server's tone-mapped re-encode, a real-time encode of a live channel,
    /// which is the thing `resolvePlayback` goes out of its way not to ask for.
    /// Nil on any failure, and the caller keeps the master: no worse than before.
    private func variantPlaylist(of master: URL) async -> URL? {
        var req = URLRequest(url: master)
        authHeaders(for: master).forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        guard let (data, response) = try? await perform(req, patient: false),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let tag = lines.firstIndex(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }),
              let uri = lines[(tag + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") })
        else { return nil }
        return URL(string: uri, relativeTo: master)?.absoluteURL
    }

    /// Take away the server's freedom to copy a bitstream through, so both
    /// streams are encoded together off one timebase.
    ///
    /// This is the repair for a transcode that arrives out of sync. Left to
    /// itself, ffmpeg will carry an H.264 or HEVC picture across untouched
    /// while re-encoding an audio track this device can't decode — and the two
    /// are then timed against different things, with a start offset landing on
    /// a video keyframe the audio was never cut at. Turning all three switches
    /// off is more work for the server and the only thing that reaches the
    /// cause; the client has no way to shift an HLS audio track after the fact.
    private static func withoutStreamCopy(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let forced = ["EnableAutoStreamCopy", "AllowVideoStreamCopy", "AllowAudioStreamCopy"]
        // `percentEncodedQueryItems` rather than `queryItems`: this URL is the
        // server's own and carries its own token, and decoding the whole thing
        // here only to encode it again is a chance to change something we were
        // handed. The three values written below need no encoding.
        var items = components.percentEncodedQueryItems ?? []
        // Replaced rather than appended. Jellyfin writes some of these into the
        // URL itself, and which of two same-named parameters the far end reads
        // is not a thing to leave to chance.
        items.removeAll { item in
            forced.contains { $0.caseInsensitiveCompare(item.name) == .orderedSame }
        }
        items.append(contentsOf: forced.map { URLQueryItem(name: $0, value: "false") })
        components.percentEncodedQueryItems = items
        return components.url ?? url
    }

    /// Make sure the chosen tracks are in the address the player opens, even on
    /// a server that didn't write them into it.
    ///
    /// MPEG-TS segments rather than fMP4 for a stream carrying its subtitles in
    /// the manifest. Jellyfin's fMP4 segments start at zero while the WebVTT it
    /// serves beside them maps its cues to a ten-second offset, so AVPlayer
    /// showed every line ten seconds late — a forced track looked empty, its
    /// lines landing after the signs they translate had gone. TS segments carry
    /// the offset the cues expect. Only where TS can carry the stream: H.264
    /// picture (HEVC reaches AVPlayer in fMP4 alone) and sound TS takes.
    nonisolated static func subtitleTimedSegments(_ url: URL, source: MediaSource, audioStreamIndex: Int?) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var query = parts.queryItems else { return url }
        func value(_ name: String) -> String? {
            query.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        guard let subtitle = value("SubtitleStreamIndex").flatMap(Int.init), subtitle >= 0,
              value("SubtitleMethod")?.lowercased() == "hls",
              value("SegmentContainer")?.lowercased() == "mp4",
              source.streams.first(where: { $0.type == "Video" })?.Codec?.lowercased() == "h264"
        else { return url }
        let audioIndex = audioStreamIndex ?? source.DefaultAudioStreamIndex
        let audio = source.audioStreams.first { $0.Index == audioIndex } ?? source.audioStreams.first
        guard let codec = audio?.Codec?.lowercased(), ["aac", "ac3", "mp3"].contains(codec) else { return url }
        for i in query.indices where query[i].name.caseInsensitiveCompare("SegmentContainer") == .orderedSame {
            query[i].value = "ts"
        }
        parts.queryItems = query
        return parts.url ?? url
    }

    /// Jellyfin builds `TranscodingUrl` from the very request above, so this is
    /// normally a no-op — and it is here for the case where it isn't. A
    /// transcode whose URL names no `AudioStreamIndex` re-reads the source's
    /// default when the segment endpoint is called, which would quietly hand
    /// back the track the viewer had just chosen against. Existing parameters
    /// are left exactly as the server wrote them: this only fills in what is
    /// missing.
    private static func carrying(
        audioStreamIndex: Int?, subtitleStreamIndex: Int?, in url: URL
    ) -> URL {
        guard audioStreamIndex != nil || subtitleStreamIndex != nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        var items = components.percentEncodedQueryItems ?? []
        func fillIn(_ name: String, _ value: Int?) {
            guard let value else { return }
            guard !items.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
            else { return }
            items.append(URLQueryItem(name: name, value: String(value)))
        }
        fillIn("AudioStreamIndex", audioStreamIndex)
        fillIn("SubtitleStreamIndex", subtitleStreamIndex)
        components.percentEncodedQueryItems = items
        return components.url ?? url
    }

    private struct PlaybackInfoBody: Encodable {
        let UserId: String
        let StartTimeTicks: Int64
        let IsPlayback: Bool
        let AutoOpenLiveStream: Bool
        let MaxStreamingBitrate: Int?
        let DeviceProfile: DeviceProfile
        let EnableDirectPlay: Bool
        let EnableDirectStream: Bool
        let EnableTranscoding: Bool
        /// Left out of the JSON entirely when nothing was chosen. Jellyfin reads
        /// an absent index as "use the source's default" and a present one as an
        /// instruction, and `-1` for the subtitle as none at all — so a null
        /// written into the body would be answering a question nobody asked.
        let AudioStreamIndex: Int?
        let SubtitleStreamIndex: Int?
    }

    // MARK: - Playback reporting

    func reportPlaybackStart(_ report: PlaybackReport) async {
        _ = try? await request("/Sessions/Playing", method: "POST", body: report)
    }

    func reportPlaybackProgress(_ report: PlaybackReport) async {
        _ = try? await request("/Sessions/Playing/Progress", method: "POST", body: report)
    }

    func reportPlaybackStopped(_ report: PlaybackReport) async {
        _ = try? await request("/Sessions/Playing/Stopped", method: "POST", body: report)
    }

    /// Tell the server an encode is still wanted. Jellyfin stops an HLS encode
    /// that nobody has pinged for a minute, whatever segments are being asked
    /// for. A player's progress reports keep it alive; a download has none,
    /// so it pings. See `DownloadManager.measureStreamsSoon`.
    func pingTranscode(playSessionId: String) async {
        _ = try? await request(
            "/Sessions/Playing/Ping?playSessionId=\(playSessionId)", method: "POST",
            countsForOffline: false, timeout: 10
        )
    }

    /// The `PlaySessionId` a download's URL carries — see `withPlaySession`.
    nonisolated static func playSessionId(of url: String) -> String? {
        URLComponents(string: url)?.queryItems?
            .first { $0.name.caseInsensitiveCompare("PlaySessionId") == .orderedSame }?.value
    }

    /// The throwing form, for a caller that needs to know the report actually
    /// reached the server before treating it as done — unlike a live session's
    /// stopped report, which is best-effort by design.
    func reportPlaybackStoppedOrThrow(_ report: PlaybackReport) async throws {
        _ = try await request("/Sessions/Playing/Stopped", method: "POST", body: report)
    }

    /// The throwing forms of the start and progress reports, for a download's
    /// sitting — see `OfflineProgress.Session` — which only counts as told
    /// once the server has actually heard it.
    func reportPlaybackStartOrThrow(_ report: PlaybackReport) async throws {
        _ = try await request("/Sessions/Playing", method: "POST", body: report)
    }

    func reportPlaybackProgressOrThrow(_ report: PlaybackReport) async throws {
        _ = try await request("/Sessions/Playing/Progress", method: "POST", body: report)
    }

    /// Tell the server to tear down a transcode job we've walked away from.
    /// Without this the ffmpeg process keeps running until it times out.
    /// Release the live stream this session opened.
    ///
    /// A separate thing from the encode, and the one that was being leaked.
    /// `AutoOpenLiveStream: true` in every PlaybackInfo above means the server
    /// opens a live-stream session — a tuner, or a connection to whatever is
    /// behind the channel — and holds it until it is closed or times out.
    /// Deleting the active encoding does not close it. So every channel change
    /// left one open, and on anything with a limit — a network tuner with two
    /// tuners, an M3U-backed channel whose source allows one connection at a
    /// time — the *next* channel opened against a session that was still
    /// holding the thing it needed. Which looks, from the sofa, exactly like
    /// the new channel freezing.
    func closeLiveStream(id: String) async {
        let q = [URLQueryItem(name: "liveStreamId", value: id)]
        _ = try? await request("/LiveStreams/Close?\(Self.encode(q))", method: "POST")
    }

    func stopTranscode(playSessionId: String) async {
        guard let s = prefs.session else { return }
        let q = [
            URLQueryItem(name: "deviceId", value: s.deviceId),
            URLQueryItem(name: "playSessionId", value: playSessionId),
        ]
        _ = try? await request("/Videos/ActiveEncodings?\(Self.encode(q))", method: "DELETE")
    }

    // MARK: - Download URLs

    /// Download URLs carry no `api_key` either — the transfer authenticates with
    /// a header. That matters more here than for playback: the URL is written
    /// into the download's metadata so an interrupted transfer can resume, and a
    /// token embedded in it would sit on disk indefinitely.
    /// How a download is fetched. Not a detail — it decides whether the thing
    /// that lands can be trusted.
    enum DownloadTransport: String, Codable, Sendable {
        /// One HTTP request for a file the server already has. It arrives with a
        /// Content-Length, so short is short and the transfer fails.
        case file
        /// An HLS playlist listing every segment up front. Each segment is its
        /// own finite request, and "did it all arrive" is answered by the
        /// manifest rather than guessed at.
        case hls
    }

    /// Where a download comes from, and how.
    ///
    /// Transcodes are fetched over HLS, never from `/Videos/{id}/stream`. That
    /// endpoint hands back the encode *while ffmpeg is still writing it*, with
    /// no Content-Length, and Jellyfin ends the response the moment the encoding
    /// job exits (`ProgressiveFileStream.StopReading`). A transfer cut short
    /// that way ends looking perfectly successful — 200, connection closed —
    /// and what lands is an MP4 whose index was never written, because ffmpeg
    /// writes that last. There is nothing on the wire to tell the two apart.
    /// Jellyfin's own maintainers say the same: download the HLS stream, which
    /// is built to be consumed as it is produced.
    func downloadURL(item: BaseItem, quality: DownloadQuality, asStream: Bool = false)
        -> (url: URL, fileName: String, transport: DownloadTransport)?
    {
        guard let s = prefs.session else { return nil }
        let safe = Self.safeFileName(item.Name ?? item.Id)
        let source = item.MediaSources?.first

        // A song is the file, always, when this device can read the file —
        // the rungs are picture sizes and mean nothing to it — and an AAC
        // encode over HLS when it can't (Ogg, WMA, the rest).
        if item.isAudio {
            if DeviceProfile.canPlayAudioAsFile(source) {
                let container = DeviceProfile.fileExtension(forContainer: source?.Container ?? item.Container, audio: true)
                guard let url = URL(string: "\(s.server)/Items/\(Self.pathId(item.Id))/Download") else { return nil }
                return (url, "\(safe).\(container)", .file)
            }
            var q = [
                URLQueryItem(name: "static", value: "false"),
                URLQueryItem(name: "deviceId", value: s.deviceId),
                URLQueryItem(name: "Context", value: "Static"),
                URLQueryItem(name: "SegmentContainer", value: "mp4"),
                URLQueryItem(name: "MinSegments", value: "1"),
                URLQueryItem(name: "AudioCodec", value: "aac"),
                URLQueryItem(name: "AudioBitrate", value: "256000"),
                URLQueryItem(name: "MaxAudioChannels", value: "2"),
            ]
            if let id = source?.Id { q.append(URLQueryItem(name: "MediaSourceId", value: id)) }
            guard let url = URL(string: "\(s.server)/Audio/\(Self.pathId(item.Id))/master.m3u8?\(Self.encode(q))") else { return nil }
            return (Self.withPlaySession(url), safe, .hls)
        }

        // An encode that would come out bigger than the file it is made from is
        // not worth making. Resolved here as well as in the caller so that no
        // route to a download can miss it — see `effectiveQuality`.
        let quality = Self.effectiveQuality(item: item, quality: quality)

        // The one case with nothing to encode and nothing to race: the file the
        // server already holds, sent as it sits on disk. Unless the caller has
        // already had that file and found it wouldn't open — see
        // `DownloadManager.verifyAndComplete` — in which case the same bytes
        // come rewrapped as a stream instead.
        if quality.original, !asStream, DeviceProfile.canPlayAsFile(source) {
            let container = DeviceProfile.fileExtension(forContainer: source?.Container ?? item.Container, audio: false)
            guard let url = URL(string: "\(s.server)/Items/\(Self.pathId(item.Id))/Download") else { return nil }
            return (url, "\(safe).\(container)", .file)
        }

        var q = [
            URLQueryItem(name: "static", value: "false"),
            URLQueryItem(name: "deviceId", value: s.deviceId),
            URLQueryItem(name: "Context", value: "Static"),
            // Fragmented MP4 segments rather than MPEG-TS: AVFoundation reads
            // them natively, and they carry HEVC, which TS segments can't.
            URLQueryItem(name: "SegmentContainer", value: "mp4"),
            URLQueryItem(name: "MinSegments", value: "1"),
            URLQueryItem(name: "AudioCodec", value: "aac"),
        ]
        if let id = source?.Id { q.append(URLQueryItem(name: "MediaSourceId", value: id)) }

        // An HLS download carries one audio track, so it has to be the one the
        // player would have picked. Text subtitles travel beside it as files
        // (see `DownloadSubtitles`); only a picture subtitle the user would
        // have had on is asked for here, painted into an encode that is
        // happening anyway.
        if let source {
            let tracks = Self.downloadTracks(
                in: source,
                saved: item.SeriesId.flatMap { prefs.trackChoice(seriesId: $0) },
                settings: TrackPreference.Settings(
                    audioLanguage: prefs.audioLanguage,
                    subtitleLanguage: prefs.subtitleLanguage,
                    forcedSubtitlesOnly: prefs.forcedSubtitlesOnly),
                reencodesPicture: !quality.original)
            if let audio = tracks.audio {
                q.append(URLQueryItem(name: "AudioStreamIndex", value: String(audio)))
            }
            if let burnIn = tracks.burnIn {
                q += [
                    URLQueryItem(name: "SubtitleStreamIndex", value: String(burnIn)),
                    URLQueryItem(name: "SubtitleMethod", value: "Encode"),
                ]
            }
        }

        if quality.original {
            // Original picture, new wrapper — the source is something
            // AVFoundation can't open as it stands. Stream copy left on, so the
            // video bitstream is carried across rather than re-encoded.
            q += [
                URLQueryItem(name: "VideoCodec", value: DeviceProfile.remuxVideoCodec(for: source)),
                URLQueryItem(name: "AllowVideoStreamCopy", value: "true"),
                URLQueryItem(name: "AllowAudioStreamCopy", value: "true"),
                URLQueryItem(name: "EnableAutoStreamCopy", value: "true"),
            ]
        } else {
            q += [
                URLQueryItem(name: "VideoCodec", value: "h264"),
                URLQueryItem(name: "VideoBitrate", value: String(quality.videoBitrate ?? 4_000_000)),
                URLQueryItem(name: "AudioBitrate", value: "192000"),
                URLQueryItem(name: "MaxWidth", value: String(quality.maxWidth ?? 1280)),
                URLQueryItem(name: "MaxHeight", value: String(quality.maxHeight ?? 720)),
                URLQueryItem(name: "MaxAudioChannels", value: "2"),
                // The three switches that make a size cap mean anything. Left at
                // their defaults the server is free to decide the source is
                // close enough and copy the original bitstream through instead
                // of encoding: a 480p download at the full 1080p size.
                URLQueryItem(name: "EnableAutoStreamCopy", value: "false"),
                URLQueryItem(name: "AllowVideoStreamCopy", value: "false"),
                URLQueryItem(name: "AllowAudioStreamCopy", value: "false"),
            ]
        }

        guard let url = URL(string: "\(s.server)/Videos/\(Self.pathId(item.Id))/master.m3u8?\(Self.encode(q))") else { return nil }
        let suffix = quality.original ? "" : " (\(quality.maxHeight ?? 0)p)"
        return (Self.withPlaySession(url), "\(safe)\(suffix)", .hls)
    }

    /// The tracks to ask an HLS download for, chosen the way the player
    /// chooses them for a stream (`TrackPreference.preferredStreams`).
    ///
    /// `audio` is nil when the server's own default is the one wanted. A
    /// subtitle is only ever named to be burned in, and only when it is a
    /// picture subtitle and the picture is being re-encoded regardless: a text
    /// one is fetched as a file and can be switched off, and burning into an
    /// Original would turn a stream copy into a full encode. The file's
    /// default subtitle counts as chosen, since the preference leaves that one
    /// unnamed for the server to send.
    static func downloadTracks(
        in source: MediaSource, saved: Preferences.TrackChoice?, settings: TrackPreference.Settings,
        reencodesPicture: Bool
    ) -> (audio: Int?, burnIn: Int?) {
        let picked = TrackPreference.preferredStreams(in: source, saved: saved, settings: settings)
        guard reencodesPicture else { return (picked.audio, nil) }
        let subtitle = picked.subtitle ?? source.DefaultSubtitleStreamIndex
        guard let subtitle, subtitle >= 0,
              let stream = source.subtitleStreams.first(where: { $0.Index == subtitle }), stream.isImageSubtitle
        else { return (picked.audio, nil) }
        return (picked.audio, subtitle)
    }

    /// Where the server serves one subtitle stream as a file, converted to
    /// `format` (`srt`, `ass`, `vtt`). The same endpoint a stream's
    /// `DeliveryUrl` names for a sidecar, but it extracts embedded text tracks
    /// too, which is what lets a download carry subtitles the HLS remux drops.
    /// Server-relative, for `request`, so the token goes in the header.
    nonisolated static func subtitlePath(itemId: String, mediaSourceId: String, index: Int, format: String) -> String {
        "/Videos/\(pathId(itemId))/\(pathId(mediaSourceId))/Subtitles/\(index)/0/Stream.\(format)"
    }

    /// `url` with a `PlaySessionId` of its own, if it hasn't one already.
    ///
    /// Every encode this device asks for carries the same `deviceId`, and
    /// Jellyfin's `KillTranscodingJobs` — run whenever a stream's encode is
    /// restarted — takes an empty `PlaySessionId` to mean *every* job for that
    /// device. So each download that started or restarted its encode could
    /// kill the others', which then answered their next segment with a 500.
    /// With a session each, a restart only reaches its own.
    nonisolated static func withPlaySession(_ url: URL) -> URL {
        // Appended to the encoded query as it stands rather than rebuilt from
        // `queryItems`, which would undo `encode`'s escaping of '+'.
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              !(parts.queryItems ?? []).contains(where: { $0.name.caseInsensitiveCompare("PlaySessionId") == .orderedSame })
        else { return url }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let query = parts.percentEncodedQuery ?? ""
        parts.percentEncodedQuery = (query.isEmpty ? "" : query + "&") + "PlaySessionId=" + id
        return parts.url ?? url
    }

    /// A title turned into something a file system will take. Trimmed by *bytes*
    /// rather than by characters: 120 characters of Japanese or emoji is 360
    /// bytes, well past the 255 a file name may be, and the move onto disk fails
    /// at the very end of the transfer.
    nonisolated static func safeFileName(_ raw: String) -> String {
        var name = raw
        for bad in ["/", ":", "\\", "\u{0}", "\n", "\r"] {
            name = name.replacingOccurrences(of: bad, with: "_")
        }
        while name.utf8.count > 120, !name.isEmpty { name.removeLast() }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "download" : trimmed
    }

    /// The header a download or an AVURLAsset has to carry to be let in.
    func authHeaders() -> [String: String] {
        ["Authorization": authorizationHeader(token: token)]
    }

    /// The same, for a URL that came from somewhere other than this session —
    /// a download's stored address, a path the server spelled out. Empty
    /// unless the URL leads to the signed-in server: the token belongs to that
    /// server and to nobody else who happens to be named in a URL.
    func authHeaders(for url: URL) -> [String: String] {
        isSessionOrigin(url) ? authHeaders() : [:]
    }

    /// Whether a URL is on the signed-in server: same scheme, host and port.
    func isSessionOrigin(_ url: URL) -> Bool {
        guard let server = prefs.session?.server, let base = URL(string: server) else { return false }
        return Self.origin(of: url) != nil && Self.origin(of: url) == Self.origin(of: base)
    }

    private nonisolated static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    /// The same credential as a query parameter, for the one caller that cannot
    /// use a header.
    ///
    /// AVFoundation fetches the segments of a downloaded stream itself, and the
    /// header fields set on the asset do not reach those requests — every
    /// segment goes out unauthenticated and the server refuses the lot. A key in
    /// the URL is the only thing it will carry. It is added when a transfer
    /// starts and deliberately not stored by the app: what goes into meta.json
    /// is the URL without it. AVFoundation may still note the URL it was given
    /// inside the package it downloads into, which is one reason the whole
    /// downloads directory is kept out of backups (`DownloadManager.root`).
    ///
    /// Only for a URL on the signed-in server; any other comes back untouched.
    ///
    /// Spelled `ApiKey`, not `api_key`. The lowercase form is one of the legacy
    /// credentials Jellyfin 12 stopped reading (with `X-Emby-Token` and
    /// `X-Emby-Authorization`), and a segment request carrying it comes back
    /// 401 from a server that has not turned `EnableLegacyAuthorization` back
    /// on. `ApiKey` is what the server writes into its own transcode URLs and
    /// has been accepted since 10.9, so it is the one spelling that works on
    /// both sides of the upgrade.
    func authorized(_ url: URL) -> URL {
        guard isSessionOrigin(url), let token, !token.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        var items = components.queryItems ?? []
        guard !items.contains(where: { $0.name == "ApiKey" || $0.name == "api_key" }) else { return url }
        items.append(URLQueryItem(name: "ApiKey", value: token))
        components.queryItems = items
        return components.url ?? url
    }

    /// The quality a download will actually be fetched at, which is not always
    /// the one that was asked for.
    ///
    /// A transcode is not automatically smaller than the file it is made from.
    /// A 45-minute episode already encoded at 3 Mbps HEVC is about a gigabyte;
    /// asking for it at the 1080p rung spends the server real encoding time to
    /// produce something *larger*, in a worse codec, with one stereo track and
    /// no subtitles. So when the original is the smaller of the two it is taken
    /// as it stands: fewer bytes, better picture, and no work for anyone.
    ///
    /// Two kinds of source qualify. One this device can open as it stands,
    /// which comes down byte for byte at exactly the size the server reports.
    /// And one whose picture is H.264 or HEVC in a wrapper AVFoundation won't
    /// read (MKV, mostly): that one is rewrapped with the video stream-copied,
    /// and a rewrap never weighs more than the file it came from — the extra
    /// audio tracks and the subtitles are left behind, and a lossless or DTS
    /// soundtrack becomes AAC — so the server's size is a ceiling on it, which
    /// is the safe side of the comparison. Any other picture codec (AV1, VP9,
    /// MPEG-2) has to be encoded whatever is asked for, so there is no
    /// original to fall back to and the rung stands.
    ///
    /// Ties go to the original: equal bytes, but the original keeps its own
    /// picture untouched.
    static func effectiveQuality(item: BaseItem, quality: DownloadQuality) -> DownloadQuality {
        if item.isAudio { return DownloadQualities.all.first(where: { $0.original }) ?? quality }
        guard !quality.original,
              let original = DownloadQualities.all.first(where: { $0.original }),
              let source = item.MediaSources?.first,
              DeviceProfile.canPlayAsFile(source) || DeviceProfile.canRemuxForDownload(source),
              let size = source.Size, size > 0,
              let encoded = transcodeSize(item: item, quality: quality),
              size <= encoded
        else { return quality }
        return original
    }

    /// Estimated on-disk size for a download choice. Exact for originals (the
    /// server reports the file size), bitrate × runtime for transcodes.
    ///
    /// Resolved through `effectiveQuality`, so the figure quoted before a
    /// download is the one the download will actually weigh — including when
    /// asking for a transcode gets you the original instead.
    static func estimateDownloadSize(item: BaseItem, quality: DownloadQuality) -> Int64? {
        if item.isAudio {
            let source = item.MediaSources?.first
            if DeviceProfile.canPlayAudioAsFile(source), let size = source?.Size, size > 0 { return size }
            guard let ticks = item.RunTimeTicks, ticks > 0 else { return nil }
            return byteCount(Double(ticks) / 10_000_000 * 256_000 / 8 * 1.02)
        }
        let resolved = effectiveQuality(item: item, quality: quality)
        if resolved.original {
            let source = item.MediaSources?.first
            // Rewrapped rather than sent as it sits: what comes down is the
            // picture and one soundtrack, not the file. See `remuxSize`.
            if !DeviceProfile.canPlayAsFile(source), let remux = remuxSize(item: item) { return remux }
            let size = source?.Size ?? 0
            return size > 0 ? size : nil
        }
        return transcodeSize(item: item, quality: resolved)
    }

    /// What an original-quality download that has to be rewrapped will weigh.
    ///
    /// The source file's size was the figure used, and it is the wrong one:
    /// an MKV carries every soundtrack and subtitle the release came with —
    /// commentary, dubs, a lossless track beside a lossy one — and the
    /// rewrap brings down the picture and one soundtrack, as AAC unless it
    /// already was. Started from the whole file, the total on the Downloads
    /// page could only fall as the transfer went on. The picture's own
    /// bitrate and one AAC soundtrack instead; nil when the server doesn't
    /// say what the picture's bitrate is.
    static func remuxSize(item: BaseItem) -> Int64? {
        guard let ticks = item.RunTimeTicks, ticks > 0,
              let source = item.MediaSources?.first,
              let videoBitrate = source.streams.first(where: { $0.type == "Video" })?.BitRate, videoBitrate > 0
        else { return nil }
        let seconds = Double(ticks) / 10_000_000
        let audios = source.streams.filter { $0.type == "Audio" }
        let audio = audios.first { $0.Index == source.DefaultAudioStreamIndex } ?? audios.first(where: { $0.IsDefault == true }) ?? audios.first
        var audioBitrate = 0
        if let audio {
            if audio.Codec?.lowercased() == "aac", let rate = audio.BitRate, rate > 0 {
                // Copied across as it is.
                audioBitrate = rate
            } else {
                // Encoded to AAC: about 128 kbps a pair of channels, as the
                // server does when no bitrate is asked for, and never more
                // than the source had.
                let channels = max(2, audio.Channels ?? 2)
                audioBitrate = min(640_000, 128_000 * channels / 2)
                if let rate = audio.BitRate, rate > 0 { audioBitrate = min(audioBitrate, rate) }
            }
        }
        let estimate = byteCount(Double(videoBitrate + audioBitrate) / 8 * seconds * 1.02)
        guard estimate > 0 else { return nil }
        // Never more than the file it is made from.
        if let size = source.Size, size > 0 { return min(estimate, size) }
        return estimate
    }

    /// What an encode at this rung would weigh. Nil when there is nothing to
    /// work it out from — an item with no runtime, or a rung with no bitrate.
    private static func transcodeSize(item: BaseItem, quality: DownloadQuality) -> Int64? {
        guard let ticks = item.RunTimeTicks, ticks > 0, let ceiling = quality.videoBitrate else { return nil }
        let video = item.MediaSources?.first?.streams.first { $0.type == "Video" }
        let seconds = Double(ticks) / 10_000_000
        // Video + 192 kbps audio, ~2% container overhead.
        return byteCount((Double(transcodeBitrate(ceiling: ceiling, source: video)) + 192_000) / 8 * seconds * 1.02)
    }

    /// A size worked out in floating point, as an integer. The inputs are the
    /// server's numbers, and a runtime or bitrate that is absurd rather than
    /// merely wrong must come out as a big estimate, not as a conversion that
    /// traps.
    private static func byteCount(_ value: Double) -> Int64 {
        guard value.isFinite, value > 0 else { return 0 }
        return Int64(min(value, 1e18))
    }

    /// What the server will actually encode at, given the rung asked for.
    ///
    /// Not simply the rung: Jellyfin treats it as a ceiling and picks the lower
    /// of it and the source's own bitrate — but it does not use the source's
    /// bitrate as it stands. It inflates a low one first (a stream at or under
    /// 2 Mbps by two and a half times, one under 3 by two) on the grounds that
    /// re-encoding an already-small stream at its own bitrate destroys it, and
    /// it scales up again when the source is in a more efficient codec than the
    /// output, since the same picture in H.264 costs more bits than it did in
    /// HEVC. Modelled here because this number is quoted to the user before
    /// anything is downloaded, and one that is merely plausible is worse than
    /// none: it becomes the figure a finished download is judged against.
    private static func transcodeBitrate(ceiling: Int, source: MediaStream?) -> Int {
        guard let rate = source?.BitRate, rate > 0 else { return ceiling }
        var floorRate = Double(rate)
        if rate <= 2_000_000 {
            floorRate *= 2.5
        } else if rate <= 3_000_000 {
            floorRate *= 2
        }
        switch source?.Codec?.lowercased() {
        case "hevc", "h265", "vp9": floorRate /= 0.6
        case "av1": floorRate /= 0.5
        default: break
        }
        // Capped before it becomes an integer: the source's bitrate is the
        // server's to state, and one past `Int.max` would trap the conversion.
        return max(1, Int(min(Double(ceiling), floorRate)))
    }

    // MARK: - Helpers

    nonisolated static func encode(_ items: [URLQueryItem]) -> String {
        var c = URLComponents()
        c.queryItems = items
        // URLComponents leaves '+' as it is, and the server reads a bare '+'
        // in a query as a space — a search for "C++" arrived as "C  ".
        return (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    }
}

// MARK: - Encoding shims

/// Lets `request(body:)` take any Encodable without generics leaking into every
/// call site.
private struct AnyEncodable: Encodable {
    private let encodeTo: (Encoder) throws -> Void
    init(_ wrapped: any Encodable) {
        encodeTo = { try wrapped.encode(to: $0) }
    }
    func encode(to encoder: Encoder) throws { try encodeTo(encoder) }
}

/// A 204 with no body is a success for the endpoints that return nothing.
private enum EmptyFallback<T> {
    static var value: T? {
        if T.self == ItemsResponse.self { return ItemsResponse(Items: [], TotalRecordCount: 0) as? T }
        if T.self == [BaseItem].self { return [BaseItem]() as? T }
        return nil
    }
}

#if os(iOS) || os(tvOS)
import UIKit
/// Main-actor, as `UIDevice` is; its one reader, `JellyfinClient.deviceName`,
/// is too.
@MainActor
enum UIDeviceName {
    static var current: String { UIDevice.current.name }
}
#endif
