//  The two rows Home draws from watched state — Continue Watching and Next
//  Up — and what is read off them: which part-watched episodes have been
//  abandoned, and which shows have been taken off Next Up by hand.
//
//  Pure functions over the two lists the server returns, kept out of the view
//  so the rules are in one place and can be read without the page around them.

import Foundation

enum HomeRows {
    /// How long an episode left partway through keeps counting as one you
    /// are watching, once Next Up has moved past it. See `standsIn`.
    static let recentWindow: TimeInterval = 30 * 24 * 60 * 60

    /// The in-progress episodes Home has given up on: each one behind where
    /// Next Up has got to for its show that no longer stands for the show
    /// (see `standsIn`), so that Continue Watching carries it only as
    /// clutter. These are what `Preferences.clearsAbandonedEpisodes` has the
    /// server forget.
    ///
    /// Only episodes behind Next Up: one skipped ahead to is deliberate, and
    /// a show Next Up has nothing for gives no point to measure from.
    static func abandoned(resume: [BaseItem], nextUp: [BaseItem], now: Date = Date()) -> [BaseItem] {
        var nextUpBySeries: [String: BaseItem] = [:]
        for item in nextUp where item.isEpisode {
            guard let seriesId = item.SeriesId, nextUpBySeries[seriesId] == nil else { continue }
            nextUpBySeries[seriesId] = item
        }
        return resume.filter { item in
            guard item.isEpisode, let seriesId = item.SeriesId,
                  let target = nextUpBySeries[seriesId], item.Id != target.Id
            else { return false }
            return order(item) < order(target) && !standsIn(item, for: target, now: now)
        }
    }

    /// Whether an in-progress episode behind `nextUp` is still one being
    /// watched: the episode immediately before it — the
    /// previous one in the season, or one from the season before when Next Up
    /// is at a season's start — or anything played inside `recentWindow`.
    /// Everything else behind Next Up was left and never returned to.
    static func standsIn(_ episode: BaseItem, for nextUp: BaseItem, now: Date) -> Bool {
        if isJustBefore(episode, nextUp) { return true }
        guard let played = Format.parseDate(episode.userData.LastPlayedDate) else { return false }
        return now.timeIntervalSince(played) < recentWindow
    }

    private static func isJustBefore(_ episode: BaseItem, _ nextUp: BaseItem) -> Bool {
        let (season, index) = order(episode)
        let (targetSeason, targetIndex) = order(nextUp)
        if season == targetSeason { return targetIndex - index == 1 }
        return targetSeason - season == 1 && targetIndex <= 1
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
    /// queued for it. Once something later has been watched, neither matches
    /// and the show is back.
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
