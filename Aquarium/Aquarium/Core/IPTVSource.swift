//  Turns a fetched M3U playlist and XMLTV guide into the same `BaseItem`
//  shape the Jellyfin path already produces, so the guide, the channel
//  column and playback don't need a second implementation — only this one
//  small adapter between "bytes from a URL" and "a row TVGuideView draws".

import Foundation

enum IPTVError: LocalizedError {
    case noPlaylist
    case badPlaylistURL
    case fetchFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPlaylist: "Add an M3U playlist URL in Settings to use a custom Live TV source."
        case .badPlaylistURL: "That M3U address doesn't look like a valid URL."
        case .fetchFailed(let reason): reason
        }
    }
}

enum IPTVSource {
    struct Loaded: Sendable {
        var channels: [BaseItem]
        var programmes: [BaseItem]
        /// The same programmes by channel id, each channel's in airtime order —
        /// so a guide query touches the channels it asks about rather than
        /// every programme in the feed.
        var byChannel: [String: [BaseItem]]
    }


    /// The most a playlist or guide is allowed to be. A guide for a few
    /// hundred channels runs to some tens of megabytes; past this it is not a
    /// guide, and reading it whole into memory was the one way a wrong address
    /// could take the app down.
    static let playlistLimit = 16 * 1024 * 1024
    static let guideLimit = 128 * 1024 * 1024

    static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// The body at `url`, read as it arrives and abandoned the moment it
    /// passes `limit` bytes, so an oversized answer costs at most the limit.
    ///
    /// Collected in the chunks the network delivers. It used to be read a byte
    /// at a time off `URLSession.bytes`, which for a forty-megabyte guide is
    /// forty million trips round an async loop — a second or more of CPU, and
    /// on the main thread at that.
    @concurrent
    static func fetch(_ url: URL, limit: Int) async throws -> Data {
        try await BoundedDownload(limit: limit).run(url)
    }

