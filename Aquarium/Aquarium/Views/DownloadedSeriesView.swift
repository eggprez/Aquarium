//  One downloaded show: its poster, its seasons, and everything on this device
//  belonging to it — plus the delete controls for the whole show and for a
//  season at a time, which is the way most of a phone's space is reclaimed.
//
//  Everything here reads the records, so it works with no server.

import SwiftUI

#if !os(tvOS)

struct DownloadedSeriesView: View {
    /// The key `DownloadGroups` gave the show, not necessarily a server id.
    let seriesKey: String

    @Environment(AppModel.self) private var app
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss

    @State private var downloads = DownloadManager.shared
    @State private var pendingDeletion: DownloadDeletion?

    private var show: DownloadSeries? {
        DownloadGroups.series(id: seriesKey)
    }

    var body: some View {
        #if os(macOS)
        // A list under season headers, with the actions in the toolbar — see
        // `DownloadsView+Mac.swift`.
        MacDownloadedSeriesView(seriesKey: seriesKey)
        #else
        phoneBody
        #endif
    }

    #if !os(macOS)
    private var phoneBody: some View {
        ScrollView {
            if let show {
                LazyVStack(alignment: .leading, spacing: 22) {
                    header(show)
                    ForEach(show.seasons) { season in
                        seasonSection(season, show: show)
                    }
                }
                .padding(.vertical, 16)
                .padding(.bottom, 24)
            } else {
                EmptyState(
                    symbol: "trash",
                    title: "Nothing left here",
                    message: "Every episode of this show has been deleted from this device."
                )
            }
        }
        .navigationTitle(show?.title ?? "Downloads")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .downloadDeletionDialog($pendingDeletion) { ids in
            let n = downloads.delete(ids)
            app.toast("Deleted \(n) episode\(n == 1 ? "" : "s")", tone: .ok)
            // The last episode taking the page with it is better than leaving
            // an empty screen the back button is the only way out of.
            if show == nil { dismiss() }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ show: DownloadSeries) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                RemoteImage(url: show.posterURL.flatMap(URL.init(string:)))
                    .frame(width: 96, height: 144)
                    .cardChrome(radius: 8)

                VStack(alignment: .leading, spacing: 4) {
                    Text(show.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.text)
                    Text(show.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                    Text(Format.bytes(show.bytes))
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                    if show.unwatched > 0 {
                        Text("\(show.unwatched) unwatched")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }
                Spacer(minLength: 0)
            }

            WrappingRow(spacing: 10, rowSpacing: 10) {
                if let start = show.resumePoint {
                    Button {
                        player.playLocal(start)
                    } label: {
                        Label(show.unwatched > 0 ? "Play next" : "Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accentStrong)
                }

                if show.records.count > 1 {
                    Button {
                        player.startShuffle(show.records)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                }

                Menu {
                    ForEach(show.seasons) { season in
                        Button(role: .destructive) {
                            pendingDeletion = .season(season, show: show.title)
                        } label: {
                            Label("Delete \(season.title) · \(season.records.count)", systemImage: "rectangle.stack")
                        }
                    }
                    let watched = show.records.filter(\.played)
                    if !watched.isEmpty {
                        Button(role: .destructive) {
                            pendingDeletion = DownloadDeletion(
                                title: "Delete watched episodes of \(show.title)?",
                                message: "\(watched.count) episode\(watched.count == 1 ? "" : "s") · \(Format.bytes(watched.reduce(0) { $0 + max($1.receivedBytes, $1.totalBytes) }))",
                                confirmLabel: "Delete \(watched.count) episode\(watched.count == 1 ? "" : "s")",
                                ids: watched.map(\.itemId)
                            )
                        } label: {
                            Label("Delete watched · \(watched.count)", systemImage: "checkmark.circle")
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        pendingDeletion = .series(show)
                    } label: {
                        Label("Delete the whole show", systemImage: "trash")
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(Theme.danger)
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }

    // MARK: - Seasons

    @ViewBuilder
    private func seasonSection(_ season: DownloadSeason, show: DownloadSeries) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                // The season's own poster where the server has one, the show's
                // where it doesn't — so a heading is never a blank rectangle.
                RemoteImage(
                    url: season.posterURL.flatMap(URL.init(string:)),
                    fallbackURL: show.posterURL.flatMap(URL.init(string:))
                )
                .frame(width: 44, height: 66)
                .cardChrome(radius: 6)

                VStack(alignment: .leading, spacing: 1) {
                    Text(season.title)
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                    Text("\(season.records.count) episode\(season.records.count == 1 ? "" : "s") · \(Format.bytes(season.bytes))")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
                Spacer()
                Menu {
                    if let first = season.records.first(where: { !$0.played }) ?? season.records.first {
                        Button {
                            player.playLocal(first)
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                    }
                    if season.records.count > 1 {
                        Button {
                            player.startShuffle(season.records)
                        } label: {
                            Label("Shuffle this season", systemImage: "shuffle")
                        }
                    }
                    Button(role: .destructive) {
                        pendingDeletion = .season(season, show: show.title)
                    } label: {
                        Label("Delete this season", systemImage: "trash")
                    }
                } label: {
                    Label("Season options", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                }
            }

            ForEach(season.records) { record in
                DownloadedRow(record: record, showsContext: false, fallbackPosterURL: show.posterURL) {
                    player.playLocal(record)
                } onDelete: {
                    downloads.delete(record.itemId)
                } onToggleWatched: {
                    downloads.setPlayed(record.itemId, played: !record.played)
                }
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }
    #endif
}

#endif
