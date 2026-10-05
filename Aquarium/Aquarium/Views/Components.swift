//  The pieces every screen is built from: cards, rows, the empty and error
//  states, and the toast overlay.

import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Metrics

enum Metrics {
    /// Poster width. A television is looked at from across a room and a phone
    /// from thirty centimetres, so the same "five across" is a very different
    /// number of points. On a phone this is the shelf size only — grids there
    /// size their cards from the column instead, so the count is exact.
    static var posterWidth: CGFloat {
        #if os(tvOS)
        return 240
        #elseif os(macOS)
        return 168
        #else
        return 112
        #endif
    }

    /// 16:9 stills — episodes, channels, backdrops.
    static var stillWidth: CGFloat { posterWidth * 1.62 }

    /// Between cards in a horizontal shelf.
    static var rowSpacing: CGFloat {
        #if os(tvOS)
        return 40
        #elseif os(macOS)
        return 16
        #else
        return 12
        #endif
    }

    /// Between columns in a grid. Tighter than a shelf: a grid is read as one
    /// block, and narrow gutters are what make it read that way.
    static var gridSpacing: CGFloat {
        #if os(tvOS)
        return 40
        #elseif os(macOS)
        return 16
        #else
        return 10
        #endif
    }

    /// Between rows in a grid. A card already carries two lines of text under
    /// its artwork, so this only has to separate that text from the next row's
    /// picture — it doesn't need to be the horizontal gap plus a margin.
    static var gridRowSpacing: CGFloat {
        #if os(tvOS)
        return 52
        #elseif os(macOS)
        return 26
        #else
        return 18
        #endif
    }

    /// Between one horizontal shelf and the next.
    static var shelfSpacing: CGFloat {
        #if os(tvOS)
        return 44
        #elseif os(macOS)
        return 30
        #else
        return 22
        #endif
    }

    /// Between a shelf's heading and its cards.
    static var shelfTitleSpacing: CGFloat {
        #if os(tvOS)
        return 16
        #elseif os(macOS)
        return 10
        #else
        return 8
        #endif
    }

    /// Breathing room around a shelf's cards. tvOS needs it because focus
    /// grows the card and would otherwise clip it against the row above; the
    /// Mac because the hover ring sits a few points outside the tile, and a
    /// scroll view clips at its own edge.
    static var shelfCardPadding: CGFloat {
        #if os(tvOS)
        return 18
        #elseif os(macOS)
        return 10
        #else
        return 0
        #endif
    }

    /// Between a card's artwork and the two lines of text under it.
    ///
    /// A television needs room the others don't: the artwork grows when the
    /// selector reaches it, and on six points of gap the bottom of a focused
    /// poster came down over its own title. This is the growth plus a margin,
    /// so the text stays where it is and stays legible.
    static var cardTextSpacing: CGFloat {
        #if os(tvOS)
        return 22
        #elseif os(macOS)
        return 7
        #else
        return 6
        #endif
    }

    /// The page margin. Twenty on the Mac — the inset a system window's
    /// content sits at — where twenty-eight was a tablet's thumb-room.
    static var gutter: CGFloat {
        #if os(tvOS)
        return 60
        #elseif os(macOS)
        return 20
        #else
        return 16
        #endif
    }

    /// Points per minute on the Live TV guide's timeline.
    ///
    /// A phone works it out rather than naming it: half an hour is meant to be
    /// exactly what fits across the screen with the phone held upright, so the
    /// scale is whatever divides the portrait programme area — the screen less
    /// the channel column — into thirty minutes.
    ///
    /// It is derived from the *portrait* width whichever way the phone is
    /// being held at the time, so this is one number for the life of the app
    /// rather than something that changes underneath a rotation. Turning the
    /// phone sideways then does what turning it is for: the same points per
    /// minute across a wider screen is more of the evening, rather than the
    /// same half hour stretched over it.
    ///
    /// Everything else names a number. A mouse has more room to read a wide
    /// row than a phone screen wants to spend, so the scale on macOS runs a
    /// little more generous; a television furthest of all, read from across a
    /// room, same reasoning as `posterWidth`. An iPad keeps the density it had
    /// — a half hour across a screen that wide is a guide showing almost
    /// nothing at all.
    ///
    static var guideMinuteWidth: CGFloat {
        #if os(tvOS)
        // Twelve, not six. At six a television fitted about four hours across
        // the screen, which sounds generous and reads as nothing: a half-hour
        // programme got 180 points, its title clipped to a word or two and the
        // time under it dropped by `GuideCell`'s own width tests. Doubled, the
        // same screen shows about two hours and a half-hour cell is 360 points
        // — two lines of title and the times beneath them, legible from a sofa.
        // The window itself is still six hours; the rest is a scroll to the
        // right, which is how a guide has always been read.
        return 12
        #elseif os(macOS)
        // 180 points to a half hour: two lines of title and the time under
        // them. At 4.5 a half-hour cell was cut to a word, and anything that
        // started before the window was a sliver reading "Fr".
        return 6
        #else
        return phoneGuideMinuteWidth
        #endif
    }

    #if os(iOS)
    /// Worked out once, the first time the guide asks, and a plain number from
    /// then on.
    ///
    /// A `let` rather than a computed property because this sits in the middle
    /// of a layout pass. Asking UIKit for the screen on every cell of every row
    /// puts a reading of live view-hierarchy state inside SwiftUI's own update
    /// of that hierarchy — a dependency its graph cannot see and has no reason
    /// to expect to hold still. Answered once and cached, it is the constant
    /// the rest of the guide's arithmetic takes it for. A phone's screen does
    /// not change size, so there is nothing to recompute anyway.
    private static let phoneGuideMinuteWidth: CGFloat = MainActor.assumeIsolated {
        // An iPad names a number like everything else that isn't a phone.
        // It was 3.4, on the reasoning above that a half hour across so wide
        // a screen shows nothing — but at 3.4 a half hour is a hundred points
        // and a sitcom's 22 minutes is 75, and nearly every cell in the grid
        // read "F…" or "Bo…". At 5.5 an iPad on its side still shows two hours
        // and the titles are words.
        guard UIDevice.current.userInterfaceIdiom == .phone else { return 5.5 }
        return (portraitWidth - guideChannelColumnWidth) / 30
    }

    /// This screen's width with the device held upright: the smaller of its
    /// two dimensions, so the answer doesn't depend on which way it is being
    /// held when the question is asked.
    ///
    /// Read from the connected scene rather than `UIScreen.main`, which is the
    /// deprecated spelling and, on a device that can show two apps at once,
    /// the wrong answer. The fallback is a small modern phone — reached only
    /// if there is no window scene at all, in which case nothing is on screen
    /// to measure against anyway.
    @MainActor
    private static var portraitWidth: CGFloat {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let size = scene?.screen.bounds.size ?? CGSize(width: 375, height: 812)
        return min(size.width, size.height)
    }
    #endif

    #if os(iOS)
    /// Asked once, for the same reason as `phoneGuideMinuteWidth`.
    private static let isPhone: Bool = MainActor.assumeIsolated {
        UIDevice.current.userInterfaceIdiom == .phone
    }
    #endif

    /// Width of the guide's pinned channel column.
    static var guideChannelColumnWidth: CGFloat {
        #if os(tvOS)
        return 280
        #elseif os(macOS)
        return 172
        #else
        // A phone has no width to spare; an iPad has, and spends it on the
        // channel's name.
        //
        // 124 left the name itself about 56 points wide once the logo, the
        // spacing and the padding were taken out — not enough room for an
        // ordinary word like "Animation" or "Cartoons" to fit on a line of
        // its own, so the system fell back to breaking it mid-word with a
        // hyphen ("Anima-tion Co…") rather than wrapping at the space after
        // it. 148 gives the label roughly 80 points, which is enough for
        // that kind of word at the row's own font size, at the cost of a
        // fraction of a point per minute off the timeline the rest of the
        // guide draws against.
        return isPhone ? 148 : 172
        #endif
    }

    /// Height of one channel's row in the guide.
    static var guideRowHeight: CGFloat {
        #if os(tvOS)
        return 96
        #elseif os(macOS)
        // A pointer needs no thumb-height row; forty is a two-line table
        // cell, which is what a guide cell holds.
        return 40
        #else
        return 60
        #endif
    }

    /// The channel logo at the head of a guide row. Sized from the row it sits
    /// in rather than fixed: a television's row is half again as tall as a
    /// phone's and more than twice as wide, and the same 40×28 tile that reads
    /// as a channel logo on a phone is an unidentifiable speck from across a
    /// room — which is the one thing the column exists to show.
    static var guideLogoSize: CGSize {
        #if os(tvOS)
        return CGSize(width: 104, height: 68)
        #elseif os(macOS)
        return CGSize(width: 48, height: 32)
        #else
        return CGSize(width: 40, height: 28)
        #endif
    }

    #if os(iOS)
    /// How much bar a page draws for itself below the status bar: exactly as
    /// much as a system navigation bar on this OS — 44 points on iOS 18, 54 on
    /// 26 — asked of UIKit rather than written down, so the app's own bars and
    /// the system's are the same height wherever the two meet. Main actor,
    /// because measuring means making a `UINavigationBar`; everything that
    /// reads it is a view.
    @MainActor static let topBar: CGFloat = {
        let measured = UINavigationBar().sizeThatFits(
            CGSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        ).height
        return measured > 0 ? measured : 44
    }()
    #endif
}

