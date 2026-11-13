// api.ts against the live QA server: writing the account's state. Played and
// favourite switches, playback reports and what the server makes of them,
// Next Up taken off and put on (removeFromNextUp, addToNextUp), and the Next
// Up day limit.
//
// Every test here changes suite-linux's state and runs only when the account
// is the suite's own (qaWritable). The user data of every item a test can
// touch is saved first and written back afterwards, whole, and the suite
// checks it came back. Next Up is exercised on Sherlock and Firefly from the
// older Shows library, which the suite-linux baseline leaves untouched, so
// the fixture shows' baseline (and any other suite sharing the account) is
// not disturbed.
//
// Server state changed, and how it is put back:
// - Played / PlayCount / position / last-played date / favourite of FX Rated
//   PG-13, FX Rated R, FX Long Remux Multitrack and every episode of Sherlock
//   and Firefly: saved in beforeAll, written back by restoreUserData (items
//   left as they were are not written), checked by expectRestored.
// - addToNextUp(…, "first") sends `DELETE /UserPlayedItems/{seriesId}` for
//   Sherlock; that changes nothing on this server (see the BUG below).
// - The play sessions the playback reports open are closed by the reports
//   themselves (`/Sessions/Playing/Stopped`).
// - The Next Up day-limit test sets next_up_days in the mocked config only.
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { qa, qaWritable } from "../helpers/qa";
import {
  byName,
  expectCleanBridgeCalls,
  expectRestored,
  fx,
  qaApiFull,
  restoreUserData,
  saveUserData,
  userData,
  type SavedUserData,
} from "../helpers/api-qa";

const SEC = 10_000_000;

beforeEach(() => {
  vi.resetModules();
});

/** A report body the way player.rs `report_body` builds it. */
function report(itemId: string, mediaSourceId: string, playSessionId: string, seconds: number, extra: Record<string, any> = {}) {
  return {
    ItemId: itemId,
    PositionTicks: Math.round(seconds * SEC),
    IsPaused: false,
    CanSeek: true,
    PlayMethod: "DirectStream",
    MediaSourceId: mediaSourceId,
    PlaySessionId: playSessionId,
    ...extra,
  };
}

/** What player.rs sends at the end: no IsPaused, no EventName. */
function stopped(itemId: string, mediaSourceId: string, playSessionId: string, seconds: number) {
  const { IsPaused: _p, ...body } = report(itemId, mediaSourceId, playSessionId, seconds);
  return body;
}

/** The series on the server's own Next Up, in its order. */
async function nextUpSeries(): Promise<string[]> {
  const r = await qa!.request(`/Shows/NextUp?userId=${qa!.userId}&Limit=100&enableResumable=true&enableRewatching=false`);
  return r.body.Items.map((i: any) => i.SeriesId);
}

/** A show's episodes as the server lists them, in order, specials first. */
async function episodesOf(seriesId: string): Promise<any[]> {
  return (await qa!.request(`/Shows/${seriesId}/Episodes?userId=${qa!.userId}`)).body.Items;
}

/** Regular (not season 0) episodes. */
function regular(eps: any[]): any[] {
  return eps.filter((e) => (e.ParentIndexNumber ?? 1) !== 0);
}

