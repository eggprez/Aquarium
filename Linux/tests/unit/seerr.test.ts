// src/seerr.ts: the reading of what a Seerr server says (where a title stands,
// which seasons can still be asked for, what an account may do, quota in
// words) and the calls a view makes, over the mocked Tauri bridge. The session
// itself lives in Rust (src-tauri/src/seerr.rs) and is tested there.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { invokeCalls, onInvoke } from "../helpers/tauri";

type Seerr = typeof import("../../src/seerr");
let seerr: Seerr;

const CONNECTED = {
  connected: true,
  server: "https://seerr.test",
  host: "seerr.test",
  secure: true,
  user_id: 7,
  user_name: "Ann",
  permissions: 32,
  settings: { partialRequestsEnabled: true, cacheImages: false },
  needs_reconnect: false,
  storage: "keyring",
};

/** Answer `seerr_request` by path; anything unmatched is refused. */
function routes(map: Array<[string | RegExp, (a: { path: string; method: string; body: any }) => any]>): void {
  onInvoke("seerr_request", async (a: { path: string; method: string; body: any }) => {
    for (const [match, answer] of map) {
      const hit = typeof match === "string" ? a.path.startsWith(match) : match.test(a.path);
      if (!hit) continue;
      const out = await answer(a);
      if (out && typeof out === "object" && "__status" in out) return { status: out.__status, body: out.body ?? null };
      return { status: 200, body: out };
    }
    throw "refused|Seerr doesn't know that title.";
  });
}

async function connected(extra: Record<string, any> = {}): Promise<void> {
  onInvoke("seerr_status", { ...CONNECTED, ...extra });
  await seerr.loadStatus();
}

beforeEach(async () => {
  vi.resetModules();
  seerr = await import("../../src/seerr");
});

const show = (extra: Record<string, any> = {}): any => ({
  id: 1396,
  name: "Breaking Bad",
  firstAirDate: "2008-01-20",
  seasons: [0, 1, 2, 3, 4, 5].map((n) => ({ seasonNumber: n, name: n ? `Season ${n}` : "Specials", episodeCount: 10 })),
  ...extra,
});

describe("where a title stands", () => {
  it("reads Seerr's numbers, and anything else as unknown", () => {
    expect([1, 2, 3, 4, 5].map(seerr.availability)).toEqual([
      "unknown", "pending", "processing", "partiallyAvailable", "available",
    ]);
    for (const odd of [undefined, null, 0, 6, 9, 2.5]) expect(seerr.availability(odd as any)).toBe("unknown");
    expect([1, 2, 3, 4, 5].map(seerr.requestStatus)).toEqual(["pending", "approved", "declined", "failed", "completed"]);
    expect(seerr.requestStatus(undefined)).toBe("pending");
  });

  it("from the title as a whole", () => {
    const of = (status?: number) => seerr.standingOfMedia(status == null ? null : { status });
    expect(of()).toBe("requestable");
    expect(of(1)).toBe("requestable");
    expect(of(2)).toBe("awaitingApproval");
    expect(of(3)).toBe("onItsWay");
    expect(of(4)).toBe("partlyAvailable");
    expect(of(5)).toBe("available");
    expect(seerr.standingOfMedia(undefined)).toBe("requestable");
  });

  it("from a request, which knows more than its title does", () => {
    const of = (status: number, media?: number) => seerr.standingOfRequest({ id: 1, status, media: { status: media } });
    // A declined request leaves the title "unknown".
    expect(of(3, 1)).toBe("declined");
    expect(of(4, 1)).toBe("failed");
    expect(of(1, 2)).toBe("awaitingApproval");
    expect(of(5, 1)).toBe("available");
    expect(of(2, 3)).toBe("onItsWay");
    expect(of(2, 1)).toBe("onItsWay");
    expect(of(2, 4)).toBe("partlyAvailable");
    expect(of(2, 5)).toBe("available");
    expect(seerr.standingOfRequest({ id: 1 })).toBe("awaitingApproval");
  });

  it("has a label for every standing and a badge for all but the plain one", () => {
    expect(seerr.STANDING_LABEL).toEqual({
      requestable: "Not in your library",
      awaitingApproval: "Waiting for approval",
      onItsWay: "On its way",
      partlyAvailable: "Some seasons available",
      available: "In your library",
      declined: "Declined",
      failed: "Couldn't be fetched",
    });
    expect(seerr.STANDING_BADGE.requestable).toBeNull();
    expect(seerr.STANDING_BADGE.awaitingApproval).toBe("Requested");
    expect(seerr.STANDING_BADGE.available).toBe("In library");
    expect(seerr.STANDING_BADGE.partlyAvailable).toBe("Partly here");
  });
});