// MARK: - Poster card

/// One tile: artwork, a progress bar if the item was started, a watched tick,
/// and two lines of text under it.
struct PosterCard: View {
    let item: BaseItem
    /// A fixed width, or `nil` to fill whatever the container proposes and take
    /// its height from the aspect ratio — which is what a grid column wants, so
    /// that "three across" is decided by the column count rather than by a
    /// poster width that happens to divide into the screen three times.
    var width: CGFloat? = Metrics.posterWidth
    /// 16:9 rather than 2:3 — episodes and channels read better as stills.
    var wide: Bool = false
    var showSubtitle: Bool = true
    /// Replaces the line under the title where the card knows something the
    /// item doesn't say for itself — a season's episode count, say.
    var subtitle: String?
    /// Which picture the card draws. See `Art`.
    var art: Art = .automatic
    /// Drawn as the selected tile — the Mac grid's click-to-select. Nothing
    /// anywhere else.
    var isSelected: Bool = false

    /// What a card is a picture *of*, where the item alone doesn't settle it.
    enum Art {
        /// Whatever the shape calls for: a still in a wide card, the item's own
        /// poster — or its series' — in a portrait one.
        case automatic
        /// The season, for a card standing in for one episode of a show you are
        /// partway through. See `Artwork.seasonArt`.
        case season
    }

    private var aspect: CGFloat { wide ? 16.0 / 9.0 : 2.0 / 3.0 }

    /// Settled: the server has no picture for this. See `artwork`.
    @State private var artMissing = false
    #if os(macOS)
    @Environment(\.displayScale) private var displayScale
    #endif

    /// What to ask the server for when the card has no width of its own. A
    /// phone column is never far off the shelf size.
    ///
    /// On the Mac the width in points is the shelf's or the column's, and the
    /// pixels are that times the screen's scale: a Retina grid used to ask
    /// for 336 pixels and draw them across 420, which is the blur the review
    /// found on every Mac grid. See `ImageLoader.requestWidth`.
    private var requestWidth: Int {
        #if os(macOS)
        let points = width ?? PosterGrid.columnMaximum(wide: wide)
        return ImageLoader.requestWidth(points: points, displayScale: displayScale)
        #else
        return Int((width ?? Metrics.posterWidth) * 2)
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cardTextSpacing) {
            artwork
                .cardChrome()
                .overlay(alignment: .topTrailing) { badges }
                // The focus lift belongs to the artwork alone. Applied to the
                // whole tile it clips the two lines of text into the poster's
                // rounded rect, and a focused card reads as its own title
                // printed over its own picture. (The Mac's hover is the other
                // way round — see `macTileState` below.)
                .artworkFocus()

            if showSubtitle {
                VStack(alignment: .leading, spacing: 1) {
                    Text(cardTitle)
                        .font(titleFont)
                        .lineLimit(1)
                        .foregroundStyle(Theme.text)
                    ForEach(Array(cardLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(subtitleFont)
                            .lineLimit(1)
                            // "Season 1: Episode 1" is a few points wider than a
                            // phone's poster column; shrinking it slightly is
                            // better than ending it in an ellipsis. Not on the
                            // Mac, where shrunken type next to unshrunken type
                            // is the thing that reads as wrong.
                            .minimumScaleFactor(subtitleScale)
                            .foregroundStyle(Theme.textDim)
                    }
                }
                .frame(maxWidth: width ?? .infinity, alignment: .leading)
            }
        }
        // The Mac's hover and selection enclose the whole tile, name and all:
        // a tile is a thing you select, and a ring around the picture alone
        // leaves the name looking like it belongs to the tile above.
        .macTileState(isSelected: isSelected)
    }

    /// `.subheadline` and `.caption` were tuned for a phone; on the Mac they
    /// come out at eleven and ten points, which under a 200-point poster is
    /// fine print. `.callout` and `.subheadline` there are the sizes the
    /// system's own media apps set a tile's name and line of facts in.
    private var titleFont: Font {
        #if os(macOS)
        .callout.weight(.medium)
        #else
        .subheadline.weight(.medium)
        #endif
    }

    private var subtitleFont: Font {
        #if os(macOS)
        .subheadline
        #else
        .caption
        #endif
    }

    private var subtitleScale: CGFloat {
        #if os(macOS)
        1
        #else
        0.8
        #endif
    }

    /// The picture, what to try when it isn't there, and the blur to paint
    /// meanwhile.
    ///
    /// The BlurHash goes only with the item's own artwork. Season art is a
    /// different picture in a different shape, and the hash filed against the
    /// episode is the blur of its 16:9 still — a wide smear behind a portrait
    /// poster, which reads as the wrong image loading rather than as a
    /// placeholder.
    private var source: (url: URL?, fallback: URL?, hash: String?) {
        switch art {
        case .automatic:
            let url = wide
                ? Artwork.still(for: item, width: requestWidth)
                : Artwork.poster(for: item, width: requestWidth)
            return (url, nil, Artwork.hash(item, type: wide ? Artwork.stillType(for: item) : "Primary"))
        case .season:
            let pair = Artwork.seasonArt(for: item, width: requestWidth)
            return (pair.url, pair.fallback, nil)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        let source = self.source
        let picture = ZStack(alignment: .bottom) {
            RemoteImage(
                url: source.url,
                fallbackURL: source.fallback,
                blurHash: source.hash,
                onResolved: { artMissing = !$0 }
            )
            // The title, on the tile, once it is settled there is no picture
            // to wait for. A shelf of text-less grey boxes says the app failed
            // to load something; the server simply has no artwork for these.
            .overlay {
                if artMissing {
                    VStack(spacing: 8) {
                        Image(systemName: item.isEpisode || item.isSeries ? "tv" : "film")
                            .font(.title3)
                        Text(cardTitle)
                            .font(.caption.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(Theme.textDim)
                    .padding(8)
                }
            }

            if let progress = item.progressFraction {
                // Scaled rather than measured: the same bar, without a
                // geometry reader and its extra layout pass in every card.
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.45))
                    Rectangle()
                        .fill(Theme.accent)
                        .scaleEffect(x: min(1, max(0, progress)), y: 1, anchor: .leading)
                }
                .frame(height: 3)
            }
        }

        if let width {
            picture.frame(width: width, height: width / aspect)
        } else {
            picture
                .frame(maxWidth: .infinity)
                .aspectRatio(aspect, contentMode: .fit)
        }
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if item.userData.played {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .padding(5)
                    .background(Theme.accentStrong, in: Circle())
                    .foregroundStyle(.white)
            } else if let unplayed = item.userData.UnplayedItemCount, unplayed > 0 {
                Text("\(unplayed)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Theme.accentStrong, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(6)
    }

    /// An episode card shows the show first, whichever shape it is drawn in:
    /// the portrait poster it borrowed belongs to the series, and a still in
    /// Continue Watching used to print the episode's own name as its heading
    /// and then again underneath.
    private var cardTitle: String {
        if item.isEpisode, let series = item.SeriesName { return series }
        return item.title
    }

    /// The lines under the heading. An episode gets two — which one it is,
    /// spelled out, and then what it is called — because "Season 1: Episode 1 ·
    /// Pilot" on one line is what a card this narrow has no room for.
    private var cardLines: [String] {
        if let subtitle { return subtitle.isEmpty ? [] : [subtitle] }
        if item.isEpisode {
            var lines: [String] = []
            if let label = item.episodeLabel { lines.append(label) }
            // Only when the heading went to the series; otherwise this is the
            // heading again.
            if item.SeriesName != nil { lines.append(item.title) }
            return lines
        }
        let facts = Format.itemSubtitle(item)
        return facts.isEmpty ? [] : [facts]
    }
}

// MARK: - Refresh

/// Ask the server again, now — and say so while it is happening.
///
/// The glyph and the spinner occupy the same fixed square, so the swap is the
/// button changing what it says rather than the row around it relaying out.
///
/// Never disabled while it spins, which on a television would be worse than a
/// second press: the focus engine drops a control that goes disabled, and the
/// selector would vanish off the page every time the button was used. The press
/// is refused where the work is instead — see `HomeView.reload`.
struct RefreshButton: View {
    var isRefreshing: Bool
    /// Set where the button floats over artwork rather than over the page
    /// colour, which on Home is the television's corner of the media bar. A
    /// glyph on its own is legible over a dark backdrop and gone over a bright
    /// one, and the artwork behind it is a different picture every few seconds.
    var overArtwork: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            #if os(tvOS)
            tvLabel
            #else
            glyph
                .foregroundStyle(overArtwork ? Color.white : Theme.accent)
                .frame(width: Self.side, height: Self.side)
                .background {
                    if overArtwork {
                        Circle().fill(.black.opacity(0.45))
                    }
                }
                .contentShape(Rectangle())
            #endif
        }
        .chipButtonStyle()
        .accessibilityLabel(isRefreshing ? "Refreshing" : "Refresh")
    }

    /// The glyph and the spinner, in the same fixed square, so the swap is the
    /// button changing what it says rather than the row around it relaying out.
    private var glyph: some View {
        ZStack {
            Image(systemName: "arrow.clockwise")
                .opacity(isRefreshing ? 0 : 1)
            ProgressView()
                .controlSize(.small)
                .opacity(isRefreshing ? 1 : 0)
        }
        .font(glyphFont)
    }

