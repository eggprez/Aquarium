//  A subtitle file read into timed lines, for the one place the app draws
//  subtitles itself: a download's subtitle file over Apple's player.
//
//  AVPlayer has no way to take a subtitle file in — its subtitles are tracks
//  of the stream — and a download saved as a stream is a package only
//  AVFoundation opens, so there is no handing it to mpv either. The files
//  `DownloadSubtitles` saves are SubRip, or ASS for a track that was ASS, and
//  both are simple enough to read: this keeps the times and the words and
//  lets the styling go.

import Foundation

struct SubtitleCue: Hashable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

enum SubtitleCues {
    /// The lines of a `.srt`, `.vtt` or `.ass` file in time order, or none
    /// when it can't be read as one.
    static func load(_ url: URL) -> [SubtitleCue] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(decoding: data, as: UTF8.self)
        let ext = url.pathExtension.lowercased()
        return parse(text, isASS: ext == "ass" || ext == "ssa")
    }

    static func parse(_ text: String, isASS: Bool) -> [SubtitleCue] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            .components(separatedBy: "\n")
        let cues = isASS ? parseASS(lines) : parseSRT(lines)
        return cues.filter { !$0.text.isEmpty && $0.end > $0.start }.sorted { $0.start < $1.start }
    }

    /// The lines on screen at `seconds`, top to bottom in the file's order.
    static func text(in cues: [SubtitleCue], at seconds: Double) -> String? {
        // The first cue starting after the moment, by bisection; the ones on
        // screen are a short way back from it.
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= seconds { low = mid + 1 } else { high = mid }
        }
        var shown: [String] = []
        var i = low - 1
        // A long cue can sit behind several short ones; a minute back is
        // further than any real file overlaps.
        while i >= 0, seconds - cues[i].start < 60 {
            if cues[i].end > seconds { shown.insert(cues[i].text, at: 0) }
            i -= 1
        }
        return shown.isEmpty ? nil : shown.joined(separator: "\n")
    }

    // MARK: SubRip and WebVTT

    /// Both are blocks of "start --> end" over the words, and differ only in
    /// what sits around them, none of which is kept.
    private static func parseSRT(_ lines: [String]) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var i = 0
        while i < lines.count {
            guard let arrow = lines[i].range(of: "-->") else {
                i += 1
                continue
            }
            let from = String(lines[i][..<arrow.lowerBound])
            // WebVTT puts position settings after the end time.
            let to = lines[i][arrow.upperBound...].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            i += 1
            var words: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                words.append(lines[i])
                i += 1
            }
            guard let start = seconds(from), let end = seconds(to) else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: plain(words.joined(separator: "\n"))))
        }
        return cues
    }

    // MARK: ASS

    /// `Dialogue:` lines, their fields in the order the `Format:` line of the
    /// events section gives. The text is the last field and may hold commas.
    private static func parseASS(_ lines: [String]) -> [SubtitleCue] {
        var format = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var inEvents = false
        var cues: [SubtitleCue] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.lowercased() == "[events]"
                continue
            }
            guard inEvents else { continue }
            if line.lowercased().hasPrefix("format:") {
                format = line.dropFirst("format:".count).split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard line.lowercased().hasPrefix("dialogue:"), !format.isEmpty else { continue }
            let fields = line.dropFirst("dialogue:".count)
                .split(separator: ",", maxSplits: format.count - 1, omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count == format.count,
                  let startAt = format.firstIndex(of: "start"), let endAt = format.firstIndex(of: "end"),
                  let textAt = format.firstIndex(of: "text"),
                  let start = seconds(fields[startAt]), let end = seconds(fields[endAt]) else { continue }
            var words = fields[textAt]
            // A drawing is shapes, not words.
            if words.range(of: #"\{[^}]*\\p[1-9]"#, options: .regularExpression) != nil { continue }
            words = words.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: " ")
                .replacingOccurrences(of: "\\h", with: " ")
            cues.append(SubtitleCue(start: start, end: end, text: plain(words)))
        }
        return cues
    }

    // MARK: Pieces

    /// "01:02:03,450", "02:03.450" or "1:02:03.45", in seconds.
    private static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// The words without their markup: `<i>`, `<font …>`, `{\an8}`.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
