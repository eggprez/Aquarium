import * as api from "../api";
import {
  playItem,
  startDownload,
  downloadSeason,
  downloadSeries,
  QUALITY_CHOICES,
} from "../playback";
import {
  el,
  clear,
  art,
  backdropLayer,
  openMenu,
  toast,
  attachContextMenu,
  itemActions,
  downloadLabel,
  emptyState,
  errorState,
  skeletonDetail,
  skeletonRow,
  skeletonRows,
  scrollRow,
  section,
  cardRow,
  icon,
  noartIcon,
  heroTitle,
  ambientTint,
} from "../ui";
import { getCached, setCached, itemSignature } from "../cache";

interface ItemData {
  item: any;
  seasons: any[];
  playTarget: any;
}

const itemCacheKey = (id: string): string => `item:${id}`;

/**
 * Fetches everything a detail page needs and caches it under the item's id.
 * Exported so a card can warm this before it's ever clicked — see
 * `prefetch.ts`, which calls this while a card sits under keyboard focus or
 * the pointer, so pressing Enter usually finds the page already in cache.
 *
 * Deduplicated: a prefetch and the page's own load landing on the same id at
 * nearly the same moment share one request rather than firing two.
 */
const inFlight = new Map<string, Promise<ItemData>>();

export function fetchItemData(itemId: string): Promise<ItemData> {
  const existing = inFlight.get(itemId);
  if (existing) return existing;
  const p = (async (): Promise<ItemData> => {
    const item = await api.getItem(itemId);
    // A series needs its seasons and its next episode before the hero can be
    // drawn, so both are fetched here and the page paints in one go rather
    // than growing a play button a second after the artwork.
    let seasons: any[] = [];
    let playTarget: any = null;
    if (item.Type === "Series") {
      // Seasons and Next Up don't depend on each other, so they go out
      // together rather than chaining another round trip onto the hero.
      const [seasonList, nextUp] = await Promise.all([
        api.getSeasons(item.Id).catch(() => []),
        api.getSeriesNextUp(item.Id).catch(() => null),
      ]);
      seasons = seasonList;
      playTarget = nextUp ?? (await firstUnplayedEpisode(item.Id, seasons));
    }
    const data: ItemData = { item, seasons, playTarget };
    setCached(itemCacheKey(itemId), data);
    return data;
  })().finally(() => inFlight.delete(itemId));
  inFlight.set(itemId, p);
  return p;
}

function itemDataSignature(d: ItemData): string {
  return itemSignature([d.item, d.playTarget, ...d.seasons]);
}

function metaChips(item: any): HTMLElement {
  const bits: (HTMLElement | string)[] = [];
  if (item.ProductionYear) bits.push(el("span", {}, [String(item.ProductionYear)]));
  if (item.RunTimeTicks) bits.push(el("span", {}, [api.ticksToText(item.RunTimeTicks)]));
  if (item.OfficialRating) bits.push(el("span", { class: "chip" }, [item.OfficialRating]));
  if (item.CommunityRating) {
    bits.push(el("span", { class: "meta-rating" }, [icon("star"), item.CommunityRating.toFixed(1)]));
  }
  for (const g of (item.Genres ?? []).slice(0, 4)) bits.push(el("span", { class: "chip" }, [g]));
  return el("div", { class: "detail-meta" }, bits);
}

/**
 * What the file on the server actually is — "1080p · HEVC · EAC3 · 5.1 · 8.4
 * GiB". The Quality menu right below it offers a bitrate ladder; without this
 * there was nothing on the page saying what the ladder was measured against.
 */
function sourceLine(item: any): HTMLElement | null {
  const bits = api.mediaSummary(item);
  return bits.length ? el("div", { class: "detail-source" }, [bits.join(" · ")]) : null;
}

/** "Directed by …", "Written by …" — one line, from the People list. */
function crewLine(people: any[]): HTMLElement | null {
  const names = (type: string): string[] =>
    people.filter((p) => p.Type === type).map((p) => p.Name).filter(Boolean).slice(0, 3);
  const parts = [
    names("Director").length ? `Directed by ${names("Director").join(", ")}` : null,
    names("Writer").length ? `Written by ${names("Writer").join(", ")}` : null,
  ].filter(Boolean);
  return parts.length ? el("div", { class: "detail-crew" }, [parts.join("  ·  ")]) : null;
}

