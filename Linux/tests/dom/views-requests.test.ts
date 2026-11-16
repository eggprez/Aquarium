// What Seerr adds to the app (src/views/requests.ts, src/views/seerrSettings.ts):
// the Requests page, a title's request page in each of its states, the "Not
// in Your Library" row under Search, what a show's and a collection's page
// gain, and connecting from Settings. Real seerr / cache / ui modules under
// the mocked Tauri bridge; the session itself never exists on this side.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { invokeCalls, invokeHandler, mockJellyfin, onInvoke, signIn, waitFor, type JfArgs } from "../helpers/tauri";
import {
  byText,
  click,
  dialogButtons,
  dialogEl,
  dialogTitle,
  lastToast,
  mountShell,
  pickDialog,
  settle,
  texts,
  toasts,
} from "../helpers/views-media";
import { query } from "../helpers/views-media-music";

vi.mock("../../src/playback", async (importOriginal) => {
  const real = await importOriginal<typeof import("../../src/playback")>();
  return { ...real, playItem: vi.fn(async () => {}) };
});

type Seerr = typeof import("../../src/seerr");
type Views = typeof import("../../src/views/requests");

let seerr: Seerr;
let views: Views;
let cache: typeof import("../../src/cache");
let root: HTMLElement;

const STATUS = {
  connected: true,
  server: "https://seerr.test",
  host: "seerr.test",
  secure: true,
  user_id: 7,
  user_name: "Ann",
  permissions: 32,
  settings: { partialRequestsEnabled: true, movie4kEnabled: false, series4kEnabled: false },
  needs_reconnect: false,
  storage: "keyring",
};

/** The stand-in Seerr behind `seerr_request`. */
interface World {
  status: Record<string, any>;
  titles: Record<string, any>;
  requests: any[];
  search: any[];
  rows: Record<string, any[]>;
  collections: Record<string, any[]>;
  quota: any;
  /** Throw this instead of answering POST /request. */
  refuse?: string;
  /** Throw this instead of listing requests. */
  listFails?: string;
}
let world: World;

const matrix = (extra: Record<string, any> = {}): any => ({
  id: 603,
  title: "The Matrix",
  releaseDate: "1999-03-31",
  runtime: 136,
  overview: "A hacker learns what the world really is.",
  posterPath: "/matrix.jpg",
  genres: [{ name: "Action" }],
  credits: { cast: [{ name: "Keanu Reeves" }, { name: "Carrie-Anne Moss" }] },
  ...extra,
});

const show = (extra: Record<string, any> = {}): any => ({
  id: 1396,
  name: "Breaking Bad",
  firstAirDate: "2008-01-20",
  posterPath: "/bb.jpg",
  seasons: [0, 1, 2, 3].map((n) => ({ seasonNumber: n, name: n ? `Season ${n}` : "Specials", episodeCount: 10, airDate: `${2007 + n}-01-01` })),
  ...extra,
});

function serve(): void {
  onInvoke("seerr_status", () => ({ ...world.status }));
  onInvoke("seerr_refresh", () => ({ ...world.status }));
  onInvoke("seerr_request", async (a: { path: string; method: string; body: any }) => {
    const [route] = a.path.split("?");
    const ok = (body: any, status = 200) => ({ status, body });
    if (a.method === "POST" && route === "/request") {
      if (world.refuse) throw world.refuse;
      const made = {
        id: world.requests.length + 1,
        status: 1,
        type: a.body.mediaType,
        is4k: a.body.is4k,
        seasons: (a.body.seasons ?? []).map((n: number) => ({ seasonNumber: n })),
        requestedBy: { id: 7 },
        media: { tmdbId: a.body.mediaId, mediaType: a.body.mediaType, status: 2 },
      };
      world.requests.unshift(made);
      const title = world.titles[`${a.body.mediaType}/${a.body.mediaId}`];
      if (title) {
        title.mediaInfo = { ...(title.mediaInfo ?? {}), status: title.mediaInfo?.status ?? 2 };
        title.mediaInfo.requests = [...(title.mediaInfo.requests ?? []), made];
      }
      return ok(made, 201);
    }
    if (a.method === "DELETE" && route!.startsWith("/request/")) {
      const id = Number(route!.split("/")[2]);
      world.requests = world.requests.filter((r) => r.id !== id);
      for (const t of Object.values(world.titles)) {
        if (!t.mediaInfo?.requests) continue;
        t.mediaInfo.requests = t.mediaInfo.requests.filter((r: any) => r.id !== id);
        if (!t.mediaInfo.requests.length) t.mediaInfo.status = 1;
      }
      return ok(null, 204);
    }
    if (route === "/request") {
      if (world.listFails) throw world.listFails;
      return ok({ results: world.requests });
    }
    if (route === "/search") return ok({ results: world.search });
    if (route!.startsWith("/discover/")) return ok({ results: world.rows[route!] ?? [] });
    if (route!.startsWith("/collection/")) {
      const parts = world.collections[route!.split("/")[2]!];
      if (!parts) throw "refused|Seerr doesn't know that title.";
      return ok({ id: 1, parts });
    }
    if (/^\/user\/\d+\/quota$/.test(route!)) return ok(world.quota);
    const title = world.titles[route!.slice(1)];
    if (title) return ok(JSON.parse(JSON.stringify(title)));
    throw "refused|Seerr doesn't know that title.";
  });
}

function sent(method?: string): any[] {
  return invokeCalls("seerr_request")
    .filter((c) => !method || c.args.method === method)
    .map((c) => c.args);
}

