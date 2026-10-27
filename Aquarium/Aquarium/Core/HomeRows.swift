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

    /// The episode Next Up will offer for a show, from its episodes in order:
    /// the first unwatched one after the last one watched, or the first
    /// unwatched one when nothing is. Nil when everything after the last
    /// watched episode has been watched too. Where "Add to Next Up" from the
    /// last watched episode picks a show up — see `JellyfinClient.addToNextUp`.
    static func nextUpTarget(_ all: [BaseItem]) -> BaseItem? {
        let episodes = walked(all)
        let lastWatched = episodes.lastIndex { $0.userData.played }
        let rest = lastWatched.map { episodes[($0 + 1)...] } ?? episodes[...]
        return rest.first { !$0.userData.played }
    }

    /// The episodes Next Up walks: specials are season zero and sit outside
    /// its order, unless a show is nothing but.
    private static func walked(_ all: [BaseItem]) -> [BaseItem] {
        let regular = all.filter { ($0.ParentIndexNumber ?? 1) != 0 }
        return regular.isEmpty ? all : regular
    }

    /// The last episode watched, in the show's order: the one whose
    /// last-played date places a show in Next Up. What "Add to Next Up" from
    /// the last watched episode dates — see `JellyfinClient.addToNextUp`.
    static func lastWatched(_ all: [BaseItem]) -> BaseItem? {
        walked(all).last { $0.userData.played }
    }

    /// Where a show starts. What "Add to Next Up" from the first episode
    /// dates, once everything has been marked unwatched.
    static func firstEpisode(_ all: [BaseItem]) -> BaseItem? {
        walked(all).first
    }

    /// Next Up with the shows added from their first episode at the front,
    /// newest first. Jellyfin orders the row by when each show's last
    /// watched episode was played, and a show with nothing watched has none,
    /// so it puts those last — past the row's 16 cards on a busy account.
    /// They are recognised by the episode offered carrying a last-played
    /// date while unwatched and not started, which only "Add to Next Up"
    /// writes. Everything else keeps the server's order.
    static func newStartsFirst(_ row: [BaseItem]) -> [BaseItem] {
        func addedAt(_ item: BaseItem) -> Date? {
            guard item.isEpisode, !item.userData.played,
                  (item.UserData?.PlaybackPositionTicks ?? 0) == 0,
                  hasPlayedDate(item)
            else { return nil }
            return Format.parseDate(item.UserData?.LastPlayedDate)
        }
        let added = row.compactMap { item in addedAt(item).map { (item, $0) } }
        guard !added.isEmpty else { return row }
        let ids = Set(added.map(\.0.Id))
        return added.sorted { $0.1 > $1.1 }.map(\.0) + row.filter { !ids.contains($0.Id) }
    }

    /// The last-played date that takes an episode out of what Next Up is
    /// built from: Jellyfin's earliest date, which it reads as never. See
    /// `JellyfinClient.removeFromNextUp`.
    static let notPlayedDate = "0001-01-01T00:00:00Z"

    /// Whether the server has a real last-played date for an episode —
    /// what puts its show on Next Up. Not one `notPlayedDate` has replaced.
    static func hasPlayedDate(_ item: BaseItem) -> Bool {
        guard let date = Format.parseDate(item.UserData?.LastPlayedDate) else { return false }
        return Calendar(identifier: .gregorian).component(.year, from: date) > 1
    }

    /// The shows Next Up still has that are past the day limit: in the
    /// server's whole answer, not in the one cut at the limit. Nothing when
    /// the cut answer is as long as the whole one, which is either a server
    /// that ignored the cutoff or two answers both at their length limit —
    /// neither says anything was left out for its date. See
    /// `JellyfinClient.nextUp`.
    static func expiredFromNextUp(everything: [BaseItem], kept: [BaseItem]) -> [String] {
        guard kept.count < everything.count else { return [] }
        let keptSeries = Set(kept.compactMap(\.SeriesId))
        var seen = Set<String>()
        return everything.compactMap(\.SeriesId).filter {
            !keptSeries.contains($0) && seen.insert($0).inserted
        }
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
