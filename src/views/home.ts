import * as api from "../api";
import { playItem } from "../playback";
import {
  el,
  clear,
  section,
  cardRow,
  skeletonRow,
  backdropLayer,
  attachContextMenu,
  itemActions,
  emptyState,
  icon,
  heroTitle,
  ambientTint,
} from "../ui";
import { favoritesRow } from "./favorites";
import { getCached, setCached, itemSignature } from "../cache";

const CACHE_KEY = "home";

interface HomeData {
  resume: any[];
  nextUp: any[];
  favorites: any[];
  mediaViews: any[];
  /** Only libraries whose Latest row came back non-empty. */
  latest: Map<string, any[]>;
}

const MEDIA_COLLECTION_TYPES = ["movies", "tvshows", "homevideos", "musicvideos", null, undefined];

function homeSignature(d: HomeData): string {
  return [
    itemSignature(d.resume),
    itemSignature(d.nextUp),
    itemSignature(d.favorites),
    [...d.latest.entries()].map(([id, items]) => `${id}=${itemSignature(items)}`).join("|"),
  ].join("#");
}

async function fetchHomeData(): Promise<HomeData> {
  const [resume, nextUp, views, favorites] = await Promise.all([
    api.getResume().catch(() => []),
    api.getNextUp().catch(() => []),
    api.getViews().catch(() => []),
    favoritesRow().catch(() => []),
  ]);
  const mediaViews = views.filter((v: any) => MEDIA_COLLECTION_TYPES.includes(v.CollectionType));
  const pairs = await Promise.all(
    mediaViews.map(
      async (v: any) => [v.Id, await api.getLatest(v.Id).catch(() => [])] as [string, any[]]
    )
  );
  const latest = new Map(pairs.filter(([, items]) => items.length));
  return { resume, nextUp, favorites, mediaViews, latest };
}

/**
 * The spotlight at the top of Home: whatever the user is most likely to press
 * play on, shown at full width with its own artwork. Returns null when the
 * candidate has no backdrop — a hero with no art is worse than no hero.
 */
function homeHero(item: any, eyebrow: string): HTMLElement | null {
  // Episodes rarely carry their own backdrop; the series' one stands in.
  const source = item.BackdropImageTags?.length
    ? item
    : item.ParentBackdropItemId
      ? { Id: item.ParentBackdropItemId, BackdropImageTags: item.ParentBackdropImageTags ?? [] }
      : item;
  const backdrop = api.imageUrl(source, "Backdrop", 1600);
  if (!backdrop) return null;

  const isEpisode = item.Type === "Episode";
  const title = isEpisode ? item.SeriesName ?? item.Name : item.Name;
  const s = item.ParentIndexNumber;
  const e = item.IndexNumber;
  const sub = isEpisode
    ? [s != null && e != null ? `S${s}:E${e}` : null, item.Name].filter(Boolean).join(" · ")
    : "";

  const resumeTicks = item.UserData?.PlaybackPositionTicks ?? 0;
  const pct =
    resumeTicks && item.RunTimeTicks
      ? Math.min(100, (resumeTicks / item.RunTimeTicks) * 100)
      : 0;

  const meta = [
    item.ProductionYear ? String(item.ProductionYear) : null,
    item.RunTimeTicks ? api.ticksToText(item.RunTimeTicks) : null,
    item.OfficialRating ?? null,
  ].filter(Boolean);
  const rating = item.CommunityRating ? item.CommunityRating.toFixed(1) : null;

  const hero = el("div", { class: "home-hero" }, [
    backdropLayer(backdrop, "hero-bg"),
    el("div", { class: "hero-inner" }, [
      el("div", { class: "hero-eyebrow" }, [eyebrow]),
      heroTitle(item, title ?? "", "hero-title"),
      sub ? el("div", { class: "hero-sub" }, [sub]) : null,
      meta.length || rating
        ? el("div", { class: "hero-meta" }, [
            meta.join("  ·  "),
            rating
              ? el("span", { class: "meta-rating" }, [
                  meta.length ? "  ·  " : "",
                  icon("star"),
                  rating,
                ])
              : null,
          ])
        : null,
      pct > 1
        ? el("div", { class: "hero-progress" }, [el("div", { style: `width:${pct}%` })])
        : null,
      item.Overview ? el("p", { class: "hero-overview" }, [item.Overview]) : null,
      el("div", { class: "hero-actions" }, [
        el("button", {
          class: "btn primary",
          onClick: () => playItem(item, { resume: resumeTicks > 0 }),
        }, [
          icon("play"),
          resumeTicks > 0
            ? `Resume · ${api.ticksToText(item.RunTimeTicks - resumeTicks)} left`
            : "Play",
        ]),
        el("button", {
          class: "btn",
          onClick: () => {
            location.hash = `#/item/${item.Id}`;
          },
        }, ["Details"]),
      ]),
    ]),
  ]);
  attachContextMenu(hero, item.Name ?? null, () => itemActions(item, { includeDetails: true }));
  // The artwork's own colour bleeds out of the bottom of the hero into the page.
  ambientTint(hero, backdrop);
  return hero;
}

/** How long a spotlight holds before the next one takes over. */
const HERO_DWELL = 9000;

/**
 * The spotlight, cycling. A home page whose hero shows the same title every
 * time you open it is a list with a picture on top; rotating a handful of picks
 * is what makes it read as a front page — it's the Netflix billboard and the
 * Apple TV top shelf.
 *
 * Rotation pauses while the pointer or the keyboard is inside the hero, because
 * the artwork changing under a button you were about to press is the one thing
 * a rotator must never do — and while nobody can see it, because a full-screen
 * crossfade of a backdrop image is not something to do for an empty room.
 */
