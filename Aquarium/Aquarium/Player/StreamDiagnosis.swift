//  What is actually inside a channel that opened and then showed no picture.
//
//  "No video track" is where AVFoundation stops, and it is not a useful place
//  to leave someone: the same symptom covers a codec this device can't decode,
//  a container it won't read that codec from, and a stream that genuinely has
//  no video in it. Those have completely different answers, and the difference
//  is written down in the stream itself — a transport stream carries a table
//  naming every elementary stream in it and what each one is.
//
//  So when the picture doesn't arrive, this reads that table. One range request
//  for the head of one segment, parsed far enough to reach the program map, and
//  the banner can name the codec instead of listing the possibilities.

import Foundation

enum StreamDiagnosis {
    struct Finding: Sendable {
        /// The sentence the player shows.
        var message: String
        /// Whether this device is going to fail to draw a picture, whatever
        /// AVFoundation says while it tries.
        var videoWillNotPlay: Bool
    }

    /// What this channel contains, read from the stream itself.
    ///
    /// Asked for every IPTV channel as it starts, rather than only once
    /// something has visibly gone wrong. The signals AVFoundation offers for
    /// "there is no picture" turned out not to mean that: an HLS master
    /// playlist declaring `RESOLUTION=1920x1080` gives the player item a
    /// presentation size of 1920×1080 whether or not a single frame ever
    /// decodes, so a stream failing exactly the way this one does looks, from
    /// the outside, like a stream that is fine. The stream's own program map
    /// says what is really in it, and it costs one ranged request to read.
    static func inspect(hlsURL: URL) async -> Finding? {
        guard let media = await mediaPlaylist(from: hlsURL),
              let segment = await firstSegment(in: media.text, base: media.url)
        else { return nil }

        // fMP4 segments are the combination Apple *does* read HEVC from, so a
        // stream that has got this far with them is failing for some other
        // reason and this has nothing to add.
        let ext = segment.pathExtension.lowercased()
        guard ext != "m4s", ext != "mp4" else { return nil }

        guard let head = await head(of: segment) else { return nil }
        let streams = TransportStream.elementaryStreams(in: head)
        guard !streams.isEmpty else { return nil }

        let video = streams.first { $0.isVideo }
        let audio = streams.first { !$0.isVideo }

        guard let video else {
            return Finding(
                message: "This channel is carrying no video at all — only \(audio?.name ?? "audio"). "
                    + "It is being sent as an audio-only stream.",
                videoWillNotPlay: true
            )
        }
        guard !video.playsFromTransportStream else { return nil }
        return Finding(
            message: "This channel's video is \(video.name), sent as MPEG-TS segments"
                + (audio.map { " with \($0.name) audio" } ?? "")
                + ". Apple's players decode \(video.name) only from fMP4 segments, never from "
                + "MPEG-TS — so the audio plays and the picture cannot. It has to be sent as "
                + "H.264, which plays from either.",
            videoWillNotPlay: true
        )
    }

    // MARK: - Walking the playlists

    /// One ephemeral session for every diagnosis rather than one per request:
    /// a diagnosis is up to three requests, and each built and tore down a
    /// session of its own.
    private static let session = URLSession(configuration: .ephemeral)

    /// As much of a playlist as is worth reading. A live one is a few
    /// kilobytes; the ceiling is for the address that turns out not to be a
    /// playlist at all.
    private static let playlistLimit = 1 << 20
    private static let segmentHeadLimit = 131_072

    /// The front of whatever is at an address — never more than `limit`, and
    /// never for longer than fifteen seconds.
    ///
    /// Read as a stream and stopped, rather than with `data(for:)`, which
    /// returns when the body ends: a channel that is a continuous transport
    /// stream under a name nobody recognises never ends, the ten-second
    /// timeout is an idle one and never fires, and the whole of it was being
    /// collected in memory until the system killed the app. The same goes for
    /// a host that ignores `Range`.
    private static func fetch(_ url: URL, range: String? = nil, limit: Int) async -> (Data, URL)? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode)
        else { return nil }
        let deadline = Date().addingTimeInterval(15)
        var data = Data()
        data.reserveCapacity(min(limit, 65_536))
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
                if data.count & 0xFFF == 0, Date() > deadline { break }
            }
        } catch {
            // What arrived before the connection dropped is still worth a look.
        }
        bytes.task.cancel()
        return (data, response.url ?? url)
    }

    /// The media playlist, following one level of master playlist if that is
    /// what the address turns out to be.
    private static func mediaPlaylist(from url: URL) async -> (text: String, url: URL)? {
        guard let (data, finalURL) = await fetch(url, limit: playlistLimit) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains("#EXTM3U") else { return nil }
        guard text.contains("#EXT-X-STREAM-INF") else { return (text, finalURL) }
        guard let variant = firstURI(in: text, base: finalURL),
              let (data, variantURL) = await fetch(variant, limit: playlistLimit)
        else { return nil }
        return (String(decoding: data, as: UTF8.self), variantURL)
    }

    private static func firstURI(in playlist: String, base: URL) -> URL? {
        for line in playlist.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            return URL(string: trimmed, relativeTo: base)?.absoluteURL
        }
        return nil
    }

    private static func firstSegment(in playlist: String, base: URL) async -> URL? {
        firstURI(in: playlist, base: base)
    }

    /// Enough of a segment to be sure of reaching the program map table, which
    /// a muxer puts at the very front and repeats. 128 KB is generous.
    private static func head(of segment: URL) async -> Data? {
        if let (data, _) = await fetch(segment, range: "bytes=0-131071", limit: segmentHeadLimit), !data.isEmpty {
            return data
        }
        return nil
    }
}