describe("seasons", () => {
  it("leaves out Specials", () => {
    expect(seerr.realSeasons(show()).map((s) => s.seasonNumber)).toEqual([1, 2, 3, 4, 5]);
    expect(seerr.realSeasons({ id: 1 })).toEqual([]);
  });

  it("still open are the ones not here and not asked for", () => {
    const title = show({
      mediaInfo: {
        status: 4,
        // 1 is in the library; Seerr lists 5 but knows nothing of it.
        seasons: [{ seasonNumber: 1, status: 5 }, { seasonNumber: 5, status: 1 }],
        requests: [
          { id: 1, status: 1, seasons: [{ seasonNumber: 2 }] }, // waiting
          { id: 2, status: 2, seasons: [{ seasonNumber: 3 }] }, // approved
          { id: 3, status: 3, seasons: [{ seasonNumber: 4 }] }, // declined: open again
        ],
      },
    });
    expect(seerr.requestableSeasons(title).map((s) => s.seasonNumber)).toEqual([4, 5]);
    expect(seerr.standingOfSeason(title, 1)).toBe("available");
    expect(seerr.standingOfSeason(title, 2)).toBe("awaitingApproval");
    expect(seerr.standingOfSeason(title, 3)).toBe("onItsWay");
    expect(seerr.standingOfSeason(title, 4)).toBe("requestable");
    expect(seerr.standingOfSeason(title, 5)).toBe("requestable");
  });

  it("of a show Seerr has never met are all open", () => {
    expect(seerr.requestableSeasons(show()).map((s) => s.seasonNumber)).toEqual([1, 2, 3, 4, 5]);
    expect(seerr.standingOfSeason(show(), 2)).toBe("requestable");
  });

  it("read a season's own state before any request's", () => {
    const title = show({
      mediaInfo: {
        seasons: [{ seasonNumber: 2, status: 3 }, { seasonNumber: 3, status: 4 }, { seasonNumber: 4, status: 2 }],
        requests: [{ id: 1, status: 1, seasons: [{ seasonNumber: 2 }] }],
      },
    });
    expect(seerr.standingOfSeason(title, 2)).toBe("onItsWay");
    expect(seerr.standingOfSeason(title, 3)).toBe("partlyAvailable");
    expect(seerr.standingOfSeason(title, 4)).toBe("awaitingApproval");
  });

  it("are named in words", () => {
    expect(seerr.seasonList([])).toBe("");
    expect(seerr.seasonList([3])).toBe("Season 3");
    expect(seerr.seasonList([3, 4])).toBe("Seasons 3 and 4");
    expect(seerr.seasonList([3, 4, 5])).toBe("Seasons 3, 4 and 5");
  });

  it("decide what the request button says", () => {
    expect(seerr.requestLabel({ id: 603 }, "movie", 0)).toBe("Request");
    expect(seerr.requestLabel(show(), "tv", 5)).toBe("Request All Seasons");
    expect(seerr.requestLabel(show(), "tv", 2)).toBe("Request 2 Seasons");
    expect(seerr.requestLabel(show(), "tv", 1)).toBe("Request 1 Season");
    // Every open season ticked, but one is already here: not "all".
    const partly = show({ mediaInfo: { seasons: [{ seasonNumber: 1, status: 5 }] } });
    expect(seerr.requestLabel(partly, "tv", 4)).toBe("Request 4 Seasons");
  });
});