/** One cast member: headshot, name, and the part they played. */
function personCard(p: any): HTMLElement {
  const img = p.PrimaryImageTag
    ? api.imageUrl({ Id: p.Id, PrimaryImageTag: p.PrimaryImageTag }, "Primary", 240)
    : null;
  // There's no person route in the app, so the name searches for itself —
  // which is what you actually want from a cast list anyway.
  return el(
    "div",
    {
      class: "person-card",
      role: "button",
      tabindex: "0",
      "aria-label": `Search for ${p.Name}`,
      onClick: () => {
        location.hash = `#/search/${encodeURIComponent(p.Name)}`;
      },
      onKeydown: (ev: KeyboardEvent) => {
        if (ev.key !== "Enter" && ev.key !== " ") return;
        ev.preventDefault();
        location.hash = `#/search/${encodeURIComponent(p.Name)}`;
      },
    },
    [
      el("div", { class: "person-photo" }, [art(img, () => noartIcon("people", 26))]),
      el("div", { class: "person-name" }, [p.Name ?? ""]),
      el("div", { class: "person-role" }, [p.Role ? `as ${p.Role}` : p.Type ?? ""]),
    ]
  );
}

/**
 * Everything below the hero. A movie's page used to stop at the play buttons
 * and leave the rest of the window empty; a series at least had its seasons.
 * Cast comes off the item we already loaded, so it paints immediately —
 * "More like this" is a second request and lands when it lands.
 */
function detailExtras(root: HTMLElement, item: any): void {
  const cast = (item.People ?? []).filter(
    (p: any) => p.Type === "Actor" || p.Type === "GuestStar"
  );
  if (cast.length) {
    root.append(
      section("Cast", scrollRow(el("div", { class: "card-row" }, cast.slice(0, 24).map(personCard))))
    );
  }

  const slot = section("More like this", skeletonRow(7));
  root.append(slot);
  void api
    .getSimilar(item.Id)
    .then((items) => {
      if (!document.contains(slot)) return;
      // No recommendations is the common case for a thin library; the section
      // disappears rather than sitting there empty.
      if (!items.length) slot.remove();
      else slot.replaceWith(section("More like this", cardRow(items)));
    })
    .catch(() => slot.remove());
}

function playButtons(item: any): HTMLElement {
  const actions = el("div", { class: "detail-actions" });
  const resumeTicks = item.UserData?.PlaybackPositionTicks ?? 0;

  if (resumeTicks > 0) {
    actions.append(
      el("button", { class: "btn primary", onClick: () => playItem(item, { resume: true }) }, [
        icon("play"),
        `Resume (${api.ticksToText(item.RunTimeTicks - resumeTicks)} left)`,
      ]),
      el("button", { class: "btn", onClick: () => playItem(item, { resume: false }) }, ["Play from start"])
    );
  } else {
    actions.append(
      el("button", { class: "btn primary", onClick: () => playItem(item, { resume: false }) }, [
        icon("play"),
        "Play",
      ])
    );
  }

  // Stream quality menu
  const qWrap = el("div", { class: "menu-wrap" });
  const qBtn = el("button", { class: "btn" }, ["Quality", icon("chevron-down")]);
  qBtn.addEventListener("click", () =>
    openMenu(qBtn, (menu) => {
      menu.append(el("div", { class: "menu-label" }, ["Stream as"]));
      // The same ladder the in-player menu and the adaptive policy use: a
      // second copy here drifted from it the moment either one changed.
      for (const q of QUALITY_CHOICES) {
        menu.append(
          el("button", {
            onClick: () => {
              menu.remove();
              // An explicit bitrate streams even when the item is downloaded.
              playItem(item, { resume: true, maxBitrate: q.maxBitrate }, { stream: true });
            },
          }, [q.label])
        );
      }
    })
  );
  qWrap.append(qBtn);
  actions.append(qWrap);

  // Download menu
  const dWrap = el("div", { class: "menu-wrap" });
  const dBtn = el("button", { class: "btn" }, [icon("download"), "Download", icon("chevron-down")]);
  dBtn.addEventListener("click", () =>
    openMenu(dBtn, (menu) => {
      menu.append(el("div", { class: "menu-label" }, ["Download as"]));
      for (const q of api.DOWNLOAD_QUALITIES) {
        menu.append(
          el("button", {
            onClick: async () => {
              menu.remove();
              try {
                await startDownload(item, q);
              } catch (e: any) {
                toast(`Download failed to start: ${e.message ?? e}`, "error");
              }
            },
          }, [downloadLabel(item, q)])
        );
      }
    })
  );
  dWrap.append(dBtn);
  actions.append(dWrap);

  // Watched toggle
  const watchBtn = el("button", {
    class: "btn",
    onClick: async () => {
      try {
        await api.markPlayed(item.Id, !item.UserData?.Played);
        item.UserData = item.UserData ?? {};
        item.UserData.Played = !item.UserData.Played;
        syncWatchBtn();
      } catch (e: any) {
        toast(e.message ?? String(e), "error");
      }
    },
  });
  // The label carries an icon now, so it's rebuilt rather than assigned to.
  const syncWatchBtn = (): void => {
    const on = !!item.UserData?.Played;
    watchBtn.title = on ? "Mark unwatched" : "Mark watched";
    watchBtn.replaceChildren(...(on ? [icon("check"), "Watched"] : ["Mark watched"]));
  };
  syncWatchBtn();
  actions.append(watchBtn);
  // Right-clicking the hero reaches everything else (favorites, go to series…).
  (actions as any).__syncWatchLabel = syncWatchBtn;

  return actions;
}

