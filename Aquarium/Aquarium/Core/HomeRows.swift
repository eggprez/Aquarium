//  The two rows Home draws from watched state — Continue Watching and Next
//  Up — and the one row they fold into when the setting says so.
//
//  Pure functions over the two lists the server returns, kept out of the view
//  so the rule for "which episode does the card stand for" is in one place
//  and can be read without the page around it.

import Foundation

enum HomeRows {
    /// Continue Watching and Next Up as one row of posters.
    ///
    /// Films and anything else that isn't an episode keep their place from
    /// Continue Watching. Each show gets one card, in the place of its most
    /// recently played episode; shows Next Up has but Continue Watching does
    /// not follow, in Next Up's order. The card stands for one episode — see
    /// `representative` — and it is that episode's progress bar the poster
    /// carries, and that episode the card opens.
    static func combined(resume: [BaseItem], nextUp: [BaseItem]) -> [BaseItem] {
        var nextUpBySeries: [String: BaseItem] = [:]
        for item in nextUp where item.isEpisode {
            guard let seriesId = item.SeriesId, nextUpBySeries[seriesId] == nil else { continue }
            nextUpBySeries[seriesId] = item
        }
        var inProgressBySeries: [String: [BaseItem]] = [:]
        for item in resume where item.isEpisode {
            guard let seriesId = item.SeriesId else { continue }
            inProgressBySeries[seriesId, default: []].append(item)
        }

        var out: [BaseItem] = []
        var placed = Set<String>()
        for item in resume {
            guard item.isEpisode, let seriesId = item.SeriesId else {
                out.append(item)
                continue
            }
            guard placed.insert(seriesId).inserted else { continue }
            out.append(representative(
                nextUp: nextUpBySeries[seriesId],
                inProgress: inProgressBySeries[seriesId] ?? [item]
            ))
        }
        for item in nextUp {
            if item.isEpisode, let seriesId = item.SeriesId {
                guard placed.insert(seriesId).inserted else { continue }
            }
            out.append(item)
        }
        return out
    }

    /// The one episode a show's card stands for, given what Next Up has
    /// queued for it and which of its episodes are partway through.
    ///
    /// When Next Up's own episode is one of them, it is that one. Otherwise
    /// the in-progress episode closest to it from before — the one you were
    /// in the middle of on the way to where Next Up has got to, which is
    /// what a show with two or three episodes started leaves behind. Failing
    /// that, the closest one after it: an episode you skipped ahead to is
    /// still the one you are watching, and dropping its progress from the
    /// row would be worse than showing it. A show Next Up has nothing for —
    /// its last episode started, or an older server — shows its most
    /// recently played in-progress episode.
    static func representative(nextUp: BaseItem?, inProgress: [BaseItem]) -> BaseItem {
        guard let nextUp else { return inProgress[0] }
        if let same = inProgress.first(where: { $0.Id == nextUp.Id }) { return same }
        let target = order(nextUp)
        let before = inProgress.filter { order($0) < target }
        if let closest = before.max(by: { order($0) < order($1) }) { return closest }
        let after = inProgress.filter { order($0) > target }
        if let closest = after.min(by: { order($0) < order($1) }) { return closest }
        return inProgress.first ?? nextUp
    }

    /// Where an episode sits in its show: season, then episode. Specials are
    /// season zero on the server and sort first, which is as good a place as
    /// any for them.
    private static func order(_ item: BaseItem) -> (Int, Int) {
        (item.ParentIndexNumber ?? 0, item.IndexNumber ?? 0)
    }

    /// `row` without the shows removed from Next Up by hand.
    ///
    /// A show was removed while a particular episode was its card — see
    /// `Preferences.hideFromNextUp` — and stays off the row while the card
    /// would still be that episode, or while Next Up still has that episode
    /// queued for it: the combined row and the separate one may stand a show
    /// on different episodes, and removing it in one must remove it in the
    /// other. Once something later has been watched, neither matches and the
    /// show is back.
    static func visible(
        _ row: [BaseItem],
        nextUp: [BaseItem],
        hiddenEpisode: (_ seriesId: String) -> String?
    ) -> [BaseItem] {
        var nextUpBySeries: [String: String] = [:]
        for item in nextUp where item.isEpisode {
            guard let seriesId = item.SeriesId, nextUpBySeries[seriesId] == nil else { continue }
            nextUpBySeries[seriesId] = item.Id
        }
        return row.filter { item in
            guard item.isEpisode, let seriesId = item.SeriesId,
                  let hiddenAt = hiddenEpisode(seriesId)
            else { return true }
            return hiddenAt != item.Id && hiddenAt != nextUpBySeries[seriesId]
        }
    }
}