describe("what an account may do", () => {
  it("is read from Seerr's bit mask", () => {
    const P = seerr.PERMISSION;
    expect(seerr.canRequest(0, "movie")).toBe(false);
    expect(seerr.canRequest(undefined, "tv")).toBe(false);
    expect(seerr.canRequest(P.request, "movie")).toBe(true);
    expect(seerr.canRequest(P.request, "tv")).toBe(true);
    expect(seerr.canRequest(P.admin, "tv")).toBe(true);
    expect(seerr.canRequest(P.requestMovie, "movie")).toBe(true);
    expect(seerr.canRequest(P.requestMovie, "tv")).toBe(false);
    expect(seerr.canRequest(P.requestTV, "tv")).toBe(true);
    expect(seerr.canRequest(P.requestTV, "movie")).toBe(false);

    expect(seerr.canRequest4K(P.request, "movie")).toBe(false);
    expect(seerr.canRequest4K(P.request4K, "movie")).toBe(true);
    expect(seerr.canRequest4K(P.request4K, "tv")).toBe(true);
    expect(seerr.canRequest4K(P.admin, "tv")).toBe(true);
    expect(seerr.canRequest4K(P.request4KMovie, "movie")).toBe(true);
    expect(seerr.canRequest4K(P.request4KMovie, "tv")).toBe(false);
    expect(seerr.canRequest4K(P.request4KTV, "tv")).toBe(true);
    expect(seerr.canRequest4K(P.request | P.autoApprove, "tv")).toBe(false);
  });

  it("puts a quota in words, and says nothing when there is no limit", () => {
    expect(seerr.quotaSummary({ days: 7, limit: 5, remaining: 2 })).toBe("2 of 5 requests left this week");
    expect(seerr.quotaSummary({ days: 1, limit: 1, remaining: 1 })).toBe("1 of 1 request left today");
    expect(seerr.quotaSummary({ days: 30, limit: 10, remaining: -3 })).toBe("0 of 10 requests left in 30 days");
    expect(seerr.quotaSummary({ limit: 3, remaining: 3 })).toBe("3 of 3 requests left");
    expect(seerr.quotaSummary({ days: 7, limit: 0, remaining: 0 })).toBeNull();
    expect(seerr.quotaSummary({ days: 7, limit: 5 })).toBeNull();
    expect(seerr.quotaSummary(undefined)).toBeNull();
  });

  it("finds this account's own waiting request and nobody else's", () => {
    const title = show({
      mediaInfo: {
        requests: [
          { id: 1, status: 1, requestedBy: { id: 9 } },
          { id: 2, status: 2, requestedBy: { id: 7 } },
          { id: 3, status: 1, requestedBy: { id: 7 } },
        ],
      },
    });
    expect(seerr.myPendingRequest(title, 7)?.id).toBe(3);
    expect(seerr.myPendingRequest(title, 8)).toBeNull();
    expect(seerr.myPendingRequest(title, undefined)).toBeNull();
    expect(seerr.myPendingRequest(show(), 7)).toBeNull();
  });
});

