//  How the files on this device fold into shows, seasons and films.
//
//  Downloads used to be presented as one flat list of episode titles, which is
//  not how anything else in the app presents a library — Home and the library
//  pages show a show as one poster and let you open it. These are the groups
//  that let Downloads do the same, built out of the records themselves so they
//  survive with no server to ask.

import Foundation

#if !os(tvOS)

/// One season's worth of downloads, under the show it belongs to.
struct DownloadSeason: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    /// The season's own poster. Nil for anything downloaded before seasons had
    /// one recorded, and for a season the server has no artwork for — callers
    /// fall back to the show's.
    var posterURL: String?
    var records: [DownloadRecord]

    var unwatched: Int { records.filter { !$0.played }.count }
    var bytes: Int64 { records.reduce(0) { $0 + max($1.receivedBytes, $1.totalBytes) } }
}

/// A show with at least one episode on this device.
struct DownloadSeries: Identifiable, Hashable, Sendable {
    /// The server's series id where a record carries one, and the show's name
    /// where it doesn't. Stable enough to put on a navigation path, which is
    /// what the Downloads grid pushes when a poster is tapped.
    var id: String
    var title: String
    var posterURL: String?
    var seasons: [DownloadSeason]
    /// Every episode in the show, season and episode order — what Play and
    /// Shuffle draw from.
    var records: [DownloadRecord]

    var unwatched: Int { records.filter { !$0.played }.count }
    var bytes: Int64 { records.reduce(0) { $0 + max($1.receivedBytes, $1.totalBytes) } }

    /// Where a "Play" on the show itself should start: the first episode not
    /// yet watched, or the top of the show once it has all been seen.
    var resumePoint: DownloadRecord? {
        records.first { !$0.played } ?? records.first
    }

    var subtitle: String {
        let s = seasons.count, e = records.count
        return "\(s) season\(s == 1 ? "" : "s") · \(e) episode\(e == 1 ? "" : "s")"
    }
}

enum DownloadGroups {
    /// Which show a record belongs to. Falls back to the name so records made
    /// before series ids were stored still group rather than each becoming a
    /// show of one.
    static func key(for record: DownloadRecord) -> String {
        if let id = record.seriesId, !id.isEmpty { return id }
        return "name:" + (record.series ?? record.title)
    }

    /// Films on this device, alphabetical.
    static func films(_ records: [DownloadRecord]) -> [DownloadRecord] {
        records
            .filter { $0.status == .complete && !$0.isEpisode && !$0.isAudio }
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    /// Shows on this device, alphabetical, each with its seasons in order.
    static func series(_ records: [DownloadRecord]) -> [DownloadSeries] {
        var buckets: [String: [DownloadRecord]] = [:]
        for record in records where record.status == .complete && record.isEpisode && !record.isAudio {
            buckets[key(for: record), default: []].append(record)
        }

        return buckets.map { key, group -> DownloadSeries in
            let ordered = group.sorted {
                (seasonSortKey($0.season), $0.episode ?? 0, $0.name)
                    < (seasonSortKey($1.season), $1.episode ?? 0, $1.name)
            }
            // Ordered already, so walking it is enough to cut the seasons out in
            // order without a second sort.
            var seasons: [DownloadSeason] = []
            for record in ordered {
                let id = "\(key)-\(record.season.map(String.init) ?? "none")"
                if seasons.last?.id == id {
                    seasons[seasons.count - 1].records.append(record)
                    if seasons[seasons.count - 1].posterURL == nil {
                        seasons[seasons.count - 1].posterURL = record.seasonArtURL
                    }
                } else {
                    seasons.append(DownloadSeason(
                        id: id,
                        title: seasonTitle(record.season),
                        posterURL: record.seasonArtURL,
                        records: [record]
                    ))
                }
            }
            return DownloadSeries(
                id: key,
                title: ordered.first?.series ?? ordered.first?.title ?? "Unknown series",
                // Lazily: the first episode with a picture is the answer, and
                // each look asks about a file.
                posterURL: ordered.lazy.compactMap(\.seriesArtURL).first
                    ?? ordered.lazy.compactMap(\.artURL).first,
                seasons: seasons,
                records: ordered
            )
        }
        .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    @MainActor
    static func series(id: String) -> DownloadSeries? {
        current().series.first { $0.id == id }
    }

    /// The shows and films, grouped once per change to the downloads rather
    /// than on every read. The Downloads screen read them from several places
    /// in its body, and one show's page grouped every show to find its own —
    /// each a bucket-and-sort of every record, redone whenever either page
    /// redrew. The records are still read, so a view asking is told when they
    /// change.
    @MainActor
    static func current() -> (series: [DownloadSeries], films: [DownloadRecord]) {
        let downloads = DownloadManager.shared
        let records = downloads.records
        if let grouped, grouped.revision == downloads.videoRevision {
            return (grouped.series, grouped.films)
        }
        let result = (series: series(records), films: films(records))
        grouped = (downloads.videoRevision, result.series, result.films)
        return result
    }

    @MainActor
    private static var grouped: (revision: Int, series: [DownloadSeries], films: [DownloadRecord])?

    /// Specials are season 0 on the server but belong at the end of a show, and
    /// an episode with no season at all belongs after those.
    static func seasonSortKey(_ season: Int?) -> Int {
        switch season {
        case .none: Int.max
        case .some(0): Int.max - 1
        case .some(let n): n
        }
    }

    static func seasonTitle(_ season: Int?) -> String {
        switch season {
        case .none: "Other episodes"
        case .some(0): "Specials"
        case .some(let n): "Season \(n)"
        }
    }
}

#endif