    /// Fetches and parses the configured playlist (required) and guide
    /// (optional — channels still tune without one, just with no schedule,
    /// same as a Jellyfin channel with no guide data configured).
    ///
    /// `@concurrent`: the download, the M3U parse, an XMLTV parse of tens of
    /// megabytes and the programme build all happen in here, and the store
    /// that calls it is main-actor. Under this project's approachable
    /// concurrency a plain async function runs on its caller's actor, so
    /// without this the whole load ran on the main thread — at launch, since
    /// the store warms it as the app opens.
    @concurrent
    static func load(playlistURLString: String, guideURLString: String) async throws -> Loaded {
        let trimmedPlaylist = playlistURLString.trimmingCharacters(in: .whitespaces)
        guard !trimmedPlaylist.isEmpty else { throw IPTVError.noPlaylist }
        guard let playlistURL = URL(string: trimmedPlaylist), isWebURL(playlistURL) else { throw IPTVError.badPlaylistURL }

        let playlistText: String
        do {
            let data = try await fetch(playlistURL, limit: Self.playlistLimit)
            playlistText = String(decoding: data, as: UTF8.self)
        } catch {
            throw IPTVError.fetchFailed("Couldn't load the playlist: \(error.localizedDescription)")
        }

        let entries = M3UParser.parse(playlistText)
        // Everything the playlist names is named relative to the playlist
        // itself unless it says otherwise — the same rule HLS uses, and the
        // reason a channel column full of empty tiles is not necessarily
        // artwork nobody supplied. Some playlist generators write a channel
        // icon as a bare root-relative path such as `/images/….png`: absolutely
        // correct in the file, and unfetchable the moment it is taken out of
        // it. Resolved here, once, so nothing downstream has to know which
        // kind it got.
        let playlistBase = playlistURL
        var channelIcons: [String: String] = [:]
        var channelNames: [String: String] = [:]
        var idsByName: [String: String] = [:]
        var programmeSources: [XMLTVProgramme] = []

        let trimmedGuide = guideURLString.trimmingCharacters(in: .whitespaces)
        var guideBase: URL?
        if !trimmedGuide.isEmpty, let guideURL = URL(string: trimmedGuide), isWebURL(guideURL),
           let data = try? await fetch(guideURL, limit: Self.guideLimit) {
            guideBase = guideURL
            let parsed = XMLTVParser.parse(data)
            channelIcons = matchKeyed(parsed.channelIcons)
            channelNames = matchKeyed(parsed.channelNames)
            // The other way in: a playlist whose `tvg-id`s don't match the
            // guide's channel ids — or has none at all — can still be lined
            // up by the name both sides display. Walked in id order rather
            // than the dictionary's own, so a guide that lists the same name
            // against two channels resolves to the same one on every reload
            // instead of shuffling between them.
            for (id, name) in parsed.channelNames.sorted(by: { $0.key < $1.key }) {
                let key = matchKey(name)
                guard !key.isEmpty, idsByName[key] == nil else { continue }
                idsByName[key] = matchKey(id)
            }
            programmeSources = parsed.programmes
        }

        var channels: [BaseItem] = []
        /// Which channel a guide entry belongs to, under every key that entry
        /// might arrive under: the channel's own id and its name.
        var channelIdByKey: [String: String] = [:]
        for (index, entry) in entries.enumerated() {
            let idKey = matchKey(entry.id)
            // A playlist id the guide doesn't carry, matched on the displayed
            // name instead.
            let guideKey = channelNames[idKey] != nil || channelIcons[idKey] != nil
                ? idKey
                : (idsByName[matchKey(entry.name)] ?? idKey)

            var item = BaseItem()
            // The index is in the id, not decoration: a playlist repeating a
            // `tvg-id` — or a generator that writes the same one against every
            // channel in a group — otherwise hands the guide two rows claiming
            // to be the same item, which SwiftUI resolves by drawing one of
            // them twice and losing the other.
            item.Id = "iptv-\(index)-\(entry.id)"
            item.Name = channelNames[guideKey] ?? entry.name
            item.type = "TvChannel"
            item.ChannelNumber = entry.channelNumber ?? String(index + 1)
            // A stream is an address on the web or it is nothing: a playlist
            // can name a file on this device, and the player would open it.
            let stream = absolute(entry.streamURL, against: playlistBase) ?? entry.streamURL
            guard let streamURL = URL(string: stream), isWebURL(streamURL) else { continue }
            item.ExternalStreamURL = stream
            // `tvg-logo=""` is as good as no logo at all, and a playlist that
            // writes the attribute out empty for every channel is common —
            // taken literally it would shadow the icon the guide carries and
            // leave the whole channel column blank.
            // On the web as well, for the same reason as the stream.
            let logo = entry.logoURL?.nonEmpty.flatMap { absolute($0, against: playlistBase) }
                ?? channelIcons[guideKey].flatMap { absolute($0, against: guideBase ?? playlistBase) }
            item.ExternalLogoURL = logo.flatMap { URL(string: $0).map(isWebURL) == true ? $0 : nil }
            channels.append(item)

            if channelIdByKey[guideKey] == nil { channelIdByKey[guideKey] = item.Id }
            let nameKey = matchKey(entry.name)
            if !nameKey.isEmpty, channelIdByKey[nameKey] == nil { channelIdByKey[nameKey] = item.Id }
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var programmes: [BaseItem] = []
        var byChannel: [String: [BaseItem]] = [:]
        var usedIds = Set<String>()
        // Each feed channel id is matched once, not once per programme.
        var channelFor: [String: String?] = [:]
        for source in programmeSources {
            let resolved: String?
            if let known = channelFor[source.channelId] {
                resolved = known
            } else {
                resolved = channelIdByKey[matchKey(source.channelId)]
                channelFor[source.channelId] = resolved
            }
            guard let channelId = resolved else { continue }
            var item = BaseItem()
            // Stable across reloads — the channel and the minute it starts —
            // where a fresh UUID made every refresh of the guide a whole new
            // set of rows to SwiftUI, none of them the same as the last. A
            // feed that lists two programmes at the same start on one channel
            // keeps both.
            var id = "iptv-\(channelId)-\(Int(source.start.timeIntervalSince1970))"
            if usedIds.contains(id) {
                var n = 2
                while usedIds.contains("\(id)-\(n)") { n += 1 }
                id = "\(id)-\(n)"
            }
            usedIds.insert(id)
            item.Id = id
            item.Name = source.title
            item.Overview = source.desc
            item.ChannelId = channelId
            item.ExternalStart = source.start
            item.ExternalEnd = source.stop
            item.StartDate = iso.string(from: source.start)
            item.EndDate = iso.string(from: source.stop)
            programmes.append(item)
            byChannel[channelId, default: []].append(item)
        }
        for key in byChannel.keys {
            byChannel[key]?.sort { ($0.ExternalStart ?? .distantPast) < ($1.ExternalStart ?? .distantPast) }
        }

        return Loaded(channels: channels, programmes: programmes, byChannel: byChannel)
    }

    /// A URL out of a playlist or a guide, made absolute.
    ///
    /// Nil only for something that isn't a URL at all — an already-absolute
    /// address ignores the base, which is what `relativeTo:` does anyway, so
    /// this is safe to run over every address either file carries.
    private static func absolute(_ raw: String, against base: URL?) -> String? {
        URL.lenient(raw, relativeTo: base)?.absoluteString
    }

    /// How a channel id or name is compared across the two files.
    ///
    /// The playlist and the guide are written by different hands — often
    /// literally different sources — and an id that matches apart from its
    /// case or a stray space is the normal case rather than the exception
    /// ("CNN.us" against "cnn.us"). Compared byte for byte, such a channel
    /// loses both its logo and its entire schedule, which is indistinguishable
    /// from a guide that doesn't cover it.
    private static func matchKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The same dictionary under `matchKey`ed keys. Sorted first for the same
    /// reason as above: two ids that differ only in case collapse to one entry
    /// here, and which of them survives shouldn't depend on hashing order.
    private static func matchKeyed(_ source: [String: String]) -> [String: String] {
        Dictionary(
            source.sorted { $0.key < $1.key }.map { (matchKey($0.key), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

/// A body collected as it arrives, given up on past a size limit.
private final class BoundedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var continuation: CheckedContinuation<Data, Error>?

    init(limit: Int) {
        self.limit = limit
    }

    func run(_ url: URL) async throws -> Data {
        // A session of its own, because a data delegate is a session's; one
        // fetch per playlist refresh makes that cheap. It holds this object
        // until it is invalidated, which the `defer` does.
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Set before the task starts, so no delegate call can find it
                // missing. A cancel that lands first ends the task the moment
                // it resumes, which still arrives here.
                lock.withLock { self.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private var tooLarge: Error { IPTVError.fetchFailed("The file is too large") }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(IPTVError.fetchFailed("The server answered \(http.statusCode)")))
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > Int64(limit) {
            finish(.failure(tooLarge))
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > 0 {
            let expected = Int(response.expectedContentLength)
            lock.withLock { data.reserveCapacity(expected) }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let over = lock.withLock {
            data.append(chunk)
            return data.count > limit
        }
        if over {
            finish(.failure(tooLarge))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else {
            finish(.success(lock.withLock { data }))
        }
    }

    /// Resumes the caller once, with whichever answer came first.
    private func finish(_ result: Result<Data, Error>) {
        let waiting = lock.withLock {
            let waiting = continuation
            continuation = nil
            return waiting
        }
        waiting?.resume(with: result)
    }
}

private extension String {
    /// Nil rather than an empty string, for the attributes a playlist writes
    /// out with nothing in them.
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