describe("titles in lists", () => {
  it("are films and shows; people and collections are left out", () => {
    expect(seerr.kindOf({ mediaType: "movie" })).toBe("movie");
    expect(seerr.kindOf({ mediaType: "tv" })).toBe("tv");
    expect(seerr.kindOf({ mediaType: "person" })).toBeNull();
    expect(seerr.kindOf({ mediaType: "collection" })).toBeNull();
    expect(seerr.kindOf({})).toBeNull();
    expect(seerr.kindOf(null)).toBeNull();
  });

  it("read their name and year from whichever fields Seerr filled", () => {
    expect(seerr.displayTitle({ title: "The Matrix" })).toBe("The Matrix");
    expect(seerr.displayTitle({ name: "Breaking Bad" })).toBe("Breaking Bad");
    expect(seerr.displayTitle(undefined)).toBe("");
    expect(seerr.yearOf("1999-03-31")).toBe("1999");
    expect(seerr.yearOf("199")).toBeNull();
    expect(seerr.yearOf("soon-ish")).toBeNull();
    expect(seerr.yearOf(undefined)).toBeNull();
    expect(seerr.resultYear({ firstAirDate: "2008-01-20" })).toBe("2008");
    expect(seerr.resultKey({ id: 603, mediaType: "movie" })).toBe("movie-603");
  });

  it("are worth offering unless they are already in the library", () => {
    const r = (mediaType: string, status?: number) => ({ id: 1, mediaType, mediaInfo: status ? { status } : undefined });
    expect(seerr.isRequestable(r("movie"))).toBe(true);
    expect(seerr.isRequestable(r("tv", 4))).toBe(false);
    expect(seerr.isRequestable(r("movie", 2))).toBe(true);
    expect(seerr.isRequestable(r("movie", 5))).toBe(false);
    expect(seerr.isRequestable(r("person"))).toBe(false);
    expect(seerr.notInLibrary([r("movie"), r("person"), r("tv", 5), r("tv", 3)]).length).toBe(2);
  });

  it("of one kind are given the kind Seerr left off", () => {
    const list = [{ id: 1 }, { id: 2, mediaType: "tv" }];
    expect(seerr.withKind(list, "movie")).toEqual([{ id: 1, mediaType: "movie" }, { id: 2, mediaType: "tv" }]);
    expect(seerr.withKind(list, null)).toBe(list);
  });

  it("open on the library's page when they are here, on a request page when not", () => {
    expect(seerr.hashFor({ id: 603, mediaType: "movie" })).toBe("#/request/movie/603");
    expect(seerr.hashFor({ id: 603, mediaType: "movie", mediaInfo: { status: 5, jellyfinMediaId: "jf1" } })).toBe("#/item/jf1");
    expect(seerr.hashFor({ id: 603, mediaType: "movie", mediaInfo: { status: 5, jellyfinMediaId4k: "jf4k" } })).toBe("#/item/jf4k");
    // Partly here, or here with no known Jellyfin id: the request page.
    expect(seerr.hashFor({ id: 1396, mediaType: "tv", mediaInfo: { status: 4, jellyfinMediaId: "jf2" } })).toBe("#/request/tv/1396");
    expect(seerr.hashFor({ id: 603, mediaType: "movie", mediaInfo: { status: 5 } })).toBe("#/request/movie/603");
    expect(seerr.hashFor({ id: 5, mediaType: "person" })).toBeNull();
    expect(seerr.hashForRequest({ id: 1, type: "tv", status: 1, media: { tmdbId: 1396 } })).toBe("#/request/tv/1396");
    expect(seerr.hashForRequest({ id: 1, type: "movie", status: 5, media: { tmdbId: 603, jellyfinMediaId: "jf1" } })).toBe("#/item/jf1");
    expect(seerr.hashForRequest({ id: 1, status: 1, media: { mediaType: "movie", tmdbId: 603 } })).toBe("#/request/movie/603");
    expect(seerr.hashForRequest({ id: 1, type: "movie" })).toBeNull();
  });

  it("are described in one line of facts", () => {
    expect(
      seerr.titleFacts(
        { id: 603, releaseDate: "1999-03-31", runtime: 136, genres: [{ name: "Action" }, { name: "Sci-Fi" }, {}, { name: "A" }, { name: "B" }] },
        "movie"
      )
    ).toBe("1999 · Film · 2 h 16 min · Action, Sci-Fi, A");
    expect(seerr.titleFacts({ id: 1, runtime: 45 }, "movie")).toBe("Film · 45 min");
    expect(seerr.titleFacts(show(), "tv")).toBe("2008 · Show · 5 seasons");
    expect(seerr.titleFacts({ id: 1, seasons: [{ seasonNumber: 1 }] }, "tv")).toBe("Show · 1 season");
  });

  it("as someone's credits come newest first, each once", () => {
    const sorted = seerr.sortCredits(
      [
        { id: 1, mediaType: "movie", releaseDate: "2001-01-01" },
        { id: 2, mediaType: "tv", firstAirDate: "2020-05-05" },
        { id: 9, mediaType: "person" },
      ],
      [
        { id: 1, mediaType: "movie", releaseDate: "2001-01-01" },
        { id: 3, mediaType: "movie" },
        { id: 1, mediaType: "tv", firstAirDate: "2010-01-01" },
      ]
    );
    expect(sorted.map(seerr.resultKey)).toEqual(["tv-2", "tv-1", "movie-1", "movie-3"]);
  });

  it("a request's own line names its kind, year, seasons and 4K", () => {
    expect(seerr.requestDetail({ id: 1, type: "movie" }, { id: 603, releaseDate: "1999-03-31" })).toBe("Film · 1999");
    expect(
      seerr.requestDetail(
        { id: 1, type: "tv", is4k: true, seasons: [{ seasonNumber: 3 }, { seasonNumber: 2 }] },
        { id: 1396, firstAirDate: "2008-01-20" }
      )
    ).toBe("Show · 2008 · Seasons 2, 3 · 4K");
    expect(seerr.requestDetail({ id: 1, type: "tv", seasons: [{ seasonNumber: 4 }] }, undefined)).toBe("Show · Season 4");
  });
});

describe("a Jellyfin item's TMDB id", () => {
  it("is read whatever case the key is in", () => {
    expect(seerr.tmdbIdOf({ ProviderIds: { Tmdb: "603" } })).toBe(603);
    expect(seerr.tmdbIdOf({ ProviderIds: { tmdb: "1396", Imdb: "tt0903747" } })).toBe(1396);
    expect(seerr.tmdbIdOf({ ProviderIds: { TMDB: 27205 } })).toBe(27205);
    expect(seerr.tmdbIdOf({ ProviderIds: { Tmdb: "" } })).toBeNull();
    expect(seerr.tmdbIdOf({ ProviderIds: { Tmdb: "tt12" } })).toBeNull();
    expect(seerr.tmdbIdOf({ ProviderIds: { Imdb: "tt1" } })).toBeNull();
    expect(seerr.tmdbIdOf({})).toBeNull();
    expect(seerr.tmdbIdOf(null)).toBeNull();
  });
});

describe("the search query", () => {
  it("is escaped down to unreserved characters", () => {
    expect(seerr.encodeQuery("matrix")).toBe("matrix");
    expect(seerr.encodeQuery("the matrix")).toBe("the%20matrix");
    expect(seerr.encodeQuery("a-b_c.d~e")).toBe("a-b_c.d~e");
    expect(seerr.encodeQuery("what's (up)! *")).toBe("what%27s%20%28up%29%21%20%2A");
    expect(seerr.encodeQuery("a&b=c/d?e#f")).toBe("a%26b%3Dc%2Fd%3Fe%23f");
    expect(seerr.encodeQuery("amélie")).toBe("am%C3%A9lie");
  });
});