    #if os(tvOS)
    /// A television gets a button rather than a glyph.
    ///
    /// What was here was an arrow in a translucent circle, and it was the one
    /// control on Home that never looked like something you could press: no
    /// edge of its own worth the name, no word saying what it did, and the
    /// focus ring `TVChipStyle` draws sitting on the bare artwork around it
    /// rather than on a control. A capsule with room inside it, a label, and a
    /// fill that inverts when the selector arrives — the same shape and the
    /// same treatment as `SeeAllButton`, so the two buttons on this page are
    /// one pair rather than two ideas.
    ///
    /// The fill is opaque on purpose. This floats over the media bar, whose
    /// backdrop is a different picture every few seconds; anything translucent
    /// reads as a dark smudge over one film and vanishes over the next.
    private var tvLabel: some View {
        FocusReader { isFocused in
            HStack(spacing: 12) {
                glyph
                    .frame(width: 30, height: 30)
                Text("Refresh")
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(isFocused ? Theme.background : Theme.text)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(isFocused ? AnyShapeStyle(Color.white) : AnyShapeStyle(Theme.raised), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
    #endif

    private var glyphFont: Font {
        #if os(tvOS)
        .body.weight(.semibold)
        #else
        .subheadline.weight(.semibold)
        #endif
    }

    #if !os(tvOS)
    private static var side: CGFloat {
        #if os(macOS)
        26
        #else
        32
        #endif
    }
    #endif
}

// MARK: - Rows

/// A horizontally scrolling shelf, the shape Home is built from.
///
/// On the Mac it is the TV app's row rather than a touch scroller: the cards
/// are sized so that a whole number of them fill the width, a ‹ and a › appear
/// at the edges while the pointer is over the row and page it a screen at a
/// time, the scroll bar shows, and the scroll snaps to a card.
struct MediaShelf: View {
    let title: String
    let items: [BaseItem]
    var wide: Bool = false
    /// Replaces the line under a card's title, per item. What "On Now" uses to
    /// put the programme under the channel; nil everywhere else leaves
    /// `PosterCard` to say what it always said.
    var subtitleFor: ((BaseItem) -> String?)?
    /// Which picture the cards draw — see `PosterCard.Art`.
    var art: PosterCard.Art = .automatic
    /// Whether the press-and-hold menu offers the title page. Off by default,
    /// because on most shelves a plain tap already goes there; on for the ones
    /// where it leads somewhere else — Next Up opens the season the episode
    /// sits in, so the episode's own page is worth an entry.
    var menuOpensDetails: Bool = false
    var onSelect: (BaseItem) -> Void
    var seeAll: (() -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(\.posterZoomNamespace) private var zoomNamespace
    #if os(macOS)
    /// The shelf's own width, measured from the heading row, which spans it.
    @State private var shelfWidth: CGFloat = 0
    @State private var isHovering = false
    @State private var isHoveringTitle = false
    /// The id of the leftmost card, which is what the paging buttons move.
    @State private var scrolledID: String?
    #endif

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    heading
                    Spacer()
                    if let seeAll {
                        SeeAllButton(action: seeAll)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                #if os(macOS)
                .background(WidthReader(width: $shelfWidth))
                #endif

                scroller
                    .focusRegion()
            }
        }
    }

    /// The heading. On the Mac a shelf with somewhere to go is itself the way
    /// there — click "Continue Watching" and the row opens as a page, with a
    /// chevron appearing beside the words under the pointer to say so, the
    /// way the TV app's rows do.
    @ViewBuilder
    private var heading: some View {
        #if os(macOS)
        if let seeAll {
            Button(action: seeAll) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(titleFont)
                        .foregroundStyle(Theme.text)
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .opacity(isHoveringTitle ? 1 : 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringTitle = $0 }
            .animation(.easeOut(duration: 0.12), value: isHoveringTitle)
            .help("See all of \(title)")
            .accessibilityAddTraits(.isHeader)
        } else {
            Text(title)
                .font(titleFont)
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
        }
        #else
        Text(title)
            .font(titleFont)
            .foregroundStyle(Theme.text)
            .accessibilityAddTraits(.isHeader)
        #endif
    }

    private func card(_ item: BaseItem, width: CGFloat) -> some View {
        Button {
            // Named for this row as well as the item: the
            // same title can sit in two rows of one page.
            app.zoomSource = "\(title)/\(item.Id)"
            onSelect(item)
        } label: {
            PosterCard(
                item: item,
                width: width,
                wide: wide,
                subtitle: subtitleFor?(item),
                art: art
            )
            // See `MediaGrid` — the tile is the target,
            // not the parts of it that happen to be drawn.
            .contentShape(Rectangle())
        }
        .buttonStyle(PosterButtonStyle())
        .posterZoomSource("\(title)/\(item.Id)", in: zoomNamespace)
        .itemContextMenu(item, allowsOpen: menuOpensDetails)
        #if os(macOS)
        .help(item.title)
        #endif
    }

    #if os(macOS)
    /// How many cards fill the row and how wide each one is. Until the width
    /// is measured the shelf takes the platform's fixed card; one layout pass
    /// later it has the real number.
    private var layout: (count: Int, width: CGFloat) {
        let available = shelfWidth - Metrics.gutter * 2
        guard available > 0 else {
            return (1, wide ? Metrics.stillWidth : Metrics.posterWidth)
        }
        let minimum = (wide ? 150 * 1.62 : 150) * PosterGrid.thumbnailScale
        return ShelfLayout.fit(available: available, minimum: minimum, spacing: Metrics.rowSpacing)
    }

    private var scroller: some View {
        let layout = self.layout
        return ScrollView(.horizontal, showsIndicators: true) {
            LazyHStack(alignment: .top, spacing: Metrics.rowSpacing) {
                ForEach(items) { item in
                    card(item, width: layout.width)
                }
            }
            .scrollTargetLayout()
            // Room for the hover ring, which sits outside the tile.
            .padding(.vertical, Metrics.shelfCardPadding)
        }
        // Margins rather than padding inside the stack, so that "aligned to a
        // card" means the card's edge lands on the gutter and not on the
        // window's edge.
        .contentMargins(.horizontal, Metrics.gutter, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $scrolledID)
        .overlay(alignment: .leading) {
            ShelfPagingButton(direction: .back) { page(by: -layout.count) }
                .padding(.leading, 4)
                .opacity(isHovering && canPage(by: -1) ? 1 : 0)
        }
        .overlay(alignment: .trailing) {
            ShelfPagingButton(direction: .forward) { page(by: layout.count) }
                .padding(.trailing, 4)
                .opacity(isHovering && canPage(by: layout.count) ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
    }

    /// Where the row is, as an index into `items`. Nothing scrolled yet is
    /// the first card.
    private var scrolledIndex: Int {
        guard let scrolledID, let index = items.firstIndex(where: { $0.Id == scrolledID }) else { return 0 }
        return index
    }

    private func canPage(by offset: Int) -> Bool {
        offset < 0 ? scrolledIndex > 0 : scrolledIndex + offset < items.count
    }

    /// One screenful along. The target is the card that becomes leftmost;
    /// past the end it is the last card, and the scroll view stops where the
    /// content does.
    private func page(by offset: Int) {
        let target = min(max(0, scrolledIndex + offset), items.count - 1)
        withAnimation(.easeInOut(duration: 0.3)) {
            scrolledID = items[target].Id
        }
    }
    #else
    private var scroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: Metrics.rowSpacing) {
                ForEach(items) { item in
                    card(item, width: wide ? Metrics.stillWidth : Metrics.posterWidth)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            // Focus on tvOS grows the card; without room it clips.
            .padding(.vertical, Metrics.shelfCardPadding)
        }
    }
    #endif

    /// A phone fits more rows on screen with a heading the weight of a list
    /// header than with one the weight of a page title.
    private var titleFont: Font {
        #if os(iOS)
        return .headline
        #else
        return .title3.weight(.semibold)
        #endif
    }
}

#if os(macOS)
/// Reports the width of whatever it is put behind, for the views that size
/// their children from it: a shelf, a skeleton shelf, a grid working out
/// which column the selection is in.
struct WidthReader: View {
    @Binding var width: CGFloat

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { width = geo.size.width }
                .onChange(of: geo.size.width) { _, new in width = new }
        }
    }
}
#endif

/// "See all", beside a shelf's heading.
///
/// On a television it draws its own capsule with room inside it, and that is
/// the whole point of it existing rather than being a bare `Button` with
/// `chipButtonStyle()` on it. That style is documented as being for "a control
/// that already draws its own capsule" — it adds nothing but a ring at the
/// label's own bounds — and the bounds of a bare piece of text are the letters.
/// So the selector arriving drew a three-point white capsule straight through
/// the words and then scaled the pair of them up together: the one control on
/// Home that became unreadable at the moment you pointed at it.
///
/// A chevron goes with it, because a capsule with room in it reads as a button
/// and a button on a shelf heading should say which way it leads. Everywhere
/// else this stays what it was: accent-coloured text, no capsule, since a
/// pointer and a finger need no selector drawn for them.
struct SeeAllButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            #if os(tvOS)
            HStack(spacing: 8) {
                Text("See all")
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(Theme.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            .contentShape(Capsule())
            #elseif os(macOS)
            // A link, in Title Case, which is what a Mac calls a small
            // accent-coloured word that goes somewhere.
            Text("See All")
                .font(.subheadline)
            #else
            Text("See all")
                .font(.subheadline)
                .foregroundStyle(Theme.accent)
            #endif
        }
        .seeAllStyle()
    }
}

private extension View {
    @ViewBuilder
    func seeAllStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        chipButtonStyle()
        #endif
    }
}

