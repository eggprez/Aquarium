// api.ts: browsing. Views, resume, Next Up (reading it and writing it), the
// home layout, latest, library queries, favourites, genres, items, seasons and
// episodes, trickplay, media segments, search, Live TV, batches by id, and the
// played and favourite switches.
//
// Every user-scoped request must name the user with `userId=` on the plain
// route (Linux/CLAUDE.md): never `/Users/{id}/...`, never a token.
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  DETAIL_FIELDS,
  ITEM_FIELDS,
  episode,
  flush,
  fresh,
  invokeCalls,
  jfCalls,
  mockJellyfin,
  onInvoke,
  parsePath,
  signIn,
} from "../helpers/api";

beforeEach(fresh);

/** Answer every request with the same 200 body. */
function answer(body: any): void {
  onInvoke("jf_request", { status: 200, body });
}

/** The one request made, parsed. */
function only(): ReturnType<typeof parsePath> & { method: string; body: any; path: string } {
  const calls = jfCalls();
  expect(calls).toHaveLength(1);
  return { ...parsePath(calls[0]!.path), method: calls[0]!.method, body: calls[0]!.body, path: calls[0]!.path };
}

describe("the routes every call uses", () => {
  it("never uses the obsolete /Users/{id}/ routes or a token, across the whole read surface", async () => {
    const api = await signIn({ next_up_days: 30 });
    answer({ Items: [], TotalRecordCount: 0 });
    await api.getViews();
    await api.getResume();
    await api.getNextUp();
    await api.getSeriesNextUp("s");
    await api.getHomeSections();
    await api.getLibraryItems("lib");
    await api.getFavorites();
    await api.getGenres("lib", "Movie");
    await api.getItem("i");
    await api.getSimilar("i");
    await api.getSeasons("s");
    await api.getEpisodes("s", "se");
    await api.getTrickplay("i");
    await api.getMediaSegments("i");
    await api.search("x");
    await api.getChannels();
    await api.getPrograms(["c"], new Date(0), new Date(1));
    await api.getItemsByIds(["a"]);
    await api.markPlayed("i", true);
    await api.setFavorite("i", true);
    await api.removeFromNextUp("s");
    await api.addToNextUp("s", "last");
    onInvoke("jf_request", { status: 200, body: [] });
    await api.getLatest("lib");
    const calls = jfCalls();
    expect(calls.length).toBeGreaterThan(20);
    for (const c of calls) {
      expect(c.path).not.toMatch(/^\/Users\//);
      expect(c.path).not.toMatch(/api_key|token/i);
      // MediaSegments is the one read that is not per user.
      if (!c.path.startsWith("/MediaSegments/")) {
        expect(parsePath(c.path).params.userId, c.path).toBe("user-1");
      }
    }
  });
});

describe("isVideoItem and the collection types kept", () => {
  it("keeps films, shows, episodes and untyped things", async () => {
    const api = await signIn();
    for (const Type of ["Movie", "Series", "Episode", "Season", "Video", "MusicVideo", "BoxSet", "TvChannel", undefined]) {
      expect(api.isVideoItem({ Type }), String(Type)).toBe(true);
    }
  });

  it("drops audiobooks, songs, books, albums, artists, photos and playlists", async () => {
    const api = await signIn();
    for (const Type of ["AudioBook", "Audio", "Book", "MusicAlbum", "MusicArtist", "Photo", "PhotoAlbum", "Playlist"]) {
      expect(api.isVideoItem({ Type }), Type).toBe(false);
    }
  });

  it("drops anything whose media type is audio, book or photo, whatever its item type", async () => {
    const api = await signIn();
    expect(api.isVideoItem({ Type: "Video", MediaType: "Audio" })).toBe(false);
    expect(api.isVideoItem({ Type: "Folder", MediaType: "Book" })).toBe(false);
    expect(api.isVideoItem({ Type: "Video", MediaType: "Photo" })).toBe(false);
    expect(api.isVideoItem({ Type: "Movie", MediaType: "Video" })).toBe(true);
  });

  it("is false for nothing at all", async () => {
    const api = await signIn();
    expect(api.isVideoItem(null)).toBe(false);
    expect(api.isVideoItem(undefined)).toBe(false);
  });

  it("VIDEO_COLLECTION_TYPES keeps video and mixed libraries and leaves out music, books and photos", async () => {
    const api = await signIn();
    for (const t of ["movies", "tvshows", "homevideos", "musicvideos", "folders", null, undefined]) {
      expect(api.VIDEO_COLLECTION_TYPES.includes(t), String(t)).toBe(true);
    }
    for (const t of ["music", "books", "photos", "playlists", "livetv", "boxsets"]) {
      expect(api.VIDEO_COLLECTION_TYPES.includes(t), t).toBe(false);
    }
  });
});

describe("getViews and getResume", () => {
  it("getViews reads /UserViews for the user", async () => {
    const api = await signIn();
    answer({ Items: [{ Id: "v1" }] });
    await expect(api.getViews()).resolves.toEqual([{ Id: "v1" }]);
    expect(jfCalls()).toEqual([{ path: "/UserViews?userId=user-1", method: "GET", body: null }]);
  });

  it("getViews is empty when the answer has no list", async () => {
    const api = await signIn();
    answer({});
    await expect(api.getViews()).resolves.toEqual([]);
  });

  it("getResume asks for sixteen videos in progress", async () => {
    const api = await signIn();
    answer({ Items: [{ Id: "r1" }] });
    await expect(api.getResume()).resolves.toEqual([{ Id: "r1" }]);
    expect(jfCalls()[0]).toEqual({
      path: `/UserItems/Resume?userId=user-1&Limit=16&Fields=${ITEM_FIELDS}&MediaTypes=Video&EnableImageTypes=Primary,Backdrop,Thumb,Logo`,
      method: "GET",
      body: null,
    });
  });

  it("getResume is empty when the answer has no list", async () => {
    const api = await signIn();
    answer({});
    await expect(api.getResume()).resolves.toEqual([]);
  });
});

describe("Next Up settings labels", () => {
  it("offers Forever first and names every choice", async () => {
    const api = await signIn();
    expect(api.NEXT_UP_DAY_CHOICES[0]).toBe(0);
    expect(api.NEXT_UP_DAY_CHOICES.map(api.nextUpDaysLabel)).toEqual([
      "Forever",
      "1 week",
      "2 weeks",
      "1 month",
      "3 months",
      "6 months",
      "1 year",
    ]);
  });
});

describe("hasPlayedDate", () => {
  it("is true for a real date and false for none, Jellyfin's earliest, or rubbish", async () => {
    const api = await signIn();
    expect(api.hasPlayedDate({ UserData: { LastPlayedDate: "2026-10-27T09:00:00Z" } })).toBe(true);
    expect(api.hasPlayedDate({ UserData: { LastPlayedDate: api.NOT_PLAYED_DATE } })).toBe(false);
    expect(api.hasPlayedDate({ UserData: { LastPlayedDate: "0001-01-01T00:00:00.0000000Z" } })).toBe(false);
    expect(api.hasPlayedDate({ UserData: { LastPlayedDate: "not a date" } })).toBe(false);
    expect(api.hasPlayedDate({ UserData: {} })).toBe(false);
    expect(api.hasPlayedDate({})).toBe(false);
    expect(api.hasPlayedDate(null)).toBe(false);
  });
});

describe("newStartsFirst", () => {
  const watchedShow = (id: string): any => ({
    Id: id,
    Type: "Episode",
    UserData: { Played: false, PlaybackPositionTicks: 0 },
  });
  const added = (id: string, date: string): any => ({
    Id: id,
    Type: "Episode",
    UserData: { Played: false, PlaybackPositionTicks: 0, LastPlayedDate: date },
  });

  it("lifts shows added from their first episode to the front, newest first (regression: Jellyfin puts never-watched shows last, past the row's 16)", async () => {
    const api = await signIn();
    const row = [watchedShow("a"), watchedShow("b"), added("old", "2026-10-01T00:00:00Z"), added("new", "2026-10-20T00:00:00Z")];
    expect(api.newStartsFirst(row).map((i) => i.Id)).toEqual(["new", "old", "a", "b"]);
  });

  it("returns the same row when nothing was added", async () => {
    const api = await signIn();
    const row = [watchedShow("a"), watchedShow("b")];
    expect(api.newStartsFirst(row)).toBe(row);
  });

  it("does not lift an episode that is in progress, already played, undated, or not an episode", async () => {
    const api = await signIn();
    const date = "2026-10-20T00:00:00Z";
    const row = [
      watchedShow("a"),
      { Id: "started", Type: "Episode", UserData: { PlaybackPositionTicks: 5, LastPlayedDate: date } },
      { Id: "played", Type: "Episode", UserData: { Played: true, LastPlayedDate: date } },
      { Id: "never", Type: "Episode", UserData: { LastPlayedDate: api.NOT_PLAYED_DATE } },
      { Id: "movie", Type: "Movie", UserData: { LastPlayedDate: date } },
      { Id: "bare", Type: "Episode" },
    ];
    expect(api.newStartsFirst(row).map((i) => i.Id)).toEqual(["a", "started", "played", "never", "movie", "bare"]);
  });
});

describe("expiredFromNextUp", () => {
  const ep = (series: string, id = series + "-e"): any => ({ Id: id, SeriesId: series });

  it("names each show only the wider answer has, once, in order", async () => {
    const api = await signIn();
    const everything = [ep("a"), ep("b"), ep("c"), ep("b", "b-2"), ep("d")];
    expect(api.expiredFromNextUp(everything, [ep("a"), ep("c")])).toEqual(["b", "d"]);
  });

  it("removes nothing when the cut answer is as long as the wider one (a server ignoring the cutoff, or both at their limit)", async () => {
    const api = await signIn();
    expect(api.expiredFromNextUp([ep("a"), ep("b")], [ep("a"), ep("b")])).toEqual([]);
    expect(api.expiredFromNextUp([ep("a"), ep("b")], [ep("x"), ep("y"), ep("z")])).toEqual([]);
  });

  it("ignores entries with no series", async () => {
    const api = await signIn();
    expect(api.expiredFromNextUp([{ Id: "loose" }, ep("a")], [])).toEqual(["a"]);
  });
});

describe("nextUpTarget", () => {
  it("is the first unwatched episode after the last watched one", async () => {
    const api = await signIn();
    const eps = [
      episode("e1", 1, 1, { Played: true }),
      episode("e2", 1, 2),
      episode("e3", 1, 3, { Played: true }),
      episode("e4", 1, 4),
      episode("e5", 2, 1),
    ];
    expect(api.nextUpTarget(eps)?.Id).toBe("e4");
  });

  it("is the first episode when nothing is watched", async () => {
    const api = await signIn();
    expect(api.nextUpTarget([episode("e1", 1, 1), episode("e2", 1, 2)])?.Id).toBe("e1");
  });

  it("is null for a finished show and for no episodes", async () => {
    const api = await signIn();
    expect(api.nextUpTarget([episode("e1", 1, 1, { Played: true })])).toBeNull();
    expect(api.nextUpTarget([])).toBeNull();
  });

  it("leaves specials out of the walk", async () => {
    const api = await signIn();
    const eps = [episode("special", 0, 1), episode("e1", 1, 1, { Played: true }), episode("e2", 1, 2)];
    expect(api.nextUpTarget(eps)?.Id).toBe("e2");
    expect(api.nextUpTarget([episode("special", 0, 1), episode("e1", 1, 1)])?.Id).toBe("e1");
  });

  it("walks the specials when a show is nothing but specials", async () => {
    const api = await signIn();
    expect(api.nextUpTarget([episode("s1", 0, 1, { Played: true }), episode("s2", 0, 2)])?.Id).toBe("s2");
  });

  it("counts an episode with no season number as a regular one", async () => {
    const api = await signIn();
    const loose = { Id: "loose", Type: "Episode", UserData: {} };
    expect(api.nextUpTarget([episode("special", 0, 1), loose])?.Id).toBe("loose");
  });
});

describe("getNextUp", () => {
  const NOW = new Date("2026-11-12T12:00:00.000Z");

  it("with no day limit asks once, for the server's most, and shows sixteen", async () => {
    const api = await signIn();
    const items = Array.from({ length: 40 }, (_, i) => ({ Id: `e${i}`, Type: "Episode", SeriesId: `s${i}`, UserData: {} }));
    answer({ Items: items });
    const row = await api.getNextUp();
    expect(row.map((i) => i.Id)).toEqual(items.slice(0, 16).map((i) => i.Id));
    const q = only();
    expect(q.route).toBe("/Shows/NextUp");
    expect(q.params).toEqual({
      userId: "user-1",
      Limit: "100",
      enableResumable: "true",
      enableRewatching: "false",
      Fields: ITEM_FIELDS,
      EnableImageTypes: "Primary,Backdrop,Thumb,Logo",
    });
  });

  it("finds a show started over even when the server lists it past the sixteenth place (regression: Add to Next Up only sometimes worked)", async () => {
    const api = await signIn();
    const items: any[] = Array.from({ length: 30 }, (_, i) => ({ Id: `e${i}`, Type: "Episode", SeriesId: `s${i}`, UserData: {} }));
    items.push({
      Id: "restarted",
      Type: "Episode",
      SeriesId: "sx",
      UserData: { Played: false, PlaybackPositionTicks: 0, LastPlayedDate: "2026-11-10T00:00:00Z" },
    });
    answer({ Items: items });
    const row = await api.getNextUp();
    expect(row).toHaveLength(16);
    expect(row[0].Id).toBe("restarted");
  });

  it("sends the account's in-progress and rewatching choices", async () => {
    const api = await signIn({ next_up_in_progress: false, next_up_rewatching: true });
    answer({ Items: [] });
    await api.getNextUp();
    expect(only().params).toMatchObject({ enableResumable: "false", enableRewatching: "true" });
  });

  it("counts episodes in progress unless that was turned off (the server leaves a started episode out otherwise)", async () => {
    const api = await signIn({ next_up_in_progress: null });
    answer({ Items: [] });
    await api.getNextUp();
    expect(only().params.enableResumable).toBe("true");
  });

  it("treats a day limit that is not one of the choices as Forever", async () => {
    const api = await signIn({ next_up_days: 5 });
    answer({});
    await expect(api.getNextUp()).resolves.toEqual([]);
    expect(only().query.has("nextUpDateCutoff")).toBe(false);
  });

  it("with a day limit asks twice: cut at the limit, and a lean uncut one", async () => {
    vi.useFakeTimers({ now: NOW });
    const api = await signIn({ next_up_days: 30 });
    answer({ Items: [{ Id: "e1", Type: "Episode", SeriesId: "s1", UserData: {} }] });
    const row = await api.getNextUp();
    expect(row.map((i) => i.Id)).toEqual(["e1"]);
    const calls = jfCalls().map((c) => parsePath(c.path));
    expect(calls).toHaveLength(2);
    const cut = calls.find((c) => c.query.has("nextUpDateCutoff"))!;
    const wide = calls.find((c) => !c.query.has("nextUpDateCutoff"))!;
    expect(cut.params).toEqual({
      userId: "user-1",
      Limit: "100",
      enableResumable: "true",
      enableRewatching: "false",
      Fields: ITEM_FIELDS,
      EnableImageTypes: "Primary,Backdrop,Thumb,Logo",
      nextUpDateCutoff: "2026-10-13T12:00:00.000Z",
    });
    expect(wide.params).toEqual({
      userId: "user-1",
      Limit: "100",
      enableResumable: "true",
      enableRewatching: "false",
      enableImages: "false",
      enableUserData: "false",
    });
  });

  /** A server with shows a (recent) and b (stale); episodes of b carry dates. */
  function staleShowServer(opts: { failWide?: boolean; failRemoval?: boolean } = {}): void {
    mockJellyfin([
      [
        "/Shows/NextUp",
        ({ path }: any) => {
          const cut = parsePath(path).query.has("nextUpDateCutoff");
          if (!cut && opts.failWide) return { __status: 500 };
          const a = { Id: "a1", Type: "Episode", SeriesId: "a", UserData: {} };
          const b = { Id: "b3", Type: "Episode", SeriesId: "b", UserData: {} };
          return { Items: cut ? [a] : [a, b] };
        },
      ],
      [
        "/Shows/b/Episodes",
        () =>
          opts.failRemoval
            ? { __status: 500 }
            : {
                Items: [
                  episode("b1", 1, 1, { Played: true, PlayCount: 2, LastPlayedDate: "2026-01-01T00:00:00Z" }),
                  episode("b2", 1, 2, { Played: true, LastPlayedDate: "2026-01-02T00:00:00Z" }),
                  episode("b3", 1, 3),
                  episode("b4", 1, 4, { LastPlayedDate: "0001-01-01T00:00:00Z" }),
                ],
              },
      ],
      ["/UserItems/", null],
    ]);
  }

  it("takes a show past the limit off Next Up on the server, by its dates alone", async () => {
    const api = await signIn({ next_up_days: 30 });
    staleShowServer();
    const row = await api.getNextUp();
    expect(row.map((i) => i.Id)).toEqual(["a1"]);
    await flush(40);
    const writes = jfCalls().filter((c) => c.method !== "GET");
    expect(writes).toEqual([
      { path: "/UserItems/b1/UserData?userId=user-1", method: "POST", body: { LastPlayedDate: "0001-01-01T00:00:00Z" } },
      { path: "/UserItems/b2/UserData?userId=user-1", method: "POST", body: { LastPlayedDate: "0001-01-01T00:00:00Z" } },
    ]);
    // What has been watched is not touched.
    expect(jfCalls().some((c) => c.path.startsWith("/UserPlayedItems"))).toBe(false);
  });

  it("removes nothing when the wider question fails, and still answers", async () => {
    const api = await signIn({ next_up_days: 30 });
    staleShowServer({ failWide: true });
    await expect(api.getNextUp()).resolves.toHaveLength(1);
    await flush(40);
    expect(jfCalls().filter((c) => c.method !== "GET")).toEqual([]);
    expect(jfCalls().some((c) => c.path.startsWith("/Shows/b/Episodes"))).toBe(false);
  });

  it("fails when the cut question itself fails", async () => {
    const api = await signIn({ next_up_days: 30 });
    onInvoke("jf_request", { status: 500, body: null });
    await expect(api.getNextUp()).rejects.toThrow("Server error 500 on /Shows/NextUp");
  });

  it("two loads at once take a show off only once", async () => {
    const api = await signIn({ next_up_days: 30 });
    staleShowServer();
    await Promise.all([api.getNextUp(), api.getNextUp()]);
    await flush(60);
    expect(jfCalls().filter((c) => c.path.startsWith("/Shows/b/Episodes"))).toHaveLength(1);
    expect(jfCalls().filter((c) => c.method === "POST")).toHaveLength(2);
  });

  it("logs a removal that failed and tries again on the next load", async () => {
    const api = await signIn({ next_up_days: 30 });
    staleShowServer({ failRemoval: true });
    await api.getNextUp();
    await flush(40);
    const logs = invokeCalls("ui_log").map((c) => c.args.msg as string);
    expect(logs).toHaveLength(1);
    expect(logs[0]).toContain("couldn't take b off");
    await api.getNextUp();
    await flush(40);
    expect(jfCalls().filter((c) => c.path.startsWith("/Shows/b/Episodes"))).toHaveLength(2);
  });

  it("puts started-over shows first under a day limit too", async () => {
    const api = await signIn({ next_up_days: 7 });
    answer({
      Items: [
        { Id: "a1", Type: "Episode", SeriesId: "a", UserData: {} },
        { Id: "n1", Type: "Episode", SeriesId: "n", UserData: { LastPlayedDate: "2026-11-11T00:00:00Z" } },
      ],
    });
    expect((await api.getNextUp()).map((i) => i.Id)).toEqual(["n1", "a1"]);
  });
});

describe("removeFromNextUp", () => {
  it("reads the show's episodes with their user data and clears only the dated ones", async () => {
    const api = await signIn();
    mockJellyfin([
      [
        "/Shows/series-1/Episodes",
        {
          Items: [
            episode("e1", 1, 1, { Played: true, LastPlayedDate: "2026-10-01T00:00:00Z" }),
            episode("e2", 1, 2),
            episode("e3", 1, 3, { LastPlayedDate: "2026-10-02T00:00:00Z" }),
          ],
        },
      ],
      ["/UserItems/", null],
    ]);
    await api.removeFromNextUp("series-1");
    expect(jfCalls()).toEqual([
      { path: `/Shows/series-1/Episodes?userId=user-1&Fields=${ITEM_FIELDS}`, method: "GET", body: null },
      { path: "/UserItems/e1/UserData?userId=user-1", method: "POST", body: { LastPlayedDate: "0001-01-01T00:00:00Z" } },
      { path: "/UserItems/e3/UserData?userId=user-1", method: "POST", body: { LastPlayedDate: "0001-01-01T00:00:00Z" } },
    ]);
  });

  it("writes nothing for a show with no dated episode or no episodes", async () => {
    const api = await signIn();
    answer({ Items: [episode("e1", 1, 1)] });
    await api.removeFromNextUp("series-1");
    answer({});
    await api.removeFromNextUp("series-1");
    expect(jfCalls().filter((c) => c.method !== "GET")).toEqual([]);
  });

  it("fails when the server cannot write the date alone (before 10.9 it answers 404)", async () => {
    const api = await signIn();
    mockJellyfin([
      ["/Shows/", { Items: [episode("e1", 1, 1, { LastPlayedDate: "2026-10-01T00:00:00Z" })] }],
      ["/UserItems/", { __status: 404 }],
    ]);
    await expect(api.removeFromNextUp("series-1")).rejects.toThrow("Server error 404 on /UserItems/e1/UserData");
  });
});

describe("addToNextUp", () => {
  const NOW = new Date("2026-11-12T12:00:00.000Z");

  function show(episodes: any[]): void {
    mockJellyfin([
      ["/Shows/series-1/Episodes", { Items: episodes }],
      ["/UserItems/", null],
      ["/UserPlayedItems/", null],
    ]);
  }

  it("from the last watched episode: dates that episode today and keeps its whole state (regression: the date sent alone brought back stale Played and PlayCount)", async () => {
    vi.useFakeTimers({ now: NOW });
    const api = await signIn();
    show([
      episode("e1", 1, 1, { Played: true, PlayCount: 1 }),
      episode("e2", 1, 2, { Played: true, PlayCount: 3, PlaybackPositionTicks: 0, LastPlayedDate: "2026-01-01T00:00:00Z" }),
      episode("e3", 1, 3),
      episode("e4", 1, 4),
    ]);
    const target = await api.addToNextUp("series-1", "last");
    expect(target.Id).toBe("e3");
    expect(jfCalls()).toEqual([
      { path: `/Shows/series-1/Episodes?userId=user-1&Fields=${ITEM_FIELDS}`, method: "GET", body: null },
      {
        path: "/UserItems/e2/UserData?userId=user-1",
        method: "POST",
        body: { LastPlayedDate: "2026-11-12T12:00:00.000Z", Played: true, PlayCount: 3, PlaybackPositionTicks: 0 },
      },
    ]);
  });

  it("from the last watched episode: the dated episode is the last watched, not the one offered (regression: Jellyfin orders the row by the last watched episode's date)", async () => {
    const api = await signIn();
    show([episode("e1", 1, 1, { Played: true, PlayCount: 1 }), episode("e2", 1, 2, { PlaybackPositionTicks: 900 })]);
    const target = await api.addToNextUp("series-1", "last");
    expect(target.Id).toBe("e2");
    const post = jfCalls().find((c) => c.method === "POST")!;
    expect(post.path).toBe("/UserItems/e1/UserData?userId=user-1");
    expect(post.body).toMatchObject({ Played: true, PlayCount: 1, PlaybackPositionTicks: 0 });
  });

  it("from the last watched episode with nothing watched: dates the first episode and keeps its position", async () => {
    vi.useFakeTimers({ now: NOW });
    const api = await signIn();
    show([episode("sp", 0, 1), episode("e1", 1, 1, { PlaybackPositionTicks: 1234 }), episode("e2", 1, 2)]);
    const target = await api.addToNextUp("series-1", "last");
    expect(target.Id).toBe("e1");
    const post = jfCalls().find((c) => c.method === "POST")!;
    expect(post).toEqual({
      path: "/UserItems/e1/UserData?userId=user-1",
      method: "POST",
      body: { LastPlayedDate: "2026-11-12T12:00:00.000Z", Played: false, PlayCount: 0, PlaybackPositionTicks: 1234 },
    });
    expect(jfCalls().some((c) => c.method === "DELETE")).toBe(false);
  });

  it("from the last watched episode on a finished show: offers nothing and writes nothing", async () => {
    const api = await signIn();
    show([episode("e1", 1, 1, { Played: true })]);
    await expect(api.addToNextUp("series-1", "last")).resolves.toBeNull();
    expect(jfCalls().filter((c) => c.method !== "GET")).toEqual([]);
  });

  it("from the first episode: marks every other episode unwatched, then dates episode one with a clean state (regression: DELETE /UserPlayedItems/<series> changes nothing on 12.2)", async () => {
    vi.useFakeTimers({ now: NOW });
    const api = await signIn();
    show([
      episode("sp", 0, 1, { LastPlayedDate: "2025-01-01T00:00:00Z" }),
      episode("e1", 1, 1, { Played: true, PlayCount: 4, PlaybackPositionTicks: 77, LastPlayedDate: "2026-01-01T00:00:00Z" }),
      episode("e2", 1, 2, { Played: true }),
      episode("e3", 1, 3, { PlaybackPositionTicks: 900 }),
      episode("e4", 1, 4),
    ]);
    const target = await api.addToNextUp("series-1", "first");
    expect(target.Id).toBe("e1");
    const clean = { LastPlayedDate: api.NOT_PLAYED_DATE, Played: false, PlayCount: 0, PlaybackPositionTicks: 0 };
    expect(jfCalls().slice(1)).toEqual([
      { path: "/UserItems/sp/UserData?userId=user-1", method: "POST", body: clean },
      { path: "/UserItems/e2/UserData?userId=user-1", method: "POST", body: clean },
      { path: "/UserItems/e3/UserData?userId=user-1", method: "POST", body: clean },
      {
        path: "/UserItems/e1/UserData?userId=user-1",
        method: "POST",
        // The full state goes with the date: sent alone, the date is written
        // over the server's cached copy and the old Played and PlayCount
        // come back.
        body: { LastPlayedDate: "2026-11-12T12:00:00.000Z", Played: false, PlayCount: 0, PlaybackPositionTicks: 0 },
      },
    ]);
    expect(jfCalls().some((c) => c.path.startsWith("/UserPlayedItems/"))).toBe(false);
  });

  it("from the first episode on a show with no episodes: offers nothing and leaves the watch state alone", async () => {
    const api = await signIn();
    show([]);
    await expect(api.addToNextUp("series-1", "first")).resolves.toBeNull();
    expect(jfCalls().filter((c) => c.method !== "GET")).toEqual([]);
  });

  it("does not date the episode when marking the show unwatched failed", async () => {
    const api = await signIn();
    mockJellyfin([
      ["/Shows/series-1/Episodes", { Items: [episode("e1", 1, 1), episode("e2", 1, 2, { Played: true })] }],
      ["/UserItems/e2/", { __status: 500 }],
      ["/UserItems/", null],
    ]);
    await expect(api.addToNextUp("series-1", "first")).rejects.toThrow("Server error 500 on /UserItems/e2/UserData");
    expect(jfCalls().some((c) => c.path.startsWith("/UserItems/e1/"))).toBe(false);
  });
});

describe("home layout", () => {
  it("HOME_FALLBACK is Jellyfin's own default order, minus the rows this client has nothing for", async () => {
    const api = await signIn();
    expect(api.HOME_FALLBACK).toEqual(["libraries", "resume", "liveTv", "nextUp", "latest"]);
  });

  it("reads the account's display preferences", async () => {
    const api = await signIn();
    answer({ CustomPrefs: {} });
    await api.getHomeSections();
    expect(jfCalls()).toEqual([
      { path: "/DisplayPreferences/usersettings?userId=user-1&client=emby", method: "GET", body: null },
    ]);
  });

  it("follows the order the account arranged, whatever case the keys are in", async () => {
    const api = await signIn();
    answer({
      CustomPrefs: {
        homesection0: "nextup",
        homeSection1: "resume",
        HOMESECTION2: "latestmedia",
        homesection3: "none",
        homesection4: "librarybuttons",
        homesection5: "livetv",
        homesection6: "none",
      },
    });
    await expect(api.getHomeSections()).resolves.toEqual(["nextUp", "resume", "latest", "libraries", "liveTv"]);
  });

  it("maps every spelling of a row and drops the ones with no screen here", async () => {
    const api = await signIn();
    for (const [name, want] of [
      ["smalllibrarytiles", "libraries"],
      ["librarytiles", "libraries"],
      ["LibraryButtons", "libraries"],
      ["resumevideo", "resume"],
      ["ResumeVideo", "resume"],
      ["NextUp", "nextUp"],
      ["LatestMedia", "latest"],
      ["LiveTv", "liveTv"],
    ] as const) {
      answer({
        CustomPrefs: Object.fromEntries([[`homesection0`, name], ...[1, 2, 3, 4, 5, 6].map((i) => [`homesection${i}`, "none"])]),
      });
      await expect(api.getHomeSections(), name).resolves.toEqual([want]);
    }
  });

  it("drops a row named twice and rows for music, books and recordings", async () => {
    const api = await signIn();
    answer({
      CustomPrefs: {
        homesection0: "resume",
        homesection1: "resumevideo",
        homesection2: "resumeaudio",
        homesection3: "resumebook",
        homesection4: "activerecordings",
        homesection5: "nextup",
        homesection6: "none",
      },
    });
    await expect(api.getHomeSections()).resolves.toEqual(["resume", "nextUp"]);
  });

  it("fills a slot the account never set with Jellyfin's default for it", async () => {
    const api = await signIn();
    answer({ CustomPrefs: { homesection0: "nextup", homesection1: 7 } });
    // Slot 1 holds a number, so it reads as unset: resume. Slots 2-6 default.
    await expect(api.getHomeSections()).resolves.toEqual(["nextUp", "resume", "liveTv", "latest"]);
  });

  it("falls back to the default order when everything is switched off, missing or unreadable", async () => {
    const api = await signIn();
    answer({ CustomPrefs: Object.fromEntries([0, 1, 2, 3, 4, 5, 6].map((i) => [`homesection${i}`, "none"])) });
    await expect(api.getHomeSections()).resolves.toEqual(api.HOME_FALLBACK);
    answer(null);
    await expect(api.getHomeSections()).resolves.toEqual(api.HOME_FALLBACK);
    onInvoke("jf_request", { status: 500, body: null });
    await expect(api.getHomeSections()).resolves.toBe(api.HOME_FALLBACK);
  });
});

describe("getSeriesNextUp", () => {
  it("asks Next Up for one episode of one show", async () => {
    const api = await signIn();
    answer({ Items: [{ Id: "e7" }, { Id: "e8" }] });
    await expect(api.getSeriesNextUp("series-1")).resolves.toEqual({ Id: "e7" });
    expect(jfCalls()[0]!.path).toBe(
      `/Shows/NextUp?userId=user-1&seriesId=series-1&Limit=1&Fields=${ITEM_FIELDS}&EnableImageTypes=Primary,Backdrop,Thumb,Logo`
    );
  });

  it("is null when the server has nothing queued", async () => {
    const api = await signIn();
    answer({ Items: [] });
    await expect(api.getSeriesNextUp("series-1")).resolves.toBeNull();
    answer({});
    await expect(api.getSeriesNextUp("series-1")).resolves.toBeNull();
  });
});

describe("getLatest", () => {
  it("asks for the newest of one library", async () => {
    const api = await signIn();
    answer([{ Id: "m1", Type: "Movie" }]);
    await expect(api.getLatest("lib-1")).resolves.toEqual([{ Id: "m1", Type: "Movie" }]);
    expect(jfCalls()).toEqual([
      { path: `/Items/Latest?userId=user-1&parentId=lib-1&Limit=16&Fields=${ITEM_FIELDS}`, method: "GET", body: null },
    ]);
  });

  it("passes a different limit", async () => {
    const api = await signIn();
    answer([]);
    await api.getLatest("lib-1", 5);
    expect(only().params.Limit).toBe("5");
  });

  it("drops what is not video from a mixed library", async () => {
    const api = await signIn();
    answer([
      { Id: "m1", Type: "Movie" },
      { Id: "a1", Type: "MusicAlbum" },
      { Id: "b1", Type: "AudioBook" },
      { Id: "p1", Type: "Photo" },
    ]);
    expect((await api.getLatest("lib-1")).map((i) => i.Id)).toEqual(["m1"]);
  });

  it("folds each single new episode into its show, in one lookup, keeping the order and dropping duplicates (regression: a TV row mixed shows with bare episodes)", async () => {
    const api = await signIn();
    mockJellyfin([
      [
        "/Items/Latest",
        [
          { Id: "ep-a", Type: "Episode", SeriesId: "show-a" },
          { Id: "show-b", Type: "Series" },
          { Id: "ep-b", Type: "Episode", SeriesId: "show-b" },
          { Id: "ep-a2", Type: "Episode", SeriesId: "show-a" },
          { Id: "ep-c", Type: "Episode", SeriesId: "show-c" },
          { Id: "m1", Type: "Movie" },
        ],
      ],
      [
        "/Items?",
        {
          Items: [
            { Id: "show-c", Type: "Series", Name: "C" },
            { Id: "show-a", Type: "Series", Name: "A" },
          ],
        },
      ],
    ]);
    const row = await api.getLatest("lib-1");
    expect(row.map((i) => i.Id)).toEqual(["show-a", "show-b", "show-c", "m1"]);
    // Only the shows not already in the row were looked up, once each.
    expect(jfCalls().slice(1)).toEqual([
      { path: `/Items?userId=user-1&Ids=show-a,show-c&Fields=${ITEM_FIELDS}`, method: "GET", body: null },
    ]);
  });

  it("asks for nothing more when the row has no episodes or every show is already there", async () => {
    const api = await signIn();
    answer([
      { Id: "show-a", Type: "Series" },
      { Id: "ep-a", Type: "Episode", SeriesId: "show-a" },
    ]);
    expect((await api.getLatest("lib-1")).map((i) => i.Id)).toEqual(["show-a"]);
    expect(jfCalls()).toHaveLength(1);
  });

  it("leaves an episode where it was when its show could not be looked up (a row with one odd card beats a lost title)", async () => {
    const api = await signIn();
    mockJellyfin([
      [
        "/Items/Latest",
        [
          { Id: "ep-a", Type: "Episode", SeriesId: "show-a" },
          { Id: "m1", Type: "Movie" },
        ],
      ],
      ["/Items?", { __status: 500 }],
    ]);
    expect((await api.getLatest("lib-1")).map((i) => i.Id)).toEqual(["ep-a", "m1"]);
  });

  it("keeps an episode whose show the lookup did not return, and one with no show id", async () => {
    const api = await signIn();
    mockJellyfin([
      [
        "/Items/Latest",
        [
          { Id: "ep-a", Type: "Episode", SeriesId: "show-a" },
          { Id: "ep-x", Type: "Episode" },
        ],
      ],
      ["/Items?", { Items: [] }],
    ]);
    expect((await api.getLatest("lib-1")).map((i) => i.Id)).toEqual(["ep-a", "ep-x"]);
  });
});

describe("getLibraryItems", () => {
  it("asks for a page of one library, sorted by name, without the non-video types", async () => {
    const api = await signIn();
    const page = { Items: [{ Id: "m1" }], TotalRecordCount: 1 };
    answer(page);
    await expect(api.getLibraryItems("lib-1")).resolves.toEqual(page);
    const q = only();
    expect(q.route).toBe("/Items");
    expect(q.method).toBe("GET");
    expect(q.params).toEqual({
      userId: "user-1",
      ParentId: "lib-1",
      Recursive: "true",
      SortBy: "SortName",
      SortOrder: "Ascending",
      Fields: ITEM_FIELDS,
      StartIndex: "0",
      Limit: "60",
      ExcludeItemTypes: "AudioBook,Audio,Book,MusicAlbum,MusicArtist,Photo,PhotoAlbum,Playlist",
    });
  });

  it("applies paging, sorting and item types", async () => {
    const api = await signIn();
    answer({ Items: [], TotalRecordCount: 0 });
    await api.getLibraryItems("lib-1", {
      startIndex: 120,
      limit: 30,
      includeTypes: "Movie",
      sortBy: "DateCreated",
      sortOrder: "Descending",
    });
    const q = only();
    expect(q.params).toMatchObject({
      StartIndex: "120",
      Limit: "30",
      IncludeItemTypes: "Movie",
      SortBy: "DateCreated",
      SortOrder: "Descending",
    });
    expect(q.query.has("ExcludeItemTypes")).toBe(false);
    expect(q.query.has("Filters")).toBe(false);
    expect(q.query.has("IsFavorite")).toBe(false);
    expect(q.query.has("Genres")).toBe(false);
  });

  it("applies the unwatched, favourites and genre filters", async () => {
    const api = await signIn();
    answer({ Items: [], TotalRecordCount: 0 });
    await api.getLibraryItems("lib-1", { unwatched: true, favorites: true, genre: "Sci-Fi & Fantasy" });
    expect(only().params).toMatchObject({ Filters: "IsUnplayed", IsFavorite: "true", Genres: "Sci-Fi & Fantasy" });
  });

  it("escapes a genre so an ampersand cannot split the query", async () => {
    const api = await signIn();
    answer({ Items: [], TotalRecordCount: 0 });
    await api.getLibraryItems("lib-1", { genre: "Action & Adventure" });
    expect(jfCalls()[0]!.path).toContain("Genres=Action+%26+Adventure");
  });
});

describe("getFavorites", () => {
  it("asks for starred films, shows and episodes across every library", async () => {
    const api = await signIn();
    answer({ Items: [{ Id: "m1" }], TotalRecordCount: 9 });
    await expect(api.getFavorites()).resolves.toEqual({ Items: [{ Id: "m1" }], TotalRecordCount: 9 });
    const q = only();
    expect(q.route).toBe("/Items");
    expect(q.params).toEqual({
      userId: "user-1",
      Recursive: "true",
      Filters: "IsFavorite",
      IncludeItemTypes: "Movie,Series,Episode",
      SortBy: "SortName",
      SortOrder: "Ascending",
      Fields: ITEM_FIELDS,
      StartIndex: "0",
      Limit: "60",
    });
    expect(q.query.has("ParentId")).toBe(false);
  });

  it("applies paging, types and sorting", async () => {
    const api = await signIn();
    answer({ Items: [] });
    await api.getFavorites({ startIndex: 60, limit: 20, includeTypes: "Series", sortBy: "DateCreated", sortOrder: "Descending" });
    expect(only().params).toMatchObject({
      StartIndex: "60",
      Limit: "20",
      IncludeItemTypes: "Series",
      SortBy: "DateCreated",
      SortOrder: "Descending",
    });
  });

  it("counts the items itself when the server sends no total, and is empty for a bare answer", async () => {
    const api = await signIn();
    answer({ Items: [{ Id: "a" }, { Id: "b" }] });
    await expect(api.getFavorites()).resolves.toEqual({ Items: [{ Id: "a" }, { Id: "b" }], TotalRecordCount: 2 });
    answer({});
    await expect(api.getFavorites()).resolves.toEqual({ Items: [], TotalRecordCount: 0 });
  });
});

describe("getGenres", () => {
  it("reads the library's filters and sorts the genre names", async () => {
    const api = await signIn();
    answer({ Genres: ["Western", "", "Comedy", null, 5, "Action"] });
    await expect(api.getGenres("lib-1", "Movie")).resolves.toEqual(["Action", "Comedy", "Western"]);
    const q = only();
    expect(q.route).toBe("/Items/Filters");
    expect(q.params).toEqual({ userId: "user-1", parentId: "lib-1", IncludeItemTypes: "Movie" });
  });

  it("leaves the type out when none is given, and is empty when the server has no genres", async () => {
    const api = await signIn();
    answer({});
    await expect(api.getGenres("lib-1", "")).resolves.toEqual([]);
    expect(only().query.has("IncludeItemTypes")).toBe(false);
    answer(null);
    await expect(api.getGenres("lib-1", "")).resolves.toEqual([]);
  });
});

describe("items, seasons and episodes", () => {
  it("getItem asks for the detail fields", async () => {
    const api = await signIn();
    answer({ Id: "m1" });
    await expect(api.getItem("m1")).resolves.toEqual({ Id: "m1" });
    expect(jfCalls()).toEqual([{ path: `/Items/m1?userId=user-1&Fields=${DETAIL_FIELDS}`, method: "GET", body: null }]);
  });

  it("only the detail page asks for the cast", async () => {
    const api = await signIn();
    answer({ Items: [] });
    await api.getLibraryItems("lib");
    expect(only().params.Fields).not.toContain("People");
  });

  it("getSimilar asks for twelve and keeps only video", async () => {
    const api = await signIn();
    answer({ Items: [{ Id: "m2", Type: "Movie" }, { Id: "a", Type: "MusicAlbum" }] });
    await expect(api.getSimilar("m1")).resolves.toEqual([{ Id: "m2", Type: "Movie" }]);
    expect(jfCalls()[0]!.path).toBe(`/Items/m1/Similar?userId=user-1&limit=12&Fields=${ITEM_FIELDS}`);
  });

  it("getSimilar passes another limit and tolerates a bare answer", async () => {
    const api = await signIn();
    answer({});
    await expect(api.getSimilar("m1", 4)).resolves.toEqual([]);
    expect(only().params.limit).toBe("4");
  });

  it("getSeasons reads a show's seasons", async () => {
    const api = await signIn();
    answer({ Items: [{ Id: "se1" }] });
    await expect(api.getSeasons("show-1")).resolves.toEqual([{ Id: "se1" }]);
    expect(jfCalls()[0]!.path).toBe(`/Shows/show-1/Seasons?userId=user-1&Fields=${ITEM_FIELDS}`);
    answer({});
    await expect(api.getSeasons("show-1")).resolves.toEqual([]);
  });

  it("getEpisodes reads one season's episodes", async () => {
    const api = await signIn();
    answer({ Items: [{ Id: "e1" }] });
    await expect(api.getEpisodes("show-1", "se1")).resolves.toEqual([{ Id: "e1" }]);
    expect(jfCalls()[0]!.path).toBe(`/Shows/show-1/Episodes?userId=user-1&seasonId=se1&Fields=${ITEM_FIELDS}`);
    answer({});
    await expect(api.getEpisodes("show-1", "se1")).resolves.toEqual([]);
  });
});

describe("getTrickplay", () => {
  const tiles = (w: number, extra: Record<string, any> = {}): any => ({
    Width: w,
    Height: Math.round((w * 9) / 16),
    TileWidth: 10,
    TileHeight: 10,
    Interval: 10000,
    ThumbnailCount: 60,
    ...extra,
  });

  it("asks for Trickplay by name, with the media sources", async () => {
    const api = await signIn();
    answer({ MediaSources: [{ Id: "m1" }], Trickplay: { m1: { 320: tiles(320) } } });
    await api.getTrickplay("m1");
    expect(jfCalls()).toEqual([{ path: "/Items/m1?userId=user-1&Fields=Trickplay,MediaSources", method: "GET", body: null }]);
  });

  it("describes the widest resolution", async () => {
    const api = await signIn();
    answer({ MediaSources: [{ Id: "m1" }], Trickplay: { m1: { 160: tiles(160), 480: tiles(480), 320: tiles(320) } } });
    await expect(api.getTrickplay("m1")).resolves.toEqual({
      itemId: "m1",
      mediaSourceId: "m1",
      width: 480,
      height: 270,
      tileWidth: 10,
      tileHeight: 10,
      interval: 10000,
      thumbnailCount: 60,
    });
  });

  it("takes the tiles of the version that plays, the first media source (a multi-version item has tiles for each)", async () => {
    const api = await signIn();
    answer({
      MediaSources: [{ Id: "v-1080" }, { Id: "v-720" }],
      Trickplay: { "v-720": { 320: tiles(320, { Interval: 5000 }) }, "v-1080": { 320: tiles(320, { Interval: 10000 }) } },
    });
    const info = await api.getTrickplay("m1");
    expect(info).toMatchObject({ itemId: "m1", mediaSourceId: "v-1080", interval: 10000 });
  });

  it("falls back to the first set when none is filed under the playing version", async () => {
    const api = await signIn();
    answer({ MediaSources: [{ Id: "other" }], Trickplay: { "v-a": { 320: tiles(320) } } });
    expect(await api.getTrickplay("m1")).toMatchObject({ mediaSourceId: "v-a" });
    answer({ Trickplay: { "v-a": { 320: tiles(320) } } });
    expect(await api.getTrickplay("m1")).toMatchObject({ mediaSourceId: "v-a" });
  });

  it("fills in what the server left out", async () => {
    const api = await signIn();
    answer({ Trickplay: { m1: { 320: { Width: 320, Interval: 10000 } } } });
    await expect(api.getTrickplay("m1")).resolves.toMatchObject({
      height: 180,
      tileWidth: 1,
      tileHeight: 1,
      thumbnailCount: 0,
    });
  });

  it("is null when the server has no tiles, which is the common case", async () => {
    const api = await signIn();
    for (const body of [
      { MediaSources: [{ Id: "m1" }] },
      { Trickplay: {} },
      { Trickplay: { m1: null } },
      { Trickplay: { m1: "x" } },
      { Trickplay: { m1: {} } },
      { Trickplay: { m1: { 0: tiles(320) } } },
      { Trickplay: { m1: { 320: { Width: 320 } } } },
      { Trickplay: { m1: { 320: { Interval: 10000 } } } },
    ]) {
      answer(body);
      await expect(api.getTrickplay("m1"), JSON.stringify(body)).resolves.toBeNull();
    }
  });

  it("is null when the request fails", async () => {
    const api = await signIn();
    onInvoke("jf_request", { status: 500, body: null });
    await expect(api.getTrickplay("m1")).resolves.toBeNull();
  });

  it("is null, without asking, when nobody is signed in", async () => {
    const api = await signIn({ has_token: false });
    await expect(api.getTrickplay("m1")).resolves.toBeNull();
    expect(jfCalls()).toEqual([]);
  });
});

describe("trickplayTile", () => {
  const info = { itemId: "m1", width: 320, height: 180, tileWidth: 10, tileHeight: 10, interval: 10000, thumbnailCount: 60 };

  it("fetches a sheet through the backend, which holds the token", async () => {
    const api = await signIn();
    onInvoke("jf_image", "data:image/jpeg;base64,AAAA");
    await expect(api.trickplayTile(info, 3)).resolves.toBe("data:image/jpeg;base64,AAAA");
    expect(invokeCalls("jf_image")[0]!.args).toEqual({ path: "/Videos/m1/Trickplay/320/3.jpg" });
  });

  it("names the version only when it is not the item itself", async () => {
    const api = await signIn();
    onInvoke("jf_image", "data:");
    await api.trickplayTile({ ...info, mediaSourceId: "m1" }, 0);
    await api.trickplayTile({ ...info, mediaSourceId: "v 2&x" }, 1);
    expect(invokeCalls("jf_image").map((c) => c.args.path)).toEqual([
      "/Videos/m1/Trickplay/320/0.jpg",
      "/Videos/m1/Trickplay/320/1.jpg?mediaSourceId=v%202%26x",
    ]);
  });

  it("fails when the backend does", async () => {
    const api = await signIn();
    onInvoke("jf_image", () => {
      throw "server|No such tile";
    });
    await expect(api.trickplayTile(info, 0)).rejects.toBeDefined();
  });
});

describe("getMediaSegments", () => {
  it("asks for intros and credits and converts ticks to seconds", async () => {
    const api = await signIn();
    answer({
      Items: [
        { Type: "Intro", StartTicks: 50_000_000, EndTicks: 950_000_000 },
        { Type: "Outro", StartTicks: 12_000_000_000, EndTicks: 12_600_000_000 },
      ],
    });
    await expect(api.getMediaSegments("m1")).resolves.toEqual([
      { type: "Intro", start: 5, end: 95 },
      { type: "Outro", start: 1200, end: 1260 },
    ]);
    expect(jfCalls()).toEqual([{ path: "/MediaSegments/m1?includeSegmentTypes=Intro&includeSegmentTypes=Outro", method: "GET", body: null }]);
  });

  it("drops segments with no length and fills in missing values", async () => {
    const api = await signIn();
    answer({
      Items: [
        { Type: "Intro", StartTicks: 100, EndTicks: 100 },
        { Type: "Intro", StartTicks: 200, EndTicks: 100 },
        { EndTicks: 10_000_000 },
        {},
      ],
    });
    await expect(api.getMediaSegments("m1")).resolves.toEqual([{ type: "", start: 0, end: 1 }]);
  });

  it("is empty for a 404 from an older server, a bare answer, or any failure", async () => {
    const api = await signIn();
    onInvoke("jf_request", { status: 404, body: null });
    await expect(api.getMediaSegments("m1")).resolves.toEqual([]);
    answer({});
    await expect(api.getMediaSegments("m1")).resolves.toEqual([]);
    onInvoke("jf_ping", true);
    onInvoke("jf_request", () => {
      throw "offline|down";
    });
    await expect(api.getMediaSegments("m1")).resolves.toEqual([]);
  });
});

describe("search", () => {
  it("searches films, shows and episodes everywhere", async () => {
    const api = await signIn();
    answer({ Items: [{ Id: "m1" }], TotalRecordCount: 30 });
    await expect(api.search("big buck")).resolves.toEqual({ Items: [{ Id: "m1" }], TotalRecordCount: 30 });
    const q = only();
    expect(q.route).toBe("/Items");
    expect(q.params).toEqual({
      userId: "user-1",
      searchTerm: "big buck",
      Recursive: "true",
      IncludeItemTypes: "Movie,Series,Episode",
      Fields: ITEM_FIELDS,
      StartIndex: "0",
      Limit: "48",
    });
  });

  it("escapes the term and applies paging", async () => {
    const api = await signIn();
    answer({ Items: [] });
    await api.search("tom & jerry? #1", { startIndex: 48, limit: 10 });
    const call = jfCalls()[0]!;
    expect(call.path).toContain("searchTerm=tom+%26+jerry%3F+%231");
    expect(parsePath(call.path).params).toMatchObject({ searchTerm: "tom & jerry? #1", StartIndex: "48", Limit: "10" });
  });

  it("counts the items itself when the server sends no total", async () => {
    const api = await signIn();
    answer({ Items: [{ Id: "a" }] });
    await expect(api.search("a")).resolves.toEqual({ Items: [{ Id: "a" }], TotalRecordCount: 1 });
    answer({});
    await expect(api.search("a")).resolves.toEqual({ Items: [], TotalRecordCount: 0 });
  });
});

describe("Live TV", () => {
  it("getChannels asks for the channels with what is on now", async () => {
    const api = await signIn();
    answer({ Items: [{ Id: "c1" }] });
    await expect(api.getChannels()).resolves.toEqual([{ Id: "c1" }]);
    expect(jfCalls()).toEqual([
      {
        path: "/LiveTv/Channels?userId=user-1&AddCurrentProgram=true&EnableImageTypes=Primary&Limit=500",
        method: "GET",
        body: null,
      },
    ]);
    answer({});
    await expect(api.getChannels()).resolves.toEqual([]);
  });

  it("getPrograms asks for what overlaps the window, not what starts in it (regression: the programme already running was missing)", async () => {
    const api = await signIn();
    answer({ Items: [{ Id: "p1" }] });
    const from = new Date("2026-11-12T20:00:00.000Z");
    const to = new Date("2026-11-12T23:00:00.000Z");
    await expect(api.getPrograms(["c1", "c2"], from, to)).resolves.toEqual([{ Id: "p1" }]);
    const q = only();
    expect(q.route).toBe("/LiveTv/Programs");
    expect(q.method).toBe("GET");
    expect(q.params).toEqual({
      userId: "user-1",
      channelIds: "c1,c2",
      minEndDate: "2026-11-12T20:00:00.000Z",
      maxStartDate: "2026-11-12T23:00:00.000Z",
      sortBy: "StartDate",
      fields: "Overview",
      enableImages: "false",
      enableUserData: "false",
      enableTotalRecordCount: "false",
      limit: "20000",
    });
    expect(q.query.has("minStartDate")).toBe(false);
  });

  it("getPrograms sends the channels eighty at a time and joins the answers in order (a 500-channel tuner would build a URL no server accepts)", async () => {
    const api = await signIn();
    const ids = Array.from({ length: 170 }, (_, i) => `c${i}`);
    onInvoke("jf_request", ({ path }: any) => {
      const first = parsePath(path).params.channelIds!.split(",")[0];
      return { status: 200, body: { Items: [{ Id: `p-${first}` }] } };
    });
    const out = await api.getPrograms(ids, new Date(0), new Date(1000));
    expect(out.map((p) => p.Id)).toEqual(["p-c0", "p-c80", "p-c160"]);
    const sizes = jfCalls().map((c) => parsePath(c.path).params.channelIds!.split(",").length);
    expect(sizes).toEqual([80, 80, 10]);
  });

  it("getPrograms asks for nothing with no channels, and tolerates a bare answer", async () => {
    const api = await signIn();
    await expect(api.getPrograms([], new Date(0), new Date(1))).resolves.toEqual([]);
    expect(jfCalls()).toEqual([]);
    answer({});
    await expect(api.getPrograms(["c1"], new Date(0), new Date(1))).resolves.toEqual([]);
  });
});

describe("batches by id", () => {
  it("getItemsByIds asks for the lean shape by default", async () => {
    const api = await signIn();
    answer({ Items: [{ Id: "a" }, { Id: "b" }] });
    await expect(api.getItemsByIds(["a", "b"])).resolves.toEqual([{ Id: "a" }, { Id: "b" }]);
    expect(jfCalls()).toEqual([{ path: "/Items?userId=user-1&Ids=a,b", method: "GET", body: null }]);
  });

  it("getItemsByIds adds fields when asked", async () => {
    const api = await signIn();
    answer({ Items: [] });
    await api.getItemsByIds(["a"], "Overview,UserData");
    expect(jfCalls()[0]!.path).toBe("/Items?userId=user-1&Ids=a&Fields=Overview,UserData");
  });

  it("getItemsByIds sends fifty ids per request", async () => {
    const api = await signIn();
    const ids = Array.from({ length: 120 }, (_, i) => `i${i}`);
    onInvoke("jf_request", ({ path }: any) => ({
      status: 200,
      body: { Items: parsePath(path).params.Ids!.split(",").map((Id) => ({ Id })) },
    }));
    const out = await api.getItemsByIds(ids);
    expect(out.map((i) => i.Id)).toEqual(ids);
    expect(jfCalls().map((c) => parsePath(c.path).params.Ids!.split(",").length)).toEqual([50, 50, 20]);
  });

  it("getItemsByIds asks for nothing with no ids and tolerates a bare answer", async () => {
    const api = await signIn();
    await expect(api.getItemsByIds([])).resolves.toEqual([]);
    expect(jfCalls()).toEqual([]);
    answer({});
    await expect(api.getItemsByIds(["a"])).resolves.toEqual([]);
  });

  it("getUserDataByIds maps each id to its watch state", async () => {
    const api = await signIn();
    answer({ Items: [{ Id: "a", UserData: { Played: true } }, { Id: "b" }] });
    const map = await api.getUserDataByIds(["a", "b", "gone"]);
    expect([...map.entries()]).toEqual([
      ["a", { Played: true }],
      ["b", {}],
    ]);
    expect(jfCalls()[0]!.path).toBe("/Items?userId=user-1&Ids=a,b,gone");
  });
});

describe("played and favourite", () => {
  it("markPlayed posts to mark and deletes to unmark", async () => {
    const api = await signIn();
    answer(null);
    await api.markPlayed("m1", true);
    await api.markPlayed("m1", false);
    expect(jfCalls()).toEqual([
      { path: "/UserPlayedItems/m1?userId=user-1", method: "POST", body: null },
      { path: "/UserPlayedItems/m1?userId=user-1", method: "DELETE", body: null },
    ]);
  });

  it("deleteItem asks the server to delete the item, and passes a refusal on", async () => {
    const api = await signIn();
    answer(null);
    await api.deleteItem("m1");
    expect(jfCalls()).toEqual([{ path: "/Items/m1", method: "DELETE", body: null }]);
  });

  it("setFavorite posts to star and deletes to unstar", async () => {
    const api = await signIn();
    answer(null);
    await api.setFavorite("m1", true);
    await api.setFavorite("m1", false);
    expect(jfCalls()).toEqual([
      { path: "/UserFavoriteItems/m1?userId=user-1", method: "POST", body: null },
      { path: "/UserFavoriteItems/m1?userId=user-1", method: "DELETE", body: null },
    ]);
  });

  it("both fail when the server refuses", async () => {
    const api = await signIn();
    onInvoke("jf_request", { status: 403, body: null });
    await expect(api.markPlayed("m1", true)).rejects.toThrow("Server error 403 on /UserPlayedItems/m1");
    await expect(api.setFavorite("m1", true)).rejects.toThrow("Server error 403 on /UserFavoriteItems/m1");
  });
});