describe("errors from Rust", () => {
  it("keep their kind across the bridge", () => {
    const e = seerr.seerrError("quickconnect|Use your password instead.");
    expect(e).toBeInstanceOf(Error);
    expect([e.kind, e.message]).toEqual(["quickconnect", "Use your password instead."]);
    expect(seerr.seerrError("refused|That has already been requested.").kind).toBe("refused");
    // Anything else is a plain message, pipe and all.
    expect([seerr.seerrError("offline|x").kind, seerr.seerrError("offline|x").message]).toEqual(["message", "offline|x"]);
    expect(seerr.seerrError(new Error("boom")).message).toBe("boom");
    expect(seerr.seerrError(e)).toBe(e);
  });
});

describe("the connection", () => {
  it("is nothing until Rust says otherwise, and nothing if it can't be asked", async () => {
    expect(seerr.getStatus()).toEqual({ connected: false });
    expect(seerr.isConnected()).toBe(false);
    onInvoke("seerr_status", () => {
      throw "no keyring today";
    });
    expect(await seerr.loadStatus()).toEqual({ connected: false });
    onInvoke("seerr_status", null);
    expect(await seerr.loadStatus()).toEqual({ connected: false });
  });

  it("announces a change once, and not a repeat of the same answer", async () => {
    const heard = vi.fn();
    document.addEventListener(seerr.SEERR_CHANGED, heard);
    await connected();
    expect(seerr.isConnected()).toBe(true);
    expect(heard).toHaveBeenCalledTimes(1);
    await seerr.loadStatus();
    expect(heard).toHaveBeenCalledTimes(1);
    seerr.forgetStatus();
    expect(seerr.isConnected()).toBe(false);
    expect(heard).toHaveBeenCalledTimes(2);
    document.removeEventListener(seerr.SEERR_CHANGED, heard);
  });

  it("with a session that ran out shows nothing of Seerr's but still offers Reconnect", async () => {
    await connected({ needs_reconnect: true });
    expect(seerr.isConnected()).toBe(false);
    expect(seerr.needsReconnect()).toBe(true);
    onInvoke("seerr_reconnect", { ...CONNECTED });
    await seerr.reconnect();
    expect(seerr.isConnected()).toBe(true);
    expect(seerr.needsReconnect()).toBe(false);
  });

  it("learns from a refused call that the session ran out", async () => {
    await connected();
    onInvoke("seerr_request", () => {
      throw "reconnect|The connection to Seerr has run out. Reconnect in Settings.";
    });
    await expect(seerr.title("movie", 603)).rejects.toMatchObject({ kind: "reconnect" });
    expect(seerr.needsReconnect()).toBe(true);
    expect(seerr.isConnected()).toBe(false);
  });

  it("probes, connects and disconnects through Rust, and never sees a cookie", async () => {
    onInvoke("seerr_probe", (a: any) => ({ server: `https://${a.address}`, secure: true, fell_back: false, name: "Requests", settings: {} }));
    expect((await seerr.probe("seerr.test")).server).toBe("https://seerr.test");
    onInvoke("seerr_connect", (a: any) => ({ ...CONNECTED, server: a.server }));
    expect((await seerr.connect("https://seerr.test")).connected).toBe(true);
    expect(seerr.isConnected()).toBe(true);
    onInvoke("seerr_disconnect", { connected: false });
    await seerr.disconnect();
    expect(seerr.isConnected()).toBe(false);

    onInvoke("seerr_connect_password", (a: any) => ({ ...CONNECTED, user_name: a.username }));
    expect((await seerr.connectWithPassword("https://seerr.test", "ann", "pw")).user_name).toBe("ann");
    expect(invokeCalls("seerr_connect_password")[0]!.args).toEqual({ server: "https://seerr.test", username: "ann", password: "pw" });

    onInvoke("seerr_probe", () => {
      throw "message|Couldn't reach a Seerr server at that address.";
    });
    await expect(seerr.probe("nowhere")).rejects.toThrow("Couldn't reach a Seerr server at that address.");
    onInvoke("seerr_connect", () => {
      throw "quickconnect|Use your Jellyfin user name and password instead.";
    });
    await expect(seerr.connect("https://seerr.test")).rejects.toMatchObject({ kind: "quickconnect" });
  });
});

