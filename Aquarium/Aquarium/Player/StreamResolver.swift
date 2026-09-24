//  Where an IPTV channel's stream really lives, and what shape it is.
//
//  A playlist URL is very often not the stream: it is an address that answers
//  "over here", and every other player follows that and looks at what it finds.
//  AVFoundation does not. It decides how to read a resource largely from the
//  path extension of the URL it was handed, before any redirect is followed, so
//  an address ending in neither `.m3u8` nor anything else it recognises is one
//  it will try to read as a file — and an HLS playlist read as a file produces
//  a player that opens, buffers, reports no picture and plays nothing.
//
//  The case in point is a channel server whose playlist writes an
//  extensionless address such as `/stream/<id>?mode=hls`, which 302s to
//  `/stream/<id>.m3u8`. VLC, mpv and ffmpeg follow it and play; this app
//  handed the first address straight to AVPlayer and got the QuickTime
//  placeholder. Following the redirects here and giving AVFoundation the
//  address it would have arrived at — extension and all — is the whole fix, and
//  it is not specific to one server: a redirect that issues a session token or
//  picks a mirror is ordinary for live streams.
//
//  The redirects are read rather than walked. Answering a *stream* URL means
//  starting a session on the far end, so each hop is asked with HEAD and the
//  chain is stopped by hand at the first thing that isn't a redirect. It also
//  stops as soon as the address carries an extension that settles the question,
//  and stops *before* asking for that one — see `conclusiveExtensions`. The
//  address AVPlayer is about to open is never touched here.

import Foundation

enum StreamResolver {
    struct Resolved {
        var url: URL
        var contentType: String?

        /// A raw MPEG transport stream, arriving as a file rather than as HLS.
        ///
        /// Worth telling apart from every other failure because no setting on
        /// this device will ever play it: AVFoundation reads transport-stream
        /// segments inside an HLS playlist and will not read a transport stream
        /// on its own, whatever is inside it. The fix is on the machine sending
        /// it, and the message can say so exactly rather than guessing at codecs.
        var isBareTransportStream: Bool {
            if url.pathExtension.lowercased() == "ts" { return true }
            guard let contentType = contentType?.lowercased() else { return false }
            return contentType.hasPrefix("video/mp2t") || contentType.hasPrefix("video/mpeg")
        }
    }

    /// How many hops to follow, and how long to spend on the whole thing. Both
    /// are small on purpose: this sits between tapping a channel and the
    /// picture starting, and an unresolved address still plays — it is the
    /// address the app used to use.
    private static let maxHops = 5
    private static let timeout: TimeInterval = 4

    /// Extensions that already answer the only question this asks. Reaching
    /// one of these ends the walk *without* a request for it.
    ///
    /// That last part matters more than it looks. On a channel server the
    /// playlist address is not an inert document — asking for it is what starts
    /// a session and spins up the transcode behind it, and a HEAD is not
    /// exempt: the route runs, the session starts, and the body is thrown away.
    /// So the resolver would open a session, drop it, and leave AVPlayer's own
    /// request a moment later to land on one that is mid-startup or already
    /// being torn down. Once the extension is known there is nothing left to
    /// learn, so the address is handed over untouched.
    private static let conclusiveExtensions: Set<String> = [
        "m3u8", "m3u", "ts", "mp4", "m4s", "mkv", "webm", "mpd"
    ]

    static func resolve(_ url: URL) async -> Resolved {
        var current = url
        for _ in 0..<maxHops {
            if conclusiveExtensions.contains(current.pathExtension.lowercased()) { break }
            guard let step = await hop(to: current) else { break }
            switch step {
            case .redirect(let next):
                current = next
            case .final(let contentType):
                return Resolved(url: current, contentType: contentType)
            }
        }
        return Resolved(url: current, contentType: nil)
    }

    private enum Step {
        case redirect(URL)
        case final(String?)
    }

    private static func hop(to url: URL) async -> Step? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let follower = RedirectStopper()
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        guard let (_, response) = try? await session.data(for: request, delegate: follower),
              let http = response as? HTTPURLResponse
        else { return nil }

        if let next = follower.location(relativeTo: url) { return .redirect(next) }
        // A server that won't answer HEAD tells us nothing, and guessing from a
        // 405 is worse than leaving the address alone.
        guard (200..<300).contains(http.statusCode) else { return nil }
        return .final(http.value(forHTTPHeaderField: "Content-Type"))
    }
}

/// Catches a redirect instead of following it, so the hop can be recorded and
/// the request stopped before anything downstream starts producing video.
private final class RedirectStopper: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var redirect: URL?

    func location(relativeTo base: URL) -> URL? {
        guard let redirect else { return nil }
        // Already absolute by the time URLSession hands it over, but resolved
        // against the address it came from regardless — a `Location` header is
        // allowed to be relative and some servers still write one that way.
        return URL(string: redirect.absoluteString, relativeTo: base)?.absoluteURL
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        redirect = request.url
        completionHandler(nil)
    }
}