async function boot(status: Record<string, any> = {}): Promise<void> {
  world.status = { ...STATUS, ...status };
  root = mountShell();
  serve();
  await signIn();
  seerr = await import("../../src/seerr");
  cache = await import("../../src/cache");
  views = await import("../../src/views/requests");
  await seerr.loadStatus();
}

beforeEach(() => {
  vi.resetModules();
  vi.clearAllMocks();
  world = {
    status: { ...STATUS },
    titles: { "movie/603": matrix(), "tv/1396": show() },
    requests: [],
    search: [],
    rows: {},
    collections: {},
    quota: { movie: { days: 7, limit: 0, remaining: 0, restricted: false }, tv: { days: 7, limit: 0, remaining: 0, restricted: false } },
  };
});
afterEach(() => {
  location.hash = "";
});

const askButton = (): HTMLButtonElement | null => root.querySelector<HTMLButtonElement>(".request-ask");
const season = (n: number): HTMLButtonElement => root.querySelector<HTMLButtonElement>(`.request-season[data-season="${n}"]`)!;

describe("the Requests page", () => {
  it("says so when no Seerr server is connected, and asks nothing", async () => {
    await boot({ connected: false });
    await views.renderRequests(root);
    expect(root.querySelector(".state h3")!.textContent).toBe("Requests aren't set up");
    expect(root.querySelector(".state p")!.textContent).toContain("Connect a Seerr server in Settings");
    expect(sent()).toEqual([]);
    click(byText(root, "button", "Open Settings"));
    expect(location.hash).toBe("#/settings");
  });

  it("says to reconnect when the session has run out", async () => {
    await boot({ needs_reconnect: true });
    await views.renderRequests(root);
    expect(root.querySelector(".state h3")!.textContent).toBe("Reconnect to Seerr");
    expect(root.querySelector(".state p")!.textContent).toContain("The connection to Seerr has run out.");
    expect(sent()).toEqual([]);
  });

  it("lists this account's requests with what each is and where it stands, then the browse rows", async () => {
    world.requests = [
      { id: 2, status: 2, type: "tv", seasons: [{ seasonNumber: 2 }, { seasonNumber: 1 }], media: { tmdbId: 1396, mediaType: "tv", status: 3 } },
      { id: 1, status: 3, type: "movie", is4k: true, media: { tmdbId: 603, mediaType: "movie", status: 1 } },
    ];
    world.rows = {
      "/discover/trending": [{ id: 27205, mediaType: "movie", title: "Inception", releaseDate: "2010-07-16", posterPath: "/i.jpg" }, { id: 9, mediaType: "person", name: "Someone" }],
      "/discover/movies": [{ id: 155, title: "The Dark Knight", releaseDate: "2008-07-18", mediaInfo: { status: 2 } }],
      "/discover/tv": [{ id: 66732, name: "Stranger Things", firstAirDate: "2016-07-15", mediaInfo: { status: 5, jellyfinMediaId: "jf-st" } }],
      "/discover/tv/upcoming": [{ id: 1399, name: "Game of Thrones" }],
    };
    await boot();
    await views.renderRequests(root);

    expect(root.querySelector("h1")!.textContent).toBe("Requests");
    expect(texts(root, "h2")).toEqual(["Your Requests", "Trending", "Popular Films", "Popular Shows", "Upcoming Shows"]);
    expect(texts(root, ".request-row-title")).toEqual(["Breaking Bad", "The Matrix"]);
    expect(texts(root, ".request-row-detail")).toEqual(["Show · 2008 · Seasons 1, 2", "Film · 1999 · 4K"]);
    expect(texts(root, ".request-row-status")).toEqual(["On its way", "Declined"]);
    expect(root.querySelectorAll(".request-row-status.warn").length).toBe(1);
    // Posters come through the Seerr server's own image proxy.
    expect(root.querySelector<HTMLImageElement>(".request-thumb img")!.src).toBe("https://seerr.test/imageproxy/tmdb/t/p/w342/bb.jpg");
    expect([...root.querySelectorAll("img")].every((i) => i.src.startsWith("https://seerr.test/imageproxy/"))).toBe(true);

    // Cards: kind filled in for the one-kind rows, a badge once asked for.
    const trending = root.querySelector('[data-shelf="trending"]')!;
    expect(texts(trending, ".card-title")).toEqual(["Inception"]);
    expect(texts(trending, ".card-sub")).toEqual(["2010 · Film"]);
    expect(trending.querySelector(".request-badge")).toBeNull();
    expect(root.querySelector('[data-shelf="popularMovies"] .request-badge')!.textContent).toBe("Requested");
    expect(root.querySelector('[data-shelf="popularTV"] .card-sub')!.textContent).toBe("2016 · Show");
    expect(root.querySelector('[data-shelf="popularTV"] .request-badge')!.textContent).toBe("In library");
    // A row with nothing in it is not drawn.
    expect(root.querySelector('[data-shelf="upcomingMovies"]')).toBeNull();

    // Only this account's requests were asked for.
    expect(sent().find((a) => a.path.startsWith("/request?"))!.path).toBe("/request?take=40&skip=0&sort=added&requestedBy=7");

    // A card opens the library's page when the title is here, a request page when not.
    click(root.querySelector('[data-shelf="popularTV"] .card'));
    expect(location.hash).toBe("#/item/jf-st");
    click(trending.querySelector(".card"));
    expect(location.hash).toBe("#/request/movie/27205");
    click(root.querySelector('.request-row[data-request="2"]'));
    expect(location.hash).toBe("#/request/tv/1396");
  });

  it("says when nothing has been requested, and why when the list didn't arrive", async () => {
    await boot();
    await views.renderRequests(root);
    expect(root.querySelector(".request-mine-empty")!.textContent).toBe(
      "Nothing requested yet. Search for a film or a show, or pick one below."
    );
    world.listFails = "unreachable|Can't reach Seerr at seerr.test";
    cache.invalidateCache("seerr:requests");
    await views.renderRequests(root);
    expect(root.querySelector(".request-mine-error")!.textContent).toBe("Can't reach Seerr at seerr.test");
    expect(root.querySelector(".request-mine-empty")).toBeNull();
  });

  it("paints the last visit at once and leaves it alone when nothing changed", async () => {
    world.requests = [{ id: 1, status: 1, type: "movie", media: { tmdbId: 603, mediaType: "movie", status: 2 } }];
    world.rows = { "/discover/trending": [{ id: 155, mediaType: "movie", title: "The Dark Knight" }] };
    await boot();
    await views.renderRequests(root);
    expect(cache.getCached("seerr:requests")).toBeTruthy();

    const again = views.renderRequests(root);
    // Before any answer: the cached page is already there.
    const row = root.querySelector(".request-row");
    expect(row).not.toBeNull();
    expect(texts(root, ".request-row-status")).toEqual(["Waiting for approval"]);
    await again;
    expect(root.querySelector(".request-row")).toBe(row);

    // Approved since: the next visit repaints.
    world.requests[0].status = 2;
    world.requests[0].media.status = 3;
    await views.renderRequests(root);
    expect(texts(root, ".request-row-status")).toEqual(["On its way"]);
  });
});