/// Cards lift slightly when pressed, which is the only affordance a tile has on
/// a device with a pointer or a finger. On tvOS the focus engine draws the lift
/// instead, from the artwork inside `PosterCard`.
///
/// Named for what it styles rather than for what it draws, because SwiftUI has
/// a `CardButtonStyle` of its own on tvOS and the two are not interchangeable.
/// The namespace poster tiles and the pages they open share, so a page can
/// zoom out of the tile that opened it. Set once by RootView; nil on tvOS,
/// where the transition is not offered.
private struct PosterZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var posterZoomNamespace: Namespace.ID? {
        get { self[PosterZoomNamespaceKey.self] }
        set { self[PosterZoomNamespaceKey.self] = newValue }
    }
}

extension View {
    /// Marks a poster tile as the place the page named by `id` zooms out of.
    /// See `ZoomedDestination` in RootView for the other half. iOS 18 and
    /// later only.
    @ViewBuilder
    func posterZoomSource(_ id: String, in namespace: Namespace.ID?) -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *), let namespace {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

struct PosterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        // Nothing on a Mac shrinks when clicked. The press is the tile going
        // a shade darker, which is what an icon in Finder does.
        configuration.label
            .brightness(configuration.isPressed ? -0.1 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        #else
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
        #endif
    }
}

#if os(tvOS)
/// Reads the focus state of the control this sits inside.
struct FocusReader<Content: View>: View {
    @Environment(\.isFocused) private var isFocused
    let content: (Bool) -> Content
    var body: some View { content(isFocused) }
}

/// What `.plain` should have been on a television.
///
/// `.plain` paints the system's light focus background underneath text this app
/// draws from a fixed dark palette, which makes a focused row white on white.
/// This draws the focus from the same palette as everything else instead, and
/// leaves the row untouched when it isn't focused — which tvOS's own card style
/// does not, since that gives every row a permanent card behind it.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FocusReader { isFocused in
            configuration.label
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .fill(isFocused ? Theme.hover : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .strokeBorder(isFocused ? Theme.accent : .clear, lineWidth: 3)
                )
                .scaleEffect(isFocused ? 1.01 : 1)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}
#endif

#if !os(tvOS)
/// What a row does while it is being pressed.
///
/// `.plain` does nothing at all, which is how an episode row came to be the one
/// control in the app that gave no sign of having been hit: a poster scales, a
/// bordered button fills, and a row sat there until the push animation started.
/// This is the fill a system list row draws, in this app's colours, bled past
/// the row's own bounds so it reads as a band across the page rather than a
/// rectangle around the text.
///
/// On the Mac the same band appears under the pointer, before the press: a
/// row that only answers a click gives no sign that it takes one.
struct RowPressStyle: ButtonStyle {
    var inset: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        RowPressLabel(configuration: configuration, inset: inset)
    }

    /// The label in its own view so it can hold the hover state; a style
    /// isn't a view and has nowhere to keep one.
    private struct RowPressLabel: View {
        let configuration: Configuration
        let inset: CGFloat
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.hover)
                        .padding(.horizontal, -inset)
                        .padding(.vertical, -4)
                        .opacity(configuration.isPressed || isHovering ? 1 : 0)
                )
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                #if os(macOS)
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .onHover { isHovering = $0 }
                #endif
        }
    }
}
#endif

#if os(tvOS)
/// What `.bordered` and `.borderedProminent` should have been on a television.
///
/// The system's styles are built around one assumption: an unfocused button is a
/// pale translucent slab that the label is expected to sit on in whatever colour
/// the surrounding environment says, and a focused one turns solid white with a
/// dark label. In an app that draws from a fixed dark palette that first state
/// comes out white on white — which is why half the buttons on this build said
/// nothing at all until the selector reached them.
///
/// Both states are drawn here instead, so a button reads the same whether or not
/// it has focus, and the focus itself is the ring, the lift and the shadow the
/// rest of the app already uses.
struct TVButtonStyle: ButtonStyle {
    enum Kind { case prominent, secondary }
    var kind: Kind = .secondary
    /// A secondary button that is *on* — favourited, watched.
    ///
    /// A colour, not `.tint`. Handing a colour to tvOS's own `.bordered` style
    /// paints the fill and the label with it, which is how the favourite button
    /// came to be a plain yellow pill with nothing written on it: the star and
    /// the word "Favorited" were both there, in the same colour as the thing
    /// behind them. Colouring the label and leaving the fill alone says the same
    /// thing and can still be read.
    var highlight: Color?

    func makeBody(configuration: Configuration) -> some View {
        FocusReader { isFocused in
            configuration.label
                .font(.callout.weight(.semibold))
                .foregroundStyle(labelColour(isFocused))
                .padding(.horizontal, 26)
                .padding(.vertical, 14)
                .background(Capsule().fill(fill(isFocused)))
                .overlay(
                    Capsule().strokeBorder(
                        isFocused ? .white.opacity(0.92) : Theme.border,
                        lineWidth: isFocused ? 3 : 1
                    )
                )
                .scaleEffect(isFocused ? 1.06 : 1)
                // Radius and offset go to nothing with the colour: a clear
                // shadow still costs its blur, and every unfocused card on a
                // television was paying for one. (The same below, and in the
                // guide's and Settings' cells.)
                .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: isFocused ? 14 : 0, y: isFocused ? 8 : 0)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }

    private func fill(_ isFocused: Bool) -> Color {
        switch kind {
        case .prominent: isFocused ? Theme.accent : Theme.accentStrong
        case .secondary: isFocused ? .white : Theme.raised
        }
    }

    /// White on the accent either way; on the secondary style the label has to
    /// flip with the fill, since focus turns that one white.
    private func labelColour(_ isFocused: Bool) -> Color {
        switch kind {
        case .prominent: .white
        // Focus turns this one's fill white, so the label has to go dark with
        // it — a highlight colour pitched for the raised fill would be the same
        // trap the system style falls into.
        case .secondary: isFocused ? Color(hex: 0x16161F) : (highlight ?? Theme.text)
        }
    }
}

/// What a poster, a still or a library tile does when the selector reaches it.
///
/// Not `.hoverEffect(.highlight)`, which is what this was. That draws the
/// system's white platter *around* the view — some fifty points larger than it
/// on every side — and the two lines of text below the artwork ended up inside
/// it, greyed out and sitting on white. It also grew the picture far enough to
/// come down over its own title.
///
/// A ring, a small lift and a shadow instead: drawn by this app, in a size this
/// app knows, so the space a card reserves under its artwork is enough. The
/// growth is 6%, which `Metrics.cardTextSpacing` is set from.
struct PosterFocus: ViewModifier {
    var radius: CGFloat = Theme.cornerRadius
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(isFocused ? Color.white : .clear, lineWidth: 5)
            )
            .scaleEffect(isFocused ? 1.06 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: isFocused ? 12 : 0, y: isFocused ? 8 : 0)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// A control that already draws its own capsule — a filter chip, a "See all" —
/// and only needs the focus engine to be visible on it. `.plain` gives it
/// nothing at all on this platform, which leaves a row of chips with no way of
/// telling which one the selector is on.
struct TVChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FocusReader { isFocused in
            configuration.label
                .overlay(
                    Capsule().strokeBorder(isFocused ? Color.white : .clear, lineWidth: 3)
                )
                .scaleEffect(isFocused ? 1.08 : 1)
                .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: isFocused ? 10 : 0, y: isFocused ? 5 : 0)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}
#endif

/// The style for a row or tile that behaves as one control and draws its own
/// colours: an episode, a channel, a cast member, a remembered search term.
extension View {
    @ViewBuilder
    func rowButtonStyle() -> some View {
        #if os(tvOS)
        buttonStyle(RowButtonStyle())
        #else
        buttonStyle(RowPressStyle())
        #endif
    }