describe.skipIf(!qa || !qaWritable)("QA server: api.ts writing state (restored afterwards)", () => {
  let saved: SavedUserData[] = [];
  let sherlock: any;
  let firefly: any;

  beforeAll(async () => {
    sherlock = await byName("Sherlock", "Series");
    firefly = await byName("Firefly", "Series");
    const ids = [
      fx("film.rated_pg13").id,
      fx("film.rated_r").id,
      fx("film.long_multitrack").id,
      ...(await episodesOf(sherlock.Id)).map((e) => e.Id),
      ...(await episodesOf(firefly.Id)).map((e) => e.Id),
    ];
    saved = await saveUserData(ids);
  });

  afterAll(async () => {
    await restoreUserData(saved);
    await expectRestored(saved);
  });

  it("starts from shows nobody has watched (or the suite cannot tell what it changed)", () => {
    const shows = saved.slice(3);
    expect(shows.length).toBeGreaterThan(5);
    expect(shows.every((u) => !u.Played && !u.PlaybackPositionTicks && !u.LastPlayedDate)).toBe(true);
  });

  it("marks a film played and unplayed", async () => {
    const api = await qaApiFull();
    const id = fx("film.rated_pg13").id;
    const before = await userData(id);
    try {
      await api.markPlayed(id, true);
      expect((await userData(id)).Played).toBe(true);
      const unwatched = await api.getLibraryItems((await api.getItem(id)).ParentId, { limit: 200, unwatched: true });
      expect(unwatched.Items.map((i) => i.Id)).not.toContain(id);
      await api.markPlayed(id, false);
      expect((await userData(id)).Played).toBe(false);
      expectCleanBridgeCalls();
    } finally {
      await restoreUserData([before]);
    }
  });

  it("stars and unstars a film, and the favourites list follows", async () => {
    const api = await qaApiFull();
    const id = fx("film.rated_r").id;
    const before = await userData(id);
    try {
      await api.setFavorite(id, true);
      expect((await userData(id)).IsFavorite).toBe(true);
      expect((await api.getFavorites({ limit: 200 })).Items.map((i) => i.Id)).toContain(id);
      await api.setFavorite(id, false);
      expect((await userData(id)).IsFavorite).toBe(false);
      expect((await api.getFavorites({ limit: 200 })).Items.map((i) => i.Id)).not.toContain(id);
    } finally {
      await restoreUserData([before]);
    }
  });

  it("keeps the position a playback report leaves on a long title, and puts it on Continue Watching", async () => {
    const api = await qaApiFull();
    const f = fx("film.long_multitrack");
    const before = await userData(f.id);
    try {
      const src = await api.resolvePlayback(f.id);
      const ms = src.mediaSourceId;
      expect((await qa!.request("/Sessions/Playing", "POST", report(f.id, ms, src.playSessionId, 0))).status).toBe(204);
      expect(
        (await qa!.request("/Sessions/Playing/Progress", "POST", report(f.id, ms, src.playSessionId, 120, { EventName: "timeupdate" }))).status
      ).toBe(204);
      expect((await qa!.request("/Sessions/Playing/Stopped", "POST", stopped(f.id, ms, src.playSessionId, 125))).status).toBe(204);
      const after = await userData(f.id);
      expect(after.Played).toBe(false);
      expect(after.PlaybackPositionTicks / SEC).toBeCloseTo(125, 0);
      expect((await api.getResume()).map((i) => i.Id)).toContain(f.id);
      expect(api.remainingText((await api.getItem(f.id)).RunTimeTicks, after.PlaybackPositionTicks)).toBe("10m");
    } finally {
      await restoreUserData([before]);
    }
  });

  it("finds a short title marked played at position 0 when stopped early (server rule, not an app bug: MinResumeDurationSeconds 300)", async () => {
    const api = await qaApiFull();
    const f = fx("film.rated_pg13");
    const before = await userData(f.id);
    try {
      const src = await api.resolvePlayback(f.id);
      await qa!.request("/Sessions/Playing", "POST", report(f.id, src.mediaSourceId, src.playSessionId, 0));
      await qa!.request("/Sessions/Playing/Stopped", "POST", stopped(f.id, src.mediaSourceId, src.playSessionId, 10));
      const after = await userData(f.id);
      expect(after.Played).toBe(true);
      expect(after.PlaybackPositionTicks).toBe(0);
      expect((await api.getResume()).map((i) => i.Id)).not.toContain(f.id);
    } finally {
      await restoreUserData([before]);
    }
  });

  it("takes a show off Next Up without touching what was watched", async () => {
    const api = await qaApiFull();
    const eps = regular(await episodesOf(firefly.Id));
    const before = await saveUserData(eps.map((e) => e.Id));
    try {
      await api.markPlayed(eps[0].Id, true);
      expect(await nextUpSeries()).toContain(firefly.Id);
      expect((await api.getNextUp()).map((i) => i.SeriesId)).toContain(firefly.Id);
      const watched = await saveUserData(eps.map((e) => e.Id));
      await api.removeFromNextUp(firefly.Id);
      expect(await nextUpSeries()).not.toContain(firefly.Id);
      expect((await api.getNextUp()).map((i) => i.SeriesId)).not.toContain(firefly.Id);
      // Watched stays watched; only the date went.
      const after = await saveUserData(eps.map((e) => e.Id));
      expect(after.map((u) => [u.Played, u.PlayCount, u.PlaybackPositionTicks])).toEqual(
        watched.map((u) => [u.Played, u.PlayCount, u.PlaybackPositionTicks])
      );
      expect(after.every((u) => !api.hasPlayedDate({ UserData: u }))).toBe(true);
      expectCleanBridgeCalls();
    } finally {
      await restoreUserData(before);
    }
  });

  it("puts a show back on Next Up from its last watched episode, which then leads the server's own row (jellyfin-next-up-rules)", async () => {
    const api = await qaApiFull();
    const eps = regular(await episodesOf(sherlock.Id));
    const before = await saveUserData(eps.map((e) => e.Id));
    try {
      await api.markPlayed(eps[0].Id, true);
      await api.removeFromNextUp(sherlock.Id);
      expect(await nextUpSeries()).not.toContain(sherlock.Id);
      const was = await userData(eps[0].Id);
      const target = await api.addToNextUp(sherlock.Id, "last");
      expect(target?.Id).toBe(eps[1].Id);
      const dated = await userData(eps[0].Id);
      // The whole state went with the date: still watched, same count and position.
      expect([dated.Played, dated.PlayCount, dated.PlaybackPositionTicks]).toEqual([was.Played, was.PlayCount, was.PlaybackPositionTicks]);
      expect(api.hasPlayedDate({ UserData: dated })).toBe(true);
      expect(Date.now() - Date.parse(dated.LastPlayedDate!)).toBeLessThan(10 * 60_000);
      // Ordered by the last *watched* episode's date: now the newest.
      expect((await nextUpSeries())[0]).toBe(sherlock.Id);
      expect((await api.getNextUp())[0]?.Id).toBe(eps[1].Id);
    } finally {
      await restoreUserData(before);
    }
  });

  it("offers a show added from a started episode only with in-progress episodes allowed (enableResumable)", async () => {
    const api = await qaApiFull();
    const eps = regular(await episodesOf(sherlock.Id));
    const before = await saveUserData(eps.map((e) => e.Id));
    try {
      await api.markPlayed(eps[0].Id, true);
      // Episode 2 started: five minutes in.
      await qa!.request(`/UserItems/${eps[1].Id}/UserData?userId=${qa!.userId}`, "POST", {
        PlaybackPositionTicks: 300 * SEC,
        Played: false,
        PlayCount: 0,
        LastPlayedDate: new Date().toISOString(),
      });
      expect((await api.getNextUp()).map((i) => i.Id)).toContain(eps[1].Id);
      await api.saveConfig({ next_up_in_progress: false });
      expect((await api.getNextUp()).map((i) => i.Id)).not.toContain(eps[1].Id);
    } finally {
      await restoreUserData(before);
    }
  });

  // BUG: addToNextUp(id, "first") (src/api.ts:723) unwatches the show with
  // `DELETE /UserPlayedItems/{seriesId}`. On the QA server's Jellyfin 12.2
  // that call answers 200 and changes no episode (measured 2026-11-12 on FX
  // Short Show, FX Long Show and Firefly, and `POST` on a series marks none
  // either; the 2026-10-27 note that it clears every episode no longer
  // holds). So "start over" leaves the watched episodes watched, the server
  // keeps offering the episode after them, and the episode returned (S01E01)
  // is not the one Next Up shows.
  it.fails("starts a show over from its first episode: unwatched throughout, front of the row (regression: partial UserData POST resurrected Played)", async () => {
    const api = await qaApiFull();
    const eps = regular(await episodesOf(sherlock.Id));
    const before = await saveUserData(eps.map((e) => e.Id));
    try {
      await api.markPlayed(eps[0].Id, true);
      await api.markPlayed(eps[1].Id, true);
      const target = await api.addToNextUp(sherlock.Id, "first");
      expect(target?.Id).toBe(eps[0].Id);
      const after = await saveUserData(eps.map((e) => e.Id));
      for (const u of after) {
        expect(u.Played, u.id).toBe(false);
        expect(u.PlayCount, u.id).toBe(0);
        expect(u.PlaybackPositionTicks, u.id).toBe(0);
      }
      expect(api.hasPlayedDate({ UserData: after[0] })).toBe(true);
      // Jellyfin puts a show with nothing watched last; the app lifts it to the front.
      expect((await api.getNextUp())[0]?.Id).toBe(eps[0].Id);
    } finally {
      await restoreUserData(before);
    }
  });

  it("dates the first episode, with nothing else, when starting over (the part that does work)", async () => {
    const api = await qaApiFull();
    const eps = regular(await episodesOf(firefly.Id));
    const before = await saveUserData(eps.map((e) => e.Id));
    try {
      // A show nobody watched: nothing for the series call to clear.
      const target = await api.addToNextUp(firefly.Id, "first");
      expect(target?.Id).toBe(eps[0].Id);
      const first = await userData(eps[0].Id);
      expect([first.Played, first.PlayCount, first.PlaybackPositionTicks]).toEqual([false, 0, 0]);
      expect(api.hasPlayedDate({ UserData: first })).toBe(true);
      expect(await nextUpSeries()).toContain(firefly.Id);
      // newStartsFirst: the started-over show leads the app's row.
      expect((await api.getNextUp())[0]?.Id).toBe(eps[0].Id);
    } finally {
      await restoreUserData(before);
    }
  });

  it("offers nothing to add for a show with nothing left to watch", async () => {
    const api = await qaApiFull();
    const eps = regular(await episodesOf(firefly.Id));
    const before = await saveUserData(eps.map((e) => e.Id));
    try {
      // Episode by episode: the series-level call does not reach them (see the BUG above).
      for (const e of eps) await api.markPlayed(e.Id, true);
      const dates = (await saveUserData(eps.map((e) => e.Id))).map((u) => u.LastPlayedDate);
      expect(await api.addToNextUp(firefly.Id, "last")).toBeNull();
      // Nothing was dated by the refusal.
      expect((await saveUserData(eps.map((e) => e.Id))).map((u) => u.LastPlayedDate)).toEqual(dates);
    } finally {
      await restoreUserData(before);
    }
  });

  it("takes a show past the day limit off Next Up on the server, and keeps one inside it", async () => {
    const api = await qaApiFull();
    const ff = regular(await episodesOf(firefly.Id));
    const sh = regular(await episodesOf(sherlock.Id));
    const before = await saveUserData([...ff, ...sh].map((e) => e.Id));
    try {
      const old = new Date(Date.now() - 40 * 86_400_000).toISOString();
      // Firefly watched 40 days ago, Sherlock today.
      await qa!.request(`/UserItems/${ff[0].Id}/UserData?userId=${qa!.userId}`, "POST", { Played: true, PlayCount: 1, PlaybackPositionTicks: 0, LastPlayedDate: old });
      await api.markPlayed(sh[0].Id, true);
      expect(await nextUpSeries()).toEqual(expect.arrayContaining([firefly.Id, sherlock.Id]));
      await api.saveConfig({ next_up_days: 30 });
      const row = await api.getNextUp();
      expect(row.map((i) => i.SeriesId)).toContain(sherlock.Id);
      expect(row.map((i) => i.SeriesId)).not.toContain(firefly.Id);
      // The removal runs in the background after the row is drawn.
      const deadline = Date.now() + 10_000;
      while ((await nextUpSeries()).includes(firefly.Id) && Date.now() < deadline) await new Promise((r) => setTimeout(r, 100));
      expect(await nextUpSeries()).not.toContain(firefly.Id);
      expect(await nextUpSeries()).toContain(sherlock.Id);
      // Taken off by date only: still watched.
      expect((await userData(ff[0].Id)).Played).toBe(true);
    } finally {
      await restoreUserData(before);
    }
  });
});