describe("a film's request page", () => {
  it("shows what it is and offers to request it", async () => {
    await boot();
    await views.renderRequestTitle(root, "movie/603");
    expect(root.querySelector(".detail-title")!.textContent).toBe("The Matrix");
    expect(root.querySelector(".detail-meta")!.textContent).toBe("1999 · Film · 2 h 16 min · Action");
    expect(root.querySelector(".request-standing")!.textContent).toBe("Not in your library");
    expect(root.querySelector(".detail-overview")!.textContent).toBe("A hacker learns what the world really is.");
    expect(root.querySelector(".request-cast p")!.textContent).toBe("Keanu Reeves, Carrie-Anne Moss");
    expect(root.querySelector<HTMLImageElement>(".detail-poster img")!.src).toBe("https://seerr.test/imageproxy/tmdb/t/p/w500/matrix.jpg");
    expect(askButton()!.textContent).toBe("Request");
    expect(askButton()!.disabled).toBe(false);
    // No limit: no quota line. No 4K on offer. Nothing to cancel or open.
    for (const absent of [".request-quota", ".request-4k", ".request-cancel", ".request-open", ".request-seasons"]) {
      expect(root.querySelector(absent)).toBeNull();
    }
  });

  it("asks, says so, and then offers to take it back", async () => {
    await boot();
    await views.renderRequestTitle(root, "movie/603");
    click(askButton());
    await settle();
    expect(sent("POST")).toEqual([{ path: "/request", method: "POST", body: { mediaType: "movie", mediaId: 603, is4k: false } }]);
    expect(lastToast()).toBe("Requested The Matrix. It's waiting for approval.");
    expect(root.querySelector(".request-standing")!.textContent).toBe("Waiting for approval");
    expect(askButton()).toBeNull();

    click(root.querySelector(".request-cancel"));
    expect(dialogTitle()).toBe("Cancel this request?");
    expect(dialogButtons()).toEqual(["Keep It", "Cancel Request"]);
    await pickDialog("Keep It");
    expect(sent("DELETE")).toEqual([]);
    click(root.querySelector(".request-cancel"));
    await pickDialog("Cancel Request");
    await settle();
    expect(sent("DELETE").map((a) => a.path)).toEqual(["/request/1"]);
    expect(lastToast()).toBe("Request cancelled");
    expect(root.querySelector(".request-standing")!.textContent).toBe("Not in your library");
    expect(askButton()).not.toBeNull();
    expect(root.querySelector(".request-cancel")).toBeNull();
  });

  it("says a request that needs no approval is on its way", async () => {
    await boot();
    await views.renderRequestTitle(root, "movie/603");
    // An account with auto-approve: the request comes back already approved.
    const inner = invokeHandler("seerr_request")!;
    onInvoke("seerr_request", async (a: any) => {
      const out = await inner(a, "seerr_request");
      if (a.method === "POST") out.body.status = 2;
      return out;
    });
    click(askButton());
    await settle();
    expect(lastToast()).toBe("Requested The Matrix. It's on its way.");
  });

  it("puts a refusal in Seerr's plain words and stays usable", async () => {
    world.refuse = "refused|That has already been requested.";
    await boot();
    await views.renderRequestTitle(root, "movie/603");
    click(askButton());
    await settle();
    expect(toasts()).toEqual(["That has already been requested."]);
    expect(askButton()!.disabled).toBe(false);
  });

  it("does not offer another account's waiting request for cancelling", async () => {
    world.titles["movie/603"] = matrix({ mediaInfo: { status: 2, requests: [{ id: 5, status: 1, requestedBy: { id: 99 } }] } });
    await boot();
    await views.renderRequestTitle(root, "movie/603");
    expect(root.querySelector(".request-standing")!.textContent).toBe("Waiting for approval");
    expect(root.querySelector(".request-cancel")).toBeNull();
    expect(askButton()).toBeNull();
  });

  it("opens the library's copy once it is there", async () => {
    world.titles["movie/603"] = matrix({ mediaInfo: { status: 5, jellyfinMediaId: "jf-matrix" } });
    await boot();
    await views.renderRequestTitle(root, "movie/603");
    expect(root.querySelector(".request-standing.ok")!.textContent).toBe("In your library");
    expect(askButton()).toBeNull();
    const open = root.querySelector<HTMLButtonElement>(".request-open")!;
    expect(open.textContent).toBe("Open in Library");
    expect(open.classList.contains("primary")).toBe(true);
    click(open);
    expect(location.hash).toBe("#/item/jf-matrix");
  });

  it("says so when the account may not request films", async () => {
    await boot({ permissions: seerrPermission("requestTV") });
    await views.renderRequestTitle(root, "movie/603");
    expect(root.querySelector(".request-not-allowed")!.textContent).toBe(
      "This account can't request films. Ask whoever runs the server."
    );
    expect(askButton()).toBeNull();
  });

  it("offers 4K only where the server has it and the account may ask", async () => {
    await boot({ settings: { movie4kEnabled: true } });
    await views.renderRequestTitle(root, "movie/603");
    expect(root.querySelector(".request-4k")).toBeNull();

    vi.resetModules();
    await boot({ settings: { movie4kEnabled: true }, permissions: 32 | seerrPermission("request4KMovie") });
    await views.renderRequestTitle(root, "movie/603");
    expect(root.querySelector(".request-4k")!.textContent).toBe("Ask for the 4K version");
    const box = root.querySelector<HTMLInputElement>(".request-4k-box")!;
    box.checked = true;
    box.dispatchEvent(new Event("change", { bubbles: true }));
    click(askButton());
    await settle();
    expect(sent("POST")[0].body).toEqual({ mediaType: "movie", mediaId: 603, is4k: true });
  });

  it("shows what is left of a quota and stops at none", async () => {
    world.quota = { movie: { days: 7, limit: 5, remaining: 2, restricted: false } };
    await boot();
    await views.renderRequestTitle(root, "movie/603");
    expect(root.querySelector(".request-quota")!.textContent).toBe("2 of 5 requests left this week");
    expect(askButton()!.disabled).toBe(false);

    world.quota = { movie: { days: 7, limit: 5, remaining: 0, restricted: true } };
    await views.renderRequestTitle(root, "movie/603");
    expect(root.querySelector(".request-quota.warn")!.textContent).toBe("0 of 5 requests left this week");
    expect(askButton()!.disabled).toBe(true);
  });

  it("says why when the title can't be read, and offers to try again", async () => {
    await boot();
    await views.renderRequestTitle(root, "movie/1");
    expect(root.querySelector(".state-error h3")!.textContent).toBe("This title didn't load");
    expect(root.querySelector(".state-error p")!.textContent).toBe("Seerr doesn't know that title.");
    world.titles["movie/1"] = matrix({ id: 1, title: "Found After All" });
    click(byText(root, "button", "Try again"));
    await settle();
    expect(root.querySelector(".detail-title")!.textContent).toBe("Found After All");
  });

  it("refuses a route that names no title, and shows the not-connected page without a server", async () => {
    await boot();
    for (const bad of ["", "person/5", "movie/abc", "movie/603/extra", "tv/"]) {
      expect(views.parseRequestRoute(bad)).toBeNull();
    }
    expect(views.parseRequestRoute("tv/1396")).toEqual({ kind: "tv", tmdbId: 1396 });
    await views.renderRequestTitle(root, "person/5");
    expect(root.querySelector(".state h3")!.textContent).toBe("That isn't a title");

    vi.resetModules();
    await boot({ connected: false });
    await views.renderRequestTitle(root, "movie/603");
    expect(root.querySelector(".state h3")!.textContent).toBe("Requests aren't set up");
    expect(sent()).toEqual([]);
  });
});

