// src/seerr.ts against the stand-in Seerr server (tests/helpers/seerr-qa.ts,
// Aquarium/Tools/seerr-mock.py on 127.0.0.1:8197), which reads what is "in
// the library" from the QA Jellyfin: the shapes the app reads are the shapes
// a Seerr 3.5 sends. Skips when the stand-in or the QA server is not running.
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { qa } from "../helpers/qa";
import { seerrQa } from "../helpers/seerr-qa";

type Seerr = typeof import("../../src/seerr");
let seerr: Seerr;

describe.skipIf(!qa || !seerrQa)("stand-in Seerr: requests end to end", () => {
  beforeAll(async () => {
    await seerrQa!.control("reset");
  });
  afterAll(async () => {
    await seerrQa?.control("reset");
  });
  beforeEach(async () => {
    vi.resetModules();
    qa!.install();
    seerrQa!.install();
    seerr = await import("../../src/seerr");
    await seerr.loadStatus();
  });

  it("is connected as the QA account, with pictures through the stand-in itself", () => {
    expect(seerr.isConnected()).toBe(true);
    expect(seerr.getStatus().user_id).toBe(seerrQa!.userId);
    expect(seerr.getStatus().settings?.mediaServerType).toBe(2);
    expect(seerr.imageUrl("/poster-movie-603.png")).toBe(`${seerrQa!.server}/imageproxy/tmdb/t/p/w342/poster-movie-603.png`);
  });

  it("serves a poster from its image proxy without a cookie", async () => {
    const res = await fetch(seerr.imageUrl("/poster-movie-603.png")!);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("image/");
  });

  it("finds a title the library lacks, and leaves out what is already there", async () => {
    const found = await seerr.search("matrix");
    const matrix = found.find((r) => r.id === 603);
    expect(matrix).toBeTruthy();
    expect(seerr.kindOf(matrix!)).toBe("movie");
    expect(seerr.displayTitle(matrix!)).toBe("The Matrix");
    expect(seerr.resultYear(matrix!)).toBe("1999");
    expect(seerr.notInLibrary(found).some((r) => r.id === 603)).toBe(true);
    for (const r of seerr.notInLibrary(found)) expect(seerr.availability(r.mediaInfo?.status)).not.toBe("available");
    // A term with characters Seerr refuses unescaped still goes through.
    expect(Array.isArray(await seerr.search("what's (up)!"))).toBe(true);
  });

  it("fills every browse row with films and shows, each with its kind", async () => {
    for (const row of seerr.BROWSE_ROWS) {
      const list = await seerr.browse(row);
      expect(list.length, row.title).toBeGreaterThan(0);
      for (const r of list) {
        expect(seerr.kindOf(r), `${row.title}: ${seerr.displayTitle(r)}`).not.toBeNull();
        if (row.kind) expect(r.mediaType).toBe(row.kind);
      }
    }
  });

  it("reads a film's page and a show's seasons", async () => {
    const film = await seerr.title("movie", 603);
    expect(seerr.displayTitle(film)).toBe("The Matrix");
    expect(seerr.titleFacts(film, "movie")).toBe("1999 · Film · 2 h 16 min · Drama");
    expect(seerr.standingOfMedia(film.mediaInfo)).toBe("requestable");

    const show = await seerr.title("tv", 1396);
    expect(seerr.displayTitle(show)).toBe("Breaking Bad");
    expect(seerr.realSeasons(show).map((s) => s.seasonNumber)).toEqual([1, 2, 3, 4, 5]);
    expect(seerr.requestableSeasons(show).length).toBe(5);
    await expect(seerr.title("movie", 999_999_999)).rejects.toThrow("Seerr doesn't know that title.");
  });

  it("requests a film, sees it waiting, then approved, and cannot ask twice", async () => {
    await seerrQa!.control("reset");
    const made = await seerr.request("movie", 603);
    expect(seerr.requestStatus(made.status)).toBe("pending");
    expect(seerr.requestKind(made)).toBe("movie");

    const mine = await seerr.myRequests();
    const row = mine.find((r) => r.id === made.id)!;
    expect(row).toBeTruthy();
    expect(seerr.standingOfRequest(row)).toBe("awaitingApproval");
    expect(seerr.hashForRequest(row)).toBe("#/request/movie/603");

    let film = await seerr.title("movie", 603);
    expect(seerr.standingOfMedia(film.mediaInfo)).toBe("awaitingApproval");
    expect(seerr.myPendingRequest(film, seerr.getStatus().user_id)?.id).toBe(made.id);
    await expect(seerr.request("movie", 603)).rejects.toThrow("That has already been requested.");

    await seerrQa!.control(`approve/${made.id}`);
    film = await seerr.title("movie", 603);
    expect(seerr.standingOfMedia(film.mediaInfo)).toBe("onItsWay");
    expect(seerr.myPendingRequest(film, seerr.getStatus().user_id)).toBeNull();
    expect(seerr.standingOfRequest((await seerr.myRequests()).find((r) => r.id === made.id)!)).toBe("onItsWay");
  });

  it("requests some seasons of a show, and the rest stay open", async () => {
    await seerrQa!.control("reset");
    const made = await seerr.request("tv", 66732, { seasons: [1, 2] });
    expect((made.seasons ?? []).map((s) => s.seasonNumber)).toEqual([1, 2]);
    const show = await seerr.title("tv", 66732);
    expect(seerr.requestableSeasons(show).map((s) => s.seasonNumber)).toEqual([3, 4]);
    expect(seerr.standingOfSeason(show, 1)).toBe("awaitingApproval");
    expect(seerr.standingOfSeason(show, 3)).toBe("requestable");
    // Asking for what is already asked for: Seerr's 202, in words.
    await expect(seerr.request("tv", 66732, { seasons: [1] })).rejects.toThrow(
      "Every season of that is already in the library or requested."
    );

    // A declined request shows as declined, and its seasons open again.
    await seerrQa!.control(`decline/${made.id}`);
    const declined = (await seerr.myRequests()).find((r) => r.id === made.id)!;
    expect(seerr.standingOfRequest(declined)).toBe("declined");
    expect(seerr.requestableSeasons(await seerr.title("tv", 66732)).length).toBe(4);
  });

  it("withdraws its own waiting request", async () => {
    await seerrQa!.control("reset");
    const made = await seerr.request("movie", 27205);
    await seerr.cancel(made);
    expect((await seerr.myRequests()).some((r) => r.id === made.id)).toBe(false);
    expect(seerr.standingOfMedia((await seerr.title("movie", 27205)).mediaInfo)).toBe("requestable");
  });

  it("reads a collection's films, someone's credits and the quota", async () => {
    const parts = await seerr.collection(2344);
    expect(parts.map((p) => [p.id, p.mediaType])).toEqual([[603, "movie"]]);
    const credits = await seerr.credits(71580);
    expect(credits.length).toBeGreaterThan(0);
    for (const c of credits) expect(seerr.kindOf(c)).not.toBeNull();
    const dates = credits.map((c) => c.releaseDate ?? c.firstAirDate ?? "");
    expect([...dates].sort().reverse()).toEqual(dates);
    const quota = await seerr.quota();
    // The stand-in sets no limit: nothing to say.
    expect(seerr.quotaSummary(quota.movie)).toBeNull();
    expect(quota.movie?.restricted).toBe(false);
  });

  it("carries on across a session the server has forgotten", async () => {
    await seerrQa!.control("expire");
    expect(seerr.displayTitle(await seerr.title("movie", 603))).toBe("The Matrix");
    expect(seerr.needsReconnect()).toBe(false);
  });

  it("knows a library show by its TMDB id, where the QA library has one", async () => {
    const api = await import("../../src/api");
    await api.loadConfig();
    const shows = await api.api(`/Items?userId=${qa!.userId}&Recursive=true&IncludeItemTypes=Series&Fields=ProviderIds&Limit=50`);
    const withId = (shows.Items ?? []).find((s: any) => seerr.tmdbIdOf(s) != null);
    if (!withId) return; // nothing in the QA library carries one
    const full = await api.getItem(withId.Id);
    expect(seerr.tmdbIdOf(full)).toBe(seerr.tmdbIdOf(withId));
    const title = await seerr.title("tv", seerr.tmdbIdOf(full)!);
    expect(["available", "partlyAvailable"]).toContain(seerr.standingOfMedia(title.mediaInfo));
    expect(seerr.libraryItemId(title.mediaInfo)).toBe(withId.Id);
  });
});