/**
 * Drift the backdrop against the page as it scrolls. The detail page opens as a
 * full-width still and then turns into a list; without this the artwork slides
 * away at exactly the speed of the text on top of it, and the whole thing reads
 * as one flat sheet moving. At 0.4× the backdrop hangs back and the page comes
 * over it.
 *
 * The listener retires itself once the hero is gone, which is how a view that
 * never gets an explicit teardown call cleans up after itself.
 */
function attachParallax(hero: HTMLElement, layer: HTMLElement | null): void {
  const content = document.getElementById("content");
  if (!layer || !content) return;
  if (window.matchMedia?.("(prefers-reduced-motion: reduce)").matches) return;
  const onScroll = (): void => {
    if (!document.contains(hero)) {
      content.removeEventListener("scroll", onScroll);
      return;
    }
    // Capped: past the height of the hero there's nothing left to reveal, and
    // an uncapped offset would drag the image out of its own frame.
    const y = Math.min(content.scrollTop, 260);
    layer.style.transform = `translate3d(0, ${(y * 0.4).toFixed(1)}px, 0)`;
  };
  content.addEventListener("scroll", onScroll, { passive: true });
  onScroll();
}

/** "S2E4", or "" when the episode carries no numbering. */
function epCode(ep: any): string {
  const s = ep.ParentIndexNumber, e = ep.IndexNumber;
  return s != null && e != null ? `S${s}E${e}` : "";
}

/**
 * Fallback for the series play button when the server's Next Up is empty — a
 * show that was never started, or one it considers finished. Picks the first
 * unwatched episode of the first season, else that season's opener.
 */
async function firstUnplayedEpisode(seriesId: string, seasons: any[]): Promise<any | null> {
  const first = seasons[0];
  if (!first) return null;
  const eps = await api.getEpisodes(seriesId, first.Id).catch(() => []);
  return eps.find((e: any) => !e.UserData?.Played) ?? eps[0] ?? null;
}

/**
 * Hero actions for a series: a caption naming what's next plus the buttons to
 * start it. Without this a series page is a dead end — you have to pick a
 * season and hunt for the episode you were on.
 */
function seriesHeroActions(target: any | null): (HTMLElement | null)[] {
  if (!target) return [null, el("div", { class: "detail-actions" })];

  const resumeTicks = target.UserData?.PlaybackPositionTicks ?? 0;
  const code = epCode(target);
  const left = resumeTicks > 0 ? api.ticksToText(target.RunTimeTicks - resumeTicks) : "";

  const caption = el("div", { class: "detail-nextup" }, [
    resumeTicks > 0 ? "Resume · " : "Next up · ",
    el("strong", {}, [[code, target.Name].filter(Boolean).join(" · ")]),
    left ? ` — ${left} left` : "",
  ]);

  const actions = el("div", { class: "detail-actions" });
  if (resumeTicks > 0) {
    actions.append(
      el("button", { class: "btn primary", onClick: () => playItem(target, { resume: true }) }, [
        icon("play"),
        `Resume${code ? ` ${code}` : ""}`,
      ]),
      el("button", { class: "btn", onClick: () => playItem(target, { resume: false }) }, [
        "Play from start",
      ])
    );
  } else {
    actions.append(
      el("button", { class: "btn primary", onClick: () => playItem(target, { resume: false }) }, [
        icon("play"),
        `Play${code ? ` ${code}` : ""}`,
      ])
    );
  }
  return [caption, actions];
}