/** One of Seerr's permission bits, by name (read from the module under test's
 *  own table would be circular: these are Seerr's numbers). */
function seerrPermission(name: "requestTV" | "request4KMovie"): number {
  return { requestTV: 524_288, request4KMovie: 2048 }[name];
}

describe("a show's request page", () => {
  it("lists the seasons, ticked, and asks for the ones left ticked", async () => {
    await boot();
    await views.renderRequestTitle(root, "tv/1396");
    expect(root.querySelector(".detail-meta")!.textContent).toBe("2008 · Show · 3 seasons");
    // Specials are left out.
    expect(texts(root, ".request-season-name")).toEqual(["Season 1", "Season 2", "Season 3"]);
    expect(texts(root, ".request-season-line")).toEqual(["10 episodes · 2008", "10 episodes · 2009", "10 episodes · 2010"]);
    expect([1, 2, 3].map((n) => season(n).getAttribute("aria-pressed"))).toEqual(["true", "true", "true"]);
    expect(askButton()!.textContent).toBe("Request All Seasons");

    click(season(2));
    expect(season(2).getAttribute("aria-pressed")).toBe("false");
    expect(askButton()!.textContent).toBe("Request 2 Seasons");
    click(season(1));
    expect(askButton()!.textContent).toBe("Request 1 Season");
    click(season(3));
    expect(askButton()!.textContent).toBe("Request 0 Seasons");
    expect(askButton()!.disabled).toBe(true);
    click(season(3));
    click(season(1));
    expect(askButton()!.disabled).toBe(false);

    click(askButton());
    await settle();
    expect(sent("POST")[0].body).toEqual({ mediaType: "tv", mediaId: 1396, is4k: false, seasons: [1, 3] });
    expect(lastToast()).toBe("Requested Breaking Bad. It's waiting for approval.");
    // Back from Seerr: 1 and 3 are asked for, 2 is still open and ticked.
    expect(texts(root, ".request-season-line")).toEqual([
      "10 episodes · 2008 · Waiting for approval",
      "10 episodes · 2009",
      "10 episodes · 2010 · Waiting for approval",
    ]);
    expect(season(1).disabled).toBe(true);
    expect(season(2).getAttribute("aria-pressed")).toBe("true");
    expect(askButton()!.textContent).toBe("Request 1 Season");
    expect(root.querySelector(".request-cancel")).not.toBeNull();
  });

  it("offers only the seasons that are not here or asked for", async () => {
    world.titles["tv/1396"] = show({
      mediaInfo: {
        status: 4,
        jellyfinMediaId: "jf-bb",
        seasons: [{ seasonNumber: 1, status: 5 }],
        requests: [{ id: 3, status: 2, seasons: [{ seasonNumber: 2 }], requestedBy: { id: 99 } }],
      },
    });
    await boot();
    await views.renderRequestTitle(root, "tv/1396");
    expect(root.querySelector(".request-standing")!.textContent).toBe("Some seasons available");
    expect(texts(root, ".request-season-line")).toEqual([
      "10 episodes · 2008 · In your library",
      "10 episodes · 2009 · On its way",
      "10 episodes · 2010",
    ]);
    expect([1, 2, 3].map((n) => season(n).disabled)).toEqual([true, true, false]);
    expect(askButton()!.textContent).toBe("Request 1 Season");
    // Partly here: the library's copy opens too, but asking is the main thing.
    const open = root.querySelector(".request-open")!;
    expect(open.classList.contains("primary")).toBe(false);
  });

  it("asks for a show whole where the server doesn't take seasons one at a time", async () => {
    await boot({ settings: { partialRequestsEnabled: false } });
    await views.renderRequestTitle(root, "tv/1396");
    expect([1, 2, 3].map((n) => season(n).disabled)).toEqual([true, true, true]);
    expect(askButton()!.textContent).toBe("Request All Seasons");
    click(askButton());
    await settle();
    expect(sent("POST")[0].body.seasons).toEqual([1, 2, 3]);
  });

  it("has nothing to ask for once every season is here", async () => {
    world.titles["tv/1396"] = show({
      mediaInfo: { status: 5, jellyfinMediaId: "jf-bb", seasons: [1, 2, 3].map((n) => ({ seasonNumber: n, status: 5 })) },
    });
    await boot();
    await views.renderRequestTitle(root, "tv/1396");
    expect(askButton()).toBeNull();
    expect(root.querySelector(".request-open.primary")).not.toBeNull();
  });
});

