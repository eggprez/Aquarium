//  The stream inspector: what is actually arriving, beside the picture.
//
//  The tvOS ribbon draws these numbers across the top of the picture because
//  a television has nowhere else to put them. A Mac has an inspector — the
//  column Finder and Preview open on ⌘I — and that is what this is: the same
//  rows `PlayerStreamRows` reads for the ribbon, in a `Form` of labelled
//  values, toggled from Playback ▸ Stream Info and left open while the picture
//  plays. It lives beside the video rather than over it, so nothing here has
//  to be legible against a snow scene.
//
//  Redraws on `player.position`, which moves every half second — the only
//  clock the throughput, stall and dropped-frame figures have, since none of
//  them is a property anything writes. See `PlayerStreamRows`.

#if os(macOS)
import SwiftUI

struct StreamInfoInspector: View {
    let player: PlayerModel

    var body: some View {
        let rows = PlayerStreamRows(player: player)
        // Read here so the body is redrawn on the player's clock even when
        // nothing else in it changed.
        let _ = player.position
        Form {
            Section("Now Playing") {
                LabeledContent("Title", value: player.title)
                if !player.subtitle.isEmpty {
                    LabeledContent("Episode", value: player.subtitle)
                }
                if let facts = factsLine {
                    LabeledContent("Details", value: facts)
                }
            }
            let file = rows.file
            if !file.isEmpty {
                section("On the Server", file)
            }
            section("Coming Down", rows.stream)
            section("Right Now", rows.now)
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
        .navigationTitle("Stream Info")
    }

    private func section(_ title: String, _ rows: [PlayerStreamRows.Row]) -> some View {
        Section(title) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                LabeledContent(row.label, value: row.value)
                    // A host name or a codec string wider than the column
                    // is still worth reading in full.
                    .help(row.value)
            }
        }
    }

    /// Year, runtime, rating — the line the title page shows, when the item
    /// carries it.
    private var factsLine: String? {
        guard let item = player.infoItem else { return nil }
        var parts: [String] = []
        if let year = item.ProductionYear { parts.append(String(year)) }
        let runtime = Format.ticks(item.RunTimeTicks)
        if !runtime.isEmpty { parts.append(runtime) }
        if let rating = item.OfficialRating, !rating.isEmpty { parts.append(rating) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
#endif
