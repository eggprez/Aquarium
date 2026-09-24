//  A second way onto Live TV, for a channel line-up Jellyfin never sees: a
//  plain M3U playlist for the channels and streams, XMLTV for the schedule.
//  See LiveTVView.
//
//  Nothing here talks to a server. These read whatever bytes IPTVSource
//  fetched from the URLs in Settings; IPTVSource is what turns the result
//  into the `BaseItem` shape the Jellyfin path already draws.

import Foundation

// MARK: - M3U

struct M3UEntry: Sendable {
    var id: String
    var name: String
    var logoURL: String?
    var channelNumber: String?
    var streamURL: String
}

enum M3UParser {
    /// `#EXTINF:-1 tvg-id="..." tvg-name="..." tvg-logo="..." tvg-chno="...",Channel Name`
    /// followed by the stream URL on its own line. Anything else —
    /// `#EXTGRP`, `#EXTVLCOPT`, blank lines — is skipped rather than
    /// rejected: a playlist found in the wild is never only the lines this
    /// cares about.
    static func parse(_ text: String) -> [M3UEntry] {
        var entries: [M3UEntry] = []
        var pendingAttributes: [String: String] = [:]
        var pendingName: String?
        var autoId = 0

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#EXTINF") {
                let (attributes, name) = parseExtinf(line)
                pendingAttributes = attributes
                pendingName = name
            } else if line.hasPrefix("#") {
                continue
            } else {
                let attributes = pendingAttributes
                let name = pendingName
                pendingAttributes = [:]
                pendingName = nil
                guard let name, !name.isEmpty else { continue }
                autoId += 1
                let tvgId = attributes["tvg-id"]
                entries.append(M3UEntry(
                    id: (tvgId?.isEmpty == false ? tvgId! : "auto-\(autoId)"),
                    name: name,
                    logoURL: attributes["tvg-logo"],
                    channelNumber: attributes["tvg-chno"],
                    streamURL: line
                ))
            }
        }
        return entries
    }

    private static let attributePattern = try! NSRegularExpression(pattern: #"([\w-]+)="([^"]*)""#)

    private static func parseExtinf(_ line: String) -> (attributes: [String: String], name: String) {
        var attributes: [String: String] = [:]
        let ns = line as NSString
        for match in attributePattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges == 3 else { continue }
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            attributes[key] = ns.substring(with: match.range(at: 2))
        }
        // The display name is everything after the comma that ends the
        // attribute list — not after the *last* comma, which is a channel
        // called "BBC One, HD" being listed as "HD", and a `group-title` of
        // "Movies, Action" swallowing the name entirely. Commas inside a
        // quoted attribute value don't end anything, so the split point is
        // the first one that isn't inside quotes.
        var inQuotes = false
        var name = ""
        for (offset, character) in line.enumerated() {
            if character == "\"" {
                inQuotes.toggle()
            } else if character == ",", !inQuotes {
                name = String(line.dropFirst(offset + 1))
                break
            }
        }
        return (attributes, name.trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - XMLTV

struct XMLTVProgramme: Sendable {
    var channelId: String
    var title: String
    var desc: String?
    var start: Date
    var stop: Date
}

/// A streaming XML parser rather than a DOM: a real XMLTV feed covering a
/// week of a few hundred channels runs to tens of megabytes, and this only
/// ever needs the handful of fields below.
final class XMLTVParser: NSObject, XMLParserDelegate {
    private(set) var channelIcons: [String: String] = [:]
    private(set) var channelNames: [String: String] = [:]
    private(set) var programmes: [XMLTVProgramme] = []

    private var currentChannelId: String?
    private var currentText = ""
    private var pendingChannel: String?
    private var pendingStart: Date?
    private var pendingStop: Date?
    private var pendingTitle: String?
    private var pendingDesc: String?
    /// Programmes the feed gave no `stop` — allowed by XMLTV, and common on
    /// feeds that mean "until the next one". Ended once the whole file is in.
    private var openEnded: [XMLTVProgramme] = []

    static func parse(_ data: Data) -> XMLTVParser {
        let result = XMLTVParser()
        let parser = XMLParser(data: data)
        // A guide is whatever address the user typed; it gets no say over what
        // else is read. Off by default, and said so here.
        parser.shouldResolveExternalEntities = false
        parser.delegate = result
        parser.parse()
        result.closeOpenEnded()
        return result
    }

    /// A programme with no stop runs until the next one on its channel starts,
    /// or for half an hour when nothing follows it.
    private func closeOpenEnded() {
        guard !openEnded.isEmpty else { return }
        var starts: [String: [Date]] = [:]
        for p in programmes { starts[p.channelId, default: []].append(p.start) }
        for p in openEnded { starts[p.channelId, default: []].append(p.start) }
        for key in starts.keys { starts[key]?.sort() }
        for var p in openEnded {
            let next = starts[p.channelId]?.first { $0 > p.start }
            p.stop = next ?? p.start.addingTimeInterval(30 * 60)
            programmes.append(p)
        }
        openEnded = []
    }

    func parser(
        _ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String]
    ) {
        currentText = ""
        switch element {
        case "channel":
            currentChannelId = attributes["id"]
        case "icon":
            // First one wins, like `display-name` below: a channel is often
            // given several icons, and the one the feed lists first is the
            // one it means — the rest are alternates and, on the feeds that
            // ship them, sometimes empty.
            if let id = currentChannelId, let src = attributes["src"],
               !src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               channelIcons[id] == nil {
                channelIcons[id] = src
            }
        case "programme":
            pendingChannel = attributes["channel"]
            pendingStart = Self.parseDate(attributes["start"])
            pendingStop = Self.parseDate(attributes["stop"])
            pendingTitle = nil
            pendingDesc = nil
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        currentText = ""
        switch element {
        case "display-name":
            if let id = currentChannelId, channelNames[id] == nil, !text.isEmpty { channelNames[id] = text }
        case "title":
            if pendingTitle == nil { pendingTitle = text }
        case "desc":
            pendingDesc = text.isEmpty ? nil : text
        case "channel":
            currentChannelId = nil
        case "programme":
            if let channel = pendingChannel, let start = pendingStart, let title = pendingTitle {
                if let stop = pendingStop {
                    if stop > start {
                        programmes.append(XMLTVProgramme(channelId: channel, title: title, desc: pendingDesc, start: start, stop: stop))
                    }
                } else {
                    openEnded.append(XMLTVProgramme(channelId: channel, title: title, desc: pendingDesc, start: start, stop: start))
                }
            }
            pendingChannel = nil
            pendingStart = nil
            pendingStop = nil
            pendingTitle = nil
            pendingDesc = nil
        default:
            break
        }
    }

    /// `20240115193000 +0000`, the usual shape — but XMLTV allows the time to
    /// be cut short (`yyyyMMddHHmm`, down to `yyyyMMdd`), and feeds in the wild
    /// write the zone with no space (`+0100`), with a colon (`+01:00`), or as
    /// `Z`/`UTC`/`GMT`. No zone means UTC. Parsed by hand rather than with a
    /// formatter per shape, which also makes this safe off the main thread.
    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let chars = Array(raw.trimmingCharacters(in: .whitespaces))
        var i = 0
        while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1 }
        let digits = chars[0..<i].compactMap { $0.wholeNumberValue }
        // yyyyMMdd at the least, and whole fields after it.
        guard digits.count >= 8, digits.count <= 14, digits.count % 2 == 0 else { return nil }
        func field(_ from: Int, _ length: Int) -> Int {
            guard from + length <= digits.count else { return 0 }
            return digits[from..<from + length].reduce(0) { $0 * 10 + $1 }
        }
        var parts = DateComponents()
        parts.year = field(0, 4)
        parts.month = field(4, 2)
        parts.day = field(6, 2)
        parts.hour = field(8, 2)
        parts.minute = field(10, 2)
        parts.second = field(12, 2)

        // The zone: whatever follows, spaces and all.
        let rest = String(chars[i...]).trimmingCharacters(in: .whitespaces)
        var offset = 0
        if let sign = rest.first, sign == "+" || sign == "-" {
            let zone = rest.dropFirst().filter { $0 != ":" }
            guard zone.count == 4 || zone.count == 2, zone.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(zone)
            else { return nil }
            let hours = zone.count == 4 ? value / 100 : value
            let minutes = zone.count == 4 ? value % 100 : 0
            offset = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        } else if !rest.isEmpty, !["Z", "UTC", "GMT"].contains(rest.uppercased()) {
            return nil
        }
        parts.timeZone = TimeZone(secondsFromGMT: offset)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: parts)
    }
}