    /// A standing action — Play, Details, Favorite, Retry. The system's styles
    /// everywhere but a television, and `TVButtonStyle` there, for the reason
    /// spelled out on it. `highlight` marks a button that is on.
    @ViewBuilder
    func appButtonStyle(prominent: Bool = false, highlight: Color? = nil) -> some View {
        #if os(tvOS)
        buttonStyle(TVButtonStyle(kind: prominent ? .prominent : .secondary, highlight: highlight))
        #elseif os(macOS)
        // No tint: a prominent button is the user's accent colour, whichever
        // they chose, and a brand purple over a graphite desktop is the one
        // thing that says the app came from somewhere else.
        if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered).tint(highlight)
        }
        #else
        if prominent {
            buttonStyle(.borderedProminent).tint(Theme.accentStrong)
        } else {
            buttonStyle(.bordered).tint(highlight)
        }
        #endif
    }

    /// Artwork that the selector can land on — a poster, a still, a library
    /// tile. The television's focus ring, and the Mac's hover ring; nothing
    /// on a phone, where a finger needs no selector drawn for it.
    @ViewBuilder
    func posterFocus(radius: CGFloat = Theme.cornerRadius) -> some View {
        #if os(tvOS)
        modifier(PosterFocus(radius: radius))
        #elseif os(macOS)
        modifier(PosterHover(radius: radius))
        #else
        self
        #endif
    }

    /// `posterFocus` for the artwork inside a `PosterCard`, whose Mac hover
    /// is drawn round the whole tile instead — see `macTileState`.
    @ViewBuilder
    func artworkFocus(radius: CGFloat = Theme.cornerRadius) -> some View {
        #if os(tvOS)
        modifier(PosterFocus(radius: radius))
        #else
        self
        #endif
    }

    /// A control that draws its own capsule and only wants the focus shown on
    /// it. `.plain` everywhere else, where a press is what needs acknowledging
    /// rather than a selector arriving.
    @ViewBuilder
    func chipButtonStyle() -> some View {
        #if os(tvOS)
        buttonStyle(TVChipStyle())
        #else
        buttonStyle(.plain)
        #endif
    }

    /// Takes a view out of the tree on a television and leaves it untouched
    /// everywhere else. For controls that are right on a screen driven by a
    /// pointer or a finger and wrong on one driven by a directional pad, where
    /// anything above the content is something to press past on the way in.
    @ViewBuilder
    func hiddenOnTV() -> some View {
        #if os(tvOS)
        EmptyView()
        #else
        self
        #endif
    }

    /// The page's name, where the platform has somewhere to put it.
    ///
    /// tvOS doesn't. A `navigationTitle` there is drawn as a fixed banner across
    /// the top of the screen with nothing behind it, so every card, shelf and
    /// backdrop scrolling up the page passes straight through the lettering and
    /// the title reads as a watermark stamped over the content. The tab strip
    /// already names the section it is showing, and a page pushed onto a stack
    /// carries its own heading in the content — see `PageHeading` — where it
    /// scrolls away like everything else.
    @ViewBuilder
    func screenTitle(_ title: String) -> some View {
        #if os(tvOS)
        self
        #else
        navigationTitle(title)
        #endif
    }

    /// Tells the focus engine to treat this container as one region: a swipe
    /// toward it lands on whichever of its children is nearest, rather than
    /// having to line up with one of them.
    ///
    /// tvOS moves focus geometrically — straight up, down, left or right from
    /// wherever the selector is — and a container whose focusable children are
    /// nested a few layers down, laid out in their own scroll view, or simply
    /// not directly in line, is a container the selector cannot get into. That
    /// is what left the guide unreachable and a pushed page with nothing but
    /// the tab strip to move around in. Nothing anywhere else: this is the one
    /// platform with a selector to guide.
    ///
    /// The Mac has one too — the Tab key and the arrow keys walk focus
    /// between controls, and a grid that isn't a section is one the keyboard
    /// walks past.
    @ViewBuilder
    func focusRegion() -> some View {
        #if os(tvOS) || os(macOS)
        focusSection()
        #else
        self
        #endif
    }

    /// Reload a screen once the player closes.
    ///
    /// A tab's view stays alive when you switch away from it, so without this
    /// the only thing that would ever reload Home is relaunching the app —
    /// leaving Continue Watching showing the episode you just finished.
    /// Playback ending is the moment that matters, because it is the one that
    /// changed what these screens say.
    @ViewBuilder
    func reloadWhenPlaybackEnds(_ reload: @escaping () async -> Void) -> some View {
        modifier(ReloadWhenPlaybackEnds(reload: reload))
    }
}

private struct ReloadWhenPlaybackEnds: ViewModifier {
    @Environment(PlayerModel.self) private var player
    let reload: () async -> Void

    func body(content: Content) -> some View {
        content.onChange(of: player.isActive) { wasActive, isActive in
            guard wasActive, !isActive else { return }
            Task { await reload() }
        }
    }
}

// MARK: - Grid

/// The column geometry every grid of cards shares — Library, Search, Favorites
/// and Downloads — so a poster is the same size whichever screen it appears on.
enum PosterGrid {
    /// On a phone the count is fixed and the cards are sized from it — three
    /// posters across, two 16:9 stills. An adaptive minimum can't promise that:
    /// it fits as many whole poster widths as the screen happens to hold, which
    /// on every current iPhone is two, with the remainder left as air.
    static func phoneColumns(wide: Bool, compact: Bool) -> Int? {
        #if os(iOS)
        compact ? (wide ? 2 : 3) : nil
        #else
        nil
        #endif
    }

    static func columns(wide: Bool, compact: Bool) -> [GridItem] {
        if let count = phoneColumns(wide: wide, compact: compact) {
            return Array(
                repeating: GridItem(.flexible(), spacing: Metrics.gridSpacing, alignment: .top),
                count: count
            )
        }
        #if os(macOS)
        // A range rather than a fixed width, with the cards filling their
        // column: a window made narrower gets one more, smaller column instead
        // of two fixed posters with a gulf of page between them.
        return [GridItem(.adaptive(minimum: columnMinimum(wide: wide), maximum: columnMaximum(wide: wide)),
                         spacing: Metrics.gridSpacing, alignment: .top)]
        #else
        return [GridItem(.adaptive(minimum: wide ? Metrics.stillWidth : Metrics.posterWidth),
                         spacing: Metrics.gridSpacing, alignment: .top)]
        #endif
    }

    /// `nil` hands sizing to the column, which is what the fixed-count phone
    /// layout needs; elsewhere the card keeps its own width.
    static func cardWidth(wide: Bool, compact: Bool) -> CGFloat? {
        #if os(macOS)
        return nil
        #else
        guard phoneColumns(wide: wide, compact: compact) == nil else { return nil }
        return wide ? Metrics.stillWidth : Metrics.posterWidth
        #endif
    }

    /// View ▸ Bigger and Smaller on the Mac: what the column bounds and the
    /// shelf's minimum card are multiplied by. One everywhere else. Read
    /// through the main actor because that is where `MacViewOptions` lives
    /// and where every caller — a view's body — already is; reading the
    /// observable there is what makes a grid redraw when the menu changes it.
    static var thumbnailScale: CGFloat {
        #if os(macOS)
        MainActor.assumeIsolated { CGFloat(MacViewOptions.shared.thumbnailSize) }
        #else
        1
        #endif
    }

    /// The narrowest and widest a Mac column runs. The widest is also what a
    /// card in that column asks the server for, since the card itself has no
    /// width of its own — see `PosterCard.requestWidth`.
    static func columnMinimum(wide: Bool) -> CGFloat {
        #if os(macOS)
        (wide ? 220 : 136) * thumbnailScale
        #else
        wide ? Metrics.stillWidth : Metrics.posterWidth
        #endif
    }

    static func columnMaximum(wide: Bool) -> CGFloat {
        #if os(macOS)
        (wide ? 360 : 210) * thumbnailScale
        #else
        wide ? Metrics.stillWidth : Metrics.posterWidth
        #endif
    }

    /// How many columns an adaptive grid of these lays out across `width`
    /// points of page — the grid's own arithmetic, repeated here so the Mac's
    /// arrow keys know which tile is above and below.
    static func columnCount(wide: Bool, width: CGFloat) -> Int {
        let available = width - Metrics.gutter * 2
        let minimum = columnMinimum(wide: wide)
        guard available > minimum else { return 1 }
        return max(1, Int(((available + Metrics.gridSpacing) / (minimum + Metrics.gridSpacing)).rounded(.down)))
    }
}

/// A tile with nothing in it yet: the shape a card will take, in the card's own
/// place in the grid.
///
/// This is what a page of results loading should look like — the layout settles
/// once, when the request is made, rather than jumping when it lands. A spinner
/// under the grid does the opposite: it occupies a row of its own, then vanishes
/// and shoves everything below it.
struct SkeletonCard: View {
    var width: CGFloat?
    var wide: Bool = false
    var showsSubtitle: Bool = true