function episodeRow(ep: any): HTMLElement {
  const img = api.imageUrl(ep, "Primary", 400);
  const pct =
    ep.UserData?.PlaybackPositionTicks && ep.RunTimeTicks
      ? Math.min(100, (ep.UserData.PlaybackPositionTicks / ep.RunTimeTicks) * 100)
      : 0;
  const code = ep.IndexNumber != null ? `${ep.IndexNumber}. ` : "";

  const dlBtn = el("button", { class: "btn small icon", title: "Download", "aria-label": "Download" }, [
    icon("download"),
  ]);
  const dlWrap = el("div", { class: "menu-wrap" }, [dlBtn]);
  dlBtn.addEventListener("click", (ev) => {
    ev.stopPropagation();
    openMenu(dlBtn, (menu) => {
      menu.append(el("div", { class: "menu-label" }, ["Download as"]));
      for (const q of api.DOWNLOAD_QUALITIES) {
        menu.append(
          el("button", {
            onClick: () => {
              menu.remove();
              startDownload(ep, q).catch((e) => toast(String(e), "error"));
            },
          }, [downloadLabel(ep, q)])
        );
      }
    });
  });

  const played = !!ep.UserData?.Played;
  // Original air date, in whatever format the desktop is set to. It's the one
  // piece of context that says where an episode sits in a show's life, and the
  // rows had room for it.
  const aired = ep.PremiereDate
    ? new Date(ep.PremiereDate).toLocaleDateString(undefined, {
        day: "numeric",
        month: "short",
        year: "numeric",
      })
    : "";
  const meta = [api.ticksToText(ep.RunTimeTicks), aired].filter(Boolean).join("  ·  ");

  const play = (): void => {
    playItem(ep, { resume: true });
  };

  const row = el("div", {
    // The whole row is the target, the way a card is — the play button and the
    // thumbnail were the only two places a click did anything.
    class: `ep-row${played ? " watched" : ""}`,
    role: "button",
    tabindex: "0",
    "aria-label": `Play ${code}${ep.Name ?? ""}`,
    onKeydown: (ev: KeyboardEvent) => {
      if (ev.key !== "Enter" && ev.key !== " ") return;
      if (ev.target !== ev.currentTarget) return; // a button inside the row
      ev.preventDefault();
      play();
    },
  }, [
    el("div", { class: "ep-thumb", onClick: play }, [
      art(img, () => noartIcon("play")),
      pct > 1
        ? el("div", { class: "progress-strip" }, [el("div", { style: `width:${pct}%` })])
        : null,
      el("div", { class: "play-overlay" }, [el("span", { class: "pbtn" }, [icon("play", 18)])]),
    ]),
    el("div", { class: "ep-body" }, [
      el("h4", {}, [`${code}${ep.Name}`, played ? icon("check", 15) : null]),
      el("p", {}, [ep.Overview ?? ""]),
      el("div", { class: "card-sub" }, [meta]),
    ]),
    el("div", { class: "ep-actions" }, [
      el("button", { class: "btn small primary", onClick: () => playItem(ep, { resume: true }) }, [
        icon("play"),
        "Play",
      ]),
      dlWrap,
    ]),
  ]);
  attachContextMenu(row, ep.Name ?? null, () =>
    itemActions(ep, { onChanged: () => row.replaceWith(episodeRow(ep)), includeDetails: true })
  );
  return row;
}

function seasonDownloadBar(season: any, eps: any[]): HTMLElement {
  const btn = el("button", { class: "btn small" }, [
    icon("download"),
    `Download season · ${eps.length} ep`,
  ]);
  btn.addEventListener("click", () =>
    openMenu(btn, (menu) => {
      menu.append(el("div", { class: "menu-label" }, ["Download all episodes as"]));
      for (const q of api.DOWNLOAD_QUALITIES) {
        const total = eps.reduce((sum, ep) => {
          const e = api.estimateDownloadSize(ep, api.effectiveDownloadQuality(ep, q));
          return e == null ? sum : sum + e;
        }, 0);
        const label = total > 0 ? `${q.label} · ${q.original ? "" : "~"}${api.bytesToText(total)}` : q.label;
        menu.append(
          el("button", {
            onClick: async () => {
              menu.remove();
              try {
                const { queued, skipped, cancelled } = await downloadSeason(eps, q);
                if (cancelled) return;
                if (queued) {
                  toast(
                    `Queued ${queued} episode${queued === 1 ? "" : "s"}` +
                      (skipped ? `, skipped ${skipped} already downloaded` : ""),
                    "ok"
                  );
                } else {
                  toast("All episodes are already downloaded or queued");
                }
              } catch (e: any) {
                toast(`Season download failed: ${e.message ?? e}`, "error");
              }
            },
          }, [label])
        );
      }
    })
  );
  return el("div", { class: "season-actions" }, [
    el("div", { class: "menu-wrap" }, [btn]),
  ]);
}

