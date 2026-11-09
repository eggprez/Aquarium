import { listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import * as api from "./api";
import {
  cancelAutoplay,
  getNowPlaying,
  getQualityState,
  getVolume,
  isAdaptiveEnabled,
  setAdaptiveEnabled,
  isAutoplayCancelled,
  isAutoplayPending,
  peekNextEpisode,
  playNextNow,
  MAX_VOLUME,
  noteVolume,
  getTracks,
  playerCtl,
  PICTURE_CONTROLS,
  QUALITY_CHOICES,
  registerPlayerBridge,
  restoreDownloadQueue,
  resumeAutoplay,
  setLiveSetting,
  getEpisodeQueue,
  playQueuedEpisode,
  cancelSleepTimer,
  setSleepTimer,
  sleepDeadline,
  SPEEDS,
  SUB_DELAY_STEP,
  switchQuality,
  switchToDownload,
  downloadedLabel,
  syncOfflineProgress,
  skipInterval,
  hideControlsAfter,
  showsRemaining,
  setShowsRemaining,
  autoplayNextEnabled,
  getUserQueue,
  clearQueue,
  playQueued,
  removeFromQueue,
  AUDIO_DELAY_STEP,
  getStreamSource,
  getNowPlayingFull,
} from "./playback";
import {
  el,
  clear,
  asButton,
  closeMenus,
  toast,
  errorState,
  openDialog,
  recentSearches,
  rememberSearch,
  clearRecentSearches,
  icon,
  art,
} from "./ui";
import { registerAdaptiveQuality } from "./adaptive";
import { wireSmoothScroll } from "./scroll";
import { initTheme } from "./theme";
import { wireSpatialNav } from "./spatial";
import { fillChannelsPanel, liveTitleLines, stepChannel } from "./channels-panel";
import { preloadLineup } from "./lineup";
import { wirePrefetch } from "./prefetch";
import { clearCache, hydrateCache, getCached, setCached } from "./cache";
import { renderLogin } from "./views/login";
import { renderHome } from "./views/home";
import { renderLibrary, renderSearch } from "./views/library";
import { renderFavorites } from "./views/favorites";
import { renderItem } from "./views/item";
import { renderLiveTv } from "./views/livetv";
import { renderDownloads, updateDownloadProgress } from "./views/downloads";
import { renderSettings } from "./views/settings";
import { renderMusic } from "./views/music";
import { renderBooks } from "./views/books";
import { wireMusicPlayer } from "./views/musicPlayer";

const $ = (id: string) => document.getElementById(id)!;

const ICONS: Record<string, string> = {
  home: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 10.5 12 3l9 7.5"/><path d="M5 9.5V21h14V9.5"/></svg>',
  movies: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="M7 5v14M17 5v14M3 10h4M3 14h4M17 10h4M17 14h4"/></svg>',
  tv: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="6" width="18" height="12" rx="2"/><path d="M8 21h8M12 18v3"/></svg>',
  livetv: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="7" width="18" height="13" rx="2"/><path d="m8 3 4 4 4-4"/><circle cx="12" cy="13.5" r="3"/></svg>',
  downloads: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 3v12m0 0 4-4m-4 4-4-4"/><path d="M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2"/></svg>',
  settings: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .34 1.87l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.7 1.7 0 0 0-1.87-.34 1.7 1.7 0 0 0-1 1.55V21a2 2 0 1 1-4 0v-.09a1.7 1.7 0 0 0-1-1.55 1.7 1.7 0 0 0-1.87.34l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.7 1.7 0 0 0 .34-1.87 1.7 1.7 0 0 0-1.55-1H3a2 2 0 1 1 0-4h.09a1.7 1.7 0 0 0 1.55-1 1.7 1.7 0 0 0-.34-1.87l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.7 1.7 0 0 0 1.87.34h0a1.7 1.7 0 0 0 1-1.55V3a2 2 0 1 1 4 0v.09a1.7 1.7 0 0 0 1 1.55h0a1.7 1.7 0 0 0 1.87-.34l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.7 1.7 0 0 0-.34 1.87v0a1.7 1.7 0 0 0 1.55 1H21a2 2 0 1 1 0 4h-.09a1.7 1.7 0 0 0-1.55 1z"/></svg>',
  folder: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 7a2 2 0 0 1 2-2h4l2 3h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>',
  music: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18V5.5l10-2V16"/><circle cx="6.5" cy="18" r="2.5"/><circle cx="16.5" cy="16" r="2.5"/></svg>',
  musicLibrary: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="4" height="16" rx="1"/><rect x="9" y="4" width="4" height="16" rx="1"/><path d="m16 5 3.5 1L16.5 20 13 19"/></svg>',
  books: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 4.5h9.5a3 3 0 0 1 3 3v12H8a3 3 0 0 1-3-3z"/><path d="M5 16.5a3 3 0 0 1 3-3h9.5"/></svg>',
  favorites: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="m12 4.5 2.35 4.9 5.15.7-3.8 3.75.95 5.15L12 16.6l-4.65 2.4.95-5.15L4.5 10.1l5.15-.7z"/></svg>',
};

let playerActive = false;
let playerEmbedded = false;
/** Which decoder mpv settled on, as last written for Settings to report — kept
 *  across restarts so it can say without a stream running while the page is
 *  open (which it can't be: the video covers the page). Compared first so the
 *  once-a-second status tick doesn't rewrite storage with the same value. */
let lastHwdecSaved = "";
let videoFullscreen = false;
let videoPip = false;
let seeking = false;

// Fullscreen shows the same player bar as windowed mode: HTML can never draw
// over the X11 video child window, so the backend cuts the bar's strip out of
// that window's shape while the controls are revealed and fills it back in on
// idle. The picture itself is never resized, so it doesn't jump as the bar
// comes and goes. Mouse motion over the video is reported by mpv
// ("player-mouse" events — the pointer belongs to mpv there); motion over the
// revealed bar comes from normal DOM events.
let fsBarShown = false;
let fsHideTimer = 0;
/**
 * Whether the pointer is over the bar, tracked explicitly from `mouseenter`/
 * `mouseleave` rather than read off `:hover` at hide-check time.
 *
 * The bar sits directly beside the embedded video, which is a *native* child
 * window rather than a DOM element — so the one crossing that matters here
 * (pointer leaving the bar toward the video) isn't a move between two
 * ordinary elements, and `:hover` can be left stuck true by it rather than
 * clearing the way it would for an ordinary `mouseout`. A bar that always
 * believes it's still hovered never times out — which is the bug this
 * replaces: the auto-hide silently not firing, rather than firing wrong.
 */
let fsBarHovered = false;

/**
 * The last pointer position that came from a *real* move, in client px, and
 * the last one mpv reported over the video, in its own coordinates.
 *
 * Both exist to answer one question: did the pointer actually move, or did the
 * geometry move under it? Revealing and hiding the bar resizes the video
 * widget, and both sides of the app report that resize as pointer activity
 * even when the cursor has not shifted a pixel — WebKit re-hit-tests after the
 * layout change and dispatches a synthetic `mousemove` at the coordinates the
 * pointer already had, and mpv re-emits `mouse-pos` because the widget it
 * measures against changed size (usually only `hover` flipping).
 *
 * Taking either at face value closes a feedback loop: the bar hides, the video
 * grows back over the cursor, that "activity" pokes the controls, the bar
 * reveals, the video shrinks, and round it goes — with the reveal latching
 * `fsBarHovered` on the way past, which is what left the bar up permanently
 * until the user moved the pointer over it and off again to produce one real
 * `mouseleave`.
 */
let fsLastPointer = { x: -1, y: -1 };
let fsLastVideoPointer = { x: -1, y: -1 };

function fsSetBar(shown: boolean): void {
  if (fsBarShown === shown) return;
  fsBarShown = shown;
  // The bar stopped following the status ticks while it was out of sight
  // (see `barOutOfSight`); bring it up to date before it slides in.
  if (shown && lastBarStatus) updatePlayerBar(lastBarStatus);
  $("player-bar").classList.toggle("revealed", shown);
  invoke("player_set_viewport", { full: true, bar: shown }).catch(() => {});
  // Subtitles sit at the very bottom of the frame, which is exactly the strip
  // the bar takes over; lift them clear of it for as long as it's up. Never
  // lower than where Settings put them, and back to that, not the bottom edge.
  const pos = userSubPos();
  invoke("player_mpv_command", {
    cmd: ["set_property", "sub-pos", shown ? Math.min(pos, 93) : pos],
  }).catch(() => {});
}

/** Settings' subtitle position (`sub_pos`; 100 is the bottom edge). */
function userSubPos(): number {
  const v = Number(api.getConfig()?.sub_pos ?? 100);
  return isFinite(v) ? v : 100;
}

/** Pointer activity: reveal the controls and (re)start the clock that hides
 *  them again. */
function fsPokeControls(): void {
  if (!videoFullscreen) return;
  fsSetBar(true);
  fsArmHide();
}

/**
 * (Re)start the auto-hide clock without revealing anything. Kept apart from
 * `fsPokeControls` because not every event that should extend a visible bar's
 * life should also be able to bring a hidden one back — see the bar's
 * `mouseleave` handler, where conflating the two was a 2.5 s reveal/hide loop.
 */
function fsArmHide(): void {
  clearTimeout(fsHideTimer);
  fsHideTimer = window.setTimeout(() => {
    if (!videoFullscreen) return;
    // Don't hide under the pointer or while a panel is open.
    if (fsBarHovered || $("player-bar").querySelector(".pb-panel")) {
      fsArmHide();
      return;
    }
    fsSetBar(false);
  }, hideControlsAfter() * 1000);
}

/**
 * Whether a `mousemove` is the pointer moving, as opposed to the layout
 * moving under it. Two kinds of impostor: a repeat of the last real position
 * (WebKit re-hit-tests after a layout change and dispatches a move at the
 * coordinates the pointer already had), and a position outside the window —
 * WebKit reports the pointer crossing from the webview onto the native video
 * widget as a move to just outside its own bounds, and every hide of the
 * fullscreen bar produces one, since the video grows back over the strip the
 * pointer was resting in. Taken as motion, that crossing revealed the bar the
 * hide had just put away.
 */
function fsPointerMoved(e: MouseEvent): boolean {
  if (
    e.clientX < 0 ||
    e.clientY < 0 ||
    e.clientX >= window.innerWidth ||
    e.clientY >= window.innerHeight
  ) {
    return false;
  }
  return e.clientX !== fsLastPointer.x || e.clientY !== fsLastPointer.y;
}

async function setVideoFullscreen(full: boolean): Promise<void> {
  videoFullscreen = full;
  clearTimeout(fsHideTimer);
  // Leaving fullscreen mid-reveal would otherwise strand the subtitles at the
  // lifted position fsSetBar puts them in.
  if (fsBarShown) {
    invoke("player_mpv_command", { cmd: ["set_property", "sub-pos", userSubPos()] }).catch(() => {});
  }
  fsBarShown = false;
  // Entering or leaving fullscreen is a fresh start for the hover latch: the
  // pointer's last DOM crossing was made against a layout that no longer
  // exists, and a stale `true` carried across would mean the new session's
  // auto-hide never fires at all.
  fsBarHovered = false;
  // The video surface covers the whole window in fullscreen and only ever
  // opens a hole for the bar-height strip the bar itself is drawn in — but
  // that hole is cut by an async call to the backend (below), while the bar's
  // own slide in/out is a local CSS transition. The two aren't synchronised,
  // so there's a real window where the strip has been un-clipped from the
  // video (or not yet re-clipped) while the bar has already animated out of
  // it — and what shows through is whatever the app underneath happens to be
  // drawing at that pixel, not black. This class paints the app black behind
  // the whole window for as long as fullscreen playback owns it, so that gap
  // reads as "the video is still there" instead of "the app flashed through".
  document.body.classList.toggle("video-fs", full);
  // `fs` swaps the bar's hard top border for a gradient and parks it off the
  // bottom edge; `revealed` (set by fsSetBar) slides it back up.
  const bar = $("player-bar");
  bar.classList.toggle("fs", full);
  bar.classList.remove("revealed");
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
  // Back to windowed: the bar is permanently on screen again, and may have
  // skipped every tick since it was last revealed.
  else if (lastBarStatus) updatePlayerBar(lastBarStatus);
}

/**
 * Picture in picture: the backend reparents the running video surface into a
 * small always-on-top window, so the stream never restarts and never re-seeks.
 *
 * The player bar stays where it is and goes on being the transport — it is the
 * only set of controls there is, since the floating window is bare picture.
 */
async function setVideoPip(on: boolean): Promise<void> {
  // Only the *entry* needs an embedded surface to move. Closing has to work
  // from the teardown path too, which clears `playerEmbedded` first and would
  // otherwise leave the floating window on screen with nothing playing in it.
  if (on && !playerEmbedded) return;
  // Fullscreen and a corner window are two answers to the same question.
  if (on && videoFullscreen) await setVideoFullscreen(false);
  try {
    videoPip = await invoke<boolean>("player_set_pip", { on });
  } catch (e) {
    toast(String(e), "error");
    videoPip = false;
  }
  reflectPip();
}

/** Draw the bar's state from `videoPip`: called on our own toggle and when the
 *  floating window is closed from its own title bar. */
/**
 * `body.video-covered`: the embedded picture is over the page, so nothing on
 * the page can be seen. styles.css freezes the perpetual animations (offline
 * pulse, skeleton shimmer, spinners) on it — invisible motion still costs a
 * composited frame per tick, and on GTK3 a full-window readback with it.
 * Picture-in-picture is deliberately excluded: the page is being browsed.
 */
function reflectCoverage(): void {
  document.body.classList.toggle("video-covered", playerActive && playerEmbedded && !videoPip);
}

function reflectPip(): void {
  const bar = document.getElementById("player-bar");
  bar?.classList.toggle("pip", videoPip);
  reflectCoverage();
  const btn = document.getElementById("pb-pip");
  if (!btn) return;
  btn.classList.toggle("on", videoPip);
  btn.setAttribute("aria-pressed", String(videoPip));
  btn.title = videoPip
    ? "Bring the video back into the window (p)"
    : "Picture in picture (p)";
  // Fullscreen would leave the app window empty while the picture is elsewhere.
  const fs = document.getElementById("pb-fullscreen") as HTMLButtonElement | null;
  if (fs) fs.disabled = videoPip;
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

// Where each route was last scrolled to. Going back to a library you were 40
// rows deep in and landing at the top of it is the single most annoying thing a
// media browser can do; every polished one restores the position instead.
const scrollMemory = new Map<string, number>();
let restoreScroll = false;

function goBack(): void {
  const target = navStack.pop();
  if (target != null) {
    navigatingBack = true;
    restoreScroll = true;
    location.hash = target;
  }
  updateBackButton();
}

/** True while the current route is Home, which is where a trail starts. */
function atHome(): boolean {
  const hash = location.hash || "#/home";
  return (hash.match(/^#\/([^/]*)/)?.[1] || "home") === "home";
}

function updateBackButton(): void {
  const btn = document.getElementById("back-btn");
  if (btn) btn.toggleAttribute("hidden", navStack.length === 0);
}

// Pages that can't render without the server.
const SERVER_PAGES = ["home", "lib", "item", "livetv", "search", "favorites", "music", "books"];

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

/** Mark the sidebar entry for the current hash. Called from both the router and
 *  buildNav: the nav is built asynchronously (it waits on /Views), so the first
 *  route() of a session runs before the buttons exist. */
function highlightNav(): void {
  const hash = location.hash || "#/home";
  const page = hash.match(/^#\/([^/]*)/)?.[1] ?? "home";
  document.querySelectorAll(".nav-item").forEach((n) => {
    const route = n.getAttribute("data-route");
    const active = route === hash || route === `#/${page}` || (!!route && hash.startsWith(`${route}/`));
    n.classList.toggle("active", active);
    // The accent colour is the only thing that said "you are here"; a screen
    // reader needs to be told in words.
    if (active) n.setAttribute("aria-current", "page");
    else n.removeAttribute("aria-current");
  });
}

/**
 * Settle the page after a render: put the scroll where this route belongs and
 * tell the top bar whether it's floating over content or over the top of it.
 */
function settleScroll(content: HTMLElement, to: number): void {
  // #content scrolls smoothly, which is right for a jump the user asked for and
  // wrong for landing on a page — restoring a position should be where the page
  // starts, not somewhere it animates to.
  const smooth = content.style.scrollBehavior;
  content.style.scrollBehavior = "auto";
  content.scrollTop = to;
  content.style.scrollBehavior = smooth;
  // scrollTop = 0 on an already-unscrolled page fires no scroll event, so the
  // bar's state has to be set here as well as in the listener.
  document.getElementById("topbar")?.classList.toggle("scrolled", content.scrollTop > 4);
}

async function route(): Promise<void> {
  closeMenus();
  const content = $("content");
  const hash = location.hash || "#/home";
  const [, page, arg] = hash.match(/^#\/([^/]*)\/?(.*)$/) ?? [];
  // Only a Back returns to where you were; picking a route yourself starts it
  // at the top, the same as opening it for the first time.
  const landAt = restoreScroll ? scrollMemory.get(hash) ?? 0 : 0;
  restoreScroll = false;

  highlightNav();
  // Restart the page-in animation. Reading offsetWidth between the two flushes
  // the removal, so re-entering the same route still animates.
  content.classList.remove("view-in");
  void content.offsetWidth;
  content.classList.add("view-in");

  // Downloaded music is the one music page that works with no server.
  if (api.isOffline() && SERVER_PAGES.includes(page || "home") && !(page === "music" && arg === "downloaded")) {
    renderOffline(content);
    settleScroll(content, 0);
    return;
  }

  try {
    switch (page) {
      case "home": await renderHome(content); break;
      case "lib": await renderLibrary(content, arg); break;
      case "item": await renderItem(content, arg); break;
      case "favorites": await renderFavorites(content); break;
      case "livetv": await renderLiveTv(content); break;
      case "downloads": await renderDownloads(content); break;
      case "settings": await renderSettings(content, showLogin); break;
      case "search": await renderSearch(content, decodeURIComponent(arg)); break;
      case "music": await renderMusic(content, arg); break;
      case "books": await renderBooks(content, arg); break;
      default: await renderHome(content);
    }
  } catch (e: any) {
    clear(content);
    content.append(
      errorState("This page didn't load", e, () => {
        void route();
      })
    );
  }
  settleScroll(content, landAt);
}

// ---------- Shell ----------

const VIEWS_CACHE_KEY = "views";

/** What the sidebar draws from a library list — enough to tell whether a
 *  refreshed list needs the nav rebuilt. */
function viewsSignature(views: any[]): string {
  return views.map((v) => `${v.Id}:${v.Name}:${v.CollectionType ?? ""}`).join(",");
}

async function buildNav(): Promise<void> {
  // The library list is the one request every page of a session waits on for
  // its sidebar; the last known list paints it immediately and the fresh one
  // only redraws it if a library was added, renamed or removed.
  const cached = getCached<any[]>(VIEWS_CACHE_KEY);
  paintNav(cached ?? null);

  const s = api.getSession();
  const userBox = $("topbar-user");
  clear(userBox);
  if (s) {
    userBox.append(
      el("span", {}, [s.userName]),
      el("div", { class: "avatar", "aria-hidden": "true" }, [s.userName.slice(0, 1).toUpperCase()])
    );
  }
  void updateSidebarFooter();

  const views = await api.getViews().catch(() => null);
  if (!views) {
    if (!cached) paintNav([]);
  } else {
    if (!cached || viewsSignature(cached) !== viewsSignature(views)) paintNav(views);
    setCached(VIEWS_CACHE_KEY, views);
  }
}

/** Draw the sidebar for a library list. `null` is "not known yet": only the
 *  entries that don't depend on the server, until the list arrives. */
function paintNav(views: any[] | null): void {
  const nav = $("nav");
  clear(nav);

  const add = (route: string, label: string, icon: string) => {
    const b = el("button", { class: "nav-item", "data-route": route, html: icon });
    b.append(el("span", {}, [label]));
    b.addEventListener("click", () => (location.hash = route));
    nav.append(b);
  };

  add("#/home", "Home", ICONS.home);
  if (!views) {
    highlightNav();
    return;
  }

  let hasLiveTv = false;
  const hasMusic = views.some((v) => v.CollectionType === "music");
  const hasBooks = views.some((v) => v.CollectionType === "books" || v.CollectionType === "audiobooks");
  if (views.length) nav.append(el("div", { class: "nav-sep" }, ["Libraries"]));
  for (const v of views) {
    if (v.CollectionType === "livetv") { hasLiveTv = true; continue; }
    // Only video libraries: Books (audiobooks), Music, Photos etc. are out of scope.
    if (!api.VIDEO_COLLECTION_TYPES.includes(v.CollectionType)) continue;
    const icon =
      v.CollectionType === "movies" ? ICONS.movies :
      v.CollectionType === "tvshows" ? ICONS.tv : ICONS.folder;
    add(`#/lib/${v.Id}`, v.Name, icon);
  }

  // Music and audiobooks have screens of their own (views/music.ts, books.ts)
  // rather than a library grid each.
  if (hasMusic) {
    nav.append(el("div", { class: "nav-sep" }, ["Music"]));
    add("#/music/discover", "Listen Now", ICONS.music);
    add("#/music/library", "Library", ICONS.musicLibrary);
  }
  if (hasBooks) {
    if (!hasMusic) nav.append(el("div", { class: "nav-sep" }, ["Listening"]));
    add("#/books", "Audiobooks", ICONS.books);
  }

  nav.append(el("div", { class: "nav-sep" }, ["Aquarium"]));
  add("#/favorites", "Favorites", ICONS.favorites);
  // Only servers that actually have a Live TV library get the entry: without a
  // tuner configured, the page can never say anything but "no channels". A
  // custom M3U source doesn't go through the server at all, so it earns the
  // entry on its own.
  if (hasLiveTv || api.getConfig()?.livetv_source === "custom") {
    add("#/livetv", "Live TV", ICONS.livetv);
  }
  add("#/downloads", "Downloads", ICONS.downloads);
  add("#/settings", "Settings", ICONS.settings);

  highlightNav();
}

/**
 * The sidebar's footer was an empty styled box. It now holds the two facts that
 * belong in the corner of a media client: which build this is, and whether the
 * app has anything outstanding with the server — transfers in flight, or watch
 * progress recorded offline that hasn't been pushed back yet.
 */
async function updateSidebarFooter(): Promise<void> {
  const foot = $("sidebar-footer");
  const [info, pending, downloads] = await Promise.all([
    invoke<any>("app_info").catch(() => ({})),
    invoke<number>("progress_pending").catch(() => 0),
    invoke<any[]>("downloads_list").catch(() => [] as any[]),
  ]);
  const active = downloads.filter((d) => d?.status === "downloading").length;

  let cls = "ok";
  let text = "Synced";
  if (api.isOffline()) {
    cls = "warn";
    text = pending > 0 ? `Offline · ${pending} to sync` : "Offline";
  } else if (active > 0) {
    cls = "busy";
    text = `${active} download${active === 1 ? "" : "s"} running`;
  } else if (pending > 0) {
    cls = "busy";
    text = `Syncing ${pending} item${pending === 1 ? "" : "s"}`;
  }

  clear(foot);
  foot.append(
    el("div", { class: "foot-version" }, [
      el("img", { src: "/aquarium-logo.svg", alt: "" }),
      el("span", {}, [`Aquarium ${info.version ? `v${info.version}` : ""}`.trim()]),
    ]),
    el("div", { class: `foot-line ${cls}` }, [
      el("span", { class: "foot-dot" }),
      el("span", {}, [text]),
    ])
  );
}

function updateOfflinePill(): void {
  $("offline-pill").toggleAttribute("hidden", !api.isOffline());
  void updateSidebarFooter();
}

/** The account whose screens the persistent cache holds: one server, one user. */
function cacheOwner(): string | null {
  const s = api.getSession();
  return s ? `${s.server}|${s.userId}` : null;
}

async function showShell(): Promise<void> {
  // The last run's screens come back from disk before anything is routed, so
  // the first page of this run paints the way a revisit does — instantly, and
  // refreshed behind itself — instead of behind a skeleton. `boot` starts this
  // read alongside the reachability probe; a fresh sign-in starts it here.
  const owner = cacheOwner();
  if (owner) await hydrateCache(owner);
  $("login-root").classList.add("hidden");
  $("shell").classList.remove("hidden");
  void wireMusicPlayer();
  buildNav();
  updateOfflinePill();
  // Reopen where the last session left off. Only on a cold start with no hash
  // — a hash already in the URL is a deliberate destination and wins.
  if (!location.hash) {
    const last = lastRoute();
    if (last) history.replaceState(null, "", last);
  }
  // Offline with content downloaded: land on Downloads, not a dead Home.
  if (api.isOffline() && (!location.hash || location.hash === "#/home")) {
    location.hash = "#/downloads";
  }
  route();
  // Push any offline watch progress accumulated while away.
  syncOfflineProgress(false);
  // Pick the season-download queue back up where the last run left it.
  void restoreDownloadQueue();
  // Live TV's line-up, so the guide and any "On Now" row open with it there.
  preloadLineup();
}

function showLogin(): void {
  // A new session — a different account, or the same one signing back in —
  // must never paint a previous session's cached screens before its own
  // requests have landed.
  clearCache();
  $("shell").classList.add("hidden");
  $("login-root").classList.remove("hidden");
  renderLogin($("login-root"), showShell);
}

/**
 * Settings → Add Account: the sign-in screen, with the account in use still
 * signed in behind it. Cancel goes back to it untouched; a sign-in makes the
 * new account the one in use and the shell redraws for it.
 */
function showAddAccount(): void {
  closeMenus();
  $("shell").classList.add("hidden");
  $("login-root").classList.remove("hidden");
  const back = () => {
    $("login-root").classList.add("hidden");
    $("shell").classList.remove("hidden");
  };
  renderLogin($("login-root"), () => void enterAccount(), { adding: true, onCancel: back });
}

/**
 * The account in use has just changed (a switch, or Add Account). Whatever was
 * playing belongs to the last one, and so do the screens in memory; the
 * persistent cache is keyed per account, so the new one's own screens come
 * back from disk.
 */
async function enterAccount(): Promise<void> {
  if (playerActive) await playerCtl.stop().catch(() => {});
  clearCache();
  history.replaceState(null, "", "#/home");
  const s = api.getSession();
  await showShell();
  if (s) toast(`Signed in as ${s.userName}`, "ok");
}

async function switchToAccount(key: string): Promise<void> {
  closeMenus();
  try {
    await api.switchAccount(key);
  } catch (e: any) {
    toast(e.message ?? "Couldn't switch account", "error");
    route();
    return;
  }
  await enterAccount();
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
  // A speech bubble with lines of text — what the Apple app uses
  // (captions.bubble). It used to be a plain box with lines, which next to
  // the quality icon's rows of sliders read as the same shape twice.
  subtitles:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6.5A2.5 2.5 0 0 1 6.5 4h11A2.5 2.5 0 0 1 20 6.5v8a2.5 2.5 0 0 1-2.5 2.5h-6.3L7 20.4V17h-.5A2.5 2.5 0 0 1 4 14.5z"/><path d="M7.5 9h4.5M14.5 9h2M7.5 12.5h2M12 12.5h4.5"/></svg>',
  // A waveform, not a speaker: the speaker already means volume, two buttons
  // to its right, and the two were being confused for each other.
  audio:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M3.5 10.5v3M7 7.5v9M10.5 4.5v15M14 8v8M17.5 6v12M21 10v4"/></svg>',
  // Three states so the icon alone says whether sound is coming out.
  volHigh:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 9.5v5h3.5L12 19V5L7.5 9.5H4z" fill="currentColor" stroke="none"/><path d="M15.5 9a4.2 4.2 0 0 1 0 6M18 6.5a8 8 0 0 1 0 11" stroke-linecap="round"/></svg>',
  volLow:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 9.5v5h3.5L12 19V5L7.5 9.5H4z" fill="currentColor" stroke="none"/><path d="M15.5 9a4.2 4.2 0 0 1 0 6" stroke-linecap="round"/></svg>',
  volMute:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 9.5v5h3.5L12 19V5L7.5 9.5H4z" fill="currentColor" stroke="none"/><path d="m15.5 10 5 4m0-4-5 4" stroke-linecap="round"/></svg>',
  tune:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M12 4v5m0 6v5M5.5 4v9m0 4v3M18.5 4v3m0 4v9"/><circle cx="12" cy="12" r="2"/><circle cx="5.5" cy="15" r="2"/><circle cx="18.5" cy="9" r="2"/></svg>',
  // The "HD" badge every TV and streaming app uses for stream quality. The
  // old rows-of-sliders glyph was one of three slider icons in the same bar.
  quality:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><rect x="2.5" y="5.5" width="19" height="13" rx="2.5"/><path d="M6.5 9v6M6.5 12h3.4M9.9 9v6" stroke-linecap="round"/><path d="M13.3 9v6h2.2a3 3 0 0 0 0-6z"/></svg>',
  // Up next: a list with a play mark, the standard "play queue" glyph.
  episodes:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6.5h16M4 12h9M4 17.5h7"/><path d="M15.5 13.2a.7.7 0 0 1 1.05-.6l5 3.05a.7.7 0 0 1 0 1.2l-5 3.05a.7.7 0 0 1-1.05-.6z" fill="currentColor" stroke="none"/></svg>',
  fullscreen:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 9V5.5A1.5 1.5 0 0 1 5.5 4H9M15 4h3.5A1.5 1.5 0 0 1 20 5.5V9M20 15v3.5a1.5 1.5 0 0 1-1.5 1.5H15M9 20H5.5A1.5 1.5 0 0 1 4 18.5V15"/></svg>',
  // The browser convention: the frame, with the picture pulled out into the
  // corner of it.
  pip:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><rect x="3" y="5" width="18" height="14" rx="2.5"/><rect x="12" y="11.5" width="7" height="6" rx="1.5" fill="currentColor" stroke="none"/></svg>',
  // Half-lit sun: the universal "brightness and contrast" mark.
  picture:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="4.2"/><path d="M12 2.6v2.2M12 19.2v2.2M2.6 12h2.2M19.2 12h2.2M5.4 5.4l1.6 1.6M17 17l1.6 1.6M18.6 5.4 17 7M7 17l-1.6 1.6"/><path d="M12 7.8a4.2 4.2 0 0 1 0 8.4z" fill="currentColor" stroke="none"/></svg>',
  sleep:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M20 14.5A8.2 8.2 0 0 1 9.5 4 8.4 8.4 0 1 0 20 14.5z"/></svg>',
  // A list of marks along a line: chapters.
  chapters:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M3.5 12h17"/><path d="M6.5 8.5v7M12 8.5v7M17.5 8.5v7"/></svg>',
  // The circled "i" every player uses for stream statistics.
  info:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="8.5"/><path d="M12 11v5.5"/><circle cx="12" cy="7.8" r="1.1" fill="currentColor" stroke="none"/></svg>',
};

/** The skip buttons' glyph, with the interval from Settings written in it. */
function skipIcon(forward: boolean, seconds: number): string {
  const glyph = forward ? PB_ICONS.fwd30 : PB_ICONS.back30;
  return glyph.replace(">30</text>", `>${seconds}</text>`);
}

/** Point the skip buttons at the current interval: glyph, tooltip, and the
 *  number the click uses (read at click time, so Settings applies at once). */
function syncSkipButtons(): void {
  const n = skipInterval();
  const back = document.getElementById("pb-back");
  const fwd = document.getElementById("pb-fwd");
  if (back && back.dataset.n !== String(n)) {
    back.dataset.n = String(n);
    back.innerHTML = skipIcon(false, n);
    back.title = `Back ${n}s (←)`;
  }
  if (fwd && fwd.dataset.n !== String(n)) {
    fwd.dataset.n = String(n);
    fwd.innerHTML = skipIcon(true, n);
    fwd.title = `Forward ${n}s (→)`;
  }
}

function pbButton(id: string, icon: string, tip: string, onClick: () => void): HTMLElement {
  const b = el("button", { class: "btn icon", id, title: tip, html: icon });
  b.addEventListener("click", () => {
    // Trace clicks so "button does nothing" reports can be diagnosed from
    // ~/.local/share/aquarium/debug.log.
    invoke("ui_log", { msg: `click ${id}` }).catch(() => {});
    Promise.resolve(onClick()).catch((e) => {
      invoke("ui_log", { msg: `click ${id} error: ${e}` }).catch(() => {});
    });
  });
  return b;
}

/**
 * mpv's audio/timing state as last reported. Mirrored here because relative
 * adjustments (a nudge of the volume, one step of subtitle delay) need a base
 * to work from, and mpv is the authority on it — its own key bindings and the
 * uosc overlay change these values without asking us.
 */
interface PlayerState {
  volume: number;
  mute: boolean;
  speed: number;
  subDelay: number;
  audioDelay: number;
}

const pbState: PlayerState = { volume: getVolume(), mute: false, speed: 1, subDelay: 0, audioDelay: 0 };

/** Chapter marks for the current file, as mpv reported them. */
interface Chapter {
  time: number;
  title: string;
}

let pbChapters: Chapter[] = [];

/** The chapter containing `seconds`, for the scrubber's hover readout. */
function chapterNameAt(seconds: number): string | null {
  let found: string | null = null;
  for (const c of pbChapters) {
    if (c.time > seconds) break;
    found = c.title || null;
  }
  return found;
}

/** Redraw the tick marks. Cheap, and only when the list actually changed —
 *  chapter-list is re-sent on every track change. */
function renderChapters(duration: number): void {
  const host = document.getElementById("pb-chapters");
  if (!host) return;
  const key = duration > 0 ? pbChapters.map((c) => c.time.toFixed(1)).join(",") : "";
  if (host.dataset.key === key) return;
  host.dataset.key = key;
  clear(host);
  if (!key) return;
  for (const c of pbChapters) {
    if (c.time >= duration) continue;
    const mark = el("i", { title: c.title || api.secondsToClock(c.time) });
    mark.style.left = `${(c.time / duration) * 100}%`;
    host.append(mark);
  }
}

/**
 * Panels open as an overlay INSIDE the player bar. Anywhere else (a dropdown,
 * a uosc menu) they can be hidden — the X11 video child window covers all HTML
 * above the bar, and uosc can't draw before mpv's video output is up (which
 * is exactly when a stuck stream makes you want a lower bitrate).
 *
 * A panel may attach a `sync` callback: it's re-run on every player-status so
 * the panel keeps telling the truth while mpv is also being driven from its own
 * key bindings and overlay.
 */
interface BarPanel extends HTMLElement {
  sync?: (st: PlayerState) => void;
}

function closeBarPanel(): void {
  $("player-bar").querySelector(".pb-panel")?.remove();
}

function toggleBarPanel(name: string, label: string, build: (panel: BarPanel) => void): void {
  const bar = $("player-bar");
  const open = bar.querySelector(".pb-panel") as HTMLElement | null;
  const reopeningSame = open?.dataset.panel === name;
  open?.remove();
  // Pressing the same button again closes rather than redraws.
  if (reopeningSame) return;
  const panel = el("div", { class: "pb-panel", "data-panel": name }, [
    el("span", { class: "pb-panel-label" }, [label]),
  ]) as BarPanel;
  build(panel);
  panel.append(
    el("button", {
      class: "btn small pb-panel-close",
      title: "Close",
      "aria-label": "Close",
      onClick: closeBarPanel,
    }, [icon("close", 15)])
  );
  bar.append(panel);
  panel.sync?.(pbState);
}

function toggleQualityPicker(): void {
  toggleBarPanel("quality", "Quality", (panel) => {
    const state = getQualityState();
    if (!state || state.live) {
      panel.append(el("span", { class: "pb-panel-note" }, ["Live TV — quality is set by the channel"]));
      return;
    }
    // The downloaded file is a rung of its own, above the streams: it's what
    // plays by default, and the way back to it after trying a stream.
    if (state.download) {
      panel.append(
        el("button", {
          class: `btn small${state.isLocal ? " primary" : ""}`,
          title: "Play the downloaded file from disk",
          onClick: () => {
            closeBarPanel();
            if (state.isLocal) return;
            switchToDownload()
              .then((ok) => { if (!ok) toast("The download isn't there anymore", "error"); })
              .catch((e) => toast(String(e), "error"));
          },
        }, [downloadedLabel(state.download)])
      );
    }
    // Streaming needs the server; from a download while offline there's
    // nowhere to switch to.
    if (state.isLocal && api.isOffline()) {
      panel.append(el("span", { class: "pb-panel-note" }, ["Offline — streaming unavailable"]));
      return;
    }
    for (const q of QUALITY_CHOICES) {
      panel.append(
        el("button", {
          class: `btn small${!state.isLocal && q.maxBitrate === state.current ? " primary" : ""}`,
          onClick: () => {
            closeBarPanel();
            switchQuality(q.maxBitrate).catch((e) => toast(`Couldn't start the stream: ${e?.message ?? e}`, "error"));
          },
        }, [q.label])
      );
    }
    // Whether the player is allowed to move that choice by itself. It belongs
    // next to the rungs it moves between — a stream that changed quality on its
    // own is the moment anyone goes looking for the off switch.
    const auto = el("button", {
      class: `btn small${isAdaptiveEnabled() ? " primary" : ""}`,
      title:
        "Drop to a smaller stream when playback stalls or can't keep up, " +
        "and climb back when the connection steadies",
      onClick: (ev: Event) => {
        const on = !isAdaptiveEnabled();
        setAdaptiveEnabled(on);
        const btn = ev.currentTarget as HTMLButtonElement;
        btn.classList.toggle("primary", on);
        toast(on ? "Quality will adapt to the connection" : "Quality stays where you set it", "ok");
      },
    }, ["Auto"]);
    panel.append(el("span", { class: "pb-panel-label" }, ["Adapt"]), auto);
  });
}

/** Best-effort English name for an mpv track's language tag ("eng" -> "English").
 *  mpv reports whatever the container did — usually ISO 639-2, sometimes
 *  639-1 — and Intl.DisplayNames understands both; null for anything it
 *  doesn't recognise, so the caller can fall back to the raw tag. */
function languageName(code: string | null | undefined): string | null {
  if (!code || code === "und") return null;
  try {
    const name = new Intl.DisplayNames(["en"], { type: "language" }).of(code);
    return name && name.toLowerCase() !== code.toLowerCase() ? name : null;
  } catch {
    return null;
  }
}

/** What to print on a track's button: the file's own title for it if it named
 *  one, else the language, else just "Track N" — always something, since an
 *  mpv track id alone means nothing to look at. */
function trackLabel(t: any, index: number): string {
  return t.title || languageName(t.lang) || t.lang || `Track ${index + 1}`;
}

/** Audio and subtitle pickers: one click shows every track with its language,
 *  the current one highlighted — replacing uosc's own in-video menu, which
 *  took a click to open and another to actually see what was selected. */
function toggleAudioPanel(): void {
  toggleBarPanel("audio", "Audio track", (panel) => {
    const tracks = getTracks().filter((t) => t.type === "audio");
    if (!tracks.length) {
      panel.append(el("span", { class: "pb-panel-note" }, ["No audio tracks reported yet"]));
      return;
    }
    tracks.forEach((t, i) => {
      panel.append(
        el("button", {
          class: `btn small${t.selected ? " primary" : ""}`,
          onClick: () => {
            closeBarPanel();
            playerCtl.setTrack("audio", t.id).catch((e) => toast(String(e), "error"));
          },
        }, [trackLabel(t, i)])
      );
    });
  });
}

function toggleSubtitlePanel(): void {
  toggleBarPanel("subs", "Subtitles", (panel) => {
    const tracks = getTracks().filter((t) => t.type === "sub");
    const noneSelected = !tracks.some((t) => t.selected);
    panel.append(
      el("button", {
        class: `btn small${noneSelected ? " primary" : ""}`,
        onClick: () => {
          closeBarPanel();
          playerCtl.setTrack("sub", "no").catch((e) => toast(String(e), "error"));
        },
      }, ["Off"])
    );
    if (!tracks.length) {
      panel.append(el("span", { class: "pb-panel-note" }, ["No subtitles for this file"]));
      return;
    }
    tracks.forEach((t, i) => {
      panel.append(
        el("button", {
          class: `btn small${t.selected ? " primary" : ""}`,
          onClick: () => {
            closeBarPanel();
            playerCtl.setTrack("sub", t.id).catch((e) => toast(String(e), "error"));
          },
        }, [trackLabel(t, i)])
      );
    });
  });
}

/** Speed and subtitle timing — the two knobs that don't fit in the bar itself
 *  but are needed mid-episode (a fast talker, or subs running ahead). */
function togglePlaybackPanel(): void {
  toggleBarPanel("tune", "Speed", (panel) => {
    panel.classList.add("pb-tune");
    const speedBtns = SPEEDS.map(
      (s) =>
        el("button", {
          class: "btn small",
          "data-speed": String(s),
          onClick: () => playerCtl.setSpeed(s).catch(() => {}),
        }, [s === 1 ? "Normal" : `${s}×`]) as HTMLButtonElement
    );
    const delay = el("span", { class: "pb-panel-value" }, ["0.0s"]);
    const audioDelay = el("span", { class: "pb-panel-value" }, ["0 ms"]);
    panel.append(
      ...speedBtns,
      el("span", { class: "pb-panel-label" }, ["Subtitle delay"]),
      el("button", {
        class: "btn small",
        title: `Subtitles ${SUB_DELAY_STEP}s earlier`,
        onClick: () => playerCtl.setSubDelay(pbState.subDelay - SUB_DELAY_STEP).catch(() => {}),
      }, ["−"]),
      delay,
      el("button", {
        class: "btn small",
        title: `Subtitles ${SUB_DELAY_STEP}s later`,
        onClick: () => playerCtl.setSubDelay(pbState.subDelay + SUB_DELAY_STEP).catch(() => {}),
      }, ["+"]),
      el("button", {
        class: "btn small",
        onClick: () => playerCtl.setSubDelay(0).catch(() => {}),
      }, ["Reset"]),
      // For a headset whose sound runs behind the picture. Saved, so the next
      // file starts with it as well.
      el("span", { class: "pb-panel-label" }, ["Audio delay"]),
      el("button", {
        class: "btn small",
        title: `Sound ${AUDIO_DELAY_STEP * 1000} ms earlier (Ctrl+−)`,
        onClick: () => nudgeAudioDelay(-1, true),
      }, ["−"]),
      audioDelay,
      el("button", {
        class: "btn small",
        title: `Sound ${AUDIO_DELAY_STEP * 1000} ms later (Ctrl+=)`,
        onClick: () => nudgeAudioDelay(1, true),
      }, ["+"]),
      el("button", {
        class: "btn small",
        title: "No audio delay (Ctrl+0)",
        onClick: () => nudgeAudioDelay(0, true),
      }, ["Reset"])
    );
    panel.sync = (st) => {
      for (const b of speedBtns) {
        b.classList.toggle("primary", Math.abs(parseFloat(b.dataset.speed!) - st.speed) < 0.001);
      }
      delay.textContent = `${st.subDelay > 0 ? "+" : ""}${st.subDelay.toFixed(1)}s`;
      const ms = Math.round(st.audioDelay * 1000);
      audioDelay.textContent = `${ms > 0 ? "+" : ""}${ms} ms`;
    };
  });
}

/**
 * Brightness, contrast, saturation and zoom, adjustable against the picture
 * they apply to. These also live in Settings, but Settings is unreachable while
 * something is playing — the video covers the page — and judging a brightness
 * change without seeing the scene is guesswork.
 */
function togglePicturePanel(): void {
  toggleBarPanel("picture", "Picture", (panel) => {
    const cfg = api.getConfig();
    const readouts: (() => void)[] = [];

    for (const control of PICTURE_CONTROLS) {
      const start = Number(cfg[control.key] ?? 0);
      const value = el("span", { class: "pb-panel-value" }, [`${start > 0 ? "+" : ""}${start}`]);
      const slider = el("input", {
        type: "range",
        class: "pb-range pb-mini",
        min: "-50",
        max: "50",
        step: "1",
        value: String(isFinite(start) ? start : 0),
        "aria-label": control.label,
        title: control.label,
      }) as HTMLInputElement;
      const paint = (v: number): void => {
        // The scale runs either side of zero, so the fill is measured from the
        // left edge of the track rather than from the value.
        setRangeFill(slider, ((v + 50) / 100) * 100);
        value.textContent = `${v > 0 ? "+" : ""}${v}`;
      };
      paint(isFinite(start) ? start : 0);
      slider.addEventListener("input", () => {
        const v = parseInt(slider.value, 10);
        paint(v);
        setLiveSetting(control.key, control.prop, v);
      });
      readouts.push(() => {
        slider.value = "0";
        paint(0);
      });
      panel.append(el("span", { class: "pb-panel-label" }, [control.label]), slider, value);
    }

    // Zoom is the answer to a 2.35:1 film in a 16:9 window: crop the bars off
    // rather than watch a letterboxed strip.
    const zoomStart = Number(cfg.video_zoom ?? 0);
    const zoomValue = el("span", { class: "pb-panel-value" }, [`${Math.round(zoomStart * 100)}%`]);
    const zoom = el("input", {
      type: "range",
      class: "pb-range pb-mini",
      min: "0",
      max: "40",
      step: "1",
      value: String(Math.round((isFinite(zoomStart) ? zoomStart : 0) * 100)),
      "aria-label": "Zoom",
      title: "Zoom",
    }) as HTMLInputElement;
    const paintZoom = (pct: number): void => {
      setRangeFill(zoom, (pct / 40) * 100);
      zoomValue.textContent = `${pct}%`;
    };
    paintZoom(Math.round((isFinite(zoomStart) ? zoomStart : 0) * 100));
    zoom.addEventListener("input", () => {
      const pct = parseInt(zoom.value, 10);
      paintZoom(pct);
      setLiveSetting("video_zoom", "video-zoom", pct / 100);
    });
    readouts.push(() => {
      zoom.value = "0";
      paintZoom(0);
    });

    panel.append(
      el("span", { class: "pb-panel-label" }, ["Zoom"]),
      zoom,
      zoomValue,
      el("button", {
        class: "btn small",
        title: "Back to the picture as delivered",
        onClick: () => {
          for (const control of PICTURE_CONTROLS) {
            setLiveSetting(control.key, control.prop, 0);
          }
          setLiveSetting("video_zoom", "video-zoom", 0);
          for (const reset of readouts) reset();
        },
      }, ["Reset"])
    );
  });
}

/** The two ways to say "stop on your own": at the end of this episode, or after
 *  a stretch of time. */
/**
 * The Up Next panel: the playing episode's season as a strip of tiles, the
 * one that's on highlighted and the strip scrolled so it sits at the left
 * with what follows it in view. It used to be mpv's own OSD menu (uosc),
 * drawn at subtitle scale inside the picture — a few lines of 10px text that
 * nobody could read from a couch.
 *
 * A strip rather than a list because the bar is the only surface there is:
 * the video covers every pixel above it, so a panel that grew upward would
 * disappear behind the picture. Each tile is a frame from the episode with
 * its number and name beside it, which is what the series page shows, at
 * the size the bar allows.
 */
function toggleEpisodePanel(): void {
  toggleBarPanel("episodes", "Up next", (panel) => {
    panel.classList.add("pb-queue");
    const note = el("span", { class: "pb-panel-note" }, ["Loading episodes…"]);
    panel.append(note);
    // Titles queued by hand play first, so they lead the strip, with the one
    // way to be rid of them all beside it.
    const queued = queueTiles();
    if (queued.length) {
      panel.append(
        el("button", {
          class: "btn small",
          title: "Take everything you queued off Up Next",
          onClick: () => {
            clearQueue();
            closeBarPanel();
            toast("Up Next cleared", "ok");
          },
        }, ["Clear Up Next"])
      );
    }
    void getEpisodeQueue()
      .then((queue) => {
        if (!panel.isConnected) return;
        note.remove();
        if (!queue) {
          if (queued.length) {
            panel.append(el("div", { class: "pb-queue-strip", role: "list" }, queued));
            return;
          }
          panel.append(el("span", { class: "pb-panel-note" }, ["Not playing an episode"]));
          return;
        }
        if (!queue.episodes.length) {
          panel.append(
            el("span", { class: "pb-panel-note" }, [
              api.isOffline() ? "Offline — the queue needs the server" : "No other episodes in this season",
            ])
          );
          return;
        }
        const { current, episodes } = queue;
        const label = panel.querySelector(".pb-panel-label");
        if (label) label.textContent = `${current.SeriesName ?? "Up next"} · ${current.SeasonName ?? ""}`.replace(/ · $/, "");
        const strip = el("div", { class: "pb-queue-strip", role: "list" }, queued);
        let currentTile: HTMLElement | null = null;
        const at = episodes.findIndex((ep: any) => ep.Id === current.Id);
        episodes.forEach((ep: any, i: number) => {
          const playing = ep.Id === current.Id;
          const played = !!ep.UserData?.Played;
          const num = ep.IndexNumber != null ? `${ep.IndexNumber}. ` : "";
          const minutes = ep.RunTimeTicks ? Math.round(ep.RunTimeTicks / 600_000_000) : 0;
          const status = playing
            ? "Playing"
            : i === at + 1 && !queued.length
              ? "Up next"
              : played
                ? "Watched"
                : minutes
                  ? `${minutes} min`
                  : "";
          const tile = el("button", {
            class: `pb-queue-tile${playing ? " playing" : ""}${played ? " watched" : ""}`,
            role: "listitem",
            title: `${num}${ep.Name ?? ""}`,
            "aria-current": playing ? "true" : null,
            onClick: () => {
              if (playing) {
                closeBarPanel();
                return;
              }
              closeBarPanel();
              playQueuedEpisode(ep.Id)
                .then((ok) => { if (!ok) toast("Couldn't start that episode", "error"); })
                .catch((e) => toast(String(e), "error"));
            },
          }, [
            el("div", { class: "pb-queue-thumb" }, [
              art(api.imageUrl(ep, "Primary", 240), () => icon("play", 18), {
                lazy: false,
                hash: api.imageHash(ep, "Primary"),
              }),
              playing ? el("span", { class: "pb-queue-now" }, [icon("play", 14)]) : null,
            ]),
            el("div", { class: "pb-queue-text" }, [
              el("span", { class: "pb-queue-name" }, [`${num}${ep.Name ?? ""}`]),
              el("span", { class: `pb-queue-status${playing || (i === at + 1 && !queued.length) ? " live" : ""}` }, [
                status,
                played && !playing ? icon("check", 12) : null,
              ]),
            ]),
          ]);
          if (playing) currentTile = tile;
          strip.append(tile);
        });
        panel.append(strip);
        // Vertical wheel scrolls the strip sideways: there is no vertical
        // direction to scroll in, and nobody tilts a wheel.
        strip.addEventListener("wheel", (ev: WheelEvent) => {
          if (Math.abs(ev.deltaY) <= Math.abs(ev.deltaX)) return;
          ev.preventDefault();
          strip.scrollLeft += ev.deltaY;
        }, { passive: false });
        // Open on the playing episode, with what follows it to the right. A
        // jump, not a glide: the strip's smooth scrolling is for the wheel.
        if (currentTile) {
          const t = currentTile as HTMLElement;
          strip.style.scrollBehavior = "auto";
          strip.scrollLeft = Math.max(0, t.offsetLeft - strip.offsetLeft - 4);
          strip.style.scrollBehavior = "";
        }
      })
      .catch((e) => {
        if (!panel.isConnected) return;
        note.textContent = `Couldn't load the season: ${e?.message ?? e}`;
      });
  });
}

/** Live TV's line-up, to change channel without leaving the player. See
 *  channels-panel.ts; shown only while a channel plays. */
function toggleChannelsPanel(): void {
  toggleBarPanel("channels", "Channels", (panel) => fillChannelsPanel(panel, closeBarPanel));
}

function toggleSleepPanel(): void {
  toggleBarPanel("sleep", "Sleep", (panel) => {
    const rebuild = (): void => {
      // Cheapest correct thing: the panel is four buttons and a label.
      closeBarPanel();
      toggleSleepPanel();
    };

    const deadline = sleepDeadline();
    const stopping = isAutoplayCancelled();

    const endOfEpisode = el("button", {
      class: `btn small${stopping ? " primary" : ""}`,
      title: "Play this one to the end, then stop",
      onClick: () => {
        if (stopping) resumeAutoplay();
        else cancelAutoplay();
        rebuild();
      },
    }, ["End of episode"]);

    panel.append(endOfEpisode, el("span", { class: "pb-panel-label" }, ["In"]));

    for (const minutes of [15, 30, 60, 90]) {
      panel.append(
        el("button", {
          class: "btn small",
          onClick: () => {
            setSleepTimer(minutes);
            toast(`Playback will stop in ${minutes} minutes`, "ok");
            rebuild();
          },
        }, [`${minutes}m`])
      );
    }

    if (deadline) {
      const left = Math.max(0, Math.round((deadline - Date.now()) / 60_000));
      panel.append(
        el("span", { class: "pb-panel-note" }, [
          left <= 1 ? "Stopping in under a minute" : `Stopping in ${left} minutes`,
        ]),
        el("button", {
          class: "btn small",
          onClick: () => {
            cancelSleepTimer();
            toast("Sleep timer cancelled", "ok");
            rebuild();
          },
        }, ["Cancel"])
      );
    }
  });
}

/**
 * Chapters as a strip of buttons, the one playing highlighted: a click jumps
 * there. The tick marks on the scrubber say where they are; this says what
 * they are called.
 */
function toggleChapterPanel(): void {
  toggleBarPanel("chapters", "Chapters", (panel) => {
    const chapters = [{ time: 0, title: "" }, ...pbChapters];
    if (!pbChapters.length) {
      panel.append(el("span", { class: "pb-panel-note" }, ["This file has no chapters"]));
      return;
    }
    const buttons = chapters.map((c, i) =>
      el("button", {
        class: "btn small pb-chapter",
        "data-time": String(c.time),
        title: api.secondsToClock(c.time),
        onClick: () => {
          closeBarPanel();
          playerCtl.seek(c.time, true).catch(() => {});
        },
      }, [
        el("span", { class: "pb-chapter-time" }, [api.secondsToClock(c.time)]),
        c.title || `Chapter ${i + 1}`,
      ]) as HTMLButtonElement
    );
    panel.append(...buttons);
    let scrolled = false;
    panel.sync = () => {
      const pos = lastBarStatus?.position ?? 0;
      let at = 0;
      chapters.forEach((c, i) => {
        if (c.time <= pos + 0.5) at = i;
      });
      buttons.forEach((b, i) => b.classList.toggle("primary", i === at));
      if (!scrolled) {
        scrolled = true;
        buttons[at]?.scrollIntoView({ inline: "center", block: "nearest" });
      }
    };
  });
}

/** Stalls seen in this file, for the stream info panel. */
let stallsThisFile = 0;

/** "12.3 Mbps" from bits per second. */
function mbps(bps: number): string {
  return bps >= 1_000_000 ? `${(bps / 1_000_000).toFixed(1)} Mbps` : `${Math.round(bps / 1000)} kbps`;
}

/** How the server is sending this: direct, a remux (only the wrapper or the
 *  sound changed) or a transcode, from the reasons in the transcode URL. */
function deliveryLabel(): string {
  const np = getNowPlayingFull();
  if (!np) return "–";
  if (np.isLocal) return "Playing from this device";
  const src = getStreamSource();
  if (!src) return np.live ? "Live, straight from the playlist" : "–";
  if (src.playMethod !== "Transcode") return "Direct play";
  const reasons = (new URL(src.url).searchParams.get("TranscodeReasons") ?? "").split(",").filter(Boolean);
  const video = reasons.some((r) => /Video|Resolution|Bitrate|Framerate|Level|Profile|Anamorphic|Interlaced|BitDepth|RefFrames/i.test(r));
  const cap = np.maxBitrate ? ` · capped at ${mbps(np.maxBitrate)}` : "";
  return `${video || np.maxBitrate ? "Transcode" : "Remux"}${cap}${reasons.length ? ` (${reasons.join(", ")})` : ""}`;
}

/**
 * Stream info: how it's being delivered, what it is, and how it's going —
 * the same facts the Apple app's info panel lists, as label/value pairs along
 * the bar (the only surface there is). Live values refresh with the status.
 */
function toggleInfoPanel(): void {
  toggleBarPanel("info", "Stream", (panel) => {
    panel.classList.add("pb-info");
    const cells = new Map<string, HTMLElement>();
    const cell = (label: string): HTMLElement => {
      const value = el("span", { class: "pb-info-value" }, ["…"]);
      panel.append(el("div", { class: "pb-info-cell" }, [el("span", { class: "pb-info-label" }, [label]), value]));
      cells.set(label, value);
      return value;
    };
    for (const l of ["Delivery", "Container", "Video", "Audio", "Resolution", "Bitrate", "On the server", "Engine", "Decoder", "Buffer", "Stalls", "Dropped frames"]) cell(l);
    const set = (label: string, text: string | null | undefined) => {
      const c = cells.get(label);
      if (c) c.textContent = text && text.trim() ? text : "–";
    };
    let engine = "mpv";
    void invoke<any>("app_info").then((info) => {
      engine = info?.mpv ? String(info.mpv) : "mpv";
    }).catch(() => {});
    const props = [
      "file-format", "video-codec", "video-format", "audio-codec-name", "audio-params/channel-count",
      "audio-params/samplerate", "video-params/w", "video-params/h", "container-fps", "video-bitrate",
      "audio-bitrate", "hwdec-current", "current-vo", "demuxer-cache-duration", "cache-speed",
    ];
    let busy = false;
    const refresh = async (): Promise<void> => {
      if (busy || !panel.isConnected) return;
      busy = true;
      const p: Record<string, string> = await invoke<any>("player_get_properties", { names: props }).catch(() => ({}));
      busy = false;
      if (!panel.isConnected) return;
      const ms = getStreamSource()?.mediaSource;
      set("Delivery", deliveryLabel());
      set("Container", p["file-format"] ?? ms?.Container);
      set("Video", [p["video-format"]?.toUpperCase() || p["video-codec"]?.split(" ")[0], p["container-fps"] ? `${parseFloat(p["container-fps"]).toFixed(3).replace(/\.?0+$/, "")} fps` : null].filter(Boolean).join(" · "));
      const ch = p["audio-params/channel-count"];
      set("Audio", [p["audio-codec-name"]?.toUpperCase(), ch ? `${ch} ch` : null, p["audio-params/samplerate"] ? `${Math.round(+p["audio-params/samplerate"] / 100) / 10} kHz` : null].filter(Boolean).join(" · "));
      set("Resolution", p["video-params/w"] && p["video-params/h"] ? `${p["video-params/w"]}×${p["video-params/h"]}` : null);
      const vb = Number(p["video-bitrate"] ?? 0) + Number(p["audio-bitrate"] ?? 0);
      const speed = Number(p["cache-speed"] ?? 0) * 8;
      set("Bitrate", [vb > 0 ? mbps(vb) : null, speed > 0 ? `arriving at ${mbps(speed)}` : null].filter(Boolean).join(" · "));
      set("On the server", ms?.Bitrate ? `${mbps(ms.Bitrate)} source` : getNowPlayingFull()?.isLocal ? "Downloaded file" : null);
      set("Engine", `${engine}${p["current-vo"] ? ` · vo=${p["current-vo"]}` : ""}`);
      const hw = p["hwdec-current"];
      set("Decoder", !hw ? null : hw === "no" ? "Software (CPU)" : `Hardware (${hw})`);
      const buf = parseFloat(p["demuxer-cache-duration"] ?? "");
      set("Buffer", isFinite(buf) ? `${Math.round(buf)} s ahead` : null);
      set("Stalls", String(stallsThisFile));
      set("Dropped frames", String(lastBarStatus?.dropped_frames ?? 0));
    };
    void refresh();
    panel.sync = () => void refresh();
  });
}

/** Up Next with nothing to say about a season: the queue, on its own. */
function queueTiles(): HTMLElement[] {
  const queue = getUserQueue();
  return queue.map((item: any, i: number) =>
    el("button", {
      class: "pb-queue-tile queued",
      role: "listitem",
      title: upNextTitle(item),
      onClick: () => {
        closeBarPanel();
        playQueued(item.Id).catch((e) => toast(String(e), "error"));
      },
      onContextmenu: (ev: MouseEvent) => {
        ev.preventDefault();
        removeFromQueue(item.Id);
        closeBarPanel();
        toggleEpisodePanel();
      },
    }, [
      el("div", { class: "pb-queue-thumb" }, [
        art(api.imageUrl(item, "Primary", 240), () => icon("play", 18), {
          lazy: false,
          hash: api.imageHash(item, "Primary"),
        }),
      ]),
      el("div", { class: "pb-queue-text" }, [
        el("span", { class: "pb-queue-name" }, [item.SeriesName ? `${item.SeriesName} · ${item.Name ?? ""}` : item.Name ?? ""]),
        el("span", { class: `pb-queue-status${i === 0 ? " live" : ""}` }, [i === 0 ? "Up next · queued" : "Queued"]),
      ]),
    ])
  );
}

// ---------- Volume ----------

// Dragging the slider issues one mpv command per pixel otherwise, and every
// one of those is logged; throttle the stream and always send the final value.
const VOLUME_THROTTLE_MS = 60;
let volumeSentAt = 0;
let volumePending = 0;
/** Incoming status is ignored briefly after a local change: the level we just
 *  set is newer than the one in flight from mpv. */
let volumeTouchedAt = 0;

function setRangeFill(range: HTMLInputElement, pct: number): void {
  range.style.setProperty("--fill", `${Math.max(0, Math.min(100, pct))}%`);
}

function volumeIcon(st: PlayerState): string {
  if (st.mute || st.volume <= 0) return PB_ICONS.volMute;
  return st.volume <= 45 ? PB_ICONS.volLow : PB_ICONS.volHigh;
}

function buildVolume(): HTMLElement {
  const btn = pbButton("pb-mute", volumeIcon(pbState), "Mute (m)", () =>
    playerCtl.setMute(!pbState.mute).catch(() => {})
  );
  const slider = el("input", {
    type: "range",
    class: "pb-range",
    id: "pb-volume",
    min: "0",
    max: String(MAX_VOLUME),
    step: "1",
    value: String(pbState.volume),
    "aria-label": "Volume",
  }) as HTMLInputElement;
  // The slider runs to mpv's 130% ceiling, so 100% sits short of the end —
  // the readout in the tooltip is what makes that legible.
  const label = (v: number): void => {
    slider.title = `Volume ${Math.round(v)}% (↑/↓)`;
  };
  label(pbState.volume);
  setRangeFill(slider, (pbState.volume / MAX_VOLUME) * 100);

  const push = (v: number): void => {
    volumeSentAt = Date.now();
    playerCtl.setVolume(v).catch(() => {});
  };
  slider.addEventListener("input", () => {
    const v = parseInt(slider.value, 10);
    volumeTouchedAt = Date.now();
    pbState.volume = v;
    setRangeFill(slider, (v / MAX_VOLUME) * 100);
    label(v);
    ($("pb-mute") as HTMLElement).innerHTML = volumeIcon(pbState);
    // Reaching for the slider while muted means "let me hear it".
    if (pbState.mute) playerCtl.setMute(false).catch(() => {});
    volumePending = v;
    if (Date.now() - volumeSentAt >= VOLUME_THROTTLE_MS) push(v);
  });
  // Release (and keyboard adjustment) always lands on the exact final value.
  slider.addEventListener("change", () => {
    volumeTouchedAt = Date.now();
    push(parseInt(slider.value, 10));
  });
  slider.addEventListener("pointerup", () => push(volumePending));

  return el("div", { class: "pb-vol" }, [btn, slider]);
}

/** Nudge the level by a step, from wherever mpv currently is. */
function bumpVolume(delta: number): void {
  const next = Math.max(0, Math.min(MAX_VOLUME, Math.round(pbState.volume + delta)));
  pbState.volume = next;
  volumeTouchedAt = Date.now();
  const slider = document.getElementById("pb-volume") as HTMLInputElement | null;
  if (slider) {
    slider.value = String(next);
    setRangeFill(slider, (next / MAX_VOLUME) * 100);
  }
  const btn = document.getElementById("pb-mute");
  if (btn) btn.innerHTML = volumeIcon(pbState);
  if (pbState.mute && delta > 0) playerCtl.setMute(false).catch(() => {});
  playerCtl.setVolume(next).catch(() => {});
}

/** Step through the preset speeds, so `[`/`]` land on the same values the
 *  panel offers rather than drifting to odd fractions. */
function stepSpeed(dir: number): void {
  const i = SPEEDS.findIndex((s) => Math.abs(s - pbState.speed) < 0.001);
  const from = i >= 0 ? i : SPEEDS.indexOf(1);
  const next = SPEEDS[Math.max(0, Math.min(SPEEDS.length - 1, from + dir))];
  if (next != null) playerCtl.setSpeed(next).catch(() => {});
}

// ---------- Scrubber previews, skippable segments, Up Next ----------
// All three are per-file state, thrown away when the playing item changes.
//
// Every one of them lives *inside* the player bar. The embedded X11 video
// covers every pixel of HTML above it, so the frame preview can't float over
// the video the way it does in a browser player, and the Up Next card can't sit
// in the corner of the picture. The bar is the only surface there is.

let mediaItemId: string | null = null;
let tpInfo: api.TrickplayInfo | null = null;
/** Tile sheets already fetched. `null` marks one that failed, so a missing tile
 *  is asked for once rather than on every pointer move across it. */
const tpTiles = new Map<number, string | null>();
let segments: api.MediaSegment[] = [];
let upNextItem: any = null;
let upNextStarting = false;

/** Point every per-file cache at a new item (or at nothing). */
function resetMediaExtras(itemId: string | null): void {
  mediaItemId = itemId;
  stallsThisFile = 0;
  tpInfo = null;
  tpTiles.clear();
  segments = [];
  upNextItem = null;
  upNextStarting = false;
  document.getElementById("pb-preview")?.classList.remove("on");
  document.getElementById("pb-skip")?.classList.remove("on");
  document.getElementById("pb-upnext")?.classList.remove("on");
  document.getElementById("player-bar")?.classList.remove("upnext");
  if (!itemId) return;

  // A downloaded file plays from disk, but it still has a server item behind
  // it — the requests are worth making, and simply come back empty offline.
  void api.getTrickplay(itemId).then((info) => {
    if (mediaItemId === itemId) tpInfo = info;
  }).catch(() => {});
  void api.getMediaSegments(itemId).then((s) => {
    if (mediaItemId === itemId) segments = s;
  }).catch(() => {});
  void peekNextEpisode().then((next) => {
    if (mediaItemId !== itemId) return;
    upNextItem = next;
    // The desktop's "next track" button is served from the Rust side, which has
    // no idea what a series is; this is the only place that knows.
    invoke("player_set_next_available", { available: !!next }).catch(() => {});
  }).catch(() => {});
}

/** The tile sheet holding thumbnail `n`, fetched at most once. */
function trickplayTile(info: api.TrickplayInfo, tile: number): string | null {
  const have = tpTiles.get(tile);
  if (have !== undefined) return have;
  tpTiles.set(tile, null); // claim the slot so the fetch isn't repeated
  void api
    .trickplayTile(info, tile)
    .then((url) => {
      if (tpInfo === info) tpTiles.set(tile, url);
    })
    .catch(() => {});
  return null;
}

/**
 * Show the frame at `seconds` in the bar's preview slot. Trickplay tiles are
 * sprite sheets — one image holding a grid of thumbnails — so this is arithmetic
 * on a background offset rather than an image request per frame.
 */
function showScrubPreview(seconds: number): void {
  const box = document.getElementById("pb-preview");
  const img = document.getElementById("pb-preview-img");
  const time = document.getElementById("pb-preview-time");
  if (!box || !img || !time) return;
  const info = tpInfo;
  if (!info) {
    box.classList.remove("on");
    return;
  }
  const per = Math.max(1, info.tileWidth * info.tileHeight);
  const n = Math.max(0, Math.floor((seconds * 1000) / info.interval));
  const url = trickplayTile(info, Math.floor(n / per));
  time.textContent = api.secondsToClock(seconds);
  box.classList.add("on");
  if (!url) return; // tile still in flight; the box shows the time meanwhile

  // Fit one thumbnail into the bar's preview slot, then scale the whole sheet
  // by the same factor so the offsets land on frame boundaries.
  const scale = Math.min(104 / info.width, 56 / info.height);
  const w = Math.round(info.width * scale);
  const h = Math.round(info.height * scale);
  const idx = n % per;
  const x = idx % info.tileWidth;
  const y = Math.floor(idx / info.tileWidth);
  img.style.width = `${w}px`;
  img.style.height = `${h}px`;
  img.style.backgroundImage = `url("${url}")`;
  img.style.backgroundSize = `${info.tileWidth * w}px ${info.tileHeight * h}px`;
  img.style.backgroundPosition = `-${x * w}px -${y * h}px`;
}

function hideScrubPreview(): void {
  document.getElementById("pb-preview")?.classList.remove("on");
}

/** The intro or credits sequence `position` is inside, if any. */
function segmentAt(position: number, duration: number): api.MediaSegment | null {
  for (const s of segments) {
    // Nothing to skip to in the last couple of seconds of the file.
    if (position >= s.start && position < s.end - 1 && s.end < duration - 1) return s;
  }
  return null;
}

function syncSkipButton(st: any): void {
  const btn = document.getElementById("pb-skip");
  if (!btn) return;
  const seg = st.duration > 0 ? segmentAt(st.position ?? 0, st.duration) : null;
  btn.classList.toggle("on", !!seg);
  if (!seg) return;
  btn.textContent = seg.type === "Outro" ? "Skip credits" : "Skip intro";
  (btn as any).__seekTo = seg.end;
}

/**
 * The Up Next card: what's coming, how long until it starts, and the two
 * answers to that. It appears over the closing stretch of an episode rather
 * than at the very end, which is the point — by the time the file runs out the
 * decision has already been made for you.
 */
const UPNEXT_LEAD = 25;

function syncUpNext(st: any): void {
  const card = document.getElementById("pb-upnext");
  if (!card) return;
  const left = st.duration > 0 ? st.duration - (st.position ?? 0) : Infinity;
  const show =
    !!upNextItem && !isAutoplayCancelled() && st.duration > 0 && left <= UPNEXT_LEAD && left > 0;
  card.classList.toggle("on", show);
  // The card needs the whole title slot; the bar holds it open at full width
  // while it's up so the card can't be crushed on a narrow window.
  $("player-bar").classList.toggle("upnext", show);
  if (!show) return;
  const label = document.getElementById("pb-upnext-when");
  const title = document.getElementById("pb-upnext-title");
  const item = upNextItem;
  if (title) title.textContent = upNextTitle(item);
  if (label) {
    // With autoplay off (and nothing queued by hand) the card still asks; it
    // just won't answer itself.
    label.textContent = upNextStarting
      ? "Starting…"
      : autoplayNextEnabled() || getUserQueue().length
        ? `Up next · in ${Math.max(0, Math.ceil(left))}s`
        : "Up next";
  }
  // The frame from the next episode, fetched once per item rather than on
  // every tick. A download that was started from the Downloads view has no
  // server image to show; the thumbnail box simply stays out of the layout.
  const thumb = document.getElementById("pb-upnext-thumb");
  if (thumb && thumb.dataset.for !== upNextKey(item)) {
    thumb.dataset.for = upNextKey(item);
    clear(thumb);
    const src = item.Id ? api.imageUrl(item, "Primary", 240) : null;
    thumb.classList.toggle("on", !!src);
    if (src) thumb.append(art(src, () => icon("play", 16), { lazy: false, hash: api.imageHash(item, "Primary") }));
  }
}

/** Something that changes when the next episode does, for the thumbnail. */
function upNextKey(item: any): string {
  return String(item?.Id ?? item?.item_id ?? item?.path ?? "");
}

/**
 * The card's one line about what's coming, spelled the way the Apple app
 * spells it: "Series · Season 2: Episode 4 · Name". Local downloads and
 * server items describe themselves differently (see playerTitleLines).
 */
function upNextTitle(item: any): string {
  const series = item.SeriesName ?? item.series;
  const name = item.Name ?? item.title ?? item.name ?? "Next episode";
  const s = item.ParentIndexNumber ?? item.season;
  const e = item.IndexNumber ?? item.episode;
  const label =
    e == null ? null : s == null ? `Episode ${e}` : s === 0 ? `Specials: Episode ${e}` : `Season ${s}: Episode ${e}`;
  if (!series) return name;
  return [series, label, name].filter(Boolean).join(" · ");
}

/** "Not now": this episode plays out and playback stops there. */
function dismissUpNext(): void {
  cancelAutoplay();
  $("player-bar").classList.remove("upnext");
  document.getElementById("pb-upnext")?.classList.remove("on");
}

/** Whether the card is on screen — the keys that answer it only count then. */
function upNextShowing(): boolean {
  return !!document.getElementById("pb-upnext")?.classList.contains("on");
}

async function startUpNext(): Promise<void> {
  if (upNextStarting) return;
  upNextStarting = true;
  const started = await playNextNow().catch(() => false);
  if (!started) {
    upNextStarting = false;
    toast("Couldn't start the next episode", "error");
  }
}

/**
 * The title box's two static lines: the series (or the item's own name) bold
 * on top, season/episode underneath. Built from the playing item's own
 * fields rather than parsed out of `st.title` — that string is the flat
 * "Series Season 2, Episode 4 · Name" shape MPRIS and toasts want, which is
 * the wrong shape for two lines that are laid out separately.
 */
function playerTitleLines(item: any, fallback: string): { line1: string; line2: string; tip?: string } {
  // A channel: its name, then what's on and what's coming up.
  const live = liveTitleLines(item);
  if (live) return live;
  if (item?.Type === "Episode" && item.SeriesName) {
    const s = item.ParentIndexNumber, e = item.IndexNumber;
    return {
      line1: item.SeriesName,
      line2: s != null && e != null ? `Season ${s}, Episode ${e}` : item.Name ?? "",
    };
  }
  // A downloaded item is its meta.json record (see startDownload in
  // playback.ts), which spells the same facts in lower case: `series`,
  // `season`, `episode`, `name`. Left to the fallback it showed mpv's
  // one-line title — "Archer S09E07 · …" — in bold on the first line and
  // nothing on the second.
  if (item?.series && item.type !== "Movie") {
    const s = item.season, e = item.episode;
    return {
      line1: item.series,
      line2: s != null && e != null ? `Season ${s}, Episode ${e}` : item.name ?? "",
    };
  }
  return { line1: item?.Name || item?.name || fallback, line2: "" };
}

function buildPlayerBar(): void {
  const bar = $("player-bar");
  clear(bar);

  // The preview covers the title while the scrubber is being hovered: with the
  // video occupying everything above the bar, this slot is the only place a
  // frame can be shown at a useful size.
  const preview = el("div", { class: "pb-preview", id: "pb-preview" }, [
    el("div", { class: "pb-preview-img", id: "pb-preview-img" }),
    el("div", { class: "pb-preview-time", id: "pb-preview-time" }, ["0:00"]),
  ]);
  // Up Next takes over the title slot rather than being inserted into the bar:
  // the bar's layout is identical whether it's showing or not, so the scrubber
  // doesn't jump sideways at the exact moment you might be reaching for it.
  //
  // The same card the Apple app shows: a quiet "Up next · in 12s" over the
  // episode's full name, with "Play now" and "Not now" as two labelled
  // buttons (Return answers it on a Mac; Enter does here). The TV app adds a
  // frame from the episode, and there's room for one in the bar, so it's here
  // too.
  const upnext = el("div", { class: "pb-upnext", id: "pb-upnext", role: "status" }, [
    el("div", { class: "pb-upnext-thumb", id: "pb-upnext-thumb" }),
    el("div", { class: "pb-upnext-text" }, [
      el("span", { class: "pb-upnext-when", id: "pb-upnext-when" }, ["Up next"]),
      el("span", { class: "pb-upnext-title", id: "pb-upnext-title" }, [""]),
    ]),
    el("div", { class: "pb-upnext-actions" }, [
      el("button", {
        class: "btn small primary",
        title: "Play the next episode now (Enter)",
        onClick: () => void startUpNext(),
      }, ["Play now"]),
      el("button", {
        class: "btn small",
        title: "Stop after this episode",
        onClick: dismissUpNext,
      }, ["Not now"]),
    ]),
  ]);

  const title = el("div", { class: "pb-title" }, [
    // Series (or the movie's own name) on its own bold line; season/episode
    // underneath. A flat "Series Season 2, Episode 4 · Name" in one box this
    // narrow was three ideas fighting for one ellipsis.
    el("h5", { id: "pb-title" }, ["–"]),
    el("div", { id: "pb-subtitle", class: "pb-subtitle" }, [""]),
    // A transient badge (Paused / Buffering… / a speed change), not part of
    // the steady two-line title — see updatePlayerBar.
    el("span", { id: "pb-state" }, [""]),
    upnext,
    // Last, so scrubbing during the closing seconds shows the frame over the
    // Up Next card rather than under it.
    preview,
  ]);

  const skip = el("button", {
    class: "btn small pb-skip",
    id: "pb-skip",
    onClick: (ev: MouseEvent) => {
      const to = (ev.currentTarget as any).__seekTo;
      if (typeof to === "number") playerCtl.seek(to, true);
    },
  }, ["Skip intro"]);

  const pos = el("span", { id: "pb-pos" }, ["0:00"]);
  // Clicking the time flips it between the length and the time left, and the
  // choice is kept (Settings → Playback has the same switch).
  const dur = el("span", {
    id: "pb-dur",
    class: "pb-dur",
    role: "button",
    tabindex: "0",
    title: "Show time remaining or the whole length",
    onClick: () => {
      setShowsRemaining(!showsRemaining());
      if (lastBarStatus) updatePlayerBar(lastBarStatus);
    },
  }, ["0:00"]);
  const range = el("input", {
    type: "range",
    class: "pb-range",
    min: "0",
    max: "1000",
    value: "0",
    id: "pb-range",
    "aria-label": "Seek",
  }) as HTMLInputElement;
  range.addEventListener("input", () => {
    seeking = true;
    setRangeFill(range, parseInt(range.value) / 10);
  });
  range.addEventListener("change", () => {
    const durS = parseFloat(range.dataset.duration ?? "0");
    if (durS > 0) playerCtl.seek((parseInt(range.value) / 1000) * durS, true);
    seeking = false;
  });

  // Chapter marks and the hover time readout both need a positioned box around
  // the <input>, which can't carry children of its own.
  const chapters = el("div", { class: "pb-chapters", id: "pb-chapters" });
  const tip = el("div", { class: "pb-tip", id: "pb-tip" }, ["0:00"]);
  const scrub = el("div", { class: "pb-scrub" }, [chapters, range, tip]);
  // A live channel has no position worth showing and nowhere to seek to; the
  // scrubber and its two clocks give way to a badge that says so.
  const liveBadge = el("div", { class: "pb-live" }, [el("span", { class: "live-dot" }), "Live"]);
  // "Where would this click land?" — the one question a bare scrubber can't
  // answer. Follows the pointer across the track and names the chapter it's in.
  scrub.addEventListener("mousemove", (ev: MouseEvent) => {
    const durS = parseFloat(range.dataset.duration ?? "0");
    const r = scrub.getBoundingClientRect();
    if (durS <= 0 || r.width <= 0) {
      tip.style.opacity = "0";
      return;
    }
    tip.style.opacity = "";
    const frac = Math.max(0, Math.min(1, (ev.clientX - r.left) / r.width));
    // Clamp the bubble so it can't hang off either end of the bar.
    tip.style.left = `${Math.max(26, Math.min(r.width - 26, frac * r.width))}px`;
    clear(tip);
    const name = chapterNameAt(frac * durS);
    if (name) tip.append(el("b", {}, [name]));
    tip.append(document.createTextNode(api.secondsToClock(frac * durS)));
    showScrubPreview(frac * durS);
  });
  scrub.addEventListener("mouseleave", hideScrubPreview);

  bar.append(
    pbButton("pb-exit", PB_ICONS.exit, "Back (stop and leave the player)", async () => {
      if (videoFullscreen) await setVideoFullscreen(false);
      await playerCtl.stop();
    }),
    title,
    skip,
    el("div", { class: "pb-controls" }, [
      pbButton("pb-back", skipIcon(false, skipInterval()), `Back ${skipInterval()}s (←)`, () => playerCtl.seek(-skipInterval(), false)),
      pbButton("pb-playpause", PB_ICONS.pause, "Play/Pause (Space)", () => playerCtl.pauseToggle()),
      pbButton("pb-fwd", skipIcon(true, skipInterval()), `Forward ${skipInterval()}s (→)`, () => playerCtl.seek(skipInterval(), false)),
      pbButton("pb-stop", PB_ICONS.stop, "Stop", () => playerCtl.stop()),
    ]),
    el("div", { class: "pb-seek" }, [liveBadge, pos, scrub, dur]),
    buildVolume(),
    el("div", { class: "pb-controls" }, [
      pbButton("pb-subs", PB_ICONS.subtitles, "Subtitles", () => toggleSubtitlePanel()),
      pbButton("pb-audio", PB_ICONS.audio, "Audio track", () => toggleAudioPanel()),
      pbButton("pb-tune", PB_ICONS.tune, "Speed, subtitle and audio delay", () => togglePlaybackPanel()),
      pbButton("pb-chapters-btn", PB_ICONS.chapters, "Chapters", () => toggleChapterPanel()),
      pbButton("pb-info", PB_ICONS.info, "Stream info (i)", () => toggleInfoPanel()),
      pbButton("pb-picture", PB_ICONS.picture, "Picture and zoom", () => togglePicturePanel()),
      pbButton("pb-sleep", PB_ICONS.sleep, "Sleep timer", () => toggleSleepPanel()),
      pbButton("pb-quality", PB_ICONS.quality, "Stream quality", () => toggleQualityPicker()),
      pbButton("pb-episodes", PB_ICONS.episodes, "Up next (this season's episodes)", () => toggleEpisodePanel()),
      pbButton("pb-channels", ICONS.livetv, "Channels (Page Up/Down changes channel)", () => toggleChannelsPanel()),
      pbButton("pb-pip", PB_ICONS.pip, "Picture in picture (p)", () => setVideoPip(!videoPip)),
      pbButton("pb-fullscreen", PB_ICONS.fullscreen, "Fullscreen (f, Esc exits)", () =>
        setVideoFullscreen(!videoFullscreen)
      ),
    ])
  );

  // See the comment on `fsBarHovered`: tracked explicitly rather than read
  // from `:hover`, since the one leave that matters here — toward the
  // embedded video's native window — isn't guaranteed to clear it.
  //
  // Latched from `mousemove` rather than `mouseenter`, and only for a move
  // that actually moved. A bar snapping up under a stationary cursor is an
  // *entry* as far as the DOM is concerned — the element arrived under the
  // pointer — so `mouseenter` fired on a pointer that had not moved and
  // pinned the bar open with nothing to un-pin it: the auto-hide checks
  // `fsBarHovered`, and only a real `mouseleave` ever cleared it. Comparing
  // against the last real position (see `fsLastPointer`) tells the two apart;
  // this handler runs before the document-level one that updates it, so the
  // value here is still the previous position.
  bar.addEventListener("mousemove", (e) => {
    if (fsBarShown && fsPointerMoved(e)) fsBarHovered = true;
  });
  // A clicked button keeps keyboard focus, and the first key after it — Space
  // to pause, an arrow to seek, which this player takes on the document —
  // makes WebKit treat the page as keyboard-driven and draw the focus ring on
  // it. So every mute, every seek left a purple ring on whatever was pressed
  // last. The ring is for focus that arrived by keyboard, and `detail` is 0
  // only for those activations; a pointer click lets go of the button.
  bar.addEventListener("click", (e: MouseEvent) => {
    if (e.detail === 0) return;
    const btn = (e.target as Element | null)?.closest("button");
    if (btn && bar.contains(btn)) btn.blur();
  });
  bar.addEventListener("mouseleave", () => {
    fsBarHovered = false;
    // The pointer just left the bar for the video (or off the fullscreen
    // window entirely) — start the clock now rather than waiting for the
    // next `player-mouse`/`mousemove` poke, so a still cursor right at the
    // boundary doesn't buy extra time it didn't ask for.
    //
    // Restart the clock only; never reveal from here. The bar sliding away
    // from under a resting pointer is itself a `mouseleave` (the element
    // stopped being under the pointer), and a reveal in response to that
    // brought the bar straight back: a hide, a leave, a reveal, 2.5 s, a
    // hide — round and round for as long as the pointer sat still over the
    // strip.
    if (videoFullscreen && fsBarShown) fsArmHide();
  });
}

/** A short note in the bar's state badge ("Subtitles off", "+10 s"), for
 *  input that has no button of its own to light up. Toasts sit on the page,
 *  which the picture covers. */
let barNote = { text: "", until: 0 };

function barNoteShowing(): boolean {
  return Date.now() < barNote.until;
}

function flashBarNote(text: string): void {
  barNote = { text, until: Date.now() + 1800 };
  const state = document.getElementById("pb-state");
  if (state) state.textContent = text;
  if (videoFullscreen) fsPokeControls();
}

/** The subtitle track `c` brings back after turning subtitles off. */
let lastSubTrack: { id: number; lang?: string } | null = null;

/** `c`: subtitles off, or back on with the track last used. */
function toggleSubtitles(): void {
  const subs = getTracks().filter((t) => t.type === "sub");
  const on = subs.find((t) => t.selected);
  if (on) {
    lastSubTrack = { id: on.id, lang: on.lang };
    playerCtl.setTrack("sub", "no").catch(() => {});
    flashBarNote("Subtitles off");
    return;
  }
  if (!subs.length) {
    flashBarNote("No subtitles for this file");
    return;
  }
  const last = lastSubTrack;
  const back =
    (last && (subs.find((t) => t.id === last.id && t.lang === last.lang) ?? subs.find((t) => last.lang && t.lang === last.lang))) ||
    subs[0];
  playerCtl.setTrack("sub", back.id).catch(() => {});
  flashBarNote(`Subtitles: ${trackLabel(back, subs.indexOf(back))}`);
}

/** `s`: skip the intro or credits the playhead is in, when there is one. */
function skipSegment(): void {
  const btn = document.getElementById("pb-skip") as any;
  if (btn?.classList.contains("on") && typeof btn.__seekTo === "number") {
    playerCtl.seek(btn.__seekTo, true).catch(() => {});
    flashBarNote(btn.textContent ?? "Skipped");
  }
}

function skipBy(dir: -1 | 1): void {
  if (getQualityState()?.live) return;
  const n = skipInterval();
  playerCtl.seek(dir * n, false).catch(() => {});
  flashBarNote(`${dir < 0 ? "−" : "+"}${n} s`);
}

function nudgeAudioDelay(dir: -1 | 0 | 1, quiet = false): void {
  // Rounded to the millisecond: mpv reports 0.050000-ish floats, and the sum
  // of a few of them is otherwise "+0 ms" rather than 0.
  const v = dir === 0 ? 0 : Math.round((pbState.audioDelay + dir * AUDIO_DELAY_STEP) * 1000) / 1000;
  // Set here as well as from the next status, so two quick presses are two steps.
  pbState.audioDelay = v;
  playerCtl.setAudioDelay(v).catch(() => {});
  if (!quiet) flashBarNote(`Audio delay ${v > 0 ? "+" : ""}${Math.round(v * 1000)} ms`);
  ($("player-bar").querySelector(".pb-panel") as BarPanel | null)?.sync?.(pbState);
}

function openInfo(): void {
  if (videoFullscreen) fsPokeControls();
  toggleInfoPanel();
}

/** Speed before a hold took it to 2×, to go back to on release. */
let speedBeforeHold: number | null = null;

/**
 * The player's controls as a menu on the picture, for a right-click there.
 * Drawn by uosc inside the video: nothing in the page can draw over it.
 */
function openPictureMenu(): void {
  const st = lastBarStatus;
  if (!st) return;
  const live = !!getQualityState()?.live;
  const n = skipInterval();
  const items: any[] = [
    { title: st.paused ? "Play" : "Pause", hint: "Space", value: "cycle pause" },
  ];
  if (!live) {
    items.push(
      { title: `Back ${n} seconds`, hint: "←", value: `seek -${n}` },
      { title: `Forward ${n} seconds`, hint: "→", value: `seek ${n}` }
    );
  }
  const skip = document.getElementById("pb-skip") as any;
  if (skip?.classList.contains("on")) items.push({ title: skip.textContent, hint: "s", value: "script-message aquarium-ctl skip" });
  if (upNextItem) items.push({ title: "Play next", hint: upNextTitle(upNextItem), value: "script-message aquarium-ctl next" });
  const tracks = getTracks();
  const subs = tracks.filter((t) => t.type === "sub");
  items.push({
    title: "Subtitles",
    hint: "c",
    items: [
      { title: "Off", active: !subs.some((t) => t.selected), value: "set sid no" },
      ...subs.map((t, i) => ({ title: trackLabel(t, i), active: !!t.selected, value: `set sid ${t.id}` })),
    ],
  });
  const audio = tracks.filter((t) => t.type === "audio");
  if (audio.length > 1) {
    items.push({
      title: "Audio",
      items: audio.map((t, i) => ({ title: trackLabel(t, i), active: !!t.selected, value: `set aid ${t.id}` })),
    });
  }
  items.push({
    title: "Speed",
    hint: Math.abs(pbState.speed - 1) < 0.001 ? "Normal" : `${pbState.speed}×`,
    items: SPEEDS.map((sp) => ({ title: sp === 1 ? "Normal" : `${sp}×`, active: Math.abs(sp - pbState.speed) < 0.001, value: `set speed ${sp}` })),
  });
  if (pbChapters.length) {
    items.push({
      title: "Chapters",
      items: [{ time: 0, title: "" }, ...pbChapters].map((c, i) => ({
        title: c.title || `Chapter ${i + 1}`,
        hint: api.secondsToClock(c.time),
        value: `script-message aquarium-chapter ${c.time}`,
      })),
    });
  }
  items.push(
    { title: "Stream info", hint: "i", value: "script-message aquarium-ctl info" },
    { title: videoFullscreen ? "Leave fullscreen" : "Fullscreen", hint: "f", value: "script-message aquarium-ctl fullscreen" },
    { title: videoPip ? "Back into the window" : "Picture in picture", hint: "p", value: "script-message aquarium-ctl pip" },
    { title: "Stop", value: "script-message aquarium-ctl stop" }
  );
  invoke("player_mpv_command", {
    cmd: ["script-message-to", "uosc", "open-menu", JSON.stringify({ type: "aquarium-player", title: "Player", items })],
  }).catch(() => {});
}

/** Keys, wheel, touch and right-click over the picture, by way of mpv
 *  (see input.conf and surface.rs `connect_touch_gestures`). */
function onPlayerInput(name: string, arg: string): void {
  if (!playerActive) return;
  if (name === "aquarium-key") {
    switch (arg) {
      case "back": skipBy(-1); break;
      case "forward": skipBy(1); break;
      case "subtitles": toggleSubtitles(); break;
      case "skip": skipSegment(); break;
      case "info": openInfo(); break;
      case "shortcuts": toggleShortcuts(); break;
      case "audio-later": nudgeAudioDelay(1); break;
      case "audio-earlier": nudgeAudioDelay(-1); break;
      case "audio-reset": nudgeAudioDelay(0); break;
    }
    return;
  }
  if (name === "aquarium-context") {
    openPictureMenu();
    return;
  }
  if (name === "aquarium-ctl") {
    switch (arg) {
      case "skip": skipSegment(); break;
      case "next": void startUpNext(); break;
      case "info": openInfo(); break;
      case "fullscreen": if (playerEmbedded && !videoPip) void setVideoFullscreen(!videoFullscreen); break;
      case "pip": void setVideoPip(!videoPip); break;
      case "stop":
        void (async () => {
          if (videoFullscreen) await setVideoFullscreen(false);
          await playerCtl.stop();
        })();
        break;
    }
    return;
  }
  if (name === "aquarium-gesture") {
    switch (arg) {
      case "tap":
        if (videoFullscreen) fsPokeControls();
        break;
      case "doubletap-left":
        skipBy(-1);
        break;
      case "doubletap-right":
        skipBy(1);
        break;
      case "doubletap-middle":
        if (playerEmbedded && !videoPip) void setVideoFullscreen(!videoFullscreen);
        break;
      // Fill crops the picture to the window; Fit shows all of it.
      case "pinch-out":
        playerCtl.setProp("panscan", 1).catch(() => {});
        flashBarNote("Fill");
        break;
      case "pinch-in":
        playerCtl.setProp("panscan", 0).catch(() => {});
        flashBarNote("Fit");
        break;
      case "hold-start":
        if (speedBeforeHold === null) speedBeforeHold = pbState.speed;
        playerCtl.setSpeed(2).catch(() => {});
        flashBarNote("2× speed");
        break;
      case "hold-end":
        if (speedBeforeHold !== null) playerCtl.setSpeed(speedBeforeHold).catch(() => {});
        speedBeforeHold = null;
        break;
    }
  }
}

/** The last player-status seen, for redrawing the bar when it comes back into
 *  view after ticks it skipped. */
let lastBarStatus: any = null;

/**
 * Fullscreen with the controls tucked away: the video covers every pixel of the
 * page, bar included. Rewriting the bar's clock and scrubber once a second
 * there is invisible, but not free — every DOM change is a web frame, and each
 * web frame a full-window paint in the UI process — for the whole length of a
 * film. `fsSetBar` redraws from `lastBarStatus` on the way back in.
 */
function barOutOfSight(): boolean {
  return videoFullscreen && !fsBarShown && playerEmbedded && !videoPip;
}

function updatePlayerBar(st: any): void {
  lastBarStatus = st.active ? st : null;
  const bar = $("player-bar");
  const content = $("content");
  if (!st.active) {
    if (isAutoplayPending()) {
      // The next episode is being fetched — keep the bar (and fullscreen) up.
      ($("pb-state") as HTMLElement).textContent = "Loading next episode…";
      return;
    }
    resetMediaExtras(null);
    playerActive = false;
    playerEmbedded = false;
    reflectCoverage();
    bar.classList.add("hidden");
    content.classList.remove("has-player");
    if (videoFullscreen) setVideoFullscreen(false);
    // Playback is over for good — autoplay already had its say above. The
    // backend keeps the floating window alive across the gap between episodes,
    // so closing it is ours to ask for.
    if (videoPip) void setVideoPip(false);
    return;
  }
  if (!playerActive) {
    playerActive = true;
    bar.classList.remove("hidden");
    content.classList.add("has-player");
  }
  playerEmbedded = !!st.embedded;
  reflectCoverage();

  // Bookkeeping that isn't drawing, so it happens whether or not the bar is
  // on screen: a new file re-resolves its extras (and tells MPRIS whether
  // there is a next episode), and Settings reports the last decoder used.
  const playingId = st.item_id ?? getNowPlaying()?.item?.Id ?? null;
  if (playingId !== mediaItemId) resetMediaExtras(playingId);
  if (typeof st.hwdec === "string" && st.hwdec && st.hwdec !== lastHwdecSaved) {
    lastHwdecSaved = st.hwdec;
    try {
      localStorage.setItem("aquarium.hwdec-last", st.hwdec);
    } catch {
      // Settings just says "not measured yet".
    }
  }
  if (Array.isArray(st.chapters)) pbChapters = st.chapters;
  if (barOutOfSight()) return;

  // mpv reports a duration for a live mux too — a growing one, which is worse
  // than none — so what's playing, not what mpv measured, decides this.
  const live = !!getQualityState()?.live;
  bar.classList.toggle("live", live);
  const fsBtn = $("pb-fullscreen");
  if (fsBtn) fsBtn.style.display = playerEmbedded ? "" : "none";
  // Both only mean anything when the picture is ours to move; mpv in a window
  // of its own is already the thing PiP would make.
  const pipBtn = $("pb-pip");
  if (pipBtn) pipBtn.style.display = playerEmbedded ? "" : "none";
  const { line1, line2, tip } = playerTitleLines(getNowPlaying()?.item, st.title || "Playing");
  const titleEl = $("pb-title") as HTMLElement;
  titleEl.textContent = line1;
  // The box is narrow and the text is ellipsised; the tooltip is the only way
  // to read the whole of "The One Where Everybody Finds Out".
  titleEl.title = tip ?? (st.title || line1);
  const subtitleEl = $("pb-subtitle") as HTMLElement;
  subtitleEl.textContent = line2;
  subtitleEl.title = line2;
  // Only the states worth interrupting for get the badge — the play/pause
  // button already says "Playing", so repeating it here under a title that's
  // otherwise silent is exactly the noise "Buffering…" needs to cut through.
  ($("pb-state") as HTMLElement).textContent = barNoteShowing()
    ? barNote.text
    : st.paused
      ? "Paused"
      : st.buffering
        ? "Buffering…"
        : "";
  ($("pb-playpause") as HTMLElement).innerHTML = st.paused ? PB_ICONS.play : PB_ICONS.pause;
  ($("pb-pos") as HTMLElement).textContent = api.secondsToClock(st.position ?? 0);
  ($("pb-dur") as HTMLElement).textContent =
    st.duration > 0
      ? showsRemaining()
        ? `−${api.secondsToClock(Math.max(0, st.duration - (st.position ?? 0)))}`
        : api.secondsToClock(st.duration)
      : "live";
  syncSkipButtons();
  const chBtn = document.getElementById("pb-chapters-btn");
  if (chBtn) chBtn.style.display = pbChapters.length ? "" : "none";
  const range = $("pb-range") as HTMLInputElement;
  range.dataset.duration = String(live ? 0 : st.duration ?? 0);
  if (!seeking && !live && st.duration > 0) {
    const pct = Math.min(100, (st.position / st.duration) * 100);
    range.value = String(Math.round(pct * 10));
    setRangeFill(range, pct);
  }
  // How much is loaded ahead of the playhead. Never behind it: on a local file
  // mpv reports no cache at all, and a buffer that trailed the position would
  // read as the stream falling behind.
  if (st.duration > 0) {
    const buffered = Math.max(st.position ?? 0, st.buffered ?? 0);
    range.style.setProperty("--buffered", `${Math.min(100, (buffered / st.duration) * 100)}%`);
  }
  renderChapters(st.duration ?? 0);
  syncSkipButton(st);
  syncUpNext(st);
  syncAudioState(st);
}

/** Mirror mpv's audio/timing state onto the bar. mpv is the authority — the
 *  same properties can be changed from its own keys or the uosc overlay. */
function syncAudioState(st: any): void {
  if (typeof st.volume === "number" && Date.now() - volumeTouchedAt > 600) {
    pbState.volume = st.volume;
    noteVolume(st.volume);
    const slider = document.getElementById("pb-volume") as HTMLInputElement | null;
    if (slider && document.activeElement !== slider) {
      slider.value = String(Math.round(st.volume));
      setRangeFill(slider, (st.volume / MAX_VOLUME) * 100);
      slider.title = `Volume ${Math.round(st.volume)}% (↑/↓)`;
    }
  }
  if (typeof st.mute === "boolean") pbState.mute = st.mute;
  if (typeof st.speed === "number" && st.speed > 0) pbState.speed = st.speed;
  if (typeof st.sub_delay === "number") pbState.subDelay = st.sub_delay;
  if (typeof st.audio_delay === "number") pbState.audioDelay = st.audio_delay;

  const muteBtn = document.getElementById("pb-mute");
  if (muteBtn) {
    muteBtn.innerHTML = volumeIcon(pbState);
    muteBtn.title = pbState.mute ? "Unmute (m)" : "Mute (m)";
  }
  const vol = document.getElementById("pb-volume");
  vol?.classList.toggle("muted", pbState.mute);
  // A speed other than 1× is easy to forget you set; say so next to the title.
  const state = document.getElementById("pb-state");
  if (state && Math.abs(pbState.speed - 1) > 0.001 && !st.paused && !barNoteShowing()) {
    state.textContent = `${pbState.speed}× speed`;
  }
  ($("player-bar").querySelector(".pb-panel") as BarPanel | null)?.sync?.(pbState);
}

// ---------- Search ----------

const SEARCH_DEBOUNCE_MS = 320;

/**
 * Go to a search page. Typing rewrites the hash in place instead of pushing,
 * so a query typed one letter at a time costs one Back press, not eleven —
 * only the first keystroke (arriving from another page) is a real navigation.
 */
function gotoSearch(term: string): void {
  const target = `#/search/${encodeURIComponent(term)}`;
  if (location.hash === target) return;
  if (location.hash.startsWith("#/search/")) {
    history.replaceState(null, "", target);
    route();
  } else {
    location.hash = target;
  }
}

function wireSearch(): void {
  const input = $("search-input") as HTMLInputElement;
  const panel = $("search-recent");
  let debounce = 0;

  const hidePanel = (): void => {
    panel.toggleAttribute("hidden", true);
  };

  const clearRecent = (): void => {
    clearRecentSearches();
    hidePanel();
  };

  const showPanel = (): void => {
    const terms = recentSearches();
    if (!terms.length || input.value.trim()) {
      hidePanel();
      return;
    }
    clear(panel);
    panel.append(
      el("div", { class: "sr-head" }, [
        el("span", {}, ["Recent searches"]),
        el("span", {
          class: "sr-clear",
          onClick: clearRecent,
          ...asButton(clearRecent),
        }, ["Clear"]),
      ])
    );
    for (const t of terms) {
      panel.append(
        el("button", {
          class: "sr-item",
          onClick: () => {
            input.value = t;
            rememberSearch(t);
            hidePanel();
            gotoSearch(t);
          },
        }, [t])
      );
    }
    panel.toggleAttribute("hidden", false);
  };

  input.addEventListener("input", () => {
    clearTimeout(debounce);
    const term = input.value.trim();
    if (!term) {
      showPanel();
      return;
    }
    hidePanel();
    debounce = window.setTimeout(() => gotoSearch(term), SEARCH_DEBOUNCE_MS);
  });

  input.addEventListener("keydown", (ev) => {
    if (ev.key === "Enter") {
      clearTimeout(debounce);
      const term = input.value.trim();
      if (!term) return;
      // Only a committed search joins the recent list.
      rememberSearch(term);
      hidePanel();
      gotoSearch(term);
    } else if (ev.key === "Escape") {
      hidePanel();
      input.blur();
    }
  });

  input.addEventListener("focus", showPanel);
  document.addEventListener("click", (ev) => {
    const t = ev.target as Node;
    if (t !== input && !panel.contains(t)) hidePanel();
  });

  // "/" focuses search from anywhere, as long as you're not already typing.
  document.addEventListener("keydown", (ev) => {
    if (ev.key !== "/" || ev.ctrlKey || ev.metaKey || ev.altKey) return;
    if (isTyping(ev.target)) return;
    ev.preventDefault();
    input.focus();
    input.select();
  });
}

/** True when the key belongs to whatever the user is typing into. */
function isTyping(target: EventTarget | null): boolean {
  const t = target as HTMLElement | null;
  if (!t) return false;
  return ["INPUT", "TEXTAREA", "SELECT"].includes(t.tagName) || t.isContentEditable;
}

/** Shell-level keys, live whether or not something is playing. */
function wireGlobalKeys(): void {
  document.addEventListener("keydown", (ev) => {
    if (ev.ctrlKey || ev.metaKey) return;
    // Alt+← is the desktop convention for Back, and it's the only way to
    // navigate back without a mouse (the button itself is tabbable, but this
    // works from anywhere).
    if (ev.altKey) {
      if (ev.key === "ArrowLeft") {
        ev.preventDefault();
        goBack();
      }
      return;
    }
    if (isTyping(ev.target)) return;
    // "?" is Shift+/ on most layouts; match the character, not the key code.
    if (ev.key === "?") {
      ev.preventDefault();
      toggleShortcuts();
    }
  });
}

// ---------- Keyboard shortcut sheet ----------

const SHORTCUTS: { group: string; rows: [string[], string][] }[] = [
  {
    group: "Anywhere",
    rows: [
      [["/"], "Focus search"],
      [["?"], "This list"],
      [["Esc"], "Close menu, panel or dialog"],
      [["Alt", "←"], "Back"],
    ],
  },
  {
    group: "Playback",
    rows: [
      [["Space"], "Play / pause"],
      [["Enter"], "Play the next episode (while Up next is showing)"],
      [["←", "→"], "Skip back / forward (the interval in Settings)"],
      [["↑", "↓"], "Volume"],
      [["m"], "Mute"],
      [["c"], "Subtitles off, or back to the last track"],
      [["s"], "Skip intro or credits"],
      [["i"], "Stream info (also Ctrl+I)"],
      [["[", "]"], "Slower / faster"],
      [["z", "Z"], "Subtitles earlier / later"],
      [["Ctrl", "−", "="], "Audio earlier / later (Ctrl+0 resets)"],
      [["f"], "Fullscreen"],
      [["p"], "Picture in picture"],
      [["Esc"], "Leave fullscreen"],
    ],
  },
  {
    group: "On the picture",
    rows: [
      [["Wheel"], "Volume"],
      [["Tilt", "Swipe ↔"], "Scrub"],
      [["Right-click"], "Player menu"],
      [["Double-click"], "Fullscreen"],
      [["Double-tap ◀ ▶"], "Skip back / forward"],
      [["Pinch"], "Fit or Fill"],
      [["Hold"], "Play at 2× while held"],
    ],
  },
  {
    group: "Browsing",
    rows: [
      [["←", "→", "↑", "↓"], "Move between cards"],
      [["Tab"], "Move between cards and controls"],
      [["Enter"], "Open the focused item"],
      [["Menu"], "Actions for the focused item"],
    ],
  },
];

let shortcutsOpen: (() => void) | null = null;

function toggleShortcuts(): void {
  if (shortcutsOpen) {
    shortcutsOpen();
    shortcutsOpen = null;
    return;
  }
  const body = SHORTCUTS.map((g) =>
    el("div", { class: "shortcut-group" }, [
      el("h4", {}, [g.group]),
      ...g.rows.map(([keys, what]) =>
        el("div", { class: "shortcut-row" }, [
          el("span", {}, [what]),
          el("span", { class: "shortcut-keys" }, keys.map((k) => el("kbd", {}, [k]))),
        ])
      ),
    ])
  );
  const close = openDialog({
    title: "Keyboard shortcuts",
    body,
    actions: [{ label: "Close", primary: true }],
    onDismiss: () => {
      shortcutsOpen = null;
    },
  });
  shortcutsOpen = () => {
    close();
    shortcutsOpen = null;
  };
}

// ---------- Quit guard ----------

/**
 * The window's close button kills every download mid-file. Rust holds the close
 * and asks here first; either answer is final for that attempt.
 *
 * The prompt is HTML, and embedded video is a native surface drawn over the
 * page (fullscreen or not), so it would sit invisibly underneath — and the
 * window could then neither close nor be asked again. The picture is moved
 * into picture-in-picture for as long as the question is up (which also
 * leaves fullscreen), and brought back if the answer is to stay. A second
 * close while it's up is the same question, not another dialog on top.
 */
let quitPromptOpen = false;

async function askBeforeQuit(count: number): Promise<void> {
  if (quitPromptOpen) return;
  quitPromptOpen = true;
  let movedToPip = false;
  if (playerActive && playerEmbedded && !videoPip) {
    await setVideoPip(true);
    movedToPip = videoPip;
    // PiP refused (it says why in a toast): stop the picture rather than ask
    // a question nobody can see. The user was closing the app anyway.
    if (!movedToPip) await playerCtl.stop().catch(() => {});
  }
  const stay = (): void => {
    quitPromptOpen = false;
    if (movedToPip && videoPip) void setVideoPip(false);
  };
  openDialog({
    title: `${count} download${count === 1 ? " is" : "s are"} still running`,
    body: [
      el("p", {}, [
        count === 1
          ? "Quitting now stops the transfer. The partial file is kept, and the download resumes from where it stopped the next time Aquarium starts."
          : "Quitting now stops those transfers. Partial files are kept, and the downloads resume from where they stopped the next time Aquarium starts.",
      ]),
    ],
    actions: [
      { label: "Keep downloading", primary: true, run: stay },
      {
        label: "Quit anyway",
        danger: true,
        run: () => {
          quitPromptOpen = false;
          void invoke("quit_confirm", { quit: true });
        },
      },
    ],
    onDismiss: stay,
  });
}

// ---------- Session memory ----------

const LAST_ROUTE_KEY = "aquarium.last-route";
// Pages that make no sense to reopen into: a stale search, or a detail page for
// something that may since have been deleted from the server.
const RESUMABLE = ["home", "lib", "favorites", "livetv", "downloads", "settings"];

function rememberRoute(): void {
  const hash = location.hash || "#/home";
  const page = hash.match(/^#\/([^/]*)/)?.[1] ?? "home";
  if (!RESUMABLE.includes(page)) return;
  try {
    localStorage.setItem(LAST_ROUTE_KEY, hash);
  } catch {
    /* the app just always opens on Home */
  }
}

function lastRoute(): string | null {
  try {
    const v = localStorage.getItem(LAST_ROUTE_KEY);
    return v && v.startsWith("#/") ? v : null;
  } catch {
    return null;
  }
}

// ---------- Boot ----------

async function boot(): Promise<void> {
  try {
    await api.loadConfig();
  } catch (e) {
    console.error("config load failed:", e);
  }
  await initTheme();
  buildPlayerBar();
  try {
    await registerPlayerBridge();
  } catch (e) {
    console.error("player bridge failed:", e);
  }
  try {
    await registerAdaptiveQuality();
  } catch (e) {
    console.error("adaptive quality failed:", e);
  }

  // `bg-idle` freezes the finite loading animations (skeleton sweep, spinner)
  // while the window is minimized or on another workspace; home.ts's hero
  // rotator stands down on its own when unseen.
  document.addEventListener("visibilitychange", () => {
    document.body.classList.toggle("bg-idle", document.hidden);
  });

  document.addEventListener("aquarium-fullscreen-toggle", () => {
    if (playerActive && playerEmbedded) setVideoFullscreen(!videoFullscreen);
  });

  document.addEventListener("aquarium-fullscreen-exit", () => {
    if (videoFullscreen) setVideoFullscreen(false);
  });

  // Switching the Live TV source in Settings can add or remove that entry, and
  // the sidebar is otherwise only built at startup and on reconnect.
  document.addEventListener("aquarium-nav-refresh", () => {
    void buildNav();
  });

  // A new mpv instance starts windowed. Whether the app follows depends on
  // what started it: the next episode, a quality switch or an episode picked
  // from the in-player menu carry on in whatever mode the last one was in
  // (fullscreen included — re-asserted, since the backend reset its
  // viewport); anything picked from the page starts windowed, bar and all,
  // even if a stale fullscreen flag says otherwise. Fullscreen is something
  // the user asks for, per session, with the button or the key.
  document.addEventListener("aquarium-player-started", (ev) => {
    if (!videoFullscreen) return;
    const continuation = !!(ev as CustomEvent).detail?.continuation;
    setVideoFullscreen(continuation);
  });

  // Autoplay found nothing next (or failed) — tear the player UI down.
  document.addEventListener("aquarium-autoplay-none", () => {
    updatePlayerBar({ active: false });
  });

  // The server stopped honouring our token (expired, or the session was
  // revoked from another device). Every page would otherwise fail on its own,
  // with Settings → Sign out as the only way out.
  document.addEventListener("aquarium-player-input", (ev) => {
    const d = (ev as CustomEvent).detail ?? {};
    const arg = d.name === "aquarium-gesture" && d.arg === "doubletap" ? `doubletap-${d.rest?.[0] ?? "middle"}` : d.arg;
    onPlayerInput(d.name, String(arg ?? ""));
  });
  // Something was queued or dequeued: the Up Next card and the desktop's
  // next button follow the queue.
  document.addEventListener("aquarium-queue-changed", () => {
    if (!playerActive) return;
    const forId = mediaItemId;
    void peekNextEpisode().then((next) => {
      if (mediaItemId !== forId) return;
      upNextItem = next;
      invoke("player_set_next_available", { available: !!next }).catch(() => {});
    }).catch(() => {});
  });
  await listen("player-stall", () => {
    stallsThisFile++;
  });

  // Next Up was changed on the server from a menu: Home redraws from a fresh
  // request rather than waiting for the next visit.
  document.addEventListener("aquarium-next-up-changed", () => {
    if (atHome() && !playerActive) route();
  });

  document.addEventListener("aquarium-account-switch", (ev) => {
    const key = (ev as CustomEvent).detail?.key;
    if (key) void switchToAccount(key);
  });
  document.addEventListener("aquarium-add-account", () => showAddAccount());

  document.addEventListener("aquarium-auth-expired", () => {
    closeMenus();
    showLogin();
    toast("Your session expired — please sign in again", "error");
  });

  // The saved address is answering as a different Jellyfin server than the one
  // this session belongs to. Could be a rebuilt server; could be someone
  // pointing the client at a host of their choosing. Either way the token does
  // not go out until a human has looked at it.
  let identityWarned = false;
  document.addEventListener("aquarium-server-identity", (ev) => {
    if (identityWarned) return;
    identityWarned = true;
    closeMenus();
    showLogin();
    toast(
      (ev as CustomEvent).detail?.message ??
        "This address is not the server you signed in to — check it and sign in again",
      "error"
    );
  });

  // Rust held a window close because transfers are in flight.
  await listen("quit-requested", (ev) => {
    void askBeforeQuit((ev.payload as any)?.downloads ?? 0);
  });

  // Offline/online transitions from the API layer.
  document.addEventListener("aquarium-connectivity", (ev) => {
    const off = !!(ev as CustomEvent).detail?.offline;
    updateOfflinePill();
    if (off) {
      toast("Server unreachable — offline mode. Downloads still work.", "error");
      // The verdict now comes a probe *after* the request that failed (see
      // api.ts), so the page that request was for has already drawn its
      // error; redraw it as the offline screen.
      route();
      // Start probing for the server's return, from the shortest interval.
      retryDelay = RETRY_MIN_MS;
      scheduleServerRetry();
    } else {
      stopServerRetry();
      toast("Back online", "ok");
      buildNav();
      route();
      syncOfflineProgress(false);
    }
  });

  // While offline, quietly retry the server — backing off rather than probing
  // at a fixed rate forever. Each probe is a TCP connect with a 5s timeout, and
  // being offline is exactly when the machine is on battery and away from a
  // network, so a flat 15s poll spends the evening waking the radio 240 times
  // an hour to hear the same answer. Backing off to a 5min ceiling makes that
  // about a dozen, and a server that comes back is still found within minutes.
  const RETRY_MIN_MS = 15_000;
  const RETRY_MAX_MS = 300_000;
  let retryDelay = RETRY_MIN_MS;
  let retryTimer = 0;

  function stopServerRetry(): void {
    clearTimeout(retryTimer);
    retryTimer = 0;
    retryDelay = RETRY_MIN_MS;
  }

  /** (Re)arm the offline probe at the current backoff, from zero or a reset —
   *  or at `delay`, for a signal that the answer may have changed. */
  function scheduleServerRetry(delay = retryDelay): void {
    clearTimeout(retryTimer);
    retryTimer = window.setTimeout(async () => {
      retryTimer = 0;
      if (!api.getSession() || !api.isOffline()) return;
      const ok = await api.checkOnline();
      // Coming back online fires the connectivity event, which stops the loop;
      // still offline means wait longer before asking again.
      if (!ok) {
        retryDelay = Math.min(retryDelay * 2, RETRY_MAX_MS);
        scheduleServerRetry();
      }
    }, delay);
  }

  // A session restored while the server is already unreachable never fires a
  // transition, so arm the first probe here.
  if (api.getSession() && api.isOffline()) scheduleServerRetry();

  // The backoff is for a server that is simply gone. A *network* that comes
  // back — Wi-Fi reconnecting after a wake, a cable going in — is the desktop's
  // to announce (GNetworkMonitor, relayed by lib.rs), and is the moment to ask
  // again rather than sit out the rest of a five-minute wait. A moment's grace
  // for the resolver: the link is up before names resolve over it.
  await listen("network-changed", (ev) => {
    if (!(ev.payload as any)?.available) return;
    if (!api.getSession() || !api.isOffline()) return;
    retryDelay = RETRY_MIN_MS;
    scheduleServerRetry(1500);
  });
  // Coming back to the window is the other cue that the network may have
  // changed while nobody was looking.
  document.addEventListener("visibilitychange", () => {
    if (document.hidden || !api.getSession() || !api.isOffline()) return;
    scheduleServerRetry(0);
  });

  $("offline-retry").addEventListener("click", async () => {
    const ok = await api.checkOnline();
    if (!ok) {
      toast("Still offline — server unreachable", "error");
      // An explicit ask means the user thinks the network changed; start the
      // backoff over so the next automatic probe is soon, not five minutes out.
      retryDelay = RETRY_MIN_MS;
      scheduleServerRetry();
    }
  });

  await listen("player-status", (ev) => updatePlayerBar(ev.payload as any));
  // Something other than mpv changed what the bar says (a channel switch
  // starting from the Channels panel); redraw now, not on the next tick.
  document.addEventListener("aquarium-bar-refresh", () => {
    if (lastBarStatus) updatePlayerBar(lastBarStatus);
  });
  // The offline-progress queue changed (queued, or pushed to the server): the
  // footer's "Syncing N items" is otherwise only re-read on navigation.
  await listen("progress-queue-changed", () => void updateSidebarFooter());
  document.addEventListener("aquarium-progress-queue", () => void updateSidebarFooter());
  await listen("download-progress", (ev) => {
    updateDownloadProgress(ev.payload, $("content"));
    // Only terminal states change the footer's summary; per-byte updates would
    // rebuild it several times a second.
    const state = (ev.payload as any)?.state;
    if (state && state !== "downloading") void updateSidebarFooter();
  });
  // Mouse moved over the video (mpv owns the pointer there): reveal the
  // fullscreen bar. Motion over the revealed bar itself arrives as normal
  // DOM events instead.
  // The floating PiP window was closed from its own title bar: the backend has
  // already put the picture back, the bar just has to stop claiming otherwise.
  await listen("player-pip", (ev) => {
    videoPip = !!(ev.payload as any)?.on;
    reflectPip();
  });
  await listen("player-mouse", (ev) => {
    // mpv re-emits `mouse-pos` whenever the widget it measures against
    // changes size — which is exactly what revealing and hiding the bar does
    // — carrying the coordinates the pointer already had and only a flipped
    // `hover`. Those repeats are geometry, not motion, and acting on them is
    // the feedback loop described on `fsLastVideoPointer`.
    const pos = ev.payload as { x?: number; y?: number } | null;
    const x = typeof pos?.x === "number" ? pos.x : -1;
    const y = typeof pos?.y === "number" ? pos.y : -1;
    if (x === fsLastVideoPointer.x && y === fsLastVideoPointer.y) return;
    fsLastVideoPointer = { x, y };
    // Unambiguous proof the pointer is on the video, not the bar — a
    // stronger signal than waiting on `mouseleave` to say the same thing,
    // and the backstop if it doesn't (see the comment on `fsBarHovered`).
    fsBarHovered = false;
    fsPokeControls();
  });
  document.addEventListener("mousemove", (e) => {
    // Same distinction as the bar's own handler, for the same reason: a
    // synthetic move at an unchanged position (or outside the window) is the
    // layout catching up, not the user asking for the controls. Recorded
    // here, after the bar's handler has already compared against the
    // previous value — and only for a real move, so the out-of-window
    // position WebKit reports for a crossing never becomes the baseline the
    // pointer's return is measured against.
    const moved = fsPointerMoved(e);
    if (moved) fsLastPointer = { x: e.clientX, y: e.clientY };
    if (moved && videoFullscreen) fsPokeControls();
  });
  // Leaving the window for another one and coming back is the other way the
  // hover latch got stranded: the pointer's last DOM crossing was onto the
  // bar, and nothing on the way out says otherwise. Nothing is hovered in a
  // window that isn't focused.
  window.addEventListener("blur", () => {
    fsBarHovered = false;
  });

  wireSearch();
  wireGlobalKeys();
  // Arrows move between tiles — except while the player owns them for seeking
  // and volume, or a menu or dialog is walking its own entries.
  wireSpatialNav(
    () =>
      playerActive ||
      !!document.querySelector(".menu") ||
      !!document.querySelector(".dialog-scrim") ||
      isTyping(document.activeElement)
  );
  // Warms a card's detail page while it's focused or hovered, so opening it
  // usually finds the page already cached.
  wirePrefetch();

  // The top bar floats over the page rather than sitting in a strip above it,
  // so the hero artwork runs edge to edge behind it. It stays invisible until
  // there's something underneath worth separating from, then frosts over.
  {
    const content = $("content");
    const topbar = $("topbar");
    // Wheel scrolling is eased frame by frame rather than jumped notch by
    // notch, so the motion is paced by the display instead of by the wheel.
    wireSmoothScroll(content);
    content.addEventListener(
      "scroll",
      () => {
        topbar.classList.toggle("scrolled", content.scrollTop > 4);
        scrollMemory.set(location.hash || "#/home", content.scrollTop);
      },
      { passive: true }
    );
  }

  window.addEventListener("hashchange", (ev) => {
    if (navigatingBack) {
      navigatingBack = false;
    } else {
      const from = hashOf((ev as HashChangeEvent).oldURL);
      // Don't stack repeats; keep home as the stack floor.
      if (from !== (location.hash || "#/home")) navStack.push(from);
    }
    // Home is the root: there is nothing above it to go back to, so landing
    // there ends the trail rather than leaving a Back button that jumps to
    // whatever page you happened to come from.
    if (atHome()) navStack.length = 0;
    updateBackButton();
    rememberRoute();
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
    // Audio delay on mpv's own Ctrl++ / Ctrl+−, and Ctrl+I for stream info.
    if (ev.ctrlKey && !ev.altKey && !ev.metaKey) {
      switch (ev.key) {
        case "=":
        case "+":
          ev.preventDefault();
          nudgeAudioDelay(1);
          break;
        case "-":
          ev.preventDefault();
          nudgeAudioDelay(-1);
          break;
        case "0":
          ev.preventDefault();
          nudgeAudioDelay(0);
          break;
        case "i":
        case "I":
          ev.preventDefault();
          openInfo();
          break;
      }
      return;
    }
    if (ev.altKey || ev.metaKey) return;
    switch (ev.key) {
      case " ":
        ev.preventDefault();
        playerCtl.pauseToggle();
        break;
      // The Up Next card is a question; Enter is yes. Only while it's up, and
      // not when a focused button has its own idea of what Enter means.
      case "Enter":
        if (!upNextShowing() || (t && t.tagName === "BUTTON")) break;
        ev.preventDefault();
        void startUpNext();
        break;
      case "ArrowLeft":
        ev.preventDefault();
        skipBy(-1);
        break;
      case "ArrowRight":
        ev.preventDefault();
        skipBy(1);
        break;
      case "c":
      case "C":
        toggleSubtitles();
        break;
      case "s":
      case "S":
        skipSegment();
        break;
      case "i":
        openInfo();
        break;
      case "ArrowUp":
        ev.preventDefault();
        bumpVolume(5);
        break;
      // Channel up and down, while a channel plays.
      case "PageUp":
      case "PageDown":
        if (getQualityState()?.live && stepChannel(ev.key === "PageUp" ? -1 : 1)) ev.preventDefault();
        break;
      case "ArrowDown":
        ev.preventDefault();
        bumpVolume(-5);
        break;
      case "m":
        playerCtl.setMute(!pbState.mute).catch(() => {});
        break;
      // mpv's own bindings for the same jobs, so muscle memory carries over.
      case "[":
        stepSpeed(-1);
        break;
      case "]":
        stepSpeed(1);
        break;
      case "z":
        playerCtl.setSubDelay(pbState.subDelay - SUB_DELAY_STEP).catch(() => {});
        break;
      case "Z":
        playerCtl.setSubDelay(pbState.subDelay + SUB_DELAY_STEP).catch(() => {});
        break;
      case "f":
        if (playerEmbedded && !videoPip) setVideoFullscreen(!videoFullscreen);
        break;
      case "p":
        void setVideoPip(!videoPip);
        break;
      case "Escape":
        if (videoFullscreen) {
          setVideoFullscreen(false);
        } else {
          // The window can be fullscreen without a video owning it (a
          // restored state, or the WM's own toggle). Esc must still get out.
          const win = getCurrentWindow();
          win.isFullscreen()
            .then((fs) => (fs ? win.setFullscreen(false) : undefined))
            .catch(() => {});
        }
        break;
    }
  });

  if (api.getSession()) {
    // Know up front whether the saved server is reachable, so a dead server
    // reads as "offline", not "nothing saved". Fast on LAN; 3s worst case.
    // The cache read runs alongside it rather than after; `showShell` awaits
    // the same promise.
    const owner = cacheOwner();
    if (owner) void hydrateCache(owner);
    await api.checkOnline();
    await showShell();
  } else {
    showLogin();
  }
}

boot();