    private var aspect: CGFloat { wide ? 16.0 / 9.0 : 2.0 / 3.0 }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.cardTextSpacing) {
            artwork
                .overlay { ShimmerOverlay() }
                .cardChrome()

            if showsSubtitle {
                VStack(alignment: .leading, spacing: 5) {
                    bar(widthFraction: 0.85, height: 9)
                    bar(widthFraction: 0.5, height: 7)
                }
                .padding(.top, 2)
                .frame(maxWidth: width ?? .infinity, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var artwork: some View {
        if let width {
            Theme.placeholderFill.frame(width: width, height: width / aspect)
        } else {
            Theme.placeholderFill
                .frame(maxWidth: .infinity)
                .aspectRatio(aspect, contentMode: .fit)
        }
    }

    private func bar(widthFraction: CGFloat, height: CGFloat) -> some View {
        SkeletonBar(height: height)
            .scaleEffect(x: widthFraction, y: 1, anchor: .leading)
    }
}

/// One line of text that hasn't arrived yet.
struct SkeletonBar: View {
    var height: CGFloat = 9
    var width: CGFloat?

    var body: some View {
        Capsule()
            .fill(Theme.skeletonBar)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// The hero at the top of Home and of a detail page, before it has anything in
/// it. Same height as the real one, so nothing moves when the artwork lands.
struct SkeletonHero: View {
    var body: some View {
        Theme.heroPlaceholderFill
            .frame(height: HeroHeader.height)
            .frame(maxWidth: .infinity)
            .overlay { ShimmerOverlay() }
            .overlay(alignment: .bottomLeading) {
                // The same blocks in the same places as the real hero's title,
                // its line of facts and its buttons, at the same distance from
                // the bottom edge.
                VStack(alignment: .leading, spacing: 12) {
                    SkeletonBar(height: 28, width: 230)
                    SkeletonBar(height: 12, width: 150)
                    HStack(spacing: 10) {
                        skeletonButton(width: 108)
                        skeletonButton(width: 92)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, 38)
            }
            .accessibilityHidden(true)
    }

    /// The shape of the button that is coming: a capsule the height of a
    /// phone's, a rounded rect the height of the Mac's.
    private func skeletonButton(width: CGFloat) -> some View {
        #if os(macOS)
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Theme.skeletonBar)
            .frame(width: width * 0.8, height: 24)
        #else
        Capsule().fill(Theme.skeletonBar).frame(width: width, height: 34)
        #endif
    }
}

/// A shelf of tiles that haven't arrived — heading included, because a heading
/// appearing a moment before its row is its own little jump.
///
/// On the Mac the count comes from the width, in the same arithmetic as the
/// shelf it stands in for: four fixed cards and a spacer was four grey
/// posters and a page of nothing on a wide window.
struct SkeletonShelf: View {
    var wide: Bool = false
    var count: Int = 4
    #if os(macOS)
    @State private var shelfWidth: CGFloat = 0
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.shelfTitleSpacing) {
            SkeletonBar(height: 13, width: 140)
                .padding(.horizontal, Metrics.gutter)
            HStack(alignment: .top, spacing: Metrics.rowSpacing) {
                ForEach(0..<cardCount, id: \.self) { _ in
                    SkeletonCard(width: cardWidth, wide: wide)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.gutter)
            #if os(macOS)
            .padding(.vertical, Metrics.shelfCardPadding)
            .background(WidthReader(width: $shelfWidth))
            #endif
        }
        .accessibilityHidden(true)
    }

    #if os(macOS)
    private var layout: (count: Int, width: CGFloat) {
        let available = shelfWidth - Metrics.gutter * 2
        guard available > 0 else { return (count, wide ? Metrics.stillWidth : Metrics.posterWidth) }
        let minimum = (wide ? 150 * 1.62 : 150) * PosterGrid.thumbnailScale
        return ShelfLayout.fit(available: available, minimum: minimum, spacing: Metrics.rowSpacing)
    }
    private var cardCount: Int { layout.count }
    private var cardWidth: CGFloat { layout.width }
    #else
    private var cardCount: Int { count }
    private var cardWidth: CGFloat { wide ? Metrics.stillWidth : Metrics.posterWidth }
    #endif
}

/// A list row that hasn't arrived: a channel, an episode.
struct SkeletonListRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Theme.placeholderFill
                .frame(width: 148, height: 83)
                .overlay { ShimmerOverlay() }
                .cardChrome(radius: 8)
            VStack(alignment: .leading, spacing: 7) {
                SkeletonBar(height: 12, width: 170)
                SkeletonBar(height: 9, width: 60)
                SkeletonBar(height: 9)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, Metrics.gutter)
        .accessibilityHidden(true)
    }
}

/// A stack of them, which is what a list-shaped screen shows on first load.
struct SkeletonList: View {
    var count: Int = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<count, id: \.self) { _ in SkeletonListRow() }
        }
    }
}

/// A grid of empty tiles, in the geometry the real one will use: what a screen
/// shows on first load instead of a spinner over nothing.
struct SkeletonGrid: View {
    var count: Int = 12
    var wide: Bool = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var isCompact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        LazyVGrid(
            columns: PosterGrid.columns(wide: wide, compact: isCompact),
            spacing: Metrics.gridRowSpacing
        ) {
            ForEach(0..<count, id: \.self) { _ in
                SkeletonCard(width: PosterGrid.cardWidth(wide: wide, compact: isCompact), wide: wide)
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }
}

/// The library and search layout: as many columns as fit, sized from the
/// poster width so every platform gets a sensible count without hard-coding one.
///
/// On the Mac it is a selectable grid, the way Finder's icon view and the TV
/// app's library are: a click selects a tile and draws the ring, a
/// double-click or Return opens it, the arrow keys move the selection, ⇧ and
/// ⌘ extend it, ⌘A takes the lot. The screens that use it don't have to know;
/// `onSelect` is still called when something opens. A screen that wants to
/// read the selection — for a toolbar that acts on it — binds `selection`.
struct MediaGrid: View {
    let items: [BaseItem]
    var wide: Bool = false
    /// Ghost tiles drawn after the real ones while the next page is in flight.
    var pendingCount: Int = 0
    var onSelect: (BaseItem) -> Void
    /// Called as the last rows come into view, for paging — by any of the
    /// last `reachAhead` tiles rather than only the very last. One tile's
    /// appearance is one chance: if it came while a page was already on its
    /// way, or the page failed, the list sat at "62 of 92" until that tile was
    /// scrolled away and back. The callers' own guards drop the repeats.
    var onReachEnd: (() -> Void)?
    /// The selected item ids, for a caller that wants them. Nil leaves the
    /// grid to keep its own. Nothing anywhere but the Mac.
    var selection: Binding<Set<String>>? = nil

    @Environment(AppModel.self) private var app
    @Environment(\.posterZoomNamespace) private var zoomNamespace
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    #if os(macOS)
    @State private var ownSelection: Set<String> = []
    /// The tile the keyboard moves from and ⇧-click extends from: the last
    /// one clicked or arrowed to.
    @State private var anchorID: String?
    @State private var gridWidth: CGFloat = 0
    @FocusState private var isFocused: Bool
    #endif

    private var isCompact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    /// How many tiles from the end start the next page: a couple of rows on
    /// any of the grids, and the page is usually there before the end is.
    private static let reachAhead = 12

    private var columns: [GridItem] { PosterGrid.columns(wide: wide, compact: isCompact) }

    private var cardWidth: CGFloat? { PosterGrid.cardWidth(wide: wide, compact: isCompact) }

    var body: some View {
        LazyVGrid(columns: columns, spacing: Metrics.gridRowSpacing) {
            ForEach(items) { item in
                tile(item)
                    .onAppear {
                        if onReachEnd != nil, items.suffix(Self.reachAhead).contains(where: { $0.Id == item.Id }) {
                            onReachEnd?()
                        }
                    }
            }
            if pendingCount > 0 {
                ForEach(0..<pendingCount, id: \.self) { _ in
                    SkeletonCard(width: cardWidth, wide: wide)
                }
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .animation(.easeOut(duration: 0.2), value: pendingCount > 0)
        #if os(macOS)
        .background(WidthReader(width: $gridWidth))
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.upArrow) { move(by: -columnCount); return .handled }
        .onKeyPress(.downArrow) { move(by: columnCount); return .handled }
        .onKeyPress(.leftArrow) { move(by: -1); return .handled }
        .onKeyPress(.rightArrow) { move(by: 1); return .handled }
        .onKeyPress(.return) { openSelection() }
        .onKeyPress(characters: .init(charactersIn: "aA")) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            selected = Set(items.map(\.Id))
            return .handled
        }
        .onChange(of: items.map(\.Id)) { _, ids in
            // A page reloaded or filtered: nothing selected that isn't there.
            let present = Set(ids)
            if !selected.isSubset(of: present) { selected = selected.intersection(present) }
        }
        #endif
        .focusRegion()
    }

    #if os(macOS)
    /// One tile. Not a button: a button opens on the click, and on the Mac
    /// the click selects. The double-click and the single are read together
    /// — a double-click is two clicks, so the tile is selected and then
    /// opened, which is what Finder does too.
    private func tile(_ item: BaseItem) -> some View {
        PosterCard(item: item, width: cardWidth, wide: wide, isSelected: selected.contains(item.Id))
            .contentShape(Rectangle())
            .onTapGesture { click(item) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { open(item) })
            .itemContextMenu(item)
            .help(item.title)
            .accessibilityAddTraits(selected.contains(item.Id) ? .isSelected : [])
    }

    private var selected: Set<String> {
        get { selection?.wrappedValue ?? ownSelection }
        nonmutating set {
            if let selection { selection.wrappedValue = newValue } else { ownSelection = newValue }
        }
    }

    private var columnCount: Int { PosterGrid.columnCount(wide: wide, width: gridWidth) }

    /// The click, read with whatever keys were down: ⌘ toggles the tile,
    /// ⇧ extends from the anchor, a plain click is the new selection.
    private func click(_ item: BaseItem) {
        isFocused = true
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selected.contains(item.Id) { selected.remove(item.Id) } else { selected.insert(item.Id) }
            anchorID = item.Id
        } else if flags.contains(.shift), let anchorID,
                  let from = items.firstIndex(where: { $0.Id == anchorID }),
                  let to = items.firstIndex(where: { $0.Id == item.Id }) {
            selected.formUnion(items[min(from, to)...max(from, to)].map(\.Id))
        } else {
            selected = [item.Id]
            anchorID = item.Id
        }
    }

    private func open(_ item: BaseItem) {
        app.zoomSource = "grid/\(item.Id)"
        onSelect(item)
    }

    /// The arrow keys: from the anchor, by one tile or one row, to a single
    /// new selection. With nothing selected the first key lands on the first
    /// tile, as it does in Finder.
    private func move(by offset: Int) {
        guard !items.isEmpty else { return }
        let from = anchorID.flatMap { id in items.firstIndex { $0.Id == id } }
        let to: Int
        if let from {
            to = min(max(0, from + offset), items.count - 1)
        } else {
            to = 0
        }
        let target = items[to]
        selected = [target.Id]
        anchorID = target.Id
    }

