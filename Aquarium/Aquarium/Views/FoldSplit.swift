//  Two halves of a screen, one above the fold and one below it.
//
//  A foldable part-open on a table is a laptop: the top half stands up and
//  the bottom half lies flat under the hands. The pages that split there —
//  the player, Now Playing, a title's page — all do it the same way, and this
//  is that way. The system says where the crease is, and the top pane ends
//  at it; nothing is drawn across the crease itself.
//
//  The top pane is the first child of the same stack whether or not the
//  split is on, so a view that must not be remade by the fold — the player's
//  AVKit controller — can live there and stay alive across it.

#if os(iOS)
import SwiftUI

struct FoldSplit<Upper: View, Lower: View>: View {
    /// Whether to split at all. Off, `upper` alone fills the view.
    let split: Bool
    /// What the crease is painted: the page's own background.
    var crease: Color = .clear
    @ViewBuilder let upper: () -> Upper
    @ViewBuilder let lower: () -> Lower

    var body: some View {
        GeometryReader { geo in
            let fold = split ? Self.foldRect(in: geo) : nil
            VStack(spacing: 0) {
                upper()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(height: fold?.minY)
                    .clipped()
                if let fold {
                    crease.frame(height: fold.height)
                    lower()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// Where the fold crosses this view. The system knows on a foldable; a
    /// developer holding the pose in Settings on anything else gets the
    /// middle.
    private static func foldRect(in geo: GeometryProxy) -> CGRect {
        if #available(iOS 27.1, *) {
            if let region = geo.reservedRegions(kind: .division).first(where: \.isActive) {
                return region.frame
            }
        }
        return CGRect(x: 0, y: geo.size.height / 2, width: geo.size.width, height: 0)
    }
}
#endif
