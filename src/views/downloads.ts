import { invoke, convertFileSrc } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import * as api from "../api";
import {
  playLocal,
  syncOfflineProgress,
  getQueuedDownloads,
  cancelQueuedDownload,
  type PendingDownload,
} from "../playback";
import { el, clear, spinner, toast } from "../ui";

type Tab = "tv" | "movies" | "queue";

let refreshTimer: number | null = null;
let activeTab: Tab = "tv";
let openSeries: string | null = null;
let openSeason: number | null = null;
let currentRoot: HTMLElement | null = null;
let queueListenerInstalled = false;
let playbackListenerInstalled = false;

// ---------- Helpers ----------

function isEpisode(dl: any): boolean {
  return dl.type === "Episode" || (!!dl.series && dl.type !== "Movie");
}

function completedSub(dl: any): string {
  const s: string[] = [];
  if (dl.quality) s.push(dl.quality);
  if (dl.size_bytes) s.push(api.bytesToText(dl.size_bytes));
  if (dl.played) s.push("watched ✓");
  else if (dl.position_ticks > 0 && dl.run_time_ticks) {
    s.push(`resume at ${api.ticksToText(dl.position_ticks)}`);
  }
  return s.join(" · ");
}

function dlRow(
  posterPath: string | undefined,
  title: string,
  bodyExtra: (Node | null)[],
  actions: HTMLElement,
  posterExtra: (Node | null)[] = []
): HTMLElement {
  return el("div", { class: "dl-row" }, [
    el("div", { class: "dl-poster" }, [
      posterPath ? el("img", { src: convertFileSrc(posterPath) }) : null,
      ...posterExtra,
    ]),
    el("div", { class: "dl-body" }, [el("h4", {}, [title]), ...bodyExtra]),
    actions,
  ]);
}

/**
 * How much of a group of episodes has been watched, 0–1. Played episodes
 * count as 1, an in-progress episode as its fraction — so one episode at 66%
 * already puts a strip on the series/season card.
 */
function watchFraction(eps: any[]): number {
  if (!eps.length) return 0;
  let sum = 0;
  for (const e of eps) {
    if (e.played) sum += 1;
    else if (e.position_ticks > 0 && e.run_time_ticks) {
      sum += Math.min(1, e.position_ticks / e.run_time_ticks);
    }
  }
  return sum / eps.length;
}

/** ✓ badge / watch-progress strip for a downloaded item's poster. */
function watchedOverlay(dl: any): (Node | null)[] {
  const pct =
    !dl.played && dl.position_ticks > 0 && dl.run_time_ticks
      ? Math.min(100, (dl.position_ticks / dl.run_time_ticks) * 100)
      : 0;
  return [
    pct > 1 ? el("div", { class: "progress-strip" }, [el("div", { style: `width:${pct}%` })]) : null,
    dl.played ? el("div", { class: "badge played" }, ["✓"]) : null,
  ];
}

function libCard(opts: {
  posterPath?: string;
  title: string;
  sub: string;
  overlay?: string;
  /** ✓ badge (fully watched). */
  played?: boolean;
  /** 0–100 progress strip along the poster bottom. */
  progressPct?: number | null;
  onOpen: () => void;
  onDelete?: () => void;
}): HTMLElement {
  const pct = opts.progressPct ?? 0;
  const poster = el("div", { class: "card-poster" }, [
    opts.posterPath
      ? el("img", { src: convertFileSrc(opts.posterPath), loading: "lazy", alt: "" })
      : el("div", { class: "noart" }, [opts.title.slice(0, 1).toUpperCase() || "?"]),
    pct > 1 ? el("div", { class: "progress-strip" }, [el("div", { style: `width:${pct}%` })]) : null,
    opts.played ? el("div", { class: "badge played" }, ["✓"]) : null,
    opts.overlay ? el("div", { class: "play-overlay" }, [el("button", { class: "pbtn" }, [opts.overlay])]) : null,
    opts.onDelete
      ? el("button", {
          class: "dl-del-badge",
          title: "Delete download",
          onClick: (ev: MouseEvent) => {
            ev.stopPropagation();
            opts.onDelete!();
          },
        }, ["×"])
      : null,
  ]);
  return el("div", { class: "card", onClick: opts.onOpen }, [
    poster,
    el("div", { class: "card-title" }, [opts.title]),
    el("div", { class: "card-sub" }, [opts.sub]),
  ]);
}