describe("pictures", () => {
  it("always come through the Seerr server itself, never from TMDB", async () => {
    // Not connected: there is no picture address at all.
    expect(seerr.imageUrl("/abc.jpg")).toBeNull();
    await connected({ settings: { cacheImages: false } });
    expect(seerr.imageUrl("/abc.jpg")).toBe("https://seerr.test/imageproxy/tmdb/t/p/w342/abc.jpg");
    expect(seerr.imageUrl("/abc.jpg", "posterLarge")).toBe("https://seerr.test/imageproxy/tmdb/t/p/w500/abc.jpg");
    expect(seerr.imageUrl("/b.jpg", "backdrop")).toBe("https://seerr.test/imageproxy/tmdb/t/p/w1280/b.jpg");
    await connected({ settings: { cacheImages: true }, server: "http://seerr.lan:5055/base" });
    expect(seerr.imageUrl("/abc.jpg")).toBe("http://seerr.lan:5055/base/imageproxy/tmdb/t/p/w342/abc.jpg");
    for (const size of ["poster", "posterLarge", "backdrop", "face"] as const) {
      expect(seerr.imageUrl("/abc.jpg", size)).not.toContain("tmdb.org");
    }
    // No path, or one that isn't a path: nothing.
    expect(seerr.imageUrl(null)).toBeNull();
    expect(seerr.imageUrl("")).toBeNull();
    expect(seerr.imageUrl("https://evil.example/x.jpg")).toBeNull();
  });
});

