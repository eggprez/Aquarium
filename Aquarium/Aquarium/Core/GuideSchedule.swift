//  One channel's programmes made to lie end to end, the way a guide draws
//  them. Feeds in the wild list the same programme twice, tuck a bulletin
//  inside the show around it, or carry a stray block that runs for hours
//  across everything else on the channel. Drawn as they came, those cells
//  land on top of one another — and the one that is on now paints its tint
//  under every programme it overlaps, which on a television looked like a
//  darker highlight over some of the episodes and not others.

import Foundation

enum GuideSchedule {
    /// `ordered` is one channel's programmes in airtime order. Exact
    /// duplicates go; a programme that starts inside the one before it cuts
    /// that one short at its own start (set through `ExternalEnd`, which
    /// `programEnd` reads first); two that start together keep the shorter,
    /// a stray block being the longer one.
    static func resolved(_ ordered: [BaseItem]) -> [BaseItem] {
        var out: [BaseItem] = []
        out.reserveCapacity(ordered.count)
        for item in ordered {
            guard let start = item.programStart, let end = item.programEnd, end > start else {
                // Undated, or ending before it starts: nothing to lay against
                // its neighbours. Left as it came.
                out.append(item)
                continue
            }
            if let last = out.last, let lastStart = last.programStart, let lastEnd = last.programEnd {
                if start == lastStart {
                    if end == lastEnd && item.title == last.title { continue }
                    if end < lastEnd { out[out.count - 1] = item }
                    continue
                }
                if start < lastEnd {
                    out[out.count - 1].ExternalEnd = start
                }
            }
            out.append(item)
        }
        return out
    }
}