/** "Download whole show" bar above the season tabs. Episode lists are fetched
 *  lazily (one request per season) only once a quality is picked, so opening a
 *  series page costs nothing extra. */
function seriesDownloadBar(item: any, seasons: any[]): HTMLElement {
  const label = `Download series · ${seasons.length} season${seasons.length === 1 ? "" : "s"}`;
  const btn = el("button", { class: "btn small" }, [icon("download"), label]);

  async function queueWholeSeries(q: api.DownloadQuality): Promise<void> {
    btn.disabled = true;
    btn.textContent = "Collecting episodes…";
    try {
      const { queued, skipped, cancelled } = await downloadSeries(item.Id, q, seasons);
      if (cancelled) return;
      if (queued) {
        toast(
          `Queued ${queued} episode${queued === 1 ? "" : "s"} from ${seasons.length} season${seasons.length === 1 ? "" : "s"}` +
            (skipped ? `, skipped ${skipped} already downloaded` : ""),
          "ok"
        );
      } else {
        toast("Every episode is already downloaded or queued");
      }
    } catch (e: any) {
      toast(`Series download failed: ${e.message ?? e}`, "error");
    } finally {
      btn.disabled = false;
      btn.replaceChildren(icon("download"), label);
    }
  }

  btn.addEventListener("click", () =>
    openMenu(btn, (menu) => {
      menu.append(el("div", { class: "menu-label" }, ["Download every episode as"]));
      for (const q of api.DOWNLOAD_QUALITIES) {
        menu.append(
          el("button", {
            onClick: () => {
              menu.remove();
              void queueWholeSeries(q);
            },
          }, [q.label])
        );
      }
    })
  );

  return el("div", { class: "season-actions" }, [el("div", { class: "menu-wrap" }, [btn])]);
}

/** Everything from the hero down. Rebuilt on the first paint of an item and on
 *  any later paint whose data actually changed — a revisit that found nothing
 *  new never reaches this at all. */