    /// Return: the anchor if it is selected, else the first selected tile.
    private func openSelection() -> KeyPress.Result {
        let id = (anchorID.flatMap { selected.contains($0) ? $0 : nil })
            ?? items.first { selected.contains($0.Id) }?.Id
        guard let id, let item = items.first(where: { $0.Id == id }) else { return .ignored }
        open(item)
        return .handled
    }
    #else
    private func tile(_ item: BaseItem) -> some View {
        Button {
            app.zoomSource = "grid/\(item.Id)"
            onSelect(item)
        } label: {
            PosterCard(item: item, width: cardWidth, wide: wide)
                // The whole tile is the target, not whichever parts of
                // it happen to have drawn something. A button's hit
                // region is its label's rendered content, and a card is
                // artwork over a placeholder with two lines of text
                // under it and gaps in between — so a tap that landed
                // in a gap, or on a poster whose picture hadn't
                // arrived, went nowhere and the item simply didn't
                // open. Given a shape it is the same rectangle
                // whatever the card is currently showing.
                .contentShape(Rectangle())
        }
        .buttonStyle(PosterButtonStyle())
        .posterZoomSource("grid/\(item.Id)", in: zoomNamespace)
        .itemContextMenu(item)
    }
    #endif
}

// MARK: - Wrapping row

/// Lays subviews out along a line and starts a new one when the next wouldn't
/// fit whole.
///
/// The detail page's actions are the reason this exists. An `HStack` given more
/// buttons than the width holds doesn't overflow — it takes the space out of the
/// labels, and "Mark watched" becomes two crushed lines reading "Mark" and
/// "watch…". `ViewThatFits` only helps if a genuinely different arrangement is
/// offered as the fallback. This gives every button the width its own label
/// asks for and spends the extra height instead.
struct WrappingRow: Layout {
    var spacing: CGFloat = 10
    var rowSpacing: CGFloat = 10

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Each child's natural size, measured once per change to the children
    /// rather than three times per layout pass — once to size the row, again
    /// to place it, and again for each child as it was placed. Every one of
    /// those asked the same question, with the same unconstrained proposal.
    struct Cache {
        var sizes: [CGSize]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    private func rows(_ sizes: [CGSize], limit: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in sizes.indices {
            let size = sizes[index]
            let extended = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, extended > limit {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = extended
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }

    private func height(of rows: [Row]) -> CGFloat {
        rows.reduce(0) { $0 + $1.height } + rowSpacing * CGFloat(max(0, rows.count - 1))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let limit = proposal.width ?? .infinity
        let rows = rows(cache.sizes, limit: limit)
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: limit.isFinite ? min(limit, max(widest, 0)) : widest, height: height(of: rows))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var y = bounds.minY
        for row in rows(cache.sizes, limit: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = cache.sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }
}

// MARK: - States

// A spinner-over-nothing loading state used to live here. Every screen that had
// one now draws the shape of what it is about to become instead — see the
// skeletons above — so the layout settles once, when the request goes out,
// rather than jumping when it lands.

struct EmptyState: View {
    var symbol: String = "tray"
    var title: String
    var message: String
    /// A way out of the empty state, when there is one — clearing the filters
    /// that emptied it, say. Nil draws no button.
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        #if os(macOS)
        // The system's own empty page, which every Mac app shows.
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        #else
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(Theme.textDim)
            Text(title).font(.headline).foregroundStyle(Theme.text)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textDim)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .appButtonStyle()
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(Metrics.gutter)
        #endif
    }
}

struct ErrorState: View {
    var title: String = "This page didn't load"
    var error: String
    var retry: (() -> Void)?

    var body: some View {
        #if os(macOS)
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(error)
        } actions: {
            if let retry {
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        #else
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(Theme.warn)
            Text(title).font(.headline).foregroundStyle(Theme.text)
            Text(error)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textDim)
                .frame(maxWidth: 460)
            if let retry {
                Button("Try again", action: retry)
                    .appButtonStyle(prominent: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(Metrics.gutter)
        #endif
    }
}

/// You're signed in, but the server can't be reached.
struct OfflineState: View {
    var onRetry: () async -> Void
    var onDownloads: (() -> Void)?
    @State private var checking = false

    private static let message = "You're signed in, but your Jellyfin server can't be reached right now. Downloaded media is still available, and playback will sync once you're back online."

    var body: some View {
        #if os(macOS)
        ContentUnavailableView {
            Label("Server Offline", systemImage: "wifi.slash")
        } description: {
            Text(Self.message)
        } actions: {
            HStack(spacing: 12) {
                if let onDownloads {
                    Button("Go to Downloads", action: onDownloads)
                        .buttonStyle(.borderedProminent)
                }
                Button(checking ? "Checking…" : "Retry Connection", action: retry)
                    .disabled(checking)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        VStack(spacing: 14) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 34))
                .foregroundStyle(Theme.warn)
            Text("Server offline").font(.title2.weight(.semibold))
            Text(Self.message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textDim)
                .frame(maxWidth: 460)
            HStack(spacing: 12) {
                if let onDownloads {
                    Button("Go to Downloads", action: onDownloads)
                        .appButtonStyle(prominent: true)
                }
                Button(checking ? "Checking…" : "Retry connection", action: retry)
                    .appButtonStyle()
                    .disabled(checking)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Metrics.gutter)
        #endif
    }

    private func retry() {
        Task {
            checking = true
            await onRetry()
            checking = false
        }
    }
}

/// The one sign that this is the device talking and not the server: a strip
/// above the tab bar on every page while the server can't be reached, saying
/// when the app will next ask on its own, with a button to ask now. Put there
/// by the shell (`RootView.withOfflineStrip`), so no page has to remember it.
struct OfflineStrip: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.warn)
            VStack(alignment: .leading, spacing: 1) {
                Text("Offline — showing downloads")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                status
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            Button(app.isCheckingConnection ? "Checking…" : "Retry") {
                Task { await app.retryNow() }
            }
            .retryStyle()
            .disabled(app.isCheckingConnection)
        }
        .stripChrome()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        if app.isCheckingConnection {
            Text("Looking for your server…")
        } else if let next = app.nextRetryAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(next.timeIntervalSince(context.date).rounded(.up)))
                Text(seconds > 0 ? "Trying again in \(seconds) s" : "Looking for your server…")
            }
        } else {
            Text("Your server can't be reached")
        }
    }
}

private extension View {
    /// The strip's box. A floating rounded card above the tab bar on a
    /// phone; on the Mac there is no tab bar, and a status strip is a
    /// full-width band of bar material with a separator over it, the way
    /// Mail's "offline" bar sits under its content.
    @ViewBuilder
    func stripChrome() -> some View {
        #if os(macOS)
        self
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        #else
        self
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 6)
        #endif
    }

    @ViewBuilder
    func retryStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        self
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Theme.link)
        #endif
    }
}

// MARK: - Toasts

struct ToastOverlay: View {
    @Environment(AppModel.self) private var app
    #if os(macOS)
    /// A toast the pointer is over, or was over a moment ago. The shell's
    /// timer takes a toast out of `app.toasts` on its own schedule; while the
    /// pointer rests on one it stays here instead, which is what "the timer
    /// pauses on hover" comes to without a timer of this view's own to pause.
    @State private var held: Toast?
    @State private var release: Task<Void, Never>?
    #endif

    private var shown: [Toast] {
        #if os(macOS)
        if let held, !app.toasts.contains(held) { return app.toasts + [held] }
        #endif
        return app.toasts
    }

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            ForEach(shown) { toast in
                ToastCard(toast: toast, dismiss: { dismiss(toast) }, hover: { hover($0, toast) })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 28)
        .padding(.horizontal, 20)
        .animation(.spring(duration: 0.3), value: shown)
        .allowsHitTesting(!shown.isEmpty)
        #if os(macOS)
        // Escape takes the newest one down.
        .onExitCommand {
            if let latest = shown.last { dismiss(latest) }
        }
        #elseif os(iOS)
        // Every outcome the app reports in words is reported in the hand at the
        // same moment. Keyed on the newest toast's id so a second one arriving
        // while the first is still up is felt too.
        .sensoryFeedback(trigger: app.toasts.last?.id) { _, latest in
            guard latest != nil else { return nil }
            switch app.toasts.last?.tone {
            case .error: return .error
            case .ok: return .success
            default: return .impact(weight: .light)
            }
        }
        #endif
    }

    private func dismiss(_ toast: Toast) {
        app.dismiss(toast)
        #if os(macOS)
        if held == toast { held = nil }
        #endif
    }

    private func hover(_ isHovering: Bool, _ toast: Toast) {
        #if os(macOS)
        release?.cancel()
        if isHovering {
            held = toast
        } else if held == toast {
            // Gone from the pointer: a moment more, then it goes as it would
            // have.
            release = Task {
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                if held == toast { held = nil }
            }
        }
        #endif
    }
}

/// One toast. Tapped, it goes; on the Mac a ✕ appears under the pointer to
/// say so.
private struct ToastCard: View {
    let toast: Toast
    let dismiss: () -> Void
    let hover: (Bool) -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(colour)
            Text(toast.text)
                .font(.subheadline)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            #if os(macOS)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
            .opacity(isHovering ? 1 : 0)
            #endif
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 460, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 0.5)
        )
        .shadow(radius: 12, y: 6)
        .onTapGesture(perform: dismiss)
        #if os(macOS)
        .onHover { hovering in
            isHovering = hovering
            hover(hovering)
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        #endif
    }

    private var symbol: String {
        switch toast.tone {
        case .info: "info.circle"
        case .ok: "checkmark.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    private var colour: Color {
        switch toast.tone {
        case .info: Theme.accent
        case .ok: Theme.ok
        case .error: Theme.danger
        }
    }
}

