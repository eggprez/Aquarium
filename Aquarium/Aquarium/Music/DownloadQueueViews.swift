//  What the Music and Audiobooks tabs say about downloads that haven't
//  finished: a strip at the top of the tab while there is a queue, and a mark
//  on each song or book that is in it.
//
//  Both are views of their own rather than lines in somebody else's `body`.
//  The queue changes once per song for as long as a library takes to drain,
//  and whatever reads it is redrawn each time — which should be a strip and a
//  handful of marks, not the page they sit on.

import SwiftUI

#if os(iOS)

/// "Downloading 1,204 songs" across the top of the tab, for as long as that
/// is true. Tapping it goes to Downloads, where the queue itself is.
struct DownloadQueueBanner: View {
    /// The Audiobooks tab's strip counts books; Music's counts songs.
    var books = false

    @Environment(AppModel.self) private var app
    @State private var downloads = DownloadManager.shared

    var body: some View {
        let waiting = downloads.audioBacklog(books: books)
        if waiting > 0 {
            Button {
                app.show(.downloads)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(.pulse, options: .repeating)
                    Text(label(waiting))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer()
                    Text("Downloads")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textDim)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textDim)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 6)
            .background(Theme.background)
            .accessibilityHint("Opens Downloads")
        }
    }

    private func label(_ n: Int) -> String {
        let noun = books ? (n == 1 ? "audiobook" : "audiobooks") : (n == 1 ? "song" : "songs")
        return "Downloading \(n.formatted()) \(noun)"
    }
}

/// The mark at the end of a song's row: on this device, arriving, or waiting
/// its turn. Nothing at all for a song that is none of those.
struct DownloadStateMark: View {
    let itemId: String

    @State private var downloads = DownloadManager.shared

    var body: some View {
        if downloads.record(for: itemId)?.status == .complete {
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.textDim)
                .accessibilityLabel("Downloaded")
        } else if let state = downloads.transferState(of: itemId) {
            switch state {
            case .downloading:
                Image(systemName: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.pulse, options: .repeating)
                    .accessibilityLabel("Downloading")
            case .queued:
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                    .accessibilityLabel("Waiting to download")
            }
        }
    }
}

/// The same in words, for a page about one thing — an audiobook's. Tapping
/// it goes to the queue.
struct DownloadStateLine: View {
    let itemId: String

    @Environment(AppModel.self) private var app
    @State private var downloads = DownloadManager.shared

    var body: some View {
        if downloads.record(for: itemId)?.status == .complete {
            Label("On this device", systemImage: "arrow.down.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textDim)
        } else if let state = downloads.transferState(of: itemId) {
            Button {
                app.show(.downloads)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: state == .downloading ? "arrow.down.circle" : "clock")
                        .symbolEffect(.pulse, options: .repeating, isActive: state == .downloading)
                    Text(state == .downloading ? "Downloading…" : "Waiting in the download queue")
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(state == .downloading ? Theme.accent : Theme.textDim)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// The same, over the corner of a cover — for an audiobook, which is a tile
/// and has no row to put a mark at the end of.
struct DownloadStateBadge: View {
    let itemId: String

    @State private var downloads = DownloadManager.shared

    var body: some View {
        if let symbol {
            Image(systemName: symbol.name)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(5)
                .background(symbol.tint, in: Circle())
                .padding(6)
                .accessibilityLabel(symbol.label)
        }
    }

    private var symbol: (name: String, tint: Color, label: String)? {
        if downloads.record(for: itemId)?.status == .complete {
            return ("arrow.down", Color.black.opacity(0.55), "Downloaded")
        }
        switch downloads.transferState(of: itemId) {
        case .downloading: return ("arrow.down", Theme.accent, "Downloading")
        case .queued: return ("clock", Color.black.opacity(0.55), "Waiting to download")
        case nil: return nil
        }
    }
}

#endif
