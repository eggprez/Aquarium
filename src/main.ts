import { listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import * as api from "./api";
import {
  getQualityState,
  isAutoplayPending,
  openUoscBinding,
  playerCtl,
  QUALITY_CHOICES,
  registerPlayerBridge,
  restoreDownloadQueue,
  showEpisodeMenu,
  switchQuality,
  syncOfflineProgress,
} from "./playback";
import { el, clear, closeMenus, toast } from "./ui";
import { renderLogin } from "./views/login";
import { renderHome } from "./views/home";
import { renderLibrary, renderSearch } from "./views/library";
import { renderItem } from "./views/item";
import { renderLiveTv } from "./views/livetv";
import { renderDownloads, updateDownloadProgress } from "./views/downloads";
import { renderSettings } from "./views/settings";

const $ = (id: string) => document.getElementById(id)!;

const ICONS: Record<string, string> = {
  home: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 10.5 12 3l9 7.5"/><path d="M5 9.5V21h14V9.5"/></svg>',
  movies: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="M7 5v14M17 5v14M3 10h4M3 14h4M17 10h4M17 14h4"/></svg>',
  tv: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="6" width="18" height="12" rx="2"/><path d="M8 21h8M12 18v3"/></svg>',
  livetv: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="7" width="18" height="13" rx="2"/><path d="m8 3 4 4 4-4"/><circle cx="12" cy="13.5" r="3"/></svg>',
  downloads: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 3v12m0 0 4-4m-4 4-4-4"/><path d="M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2"/></svg>',
  settings: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .34 1.87l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.7 1.7 0 0 0-1.87-.34 1.7 1.7 0 0 0-1 1.55V21a2 2 0 1 1-4 0v-.09a1.7 1.7 0 0 0-1-1.55 1.7 1.7 0 0 0-1.87.34l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.7 1.7 0 0 0 .34-1.87 1.7 1.7 0 0 0-1.55-1H3a2 2 0 1 1 0-4h.09a1.7 1.7 0 0 0 1.55-1 1.7 1.7 0 0 0-.34-1.87l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.7 1.7 0 0 0 1.87.34h0a1.7 1.7 0 0 0 1-1.55V3a2 2 0 1 1 4 0v.09a1.7 1.7 0 0 0 1 1.55h0a1.7 1.7 0 0 0 1.87-.34l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.7 1.7 0 0 0-.34 1.87v0a1.7 1.7 0 0 0 1.55 1H21a2 2 0 1 1 0 4h-.09a1.7 1.7 0 0 0-1.55 1z"/></svg>',
  folder: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 7a2 2 0 0 1 2-2h4l2 3h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>',
};

let playerActive = false;
let playerEmbedded = false;
let videoFullscreen = false;
let seeking = false;

// Fullscreen shows the same player bar as windowed mode: HTML can never draw
// over the X11 video child window, so instead the video is shrunk by the bar
// height while the controls are revealed, and expanded back on idle. Mouse
// motion over the video is reported by mpv ("player-mouse" events — the
// pointer belongs to mpv there); motion over the revealed bar comes from
// normal DOM events.
let fsBarShown = false;
let fsHideTimer = 0;

function fsSetBar(shown: boolean): void {
  if (fsBarShown === shown) return;
  fsBarShown = shown;
  invoke("player_set_viewport", { full: true, bar: shown }).catch(() => {});
}

function fsPokeControls(): void {
  if (!videoFullscreen) return;
  fsSetBar(true);
  clearTimeout(fsHideTimer);
  fsHideTimer = window.setTimeout(() => {
    if (!videoFullscreen) return;
    const bar = $("player-bar");
    // Don't hide under the pointer or while the quality picker is open.
    if (bar.matches(":hover") || bar.querySelector(".pb-quality-picker")) {
      fsPokeControls();
      return;
    }
    fsSetBar(false);
  }, 2500);
}

async function setVideoFullscreen(full: boolean): Promise<void> {
  videoFullscreen = full;
  clearTimeout(fsHideTimer);
  fsBarShown = false;
  try {
    await getCurrentWindow().setFullscreen(full);
  } catch {
    /* window may not permit it */
  }
  try {
    await invoke("player_set_viewport", { full, bar: false });
  } catch {
    /* no active surface */
  }
  // Flash the controls on entry so they're discoverable, then auto-hide.
  if (full) fsPokeControls();
}

// ---------- Router ----------

// In-app back navigation. `location.hash` assignments are scattered across the
// views, and every one fires `hashchange`, so we track where each navigation
// came *from* (the event's oldURL) to build a back stack. The back button pops
// it; the `back` flag stops a back-initiated hashchange from re-pushing.
const navStack: string[] = [];
let navigatingBack = false;

function hashOf(url: string): string {
  const i = url.indexOf("#");
  return i >= 0 ? url.slice(i) : "#/home";
}

function goBack(): void {
  const target = navStack.pop();
  if (target != null) {
    navigatingBack = true;
    location.hash = target;
  }
  updateBackButton();
}

function updateBackButton(): void {
  const btn = document.getElementById("back-btn");
  if (btn) btn.toggleAttribute("hidden", navStack.length === 0);
}

// Pages that can't render without the server.
const SERVER_PAGES = ["home", "lib", "item", "livetv", "search"];

function renderOffline(content: HTMLElement): void {
  clear(content);
  content.append(
    el("div", { class: "offline-screen" }, [
      el("h1", { class: "page-title" }, ["Server offline"]),
      el("p", {}, [
        "You're signed in, but your Jellyfin server can't be reached right now. Downloaded media is still available, and playback will sync once you're back online.",
      ]),
      el("div", { class: "offline-actions" }, [
        el("button", {
          class: "btn primary",
          onClick: () => (location.hash = "#/downloads"),
        }, ["Go to Downloads"]),
        el("button", {
          class: "btn",
          onClick: async (ev: MouseEvent) => {
            const b = ev.currentTarget as HTMLButtonElement;
            b.disabled = true;
            b.textContent = "Checking…";
            const ok = await api.checkOnline();
            b.disabled = false;
            b.textContent = "Retry connection";
            if (ok) route();
            else toast("Still offline — server unreachable", "error");
          },
        }, ["Retry connection"]),
      ]),
    ])
  );
}

async function route(): Promise<void> {
  closeMenus();
  const content = $("content");
  const hash = location.hash || "#/home";
  const [, page, arg] = hash.match(/^#\/([^/]*)\/?(.*)$/) ?? [];

  document.querySelectorAll(".nav-item").forEach((n) => {
    n.classList.toggle("active", n.getAttribute("data-route") === hash || n.getAttribute("data-route") === `#/${page}`);
  });

  if (api.isOffline() && SERVER_PAGES.includes(page || "home")) {
    renderOffline(content);
    content.scrollTop = 0;
    return;
  }

  try {
    switch (page) {
      case "home": await renderHome(content); break;
      case "lib": await renderLibrary(content, arg); break;
      case "item": await renderItem(content, arg); break;
      case "livetv": await renderLiveTv(content); break;
      case "downloads": await renderDownloads(content); break;
      case "settings": await renderSettings(content, showLogin); break;
      case "search": await renderSearch(content, decodeURIComponent(arg)); break;
      default: await renderHome(content);
    }
  } catch (e: any) {
    clear(content);
    content.append(el("div", { class: "empty" }, [`Failed to load: ${e.message ?? e}`]));
  }
  content.scrollTop = 0;
}

// ---------- Shell ----------

async function buildNav(): Promise<void> {
  const nav = $("nav");
  clear(nav);

  const add = (route: string, label: string, icon: string) => {
    const b = el("button", { class: "nav-item", "data-route": route, html: icon });
    b.append(el("span", {}, [label]));
    b.addEventListener("click", () => (location.hash = route));
    nav.append(b);
  };

  add("#/home", "Home", ICONS.home);

  const views = await api.getViews().catch(() => []);
  let hasLiveTv = false;
  if (views.length) nav.append(el("div", { class: "nav-sep" }, ["Libraries"]));
  for (const v of views) {
    if (v.CollectionType === "livetv") { hasLiveTv = true; continue; }
    // Music-type libraries are out of scope for this client.
    if (["boxsets", "playlists", "music", "audiobooks", "podcasts"].includes(v.CollectionType)) continue;
    const icon =
      v.CollectionType === "movies" ? ICONS.movies :
      v.CollectionType === "tvshows" ? ICONS.tv : ICONS.folder;
    add(`#/lib/${v.Id}`, v.Name, icon);
  }

  nav.append(el("div", { class: "nav-sep" }, ["FellyJin"]));
  add("#/livetv", "Live TV", ICONS.livetv);
  add("#/downloads", "Downloads", ICONS.downloads);
  add("#/settings", "Settings", ICONS.settings);
  void hasLiveTv;

  const s = api.getSession();
  const userBox = $("topbar-user");
  clear(userBox);
  if (s) {
    userBox.append(
      el("span", {}, [s.userName]),
      el("div", { class: "avatar" }, [s.userName.slice(0, 1).toUpperCase()])
    );
  }
}

function updateOfflinePill(): void {
  $("offline-pill").toggleAttribute("hidden", !api.isOffline());
}

function showShell(): void {
  $("login-root").classList.add("hidden");
  $("shell").classList.remove("hidden");
  buildNav();
  updateOfflinePill();
  // Offline with content downloaded: land on Downloads, not a dead Home.
  if (api.isOffline() && (!location.hash || location.hash === "#/home")) {
    location.hash = "#/downloads";
  }
  route();
  // Push any offline watch progress accumulated while away.
  syncOfflineProgress(false);
  // Pick the season-download queue back up where the last run left it.
  void restoreDownloadQueue();
}

function showLogin(): void {
  $("shell").classList.add("hidden");
  $("login-root").classList.remove("hidden");
  renderLogin($("login-root"), showShell);
}

// ---------- Player bar ----------

const PB_ICONS = {
  exit:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 18l-6-6 6-6"/></svg>',
  back30:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M11 5 7 8.5 11 12V9.2c3.6 0 6.3 2.6 6.3 6h1.9c0-4.4-3.6-8-8.2-8z" fill="currentColor" stroke="none"/><text x="7.5" y="20" font-size="7.5" fill="currentColor" stroke="none" font-weight="700">30</text></svg>',
  fwd30:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="m13 5 4 3.5L13 12V9.2c-3.6 0-6.3 2.6-6.3 6H4.8c0-4.4 3.6-8 8.2-8z" fill="currentColor" stroke="none"/><text x="9.5" y="20" font-size="7.5" fill="currentColor" stroke="none" font-weight="700">30</text></svg>',
  play: '<svg viewBox="0 0 24 24"><path d="M8 5.5v13l10-6.5z" fill="currentColor"/></svg>',
  pause:
    '<svg viewBox="0 0 24 24"><rect x="7" y="5.5" width="3.4" height="13" rx="1" fill="currentColor"/><rect x="13.6" y="5.5" width="3.4" height="13" rx="1" fill="currentColor"/></svg>',
  stop: '<svg viewBox="0 0 24 24"><rect x="6.5" y="6.5" width="11" height="11" rx="2" fill="currentColor"/></svg>',
  subtitles:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="5" width="18" height="14" rx="2.5"/><path d="M6.5 12h4M13 12h4.5M6.5 15.5h2.5M11.5 15.5h6"/></svg>',
  audio:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 9.5v5h3.5L12 19V5L7.5 9.5H4z" fill="currentColor" stroke="none"/><path d="M15.5 9a4.2 4.2 0 0 1 0 6M18 6.5a8 8 0 0 1 0 11" stroke-linecap="round"/></svg>',
  quality:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 7h9M17 7h3M4 12h3M11 12h9M4 17h9M17 17h3"/><circle cx="15" cy="7" r="2"/><circle cx="9" cy="12" r="2"/><circle cx="15" cy="17" r="2"/></svg>',
  episodes:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><rect x="3" y="4.5" width="13" height="9" rx="2"/><path d="M20 8v9a2 2 0 0 1-2 2H6"/><path d="m8 7.5 4 2.5-4 2.5z" fill="currentColor" stroke="none"/></svg>',
  fullscreen:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 9V5.5A1.5 1.5 0 0 1 5.5 4H9M15 4h3.5A1.5 1.5 0 0 1 20 5.5V9M20 15v3.5a1.5 1.5 0 0 1-1.5 1.5H15M9 20H5.5A1.5 1.5 0 0 1 4 18.5V15"/></svg>',
};

function pbButton(id: string, icon: string, tip: string, onClick: () => void): HTMLElement {
  const b = el("button", { class: "btn icon", id, title: tip, html: icon });
  b.addEventListener("click", () => {
    // Trace clicks so "button does nothing" reports can be diagnosed from
    // ~/.local/share/fellyjin/debug.log.
    invoke("ui_log", { msg: `click ${id}` }).catch(() => {});
    Promise.resolve(onClick()).catch((e) => {
      invoke("ui_log", { msg: `click ${id} error: ${e}` }).catch(() => {});
    });
  });
  return b;
}

/**
 * Quality picker: an overlay INSIDE the player bar. Anywhere else (dropdown,
 * uosc menu) it can be hidden — the X11 video child window covers all HTML
 * above the bar, and uosc can't draw before mpv's video output is up (which
 * is exactly when a stuck stream makes you want a lower bitrate).
 */
function toggleQualityPicker(): void {
  const bar = $("player-bar");
  const existing = bar.querySelector(".pb-quality-picker");
  if (existing) {
    existing.remove();
    return;
  }
  const state = getQualityState();
  const pick = el("div", { class: "pb-quality-picker" }, [
    el("span", { class: "pbq-label" }, ["Quality"]),
  ]);
  if (!state || state.isLocal) {
    pick.append(el("span", { class: "pbq-note" }, ["Playing a downloaded file — quality is fixed"]));
  } else {
    for (const q of QUALITY_CHOICES) {
      const active = q.maxBitrate === state.current;
      pick.append(
        el("button", {
          class: `btn small${active ? " primary" : ""}`,
          onClick: () => {
            pick.remove();
            switchQuality(q.maxBitrate).catch((e) => toast(String(e), "error"));
          },
        }, [q.label])
      );
    }
  }
  pick.append(el("button", { class: "btn small pbq-close", title: "Close", onClick: () => pick.remove() }, ["×"]));
  bar.append(pick);
}

function buildPlayerBar(): void {
  const bar = $("player-bar");
  clear(bar);

  const title = el("div", { class: "pb-title" }, [
    el("h5", { id: "pb-title" }, ["–"]),
    el("span", { id: "pb-state" }, [""]),
  ]);

  const pos = el("span", { id: "pb-pos" }, ["0:00"]);
  const dur = el("span", { id: "pb-dur" }, ["0:00"]);
  const range = el("input", { type: "range", min: "0", max: "1000", value: "0", id: "pb-range" }) as HTMLInputElement;
  range.addEventListener("input", () => {
    seeking = true;
    range.style.setProperty("--fill", `${parseInt(range.value) / 10}%`);
  });
  range.addEventListener("change", () => {
    const durS = parseFloat(range.dataset.duration ?? "0");
    if (durS > 0) playerCtl.seek((parseInt(range.value) / 1000) * durS, true);
    seeking = false;
  });

  bar.append(
    pbButton("pb-exit", PB_ICONS.exit, "Back (stop and leave the player)", async () => {
      if (videoFullscreen) await setVideoFullscreen(false);
      await playerCtl.stop();
    }),
    title,
    el("div", { class: "pb-controls" }, [
      pbButton("pb-back", PB_ICONS.back30, "Back 30s (←)", () => playerCtl.seek(-30, false)),
      pbButton("pb-playpause", PB_ICONS.pause, "Play/Pause (Space)", () => playerCtl.pauseToggle()),
      pbButton("pb-fwd", PB_ICONS.fwd30, "Forward 30s (→)", () => playerCtl.seek(30, false)),
      pbButton("pb-stop", PB_ICONS.stop, "Stop", () => playerCtl.stop()),
    ]),
    el("div", { class: "pb-seek" }, [pos, range, dur]),
    el("div", { class: "pb-controls" }, [
      pbButton("pb-subs", PB_ICONS.subtitles, "Subtitles", () => openUoscBinding("subtitles")),
      pbButton("pb-audio", PB_ICONS.audio, "Audio track", () => openUoscBinding("audio")),
      pbButton("pb-quality", PB_ICONS.quality, "Stream quality", () => toggleQualityPicker()),
      pbButton("pb-episodes", PB_ICONS.episodes, "Episode queue", () => showEpisodeMenu()),
      pbButton("pb-fullscreen", PB_ICONS.fullscreen, "Fullscreen (f, Esc exits)", () =>
        setVideoFullscreen(!videoFullscreen)
      ),
    ])
  );
}

function updatePlayerBar(st: any): void {
  const bar = $("player-bar");
  const content = $("content");
  if (!st.active) {
    if (isAutoplayPending()) {
      // The next episode is being fetched — keep the bar (and fullscreen) up.
      ($("pb-state") as HTMLElement).textContent = "Loading next episode…";
      return;
    }
    playerActive = false;
    playerEmbedded = false;
    bar.classList.add("hidden");
    content.classList.remove("has-player");
    if (videoFullscreen) setVideoFullscreen(false);
    return;
  }
  if (!playerActive) {
    playerActive = true;
    bar.classList.remove("hidden");
    content.classList.add("has-player");
  }
  playerEmbedded = !!st.embedded;
  const fsBtn = $("pb-fullscreen");
  if (fsBtn) fsBtn.style.display = playerEmbedded ? "" : "none";
  ($("pb-title") as HTMLElement).textContent = st.title || "Playing";
  ($("pb-state") as HTMLElement).textContent = st.paused ? "Paused" : "Playing";
  ($("pb-playpause") as HTMLElement).innerHTML = st.paused ? PB_ICONS.play : PB_ICONS.pause;
  ($("pb-pos") as HTMLElement).textContent = api.secondsToClock(st.position ?? 0);
  ($("pb-dur") as HTMLElement).textContent = st.duration > 0 ? api.secondsToClock(st.duration) : "live";
  const range = $("pb-range") as HTMLInputElement;
  range.dataset.duration = String(st.duration ?? 0);
  if (!seeking && st.duration > 0) {
    const pct = Math.min(100, (st.position / st.duration) * 100);
    range.value = String(Math.round(pct * 10));
    range.style.setProperty("--fill", `${pct}%`);
  }
}

// ---------- Boot ----------

async function boot(): Promise<void> {
  try {
    await api.loadConfig();
  } catch (e) {
    console.error("config load failed:", e);
  }
  buildPlayerBar();
  try {
    await registerPlayerBridge();
  } catch (e) {
    console.error("player bridge failed:", e);
  }

  document.addEventListener("fellyjin-fullscreen-toggle", () => {
    if (playerActive && playerEmbedded) setVideoFullscreen(!videoFullscreen);
  });

  document.addEventListener("fellyjin-fullscreen-exit", () => {
    if (videoFullscreen) setVideoFullscreen(false);
  });

  // A new mpv instance starts windowed with uosc controls disabled; if we're
  // in fullscreen (autoplay or quality switch), re-assert it.
  document.addEventListener("fellyjin-player-started", () => {
    if (videoFullscreen) setVideoFullscreen(true);
  });

  // Autoplay found nothing next (or failed) — tear the player UI down.
  document.addEventListener("fellyjin-autoplay-none", () => {
    updatePlayerBar({ active: false });
  });

  // Offline/online transitions from the API layer.
  document.addEventListener("fellyjin-connectivity", (ev) => {
    const off = !!(ev as CustomEvent).detail?.offline;
    updateOfflinePill();
    if (off) {
      toast("Server unreachable — offline mode. Downloads still work.", "error");
    } else {
      toast("Back online", "ok");
      buildNav();
      route();
      syncOfflineProgress(false);
    }
  });

  // While offline, quietly retry the server every 15 seconds.
  setInterval(() => {
    if (api.getSession() && api.isOffline()) api.checkOnline();
  }, 15_000);

  $("offline-retry").addEventListener("click", async () => {
    const ok = await api.checkOnline();
    if (!ok) toast("Still offline — server unreachable", "error");
  });

  await listen("player-status", (ev) => updatePlayerBar(ev.payload as any));
  await listen("download-progress", (ev) => {
    updateDownloadProgress(ev.payload, $("content"));
  });
  // Mouse moved over the video (mpv owns the pointer there): reveal the
  // fullscreen bar. Motion over the revealed bar itself arrives as normal
  // DOM events instead.
  await listen("player-mouse", () => fsPokeControls());
  document.addEventListener("mousemove", () => {
    if (videoFullscreen) fsPokeControls();
  });

  const search = $("search-input") as HTMLInputElement;
  search.addEventListener("keydown", (ev) => {
    if (ev.key === "Enter" && search.value.trim()) {
      location.hash = `#/search/${encodeURIComponent(search.value.trim())}`;
    }
  });

  window.addEventListener("hashchange", (ev) => {
    if (navigatingBack) {
      navigatingBack = false;
    } else {
      const from = hashOf((ev as HashChangeEvent).oldURL);
      // Don't stack repeats; keep home as the stack floor.
      if (from !== (location.hash || "#/home")) navStack.push(from);
    }
    updateBackButton();
    route();
  });

  const backBtn = $("back-btn");
  backBtn.addEventListener("click", goBack);
  // Mouse "back" button (button 3) also navigates back.
  window.addEventListener("mouseup", (ev) => {
    if (ev.button === 3) {
      ev.preventDefault();
      goBack();
    }
  });

  // Playback keyboard shortcuts (the webview keeps keyboard focus while the
  // video surface is embedded).
  document.addEventListener("keydown", (ev) => {
    if (!playerActive) return;
    const t = ev.target as HTMLElement;
    if (t && ["INPUT", "TEXTAREA", "SELECT"].includes(t.tagName)) return;
    switch (ev.key) {
      case " ":
        ev.preventDefault();
        playerCtl.pauseToggle();
        break;
      case "ArrowLeft":
        ev.preventDefault();
        playerCtl.seek(-10, false);
        break;
      case "ArrowRight":
        ev.preventDefault();
        playerCtl.seek(10, false);
        break;
      case "f":
        if (playerEmbedded) setVideoFullscreen(!videoFullscreen);
        break;
      case "Escape":
        if (videoFullscreen) setVideoFullscreen(false);
        break;
    }
  });

  if (api.getSession()) {
    // Know up front whether the saved server is reachable, so a dead server
    // reads as "offline", not "nothing saved". Fast on LAN; 3s worst case.
    await api.checkOnline();
    showShell();
  } else {
    showLogin();
  }
}

boot();