// MARK: - Transport stream tables

/// Just enough MPEG-TS to read the program map table: which elementary streams
/// a segment contains and what each one is. Everything else in the format is
/// beside the point here.
enum TransportStream {
    struct Stream {
        var name: String
        var isVideo: Bool
        /// Whether an Apple platform will take this codec from inside a
        /// transport stream — which for video means H.264 and MPEG-2 only.
        var playsFromTransportStream: Bool
    }

    private static let packetSize = 188
    private static let syncByte: UInt8 = 0x47

    private static func describe(_ type: UInt8) -> Stream? {
        switch type {
        case 0x01: Stream(name: "MPEG-1 video", isVideo: true, playsFromTransportStream: false)
        case 0x02: Stream(name: "MPEG-2 video", isVideo: true, playsFromTransportStream: false)
        case 0x1B: Stream(name: "H.264", isVideo: true, playsFromTransportStream: true)
        case 0x24, 0x27: Stream(name: "H.265 (HEVC)", isVideo: true, playsFromTransportStream: false)
        case 0x33: Stream(name: "AV1", isVideo: true, playsFromTransportStream: false)
        case 0x03, 0x04: Stream(name: "MPEG audio", isVideo: false, playsFromTransportStream: true)
        case 0x0F, 0x11: Stream(name: "AAC", isVideo: false, playsFromTransportStream: true)
        case 0x81: Stream(name: "AC-3", isVideo: false, playsFromTransportStream: true)
        case 0x87: Stream(name: "E-AC-3", isVideo: false, playsFromTransportStream: true)
        default: nil
        }
    }

    static func elementaryStreams(in data: Data) -> [Stream] {
        let bytes = [UInt8](data)
        guard let start = bytes.firstIndex(of: syncByte) else { return [] }

        var programMapPIDs = Set<Int>()
        var found: [Stream] = []

        var offset = start
        while offset + packetSize <= bytes.count {
            let packet = Array(bytes[offset..<(offset + packetSize)])
            offset += packetSize
            guard packet[0] == syncByte else {
                // Lost alignment; hunt for the next sync byte rather than
                // walking off into the middle of a packet.
                guard let next = bytes[(offset - packetSize + 1)...].firstIndex(of: syncByte) else { break }
                offset = next
                continue
            }
            guard let section = sectionPayload(of: packet) else { continue }
            let pid = (Int(packet[1] & 0x1F) << 8) | Int(packet[2])

            if pid == 0 {
                programMapPIDs.formUnion(mapPIDs(inPAT: section))
            } else if programMapPIDs.contains(pid) {
                found = streams(inPMT: section)
                if !found.isEmpty { return found }
            }
        }
        return found
    }

    /// The start of a table section carried by this packet, or nil when the
    /// packet doesn't begin one.
    private static func sectionPayload(of packet: [UInt8]) -> ArraySlice<UInt8>? {
        let startsSection = packet[1] & 0x40 != 0
        guard startsSection else { return nil }
        let control = (packet[3] >> 4) & 0x3
        var index = 4
        if control == 2 { return nil }
        if control == 3 {
            index += 1 + Int(packet[4])
        }
        guard index < packet.count else { return nil }
        // A section-carrying payload opens with a pointer to where the section
        // itself starts.
        let pointer = Int(packet[index])
        let sectionStart = index + 1 + pointer
        guard sectionStart < packet.count else { return nil }
        return packet[sectionStart...]
    }

    private static func sectionEnd(_ section: ArraySlice<UInt8>) -> Int? {
        let base = section.startIndex
        guard section.count > 3 else { return nil }
        let length = (Int(section[base + 1] & 0x0F) << 8) | Int(section[base + 2])
        // The last four bytes of every section are its CRC.
        let end = base + 3 + length - 4
        return end <= section.endIndex ? end : nil
    }

    private static func mapPIDs(inPAT section: ArraySlice<UInt8>) -> Set<Int> {
        guard let end = sectionEnd(section) else { return [] }
        var pids = Set<Int>()
        var i = section.startIndex + 8
        while i + 4 <= end {
            let program = (Int(section[i]) << 8) | Int(section[i + 1])
            let pid = (Int(section[i + 2] & 0x1F) << 8) | Int(section[i + 3])
            if program != 0 { pids.insert(pid) }
            i += 4
        }
        return pids
    }

    private static func streams(inPMT section: ArraySlice<UInt8>) -> [Stream] {
        guard let end = sectionEnd(section) else { return [] }
        let base = section.startIndex
        guard base + 12 <= section.endIndex else { return [] }
        let programInfoLength = (Int(section[base + 10] & 0x0F) << 8) | Int(section[base + 11])
        var i = base + 12 + programInfoLength
        var out: [Stream] = []
        while i + 5 <= end {
            let type = section[i]
            let infoLength = (Int(section[i + 3] & 0x0F) << 8) | Int(section[i + 4])
            if let stream = describe(type) { out.append(stream) }
            i += 5 + infoLength
        }
        return out
    }
}