async function deleteDownload(itemId: string, root: HTMLElement): Promise<void> {
  await invoke("download_delete", { itemId });
  toast("Download deleted");
  renderDownloads(root, { keepTab: true });
}

async function deleteMany(eps: any[], root: HTMLElement): Promise<void> {
  for (const ep of eps) {
    await invoke("download_delete", { itemId: ep.item_id }).catch(() => {});
  }
  toast(`Deleted ${eps.length} download${eps.length === 1 ? "" : "s"}`);
  renderDownloads(root, { keepTab: true });
}

/** Danger button that arms on first click ("Delete N episodes?") and only
 *  deletes on a second click within a few seconds. */
function deleteAllButton(label: string, count: number, onConfirm: () => void): HTMLElement {
  const btn = el("button", { class: "btn small danger" }, [label]);
  let armed = false;
  let timer = 0;
  btn.addEventListener("click", () => {
    if (!armed) {
      armed = true;
      btn.textContent = `Delete ${count} episode${count === 1 ? "" : "s"}?`;
      timer = window.setTimeout(() => {
        armed = false;
        btn.textContent = label;
      }, 4000);
    } else {
      clearTimeout(timer);
      btn.textContent = "Deleting…";
      (btn as HTMLButtonElement).disabled = true;
      onConfirm();
    }
  });
  return btn;
}

// ---------- Tabs ----------

function renderTvTab(pane: HTMLElement, tv: any[], root: HTMLElement): void {
  clear(pane);
  if (!tv.length) {
    pane.append(el("div", { class: "empty" }, ["No TV downloads yet."]));
    return;
  }

  // Group episodes by series name.
  const groups = new Map<string, any[]>();
  for (const dl of tv) {
    const key = dl.series ?? dl.title ?? dl.name ?? dl.item_id;
    (groups.get(key) ?? groups.set(key, []).get(key)!).push(dl);
  }

  if (openSeries && !groups.has(openSeries)) {
    openSeries = null;
    openSeason = null;
  }

  if (!openSeries) {
    // Series grid.
    const grid = el("div", { class: "card-grid" });
    for (const [series, eps] of [...groups].sort((a, b) => a[0].localeCompare(b[0]))) {
      // Prefer the portrait series poster; fall back to an episode still.
      const poster =
        eps.find((e) => e.series_poster_path)?.series_poster_path ??
        eps.find((e) => e.poster_path)?.poster_path;
      const watched = eps.filter((e) => e.played).length;
      const frac = watchFraction(eps);
      grid.append(
        libCard({
          posterPath: poster,
          title: series,
          sub:
            `${eps.length} episode${eps.length === 1 ? "" : "s"}` +
            (watched ? ` · ${watched} watched` : ""),
          played: watched === eps.length,
          progressPct: frac > 0 && frac < 1 ? frac * 100 : null,
          onOpen: () => {
            openSeries = series;
            openSeason = null;
            renderTvTab(pane, tv, root);
          },
        })
      );
    }
    pane.append(grid);
    return;
  }

  const eps = groups.get(openSeries)!;
  const bySeason = new Map<number, any[]>();
  for (const ep of eps) {
    const s = typeof ep.season === "number" ? ep.season : -1;
    (bySeason.get(s) ?? bySeason.set(s, []).get(s)!).push(ep);
  }
  for (const list of bySeason.values()) {
    list.sort((a, b) => (a.episode ?? 0) - (b.episode ?? 0));
  }
  if (openSeason != null && !bySeason.has(openSeason)) openSeason = null;

  const seasonTitle = (n: number) => (n >= 0 ? `Season ${n}` : "Episodes");

  if (openSeason == null) {
    // One series: a grid of its downloaded seasons.
    pane.append(
      el("div", { class: "lib-crumb" }, [
        el("a", {
          onClick: () => {
            openSeries = null;
            renderTvTab(pane, tv, root);
          },
        }, ["← All shows"]),
        el("span", {}, [openSeries]),
        el("span", { style: "margin-left:auto" }, [
          deleteAllButton("Delete series", eps.length, () => deleteMany(eps, root)),
        ]),
      ])
    );
    const grid = el("div", { class: "card-grid" });
    for (const [season, list] of [...bySeason].sort((a, b) => a[0] - b[0])) {
      const poster =
        list.find((e) => e.season_poster_path)?.season_poster_path ??
        list.find((e) => e.series_poster_path)?.series_poster_path ??
        list.find((e) => e.poster_path)?.poster_path;
      const watched = list.filter((e) => e.played).length;
      const frac = watchFraction(list);
      grid.append(
        libCard({
          posterPath: poster,
          title: seasonTitle(season),
          sub:
            `${list.length} episode${list.length === 1 ? "" : "s"}` +
            (watched ? ` · ${watched} watched` : ""),
          played: watched === list.length,
          progressPct: frac > 0 && frac < 1 ? frac * 100 : null,
          onOpen: () => {
            openSeason = season;
            renderTvTab(pane, tv, root);
          },
        })
      );
    }
    pane.append(grid);
    return;
  }

  // One season: its episode list.
  const list = bySeason.get(openSeason)!;
  pane.append(
    el("div", { class: "lib-crumb" }, [
      el("a", {
        onClick: () => {
          openSeason = null;
          renderTvTab(pane, tv, root);
        },
      }, ["← Seasons"]),
      el("span", {}, [`${openSeries} · ${seasonTitle(openSeason)}`]),
      el("span", { style: "margin-left:auto" }, [
        deleteAllButton("Delete season", list.length, () => deleteMany(list, root)),
      ]),
    ])
  );
  for (const ep of list) {
    const code = ep.episode != null ? `${ep.episode}. ` : "";
    const actions = el("div", { class: "dl-actions" }, [
      ep.path ? el("button", { class: "btn small primary", onClick: () => playLocal(ep) }, ["▶ Play"]) : null,
      el("button", { class: "btn small danger", onClick: () => deleteDownload(ep.item_id, root) }, ["Delete"]),
    ]);
    pane.append(
      dlRow(
        ep.poster_path,
        `${code}${ep.name ?? ep.title ?? ep.item_id}`,
        [el("div", { class: "dl-sub" }, [completedSub(ep)])],
        actions,
        watchedOverlay(ep)
      )
    );
  }
}