describe("calls", () => {
  it("search with the escaped term and keep what has an id", async () => {
    await connected();
    routes([["/search", () => ({ results: [{ id: 603, mediaType: "movie" }, { name: "no id" }, null] })]]);
    expect(await seerr.search("what's up")).toEqual([{ id: 603, mediaType: "movie" }]);
    expect(invokeCalls("seerr_request")[0]!.args).toEqual({ path: "/search?query=what%27s%20up&page=1", method: "GET", body: null });
  });

  it("browse every row from its own path, kinds filled in, people dropped", async () => {
    await connected();
    routes([
      ["/discover/trending", () => ({ results: [{ id: 1, mediaType: "movie" }, { id: 2, mediaType: "person" }, { id: 3, mediaType: "tv" }] })],
      [/^\/discover\/(movies|tv)/, () => ({ results: [{ id: 5 }] })],
    ]);
    expect(seerr.BROWSE_ROWS.map((r) => [r.title, r.path])).toEqual([
      ["Trending", "/discover/trending"],
      ["Popular Films", "/discover/movies"],
      ["Popular Shows", "/discover/tv"],
      ["Upcoming Films", "/discover/movies/upcoming"],
      ["Upcoming Shows", "/discover/tv/upcoming"],
    ]);
    const kinds: (string | undefined)[][] = [];
    for (const row of seerr.BROWSE_ROWS) kinds.push((await seerr.browse(row)).map((r) => r.mediaType));
    expect(kinds).toEqual([["movie", "tv"], ["movie"], ["tv"], ["movie"], ["tv"]]);
    expect(invokeCalls("seerr_request").map((c) => c.args.path)).toEqual(seerr.BROWSE_ROWS.map((r) => `${r.path}?page=1`));
  });

  it("read a title, a collection's films and someone's credits", async () => {
    await connected();
    routes([
      ["/movie/603", () => ({ id: 603, title: "The Matrix" })],
      ["/tv/9", () => ({ message: "odd" })],
      ["/collection/2344", () => ({ id: 2344, parts: [{ id: 603 }, { id: 604, mediaType: "movie" }] })],
      ["/person/71580/combined_credits", () => ({ cast: [{ id: 1, mediaType: "tv", firstAirDate: "2010-01-01" }], crew: null })],
    ]);
    expect((await seerr.title("movie", 603)).title).toBe("The Matrix");
    await expect(seerr.title("tv", 9)).rejects.toThrow("Seerr sent something this app couldn't read");
    expect(await seerr.collection(2344)).toEqual([{ id: 603, mediaType: "movie" }, { id: 604, mediaType: "movie" }]);
    expect((await seerr.credits(71580)).map(seerr.resultKey)).toEqual(["tv-1"]);
    await expect(seerr.title("movie", 1)).rejects.toMatchObject({ kind: "refused", message: "Seerr doesn't know that title." });
  });

  it("ask for a film, and for seasons of a show, and say so to the rest of the app", async () => {
    await connected();
    const heard = vi.fn();
    document.addEventListener(seerr.SEERR_REQUESTS_CHANGED, heard);
    routes([["/request", (a) => ({ __status: 201, body: { id: 4, status: 1, type: a.body.mediaType } })]]);
    expect((await seerr.request("movie", 603)).id).toBe(4);
    await seerr.request("tv", 1396, { seasons: [2, 3], is4k: true });
    // Seasons mean nothing for a film and are not sent.
    await seerr.request("movie", 13, { seasons: [1] });
    expect(invokeCalls("seerr_request").map((c) => c.args)).toEqual([
      { path: "/request", method: "POST", body: { mediaType: "movie", mediaId: 603, is4k: false } },
      { path: "/request", method: "POST", body: { mediaType: "tv", mediaId: 1396, is4k: true, seasons: [2, 3] } },
      { path: "/request", method: "POST", body: { mediaType: "movie", mediaId: 13, is4k: false } },
    ]);
    expect(heard).toHaveBeenCalledTimes(3);
    document.removeEventListener(seerr.SEERR_REQUESTS_CHANGED, heard);
  });

  it("turn Seerr's 'nothing left to ask for' into words, and an unreadable answer into an error", async () => {
    await connected();
    routes([["/request", () => ({ __status: 202, body: { message: "No seasons available to request" } })]]);
    await expect(seerr.request("tv", 1396, { seasons: [1] })).rejects.toThrow(
      "Every season of that is already in the library or requested."
    );
    routes([["/request", () => ({ __status: 201, body: { ok: true } })]]);
    await expect(seerr.request("movie", 603)).rejects.toThrow("Seerr took the request but sent back something this app couldn't read");
    onInvoke("seerr_request", () => {
      throw "refused|You've used all your requests for now. More open up as the oldest ones age out.";
    });
    await expect(seerr.request("movie", 603)).rejects.toMatchObject({ kind: "refused" });
  });

  it("list this account's requests only, withdraw one, and read its quota", async () => {
    await connected();
    routes([
      ["/request?", () => ({ pageInfo: { results: 1 }, results: [{ id: 4, status: 1 }, { nope: true }] })],
      ["/request/4", () => ({ __status: 204 })],
      ["/user/7/quota", () => ({ movie: { days: 7, limit: 5, remaining: 2 }, tv: {} })],
    ]);
    expect(await seerr.myRequests()).toEqual([{ id: 4, status: 1 }]);
    await seerr.cancel({ id: 4 });
    expect(seerr.quotaSummary((await seerr.quota()).movie)).toBe("2 of 5 requests left this week");
    expect(invokeCalls("seerr_request").map((c) => [c.args.method, c.args.path])).toEqual([
      ["GET", "/request?take=40&skip=0&sort=added&requestedBy=7"],
      ["DELETE", "/request/4"],
      ["GET", "/user/7/quota"],
    ]);
  });

  it("are not made at all without a connection to make them as", async () => {
    await expect(seerr.myRequests()).rejects.toMatchObject({ kind: "notconnected" });
    await expect(seerr.quota()).rejects.toMatchObject({ kind: "notconnected" });
    expect(invokeCalls("seerr_request")).toEqual([]);
    // Refreshing is quiet, and asks nothing when there is nothing to refresh.
    await seerr.refreshAccount();
    expect(invokeCalls("seerr_refresh")).toEqual([]);
    await connected();
    onInvoke("seerr_refresh", { ...CONNECTED, permissions: 1056 });
    await seerr.refreshAccount();
    expect(seerr.getStatus().permissions).toBe(1056);
  });
});

describe("the sentences Settings says", () => {
  it("promise a kept session and no password", () => {
    expect(seerr.COPY.offer).toContain("Seerr takes requests for films and shows the library doesn't have yet.");
    expect(seerr.COPY.kept).toContain("no password is stored");
    expect(seerr.COPY.kept).toContain("keyring");
    expect(seerr.COPY.keptInFile).toContain("config.json");
  });
});