// MARK: - Small pieces

#if os(iOS)
/// The application's own mark: the icon it ships with, and the wordmark set the
/// way the sign-in screen sets it.
struct BrandMark: View {
    var body: some View {
        HStack(spacing: 7) {
            Image("Logo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 24, height: 24)
            HStack(spacing: 0) {
                Text("Aqua").fontWeight(.semibold)
                Text("rium").fontWeight(.heavy).foregroundStyle(Theme.accent)
            }
            .font(.title3)
            .foregroundStyle(Theme.text)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aquarium")
        .accessibilityAddTraits(.isHeader)
    }
}

/// The solid band at the top of the screens whose artwork would otherwise run
/// to the edge of the display: the page colour, opaque, with whatever the
/// screen puts in it — the wordmark on Home, the way back on a detail page —
/// sitting under the Dynamic Island, and the artwork starting below.
///
/// What this replaces was a scrim: a blur fading into the artwork, with the
/// hero running the full height of the display behind it. That left the clock
/// and the island floating on whatever the backdrop happened to be doing, and
/// the top of the screen looking different on every title.
///
/// Every one of these screens draws this rather than using a navigation bar,
/// and that is worth the price of a hand-made back button. A page pushed from
/// a large-titled screen — Library, Search, Favourites — got that screen's bar
/// height to start with, and only took its own once something else made the
/// page redraw: the top of a series page shrank a moment *after* it had
/// finished loading, which is the last moment anything should move. A bar the
/// page draws for itself is the height it is from the first frame.
struct AppTopBar<Content: View>: View {
    /// How tall the band is. The default is a system navigation bar's own
    /// height, which is what a bar standing in for one wants. A screen whose
    /// heading *is* this bar — nothing else on the page names it — can ask for
    /// more, the way a large title would have taken more.
    var height: CGFloat = Metrics.topBar
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 9)
            .frame(height: height, alignment: .bottom)
            // The bar is fitted below the status bar and its fill is what
            // reaches up past it. Measuring the inset instead — a
            // GeometryReader inside an `ignoresSafeArea`, which is the usual
            // trick — reports zero as often as not, and a bar built on that
            // number puts the wordmark through the middle of the clock.
            .background {
                Theme.background.ignoresSafeArea(edges: .top)
            }
            // The one thing separating an opaque bar from the artwork under it.
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Theme.border)
                    .frame(height: 0.5)
            }
    }
}

/// Puts the back-swipe back on a page that hides the navigation bar.
///
/// UIKit switches off `interactivePopGestureRecognizer` when a page has no
/// navigation bar, on the assumption that a page without a bar has no back
/// button either. These pages have one — it is drawn in `AppTopBar` — and the
/// swipe is how most people actually leave a page, so it has to come back.
///
/// The delegate applies the same rule the bar's own would: only when there is
/// something to go back to, and never while another push or pop is already
/// running. The previous delegate is restored on the way out, so this page
/// changes nothing for the pages that keep their bar.
struct BackSwipe: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        Host(coordinator: context.coordinator)
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var navigation: UINavigationController?
        weak var previousDelegate: UIGestureRecognizerDelegate?

        func gestureRecognizerShouldBegin(_ recogniser: UIGestureRecognizer) -> Bool {
            guard let navigation else { return false }
            return navigation.viewControllers.count > 1 && navigation.transitionCoordinator == nil
        }
    }

    private final class Host: UIViewController {
        private let coordinator: Coordinator

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            guard let navigation = parent?.navigationController else {
                restore()
                return
            }
            guard let gesture = navigation.interactivePopGestureRecognizer else { return }
            coordinator.navigation = navigation
            coordinator.previousDelegate = gesture.delegate
            gesture.delegate = coordinator
            gesture.isEnabled = true
        }

        private func restore() {
            guard let gesture = coordinator.navigation?.interactivePopGestureRecognizer,
                  gesture.delegate === coordinator
            else { return }
            gesture.delegate = coordinator.previousDelegate
        }

        deinit { }
    }
}

/// The way back, for a page that draws its own bar. The system's back button
/// comes with the system's navigation bar, and that bar is the thing these
/// pages are doing without.
struct BarBackButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.backward")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.accent)
                // The glyph keeps the gutter; the rest of the frame is
                // somewhere to land a thumb.
                .frame(width: 44, height: 38, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }
}
#endif

#if os(tvOS)
/// What a pushed page is called, drawn as the first thing in its scroll view.
///
/// This is the tvOS half of `screenTitle`: the name has to be somewhere, and the
/// one place it can be without hanging over the content is inside it. It scrolls
/// off the top with the first row, which is what makes it a heading rather than
/// the watermark a `navigationTitle` becomes here.
struct PageHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title.weight(.semibold))
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }
}
#endif

/// A fact worth reading as its own thing rather than as another clause in a
/// grey sentence — a genre, a studio.
///
/// A capsule on a phone; on the Mac, where a pill reads as a web tag, the
/// same fact in secondary text, the way the TV app lists a film's genres.
struct MetaChip: View {
    var text: String
    var symbol: String?

    var body: some View {
        #if os(macOS)
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.caption)
            }
            Text(text).font(.subheadline)
        }
        .foregroundStyle(.secondary)
        #else
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.caption2)
            }
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(Theme.textBody)
        .background(Theme.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
        #endif
    }
}

#if !os(tvOS)
/// The levels above the page you are on: an episode's show and season, a
/// season's show.
///
/// A title page can be reached from anywhere — an episode straight off Home,
/// a season out of search — and until now the only way up from one was the way
/// you came down, which on those two routes is not up at all. This is the way
/// up, and it is on every one of those pages regardless of how it was opened.
///
/// Reading matter that happens to be live, rather than another row of buttons:
/// the page already has a row of buttons, and a show's name set in a pill next
/// to Play would read as something that starts it. So it is a line of small
/// type in the colour this app gives to words that lead somewhere — a label
/// you can press, which is what a link is.
struct AncestorTrail: View {
    let item: BaseItem

    @Environment(AppModel.self) private var app

    /// One level up: what to call it, and what to open.
    private struct Step: Identifiable {
        let id: String
        let name: String
    }

    var body: some View {
        let steps = self.steps
        if !steps.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textDim)
                    }
                    Button {
                        // Back where it is behind us, forwards where it isn't.
                        app.navigate(to: .item(step.id))
                    } label: {
                        Text(step.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.link)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .crumbStyle(name: step.name)
                    .accessibilityHint("Opens \(step.name)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Show first, then season — the order they are in, and the order the
    /// chevrons read. A show has nothing above it, and a film has nothing above
    /// it either.
    private var steps: [Step] {
        var out: [Step] = []
        if let id = seriesId, id != item.Id,
           let name = item.SeriesName, !name.isEmpty {
            out.append(Step(id: id, name: name))
        }
        if item.isEpisode, let id = seasonId, id != item.Id {
            out.append(Step(id: id, name: seasonName))
        }
        return out
    }

    /// A season's parent *is* its show, which is the fallback for a server that
    /// fills in `ParentId` and not `SeriesId`.
    private var seriesId: String? {
        guard item.isEpisode || item.isSeason else { return nil }
        return item.SeriesId ?? (item.isSeason ? item.ParentId : nil)
    }

    /// And an episode's parent is its season.
    private var seasonId: String? {
        let id = item.SeasonId ?? item.ParentId
        return (id?.isEmpty ?? true) ? nil : id
    }

    /// What the server calls it, or what its number makes it. Season zero is
    /// Jellyfin's specials, which is never what "Season 0" means to anyone
    /// reading it.
    private var seasonName: String {
        if let name = item.SeasonName, !name.isEmpty { return name }
        guard let number = item.ParentIndexNumber else { return "Season" }
        return number == 0 ? "Specials" : "Season \(number)"
    }
}

private extension View {
    /// A crumb is a link on the Mac — the system's own, with a tooltip for
    /// the name the line may have cut short — and a pressable row elsewhere.
    @ViewBuilder
    func crumbStyle(name: String) -> some View {
        #if os(macOS)
        buttonStyle(.link).help("Open \(name)")
        #else
        buttonStyle(RowPressStyle(inset: 6))
        #endif
    }
}
#endif

/// The line of facts under a title: year · runtime · rating · ★.
struct FactsLine: View {
    let item: BaseItem

    var body: some View {
        let parts = facts
        if !parts.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Text(part)
                }
            }
            .font(.subheadline)
            .foregroundStyle(Theme.textDim)
        }
    }

    private var facts: [String] {
        var out: [String] = []
        if let year = item.ProductionYear { out.append(String(year)) }
        let runtime = Format.ticks(item.RunTimeTicks)
        if !runtime.isEmpty { out.append(runtime) }
        if let rating = item.OfficialRating, !rating.isEmpty { out.append(rating) }
        if let community = item.CommunityRating {
            out.append("★ " + String(format: "%.1f", community))
        }
        return out
    }
}

/// The description of what the file on the server actually is, beside the
/// quality menu — "1080p · HEVC · EAC3 · 5.1 · 8.4 GiB".
struct MediaSummaryLine: View {
    let item: BaseItem

    var body: some View {
        let parts = Format.mediaSummary(item)
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(Theme.textDim)
        }
    }
}