function renderMoviesTab(pane: HTMLElement, movies: any[], root: HTMLElement): void {
  clear(pane);
  if (!movies.length) {
    pane.append(el("div", { class: "empty" }, ["No movie downloads yet."]));
    return;
  }
  const grid = el("div", { class: "card-grid" });
  for (const dl of [...movies].sort((a, b) => (a.title ?? "").localeCompare(b.title ?? ""))) {
    const sub = [dl.year, dl.size_bytes ? api.bytesToText(dl.size_bytes) : null].filter(Boolean).join(" · ");
    const pct =
      !dl.played && dl.position_ticks > 0 && dl.run_time_ticks
        ? Math.min(100, (dl.position_ticks / dl.run_time_ticks) * 100)
        : null;
    grid.append(
      libCard({
        posterPath: dl.poster_path,
        title: dl.title ?? dl.name ?? dl.item_id,
        sub,
        played: !!dl.played,
        progressPct: pct,
        overlay: dl.path ? "▶" : undefined,
        onOpen: () => {
          if (dl.path) playLocal(dl);
        },
        onDelete: () => deleteDownload(dl.item_id, root),
      })
    );
  }
  pane.append(grid);
}

function renderQueueTab(
  pane: HTMLElement,
  active: any[],
  errored: any[],
  waiting: PendingDownload[],
  root: HTMLElement
): void {
  clear(pane);
  if (!active.length && !errored.length && !waiting.length) {
    pane.append(el("div", { class: "empty" }, ["No active or queued downloads."]));
    return;
  }

  if (active.length) {
    pane.append(el("h3", { class: "season-group" }, ["Downloading"]));
    for (const dl of active) {
      const sub: string[] = [];
      if (dl.quality) sub.push(dl.quality);
      if (dl.estimated_bytes) sub.push(`of ~${api.bytesToText(dl.estimated_bytes)}`);
      const bar = el("div", { class: "dl-bar", "data-item": dl.item_id }, [el("div", { style: "width:0%" })]);
      const actions = el("div", { class: "dl-actions" }, [
        el("button", {
          class: "btn small danger",
          onClick: () => invoke("download_cancel", { itemId: dl.item_id }),
        }, ["Cancel"]),
      ]);
      pane.append(
        dlRow(
          dl.poster_path,
          dl.title ?? dl.name ?? dl.item_id,
          [el("div", { class: "dl-sub", "data-sub": dl.item_id }, [sub.join(" · ")]), bar],
          actions
        )
      );
    }
  }

  if (waiting.length) {
    pane.append(el("h3", { class: "season-group" }, [`Up next · ${waiting.length}`]));
    waiting.forEach((p, i) => {
      const parts: string[] = [];
      if (p.series && p.season != null && p.episode != null) parts.push(`${p.series} · S${p.season}E${p.episode}`);
      else if (p.series) parts.push(p.series);
      parts.push(`Waiting · ${p.quality}`);
      const actions = el("div", { class: "dl-actions" }, [
        el("span", { class: "queue-pos" }, [`#${i + 1}`]),
        el("button", { class: "btn small danger", onClick: () => cancelQueuedDownload(p.id) }, ["Remove"]),
      ]);
      pane.append(dlRow(undefined, p.title, [el("div", { class: "dl-sub" }, [parts.join(" · ")])], actions));
    });
  }

  if (errored.length) {
    pane.append(el("h3", { class: "season-group" }, ["Failed"]));
    for (const dl of errored) {
      const actions = el("div", { class: "dl-actions" }, [
        el("button", {
          class: "btn small",
          onClick: async () => {
            try {
              await invoke("download_retry", { itemId: dl.item_id });
              renderDownloads(root, { keepTab: true });
            } catch (e) {
              toast(`Retry failed: ${e}`, "error");
            }
          },
        }, ["Retry"]),
        el("button", { class: "btn small danger", onClick: () => deleteDownload(dl.item_id, root) }, ["Delete"]),
      ]);
      pane.append(
        dlRow(
          dl.poster_path,
          dl.title ?? dl.name ?? dl.item_id,
          [el("div", { class: "dl-sub" }, [`failed: ${dl.error ?? "unknown error"}`])],
          actions
        )
      );
    }
  }
}