describe("Search, carried on past the library", () => {
  type Lib = typeof import("../../src/views/library");
  let lib: Lib;
  let found: any[];

  async function search(term: string): Promise<void> {
    mockJellyfin([
      [/^\/Items\?/, (a: JfArgs) => (query(a.path).get("searchTerm") != null ? { Items: found, TotalRecordCount: found.length } : { Items: [] })],
    ]);
    lib = await import("../../src/views/library");
    await lib.renderSearch(root, term);
  }
  const shelf = (): Element | null => root.querySelector('[data-shelf="search"]');

  beforeEach(() => {
    found = [];
    world.search = [
      { id: 603, mediaType: "movie", title: "The Matrix", releaseDate: "1999-03-31" },
      { id: 604, mediaType: "movie", title: "The Matrix Reloaded", mediaInfo: { status: 5, jellyfinMediaId: "jf-r" } },
      { id: 5, mediaType: "person", name: "Matrix Person" },
      { id: 2344, mediaType: "collection", title: "The Matrix Collection" },
      { id: 700, mediaType: "tv", name: "Matrix: The Series", mediaInfo: { status: 3 } },
    ];
  });

  it("adds what isn't here under 'No results', after the search has been still a moment", async () => {
    await boot();
    await search("the matrix!");
    expect(root.querySelector(".state h3")!.textContent).toContain("No results");
    // Debounced: nothing has left the house yet.
    expect(sent()).toEqual([]);
    await waitFor(() => shelf() != null, 3000);
    expect(sent().map((a) => a.path)).toEqual(["/search?query=the%20matrix%21&page=1"]);
    expect(shelf()!.querySelector("h2")!.textContent).toBe("Not in Your Library");
    expect(shelf()!.querySelector(".request-shelf-sub")!.textContent).toBe("Open one to request it.");
    // Films and shows that are not already available; no people, no collections.
    expect(texts(shelf()!, ".card-title")).toEqual(["The Matrix", "Matrix: The Series"]);
    expect(shelf()!.querySelector('[data-seerr="tv-700"] .request-badge')!.textContent).toBe("On its way");
    // Under the empty state, not instead of it.
    expect(root.querySelector(".state")!.compareDocumentPosition(shelf()!) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });

  it("adds it under the library's own results too", async () => {
    found = [{ Id: "m1", Type: "Movie", Name: "The Matrix Revolutions", ImageTags: {}, UserData: {} }];
    await boot();
    await search("matrix");
    expect(texts(root, ".card-grid .card-title")).toEqual(["The Matrix Revolutions"]);
    await waitFor(() => shelf() != null, 3000);
    expect(root.querySelector(".card-grid")!.compareDocumentPosition(shelf()!) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });

  it("draws nothing when everything Seerr found is already here", async () => {
    world.search = [world.search[1], world.search[2]];
    await boot();
    await search("matrix");
    await waitFor(() => sent().length === 1, 3000);
    await settle();
    expect(shelf()).toBeNull();
  });

  it("is not asked for a term a keystroke has already replaced", async () => {
    await boot();
    await search("matr");
    await search("matrix");
    await waitFor(() => shelf() != null, 3000);
    expect(sent().map((a) => a.path)).toEqual(["/search?query=matrix&page=1"]);
  });

  it("is not there at all without a Seerr server, or for a single letter", async () => {
    await boot({ connected: false });
    expect(views.seerrSearchSection("matrix")).toBeNull();
    await search("matrix");
    expect(root.querySelector(".seerr-search")).toBeNull();

    vi.resetModules();
    await boot();
    expect(views.seerrSearchSection(" m ")).toBeNull();
    expect(views.seerrSearchSection("ma")).not.toBeNull();
  });

  it("leaves Search as it was when Seerr can't be asked", async () => {
    await boot();
    onInvoke("seerr_request", () => {
      throw "unreachable|Can't reach Seerr at seerr.test";
    });
    await search("matrix");
    await waitFor(() => invokeCalls("seerr_request").length === 1, 3000);
    await settle();
    expect(shelf()).toBeNull();
    expect(root.querySelector(".state h3")!.textContent).toContain("No results");
    expect(toasts()).toEqual([]);
  });
});

describe("what a library page gains", () => {
  const series = (extra: Record<string, any> = {}): any => ({ Id: "s1", Type: "Series", Name: "Breaking Bad", ProviderIds: { Tmdb: "1396" }, ...extra });

  it("tells a show's page which seasons exist that aren't here", async () => {
    world.titles["tv/1396"] = show({ mediaInfo: { status: 4, seasons: [{ seasonNumber: 1, status: 5 }] } });
    await boot();
    const box = views.seerrItemHooks(series())!;
    root.append(box);
    await settle();
    expect(box.querySelector(".seerr-more-title")!.textContent).toBe("2 more seasons exist");
    expect(box.querySelector(".seerr-more-sub")!.textContent).toBe("Seasons 2 and 3 aren't in your library.");
    click(byText(box, "button", "Request…"));
    expect(location.hash).toBe("#/request/tv/1396");
  });

  it("says it in the singular for one", async () => {
    world.titles["tv/1396"] = show({ mediaInfo: { status: 4, seasons: [{ seasonNumber: 1, status: 5 }, { seasonNumber: 2, status: 5 }] } });
    await boot();
    const box = views.seerrItemHooks(series())!;
    await settle();
    expect(box.querySelector(".seerr-more-title")!.textContent).toBe("1 more season exists");
    expect(box.querySelector(".seerr-more-sub")!.textContent).toBe("Season 3 isn't in your library.");
  });

  it("draws nothing when nothing is missing, and remembers the answer for next time", async () => {
    world.titles["tv/1396"] = show({ mediaInfo: { status: 5, seasons: [1, 2, 3].map((n) => ({ seasonNumber: n, status: 5 })) } });
    await boot();
    const box = views.seerrItemHooks(series())!;
    await settle();
    expect(box.children.length).toBe(0);

    // A season has since been removed from the library: the cached answer
    // (nothing) is what paints first, and the fresh one replaces it.
    world.titles["tv/1396"].mediaInfo.seasons.pop();
    const next = views.seerrItemHooks(series())!;
    expect(next.children.length).toBe(0);
    await settle();
    expect(next.querySelector(".seerr-more-sub")!.textContent).toBe("Season 3 isn't in your library.");
    // And that one is there at once on the visit after.
    expect(views.seerrItemHooks(series())!.querySelector(".seerr-more-title")).not.toBeNull();
  });

  it("is absent without a Seerr server, without a TMDB id, and for other kinds of item", async () => {
    await boot();
    expect(views.seerrItemHooks(series({ ProviderIds: { Imdb: "tt1" } }))).toBeNull();
    expect(views.seerrItemHooks(series({ ProviderIds: undefined }))).toBeNull();
    expect(views.seerrItemHooks({ Id: "m1", Type: "Movie", ProviderIds: { Tmdb: "603" } })).toBeNull();
    expect(sent()).toEqual([]);
    vi.resetModules();
    await boot({ connected: false });
    expect(views.seerrItemHooks(series())).toBeNull();
    expect(sent()).toEqual([]);
  });

  it("shows a collection the films it is missing", async () => {
    world.collections["2344"] = [
      { id: 603, title: "The Matrix", mediaInfo: { status: 5 } },
      { id: 604, title: "The Matrix Reloaded", releaseDate: "2003-05-15" },
      { id: 605, title: "The Matrix Revolutions", mediaInfo: { status: 2 } },
    ];
    await boot();
    const box = views.seerrItemHooks({ Id: "c1", Type: "BoxSet", ProviderIds: { tmdb: "2344" } })!;
    await settle();
    expect(box.querySelector("h2")!.textContent).toBe("Missing From This Collection");
    expect(texts(box, ".card-title")).toEqual(["The Matrix Reloaded", "The Matrix Revolutions"]);
    expect(texts(box, ".card-sub")).toEqual(["2003 · Film", "Film"]);
    click(box.querySelector(".card"));
    expect(location.hash).toBe("#/request/movie/604");
  });

  it("stays empty for a collection Seerr doesn't know", async () => {
    await boot();
    const box = views.seerrItemHooks({ Id: "c1", Type: "BoxSet", ProviderIds: { Tmdb: "9" } })!;
    await settle();
    expect(box.children.length).toBe(0);
  });

  it("appears on the show's own page, between the hero and the seasons", async () => {
    world.titles["tv/1396"] = show({ mediaInfo: { status: 4, seasons: [{ seasonNumber: 1, status: 5 }] } });
    await boot();
    mockJellyfin([
      [/^\/Items\/s1\?/, (a: JfArgs) => {
        expect(query(a.path).get("Fields")).toContain("ProviderIds");
        return series({ ImageTags: {}, UserData: {}, People: [] });
      }],
      [/^\/Shows\/s1\/Seasons/, { Items: [{ Id: "se1", Type: "Season", Name: "Season 1", IndexNumber: 1, SeriesId: "s1" }] }],
      [/.*/, { Items: [] }],
    ]);
    const item = await import("../../src/views/item");
    await item.renderItem(root, "s1");
    await settle();
    const hook = root.querySelector(".seerr-hooks")!;
    expect(hook.querySelector(".seerr-more-title")!.textContent).toBe("2 more seasons exist");
    expect(root.querySelector(".detail-hero")!.compareDocumentPosition(hook) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(hook.compareDocumentPosition(root.querySelector(".season-tabs")!) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });
});

describe("Requests in Settings", () => {
  type Settings = typeof import("../../src/views/seerrSettings");
  let settings: Settings;

  async function block(status: Record<string, any> = {}): Promise<HTMLElement> {
    await boot(status);
    settings = await import("../../src/views/seerrSettings");
    const b = settings.seerrSettingsBlock();
    root.append(b);
    await settle();
    return b;
  }
  const rows = (b: HTMLElement): string[] => texts(b, ".settings-row .lbl");
  const input = (cls: string): HTMLInputElement => dialogEl()!.querySelector<HTMLInputElement>(cls)!;
  const type = (el: HTMLInputElement, value: string): void => {
    el.value = value;
    el.dispatchEvent(new Event("input", { bubbles: true }));
  };
  const go = (): HTMLButtonElement => dialogEl()!.querySelector<HTMLButtonElement>(".seerr-connect-go")!;
  const probed = (extra: Record<string, any> = {}) => ({ server: "https://seerr.test", secure: true, fell_back: false, name: "Requests", settings: {}, ...extra });

  it("offers to connect while nothing is", async () => {
    const b = await block({ connected: false });
    expect(b.querySelector("h3")!.textContent).toBe("Requests");
    expect(rows(b)).toEqual(["Connect to Seerr…"]);
    expect(b.querySelector(".sub")!.textContent).toBe(
      "Seerr takes requests for films and shows the library doesn't have yet. Connect one and they can be asked for from Search and from a Requests page."
    );
  });

  it("connects with one address and no password over https", async () => {
    const b = await block({ connected: false });
    onInvoke("seerr_probe", () => probed());
    onInvoke("seerr_connect", () => {
      world.status = { ...STATUS };
      return { ...STATUS };
    });
    click(b.querySelector(".seerr-connect-button"));
    expect(dialogTitle()).toBe("Connect to Seerr");
    expect(dialogEl()!.textContent).toContain("No password is typed or kept.");
    expect(input(".seerr-connect-address").placeholder).toBe("requests.example.com");
    expect(go().disabled).toBe(true);
    type(input(".seerr-connect-address"), "seerr.test");
    expect(go().disabled).toBe(false);
    click(go());
    await settle();

    expect(invokeCalls("seerr_probe")[0]!.args).toEqual({ address: "seerr.test" });
    expect(invokeCalls("seerr_connect")[0]!.args).toEqual({ server: "https://seerr.test" });
    expect(invokeCalls("seerr_connect_password")).toEqual([]);
    expect(dialogEl()).toBeNull();
    expect(lastToast()).toBe("Connected to Requests. Requests is in the sidebar.");
    expect(rows(b)).toEqual(["Seerr server", "Signed in as", "Connection", "Session", "Disconnect"]);
  });

  it("stops to say so before signing in over plain http", async () => {
    const b = await block({ connected: false });
    onInvoke("seerr_probe", () => probed({ server: "http://seerr.lan:5055", secure: false, fell_back: true }));
    onInvoke("seerr_connect", () => ({ ...STATUS, server: "http://seerr.lan:5055", secure: false }));
    click(b.querySelector(".seerr-connect-button"));
    type(input(".seerr-connect-address"), "seerr.lan:5055");
    click(go());
    await settle();
    expect(invokeCalls("seerr_connect")).toEqual([]);
    expect(dialogEl()!.querySelector(".seerr-connect-insecure")!.textContent).toBe("This connection isn't encrypted");
    expect(dialogEl()!.textContent).toContain(
      "Requests answered at http://seerr.lan:5055 over plain http. Anyone on the network between this device and that server could read what is sent, including the session Aquarium signs in with. That is fine on a home network you trust, and not anywhere else."
    );
    expect(go().textContent).toBe("Connect Anyway");
    click(go());
    await settle();
    expect(invokeCalls("seerr_connect")[0]!.args).toEqual({ server: "http://seerr.lan:5055" });
    expect(dialogEl()).toBeNull();
  });

  it("can be backed out of at the warning with nothing sent", async () => {
    const b = await block({ connected: false });
    onInvoke("seerr_probe", () => probed({ server: "http://seerr.lan", secure: false }));
    click(b.querySelector(".seerr-connect-button"));
    type(input(".seerr-connect-address"), "seerr.lan");
    click(go());
    await settle();
    click(dialogEl()!.querySelector(".seerr-connect-cancel"));
    expect(dialogEl()).toBeNull();
    expect(invokeCalls("seerr_connect")).toEqual([]);
    expect(rows(b)).toEqual(["Connect to Seerr…"]);
  });

  it("asks for the Jellyfin password only when there is no Quick Connect, and sends it once", async () => {
    const b = await block({ connected: false });
    onInvoke("seerr_probe", () => probed());
    onInvoke("seerr_connect", () => {
      throw "quickconnect|This Seerr server can't sign in with Quick Connect. Use your Jellyfin user name and password instead.";
    });
    let attempts = 0;
    onInvoke("seerr_connect_password", () => {
      if (attempts++ === 0) throw "message|That user name or password isn't right.";
      return { ...STATUS };
    });
    click(b.querySelector(".seerr-connect-button"));
    type(input(".seerr-connect-address"), "seerr.test");
    click(go());
    await settle();

    expect(dialogEl()!.textContent).toContain(
      "Requests can't sign in with Quick Connect, so it needs your Jellyfin user name and password. They are sent to it once, encrypted, and not kept on this device."
    );
    // The Jellyfin account's own name is filled in.
    expect(input(".seerr-connect-username").value).toBe("tester");
    expect(input(".seerr-connect-password").type).toBe("password");
    expect(go().textContent).toBe("Sign In");
    type(input(".seerr-connect-password"), "wrong");
    click(go());
    await settle();
    expect(dialogEl()!.querySelector(".seerr-connect-error")!.textContent).toBe("That user name or password isn't right.");
    // The form is drawn again empty: the typed password is not kept.
    expect(input(".seerr-connect-password").value).toBe("");
    type(input(".seerr-connect-password"), "hunter2");
    click(go());
    await settle();
    expect(invokeCalls("seerr_connect_password").map((c) => c.args)).toEqual([
      { server: "https://seerr.test", username: "tester", password: "wrong" },
      { server: "https://seerr.test", username: "tester", password: "hunter2" },
    ]);
    expect(dialogEl()).toBeNull();
    expect(document.body.innerHTML).not.toContain("hunter2");
  });

  it("says what was wrong with an address and lets it be corrected", async () => {
    const b = await block({ connected: false });
    onInvoke("seerr_probe", () => {
      throw "message|That address answered, but not as a Seerr server.";
    });
    click(b.querySelector(".seerr-connect-button"));
    type(input(".seerr-connect-address"), "jellyfin.test");
    click(go());
    await settle();
    expect(dialogEl()!.querySelector(".seerr-connect-error")!.textContent).toBe("That address answered, but not as a Seerr server.");
    expect(input(".seerr-connect-address").value).toBe("jellyfin.test");
    expect(go().disabled).toBe(false);
  });

  it("shows where it is connected, as whom, how, and where the session is kept", async () => {
    const b = await block();
    expect(rows(b)).toEqual(["Seerr server", "Signed in as", "Connection", "Session", "Disconnect"]);
    expect(b.querySelector(".seerr-settings-server")!.textContent).toBe("seerr.test");
    expect(b.querySelector(".seerr-settings-user")!.textContent).toBe("Ann");
    expect(b.querySelector(".seerr-settings-connection")!.textContent).toBe("HTTPS");
    expect(b.querySelector(".seerr-settings-connection")!.classList.contains("ok")).toBe(true);
    expect(b.querySelector(".seerr-settings-session")!.textContent).toBe("Keyring");
    expect(b.textContent).toContain("Only Seerr's session is kept, in the keyring beside your Jellyfin sign-in; no password is stored.");
  });

  it("is plain about http and about a session kept in a file", async () => {
    const b = await block({ secure: false, storage: "file" });
    expect(b.querySelector(".seerr-settings-connection")!.textContent).toBe("HTTP");
    expect(b.querySelector(".seerr-settings-connection")!.classList.contains("warn")).toBe(true);
    expect(b.querySelector(".seerr-settings-session")!.textContent).toBe("Config file");
    expect(b.querySelector(".seerr-settings-session")!.classList.contains("warn")).toBe(true);
  });

  it("offers Reconnect when the session has run out", async () => {
    const b = await block({ needs_reconnect: true });
    expect(b.querySelector(".seerr-settings-session")!.textContent).toBe("Run out");
    expect(rows(b)).toContain("Reconnect");
    onInvoke("seerr_reconnect", () => {
      throw "quickconnect|This Seerr server can't sign in with Quick Connect. Use your Jellyfin user name and password instead.";
    });
    click(b.querySelector(".seerr-reconnect-button"));
    await settle();
    expect(b.querySelector(".seerr-settings-error")!.textContent).toContain("can't sign in with Quick Connect");
    onInvoke("seerr_reconnect", () => ({ ...STATUS }));
    click(b.querySelector(".seerr-reconnect-button"));
    await settle();
    expect(b.querySelector(".seerr-settings-session")!.textContent).toBe("Keyring");
    expect(rows(b)).not.toContain("Reconnect");
    expect(b.querySelector(".seerr-settings-error")).toBeNull();
  });

  it("disconnects only after asking", async () => {
    const b = await block();
    onInvoke("seerr_disconnect", () => {
      world.status = { connected: false };
      return { connected: false };
    });
    click(b.querySelector(".seerr-disconnect-button"));
    expect(dialogTitle()).toBe("Disconnect from Seerr?");
    expect(dialogEl()!.textContent).toContain(
      "Requests you have already made stay on the server. This device stops showing them until you connect again."
    );
    expect(dialogButtons()).toEqual(["Cancel", "Disconnect"]);
    await pickDialog("Cancel");
    expect(invokeCalls("seerr_disconnect")).toEqual([]);
    click(b.querySelector(".seerr-disconnect-button"));
    await pickDialog("Disconnect");
    await settle();
    expect(invokeCalls("seerr_disconnect").length).toBe(1);
    expect(rows(b)).toEqual(["Connect to Seerr…"]);
    expect(seerr.isConnected()).toBe(false);
  });
});