function paintItem(page: HTMLElement, data: ItemData): void {
  clear(page);
  const root = page;
  const { item, seasons, playTarget } = data;

  // Episodes get their series' backdrop for a nicer hero.
  const backdropSource =
    item.BackdropImageTags?.length ? item :
    item.ParentBackdropItemId
      ? { Id: item.ParentBackdropItemId, BackdropImageTags: item.ParentBackdropImageTags ?? [] }
      : item;
  const backdrop = api.imageUrl(backdropSource, "Backdrop", 1600);
  const poster = api.imageUrl(item, "Primary", 500);

  let title = item.Name;
  let subtitle = "";
  if (item.Type === "Episode") {
    title = item.Name;
    const s = item.ParentIndexNumber, e = item.IndexNumber;
    subtitle = `${item.SeriesName ?? ""}${s != null ? ` · Season ${s}` : ""}${e != null ? `, Episode ${e}` : ""}`;
  }

  // Series get "play what's next" buttons; everything else gets the full
  // play/quality/download/watched bar.
  const actionBar = item.Type !== "Series" ? playButtons(item) : null;
  const actionNodes = actionBar ? [actionBar] : seriesHeroActions(playTarget);

  // The backdrop moves, so it gets its own clipping frame. Putting the clip on
  // the hero itself would cut off the Quality and Download dropdowns, which
  // open inside it.
  const backdropLayerEl = backdropLayer(backdrop, "detail-backdrop");
  const hero = el("div", { class: "detail-hero" }, [
    backdropLayerEl ? el("div", { class: "detail-backdrop-clip" }, [backdropLayerEl]) : null,
    el("div", { class: "detail-inner" }, [
      el("div", { class: "detail-poster" }, [art(poster, title ?? "?", { lazy: false })]),
      el("div", { class: "detail-info" }, [
        // An episode's heading is the episode's own name, and the logo art
        // Jellyfin hands back for it is the *series'* — so title art is only
        // right where the heading and the artwork name the same thing.
        item.Type === "Episode"
          ? el("h1", { class: "detail-title" }, [title ?? ""])
          : heroTitle(item, title ?? "", "detail-title"),
        subtitle
          ? el("div", {
              class: "detail-meta clickable",
              onClick: () => { if (item.SeriesId) location.hash = `#/item/${item.SeriesId}`; },
            }, [subtitle])
          : null,
        metaChips(item),
        item.Overview ? el("p", { class: "detail-overview" }, [item.Overview]) : null,
        crewLine(item.People ?? []),
        sourceLine(item),
        ...actionNodes,
      ]),
    ]),
  ]);
  // Right-click anywhere on the hero for the same menu the cards use.
  attachContextMenu(hero, item.Name ?? null, () =>
    itemActions(item, { onChanged: () => (actionBar as any)?.__syncWatchLabel?.() })
  );
  ambientTint(hero, backdrop ?? poster);
  root.append(hero);
  attachParallax(hero, backdropLayerEl);

  if (item.Type !== "Series") {
    detailExtras(root, item);
    return;
  }

  {
    if (!seasons.length) {
      root.append(
        emptyState({
          icon: "episodes",
          title: "No seasons for this show",
          body: "Jellyfin has the series but no episodes filed under it. A library scan on the server usually fixes this.",
        })
      );
      return;
    }
    const tabs = el("div", { class: "season-tabs" });
    const epList = el("div", {});
    root.append(seriesDownloadBar(item, seasons), tabs, epList);

    async function showSeason(season: any, btn: HTMLElement): Promise<void> {
      tabs.querySelectorAll(".btn").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      clear(epList);
      const loading = skeletonRows(5, "ep-row", "ep-thumb");
      epList.append(loading);
      const eps = await api.getEpisodes(item.Id, season.Id).catch(() => []);
      // A faster second click on another season already owns the list.
      if (!document.contains(loading)) return;
      clear(epList);
      if (!eps.length) {
        epList.append(
          emptyState({
            icon: "episodes",
            title: "This season is empty",
            body: `Jellyfin lists ${season.Name ?? "this season"} but has no episodes in it yet.`,
          })
        );
        return;
      }
      epList.append(seasonDownloadBar(season, eps));
      for (const ep of eps) epList.append(episodeRow(ep));
    }

    // Open on the season the play button would start from, so the episode
    // you're actually on is the one on screen.
    const targetSeason = seasons.findIndex((s: any) => s.Id === playTarget?.SeasonId);
    const openIdx = targetSeason >= 0 ? targetSeason : 0;
    seasons.forEach((season: any, idx: number) => {
      const btn = el("button", { class: "btn small" }, [season.Name ?? `Season ${season.IndexNumber}`]);
      btn.addEventListener("click", () => showSeason(season, btn));
      tabs.append(btn);
      if (idx === openIdx) showSeason(season, btn);
    });
  }

  // Cast and recommendations sit below the season list, where they don't push
  // the episodes off the first screen.
  detailExtras(root, item);
}

export async function renderItem(root: HTMLElement, itemId: string): Promise<void> {
  clear(root);
  const page = el("div", {});
  root.append(page);

  // A page reached with its data already cached — a revisit, or a card that
  // sat under focus long enough for `prefetch.ts` to warm it — paints
  // instantly instead of behind a skeleton. Either way the real fetch still
  // runs behind it, so a resume position or a newly aired episode picked up
  // since the cache was written is never more than one visit stale.
  const cached = getCached<ItemData>(itemCacheKey(itemId));
  if (cached) {
    paintItem(page, cached);
  } else {
    page.append(skeletonDetail());
  }

  let data: ItemData;
  try {
    data = await fetchItemData(itemId);
  } catch (e: any) {
    if (!document.contains(page)) return; // navigated away while loading
    if (!cached) {
      clear(page);
      page.append(errorState("This page didn't load", e, () => void renderItem(root, itemId)));
    }
    return;
  }
  if (!document.contains(page)) return; // navigated away while loading
  if (!cached || itemDataSignature(cached) !== itemDataSignature(data)) {
    paintItem(page, data);
  }
}