// ---------- Server watch-state refresh ----------

/**
 * When online, pull each downloaded item's watched/resume state from Jellyfin
 * into its local meta so the Downloads view matches the server. Items with
 * local progress still waiting to sync are skipped — local wins until pushed.
 * Returns true when anything changed (the caller re-renders).
 */
async function refreshWatchState(completed: any[]): Promise<boolean> {
  if (api.isOffline() || !api.getSession() || !completed.length) return false;
  const pending = new Set(await invoke<string[]>("progress_pending_ids").catch(() => []));
  const candidates = completed.filter((d) => !pending.has(d.item_id));
  if (!candidates.length) return false;
  const fresh = await api.getUserDataByIds(candidates.map((d) => d.item_id));
  let changed = false;
  for (const d of candidates) {
    const ud = fresh.get(d.item_id);
    if (!ud) continue; // item deleted on the server — keep local state
    const played = !!ud.Played;
    const pos = played ? 0 : ud.PlaybackPositionTicks ?? 0;
    if (played === !!d.played && pos === (d.position_ticks ?? 0)) continue;
    d.played = played;
    d.position_ticks = pos;
    changed = true;
    invoke("download_set_watch_state", {
      itemId: d.item_id,
      positionTicks: pos,
      played,
    }).catch(() => {});
  }
  return changed;
}

// ---------- Entry point ----------