describe("removing a title through Seerr", () => {
  const MANAGER = { permissions: 16 | 32 };
  const film = (extra: Record<string, any> = {}): any => ({ Id: "m1", Type: "Movie", Name: "Heat", ProviderIds: { Tmdb: "949" }, ...extra });
  const series = (): any => ({ Id: "s1", Type: "Series", Name: "Severance", ProviderIds: { Tmdb: "95396" } });
  const onRadarr = { id: 949, title: "Heat", mediaInfo: { id: 41, status: 5, serviceId: 0, externalServiceId: 12, requests: [{ id: 7 }, { id: 9 }] } };
  const paths = (): string[] => invokeCalls("seerr_request").map((c) => `${c.args.method} ${c.args.path}`);

  it("is for accounts that manage requests, on films and whole shows", async () => {
    expect(seerr.canManageRequests(32)).toBe(false);
    expect(seerr.canManageRequests(16)).toBe(true);
    expect(seerr.canManageRequests(2)).toBe(true);
    expect(seerr.mightRemove(film())).toBe(false); // not connected
    await connected(MANAGER);
    expect(seerr.mightRemove(film())).toBe(true);
    expect(seerr.mightRemove(series())).toBe(true);
    expect(seerr.mightRemove({ Type: "Season" })).toBe(false);
    expect(seerr.mightRemove({ Type: "Episode" })).toBe(false);
    expect(seerr.serviceName("movie")).toBe("Radarr");
    expect(seerr.serviceName("tv")).toBe("Sonarr");
  });

  it("is offered for a film Seerr has on Radarr", async () => {
    await connected(MANAGER);
    routes([["/service/radarr", () => [{ id: 0, is4k: false, isDefault: true }]], ["/movie/949", () => onRadarr]]);
    expect(await seerr.removal(film())).toEqual({ kind: "movie", tmdbId: 949, mediaId: 41, copies: [false], requestIds: [7, 9] });
    expect(paths()).toEqual(["GET /service/radarr", "GET /movie/949"]);
  });

  it("asks about Sonarr for a show", async () => {
    await connected(MANAGER);
    routes([["/service/sonarr", () => [{ id: 0 }]], ["/tv/95396", () => ({ id: 95396, mediaInfo: { id: 8, serviceId: 0 } })]]);
    expect((await seerr.removal(series()))?.mediaId).toBe(8);
    expect(paths()[0]).toBe("GET /service/sonarr");
  });

  it("is not offered without the right, and asks Seerr nothing", async () => {
    await connected();
    routes([["/service/radarr", () => [{ id: 0 }]], ["/movie/949", () => onRadarr]]);
    expect(await seerr.removal(film())).toBeNull();
    expect(paths()).toEqual([]);
  });

  it("is not offered when Seerr has no Radarr, or has not put the title on it, or has never met it", async () => {
    await connected(MANAGER);
    routes([["/service/radarr", () => []], ["/movie/949", () => onRadarr]]);
    expect(await seerr.removal(film())).toBeNull();
    routes([["/service/radarr", () => [{ id: 0 }]], ["/movie/949", () => ({ id: 949, mediaInfo: { id: 41, status: 5 } })]]);
    expect(await seerr.removal(film())).toBeNull();
    routes([["/service/radarr", () => [{ id: 0 }]], ["/movie/949", () => ({ id: 949 })]]);
    expect(await seerr.removal(film())).toBeNull();
    // No TMDB id, or Seerr unreachable: nothing to offer either.
    expect(await seerr.removal(film({ ProviderIds: {} }))).toBeNull();
    routes([]);
    expect(await seerr.removal(film())).toBeNull();
  });

  it("removes the 4K copy only where there is a 4K server", async () => {
    await connected(MANAGER);
    const both = { id: 949, mediaInfo: { id: 41, serviceId: 0, serviceId4k: 1 } };
    routes([["/service/radarr", () => [{ id: 0, is4k: false }]], ["/movie/949", () => both]]);
    expect((await seerr.removal(film()))?.copies).toEqual([false]);
    routes([["/service/radarr", () => [{ id: 0, is4k: false }, { id: 1, is4k: true }]], ["/movie/949", () => both]]);
    expect((await seerr.removal(film()))?.copies).toEqual([false, true]);
  });

  it("takes it off Radarr, then clears the requests and the record, and tells the lists", async () => {
    await connected(MANAGER);
    const heard = vi.fn();
    document.addEventListener(seerr.SEERR_REQUESTS_CHANGED, heard);
    routes([
      ["/request/9", () => { throw "refused|Seerr doesn't know that title."; }],
      [/^\/(media|request)\//, () => ({ __status: 204 })],
    ]);
    await seerr.remove({ kind: "movie", tmdbId: 949, mediaId: 41, copies: [false, true], requestIds: [7, 9] });
    expect(paths()).toEqual([
      "DELETE /media/41/file?is4k=false",
      "DELETE /media/41/file?is4k=true",
      "DELETE /request/7",
      "DELETE /request/9", // already gone: not a failure
      "DELETE /media/41",
    ]);
    expect(heard).toHaveBeenCalledTimes(1);
    document.removeEventListener(seerr.SEERR_REQUESTS_CHANGED, heard);
  });

  it("stops at a refusal from Radarr, leaving requests and the record alone", async () => {
    await connected(MANAGER);
    routes([]);
    await expect(seerr.remove({ kind: "movie", tmdbId: 949, mediaId: 41, copies: [false], requestIds: [7] })).rejects.toMatchObject({ kind: "refused" });
    expect(paths()).toEqual(["DELETE /media/41/file?is4k=false"]);
  });
});