function heroRotator(items: any[], eyebrow: string): HTMLElement | null {
  const slides = items
    .map((item) => ({ item, node: homeHero(item, eyebrow) }))
    .filter((s) => s.node);
  if (!slides.length) return null;
  const first = slides[0]!.node!;
  if (slides.length === 1) return first;

  const stage = el("div", { class: "hero-stage" });
  for (const s of slides) {
    s.node!.classList.add("hero-slide");
    stage.append(s.node!);
  }
  first.classList.add("on");

  const dots = el("div", { class: "hero-dots" });
  let at = 0;
  let timer = 0;

  const show = (i: number): void => {
    if (i === at) return;
    slides[at]?.node?.classList.remove("on");
    at = i;
    slides[at]?.node?.classList.add("on");
    dots.querySelectorAll("button").forEach((b, n) => {
      b.classList.toggle("on", n === at);
      b.setAttribute("aria-current", n === at ? "true" : "false");
    });
  };

  slides.forEach((s, i) => {
    const name = s.item.SeriesName ?? s.item.Name ?? `Item ${i + 1}`;
    dots.append(
      el("button", {
        class: i === 0 ? "on" : null,
        "aria-label": `Show ${name}`,
        "aria-current": i === 0 ? "true" : "false",
        onClick: () => {
          show(i);
          // A deliberate pick resets the clock rather than being overtaken a
          // moment later by the rotation that was already in flight.
          restart();
        },
      })
    );
  });
  stage.append(dots);

  const stop = (): void => {
    if (timer) window.clearInterval(timer);
    timer = 0;
  };
  /**
   * Nobody is looking at this: the window isn't on screen, or something is
   * playing. An embedded player covers the page completely, and playback
   * started from a Continue Watching row leaves this view mounted underneath —
   * where it would otherwise go on crossfading full-screen artwork behind an
   * opaque video for the length of a film.
   */
  const unseen = (): boolean =>
    document.hidden || !!document.getElementById("content")?.classList.contains("has-player");

  const restart = (): void => {
    stop();
    timer = window.setInterval(() => {
      // The page this belongs to is gone; nothing left to rotate.
      if (!document.contains(stage)) return stop();
      if (unseen()) return;
      if (stage.matches(":hover") || stage.contains(document.activeElement)) return;
      show((at + 1) % slides.length);
    }, HERO_DWELL);
  };
  restart();

  return stage;
}

/** Everything below the topbar. Rebuilt wholesale on the first paint of a
 *  session and on any later paint whose data actually changed — the common
 *  case, a revisit with nothing new, never reaches this at all. */
function paintHome(page: HTMLElement, data: HomeData): void {
  clear(page);
  const { resume, nextUp, favorites, mediaViews, latest } = data;

  // The spotlight is Next Up: the episode each show in progress is waiting
  // on. Continue Watching keeps its own row below; it only stands in up here
  // when nothing is queued at all (a movies-only account, say), because a
  // hero with something to play beats no hero. The plain "Home" title is the
  // last fallback, for when none of them has usable artwork.
  const seen = new Set<string>();
  const fromNextUp = nextUp.length > 0;
  const picks = (fromNextUp ? nextUp : resume)
    .filter((i: any) => i?.Id && !seen.has(i.Id) && seen.add(i.Id))
    .slice(0, 5);
  const hero = heroRotator(picks, fromNextUp ? "Next up" : "Continue watching");
  page.append(hero ?? el("h1", { class: "page-title" }, ["Home"]));

  if (resume.length) {
    page.append(section("Continue Watching", cardRow(resume, { wide: true })));
  }
  if (nextUp.length) {
    page.append(section("Next Up", cardRow(nextUp, { wide: true })));
  }
  // Starred items, newest first — the row is the shortcut, the Favorites page
  // is the whole list.
  if (favorites.length) {
    page.append(
      section("Favorites", cardRow(favorites), () => {
        location.hash = "#/favorites";
      })
    );
  }

  for (const view of mediaViews) {
    const items = latest.get(view.Id);
    if (!items?.length) continue;
    page.append(
      section(`Latest in ${view.Name}`, cardRow(items), () => {
        location.hash = `#/lib/${view.Id}`;
      })
    );
  }

  if (!resume.length && !nextUp.length && !favorites.length && !latest.size) {
    page.append(
      emptyState({
        icon: "library",
        title: "Nothing to watch yet",
        body: "Your Jellyfin libraries came back empty. Add media on the server and run a library scan — it'll show up here.",
        action: { label: "Open Settings", run: () => (location.hash = "#/settings") },
      })
    );
  }
}

export async function renderHome(root: HTMLElement): Promise<void> {
  clear(root);
  const page = el("div", {});
  root.append(page);

  // A revisit — or a cold start, since the cache is persisted across runs —
  // paints the last known Home instantly — no skeleton, no blank page — while
  // the real request runs behind it, only touching the screen again if
  // something actually changed. The very first Home ever, on this account,
  // has nothing to show yet, so it falls back to a skeleton shaped like the
  // page that's about to arrive.
  const cached = getCached<HomeData>(CACHE_KEY);
  if (cached) {
    paintHome(page, cached);
  } else {
    page.append(
      el("div", { class: "home-hero skeleton sk-box" }),
      section("Continue Watching", skeletonRow(5, { wide: true })),
      section("Latest", skeletonRow(7))
    );
  }

  const data = await fetchHomeData();
  // Navigated away while loading.
  if (!document.contains(page)) return;
  if (!cached || homeSignature(cached) !== homeSignature(data)) {
    paintHome(page, data);
  }
  setCached(CACHE_KEY, data);
}