export async function renderDownloads(
  root: HTMLElement,
  opts: { keepTab?: boolean } = {}
): Promise<void> {
  if (refreshTimer) {
    clearInterval(refreshTimer);
    refreshTimer = null;
  }
  currentRoot = root;
  if (!opts.keepTab) {
    activeTab = "tv";
    openSeries = null;
    openSeason = null;
  }

  clear(root);
  root.append(spinner());

  const [items, pending] = await Promise.all([
    invoke<any[]>("downloads_list"),
    invoke<number>("progress_pending"),
  ]);
  const waiting = getQueuedDownloads();

  const completed = items.filter((d) => d.status === "complete");
  const tv = completed.filter(isEpisode);
  const movies = completed.filter((d) => !isEpisode(d));
  const active = items.filter((d) => d.status === "downloading");
  const errored = items.filter((d) => d.status === "error");

  clear(root);
  root.append(
    el("div", { class: "section-head" }, [
      el("h1", { class: "page-title", style: "margin-bottom:0" }, ["Downloads"]),
      el("div", { style: "display:flex;gap:10px;align-items:center" }, [
        el("span", { class: "sync-pill" }, [
          pending > 0 ? `${pending} watch state(s) waiting to sync` : "Watch state in sync",
        ]),
        el("button", {
          class: "btn small",
          onClick: async () => {
            await syncOfflineProgress(true);
            renderDownloads(root, { keepTab: true });
          },
        }, ["Sync now"]),
      ]),
    ])
  );

  const pane = el("div", { class: "dl-pane" });
  const queueCount = active.length + waiting.length + errored.length;

  const tabs: { id: Tab; label: string; count: number }[] = [
    { id: "tv", label: "TV", count: tv.length },
    { id: "movies", label: "Movies", count: movies.length },
    { id: "queue", label: "Queue", count: queueCount },
  ];

  function paint(): void {
    if (activeTab === "tv") renderTvTab(pane, tv, root);
    else if (activeTab === "movies") renderMoviesTab(pane, movies, root);
    else renderQueueTab(pane, active, errored, waiting, root);
  }

  const tabBar = el("div", { class: "dl-tabs" });
  for (const t of tabs) {
    const btn = el("button", { class: `btn small${t.id === activeTab ? " active" : ""}` }, [
      t.label,
      t.count ? el("span", { class: "dl-tab-count" }, [String(t.count)]) : null,
    ]);
    btn.addEventListener("click", () => {
      if (activeTab !== t.id) {
        openSeries = null;
        openSeason = null;
      }
      activeTab = t.id;
      tabBar.querySelectorAll(".btn").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      paint();
    });
    tabBar.append(btn);
  }
  root.append(tabBar, pane);
  paint();

  // Reconcile watched state with the server in the background; repaint when
  // something actually changed and this view is still on screen.
  void refreshWatchState(completed)
    .then((changed) => {
      if (changed && document.contains(pane)) paint();
    })
    .catch(() => {});

  // Refresh the view when the in-memory batch queue changes (installed once).
  if (!queueListenerInstalled) {
    queueListenerInstalled = true;
    document.addEventListener("fellyjin-download-queue", () => {
      if (currentRoot && document.contains(currentRoot) && currentRoot.querySelector(".dl-tabs")) {
        renderDownloads(currentRoot, { keepTab: true });
      }
    });
  }

  // Re-render when playback ends (installed once): watching a download
  // updates its meta.json, but this view was rendered before playback began —
  // without this, the ✓ / progress just watched never appears until the user
  // navigates away and back.
  if (!playbackListenerInstalled) {
    playbackListenerInstalled = true;
    let wasActive = false;
    void listen("player-status", (ev) => {
      const st = ev.payload as any;
      if (st.active) {
        wasActive = true;
        return;
      }
      if (!wasActive) return;
      wasActive = false;
      if (currentRoot && document.contains(currentRoot) && currentRoot.querySelector(".dl-tabs")) {
        renderDownloads(currentRoot, { keepTab: true });
      }
    });
  }
}

function etaText(seconds: number): string {
  if (!isFinite(seconds) || seconds <= 0) return "";
  if (seconds < 60) return `${Math.round(seconds)}s left`;
  const m = Math.floor(seconds / 60);
  if (m < 60) return `${m}m ${Math.round(seconds % 60)}s left`;
  return `${Math.floor(m / 60)}h ${m % 60}m left`;
}

/** Called from main.ts on download-progress events to update visible bars. */
export function updateDownloadProgress(payload: any, root: HTMLElement): void {
  if (payload.state === "complete" || payload.state === "error" || payload.state === "canceled") {
    // A download finished: re-render so it moves into the right tab and the
    // next queued item appears. Only if the Downloads view is mounted.
    if (root.querySelector(".dl-tabs")) renderDownloads(root, { keepTab: true });
    return;
  }
  const bar = root.querySelector<HTMLElement>(`.dl-bar[data-item="${payload.item_id}"] > div`);
  const sub = root.querySelector<HTMLElement>(`[data-sub="${payload.item_id}"]`);
  const approx = payload.estimated ? "~" : "";
  const speed = payload.speed_bps ? `${api.bytesToText(payload.speed_bps)}/s` : "";

  if (payload.total) {
    const pct = Math.min(100, (payload.received / payload.total) * 100);
    if (bar) bar.style.width = `${pct}%`;
    if (sub) {
      const remaining =
        payload.speed_bps > 0 ? (payload.total - payload.received) / payload.speed_bps : NaN;
      sub.textContent = [
        `${pct.toFixed(0)}%`,
        `${api.bytesToText(payload.received)} of ${approx}${api.bytesToText(payload.total)}`,
        speed,
        etaText(remaining),
      ]
        .filter(Boolean)
        .join(" · ");
    }
  } else {
    // No size information at all — show an indeterminate shimmer.
    if (bar) {
      bar.style.width = "100%";
      bar.style.opacity = "0.35";
    }
    if (sub) {
      sub.textContent = [`${api.bytesToText(payload.received)} downloaded`, speed]
        .filter(Boolean)
        .join(" · ");
    }
  }
}
