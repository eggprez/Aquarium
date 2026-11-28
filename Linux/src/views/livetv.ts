import * as api from "../api";
import * as iptv from "../iptv";
import { getNowPlaying } from "../playback";
import { loadLineup, lineupKey, nowNextSync, onNow as lineupOnNow, playChannel, refreshNow } from "../lineup";
import { el, clear, art, attachContextMenu, emptyState, icon, openDialog, skeletonRows, toast, type MenuAction } from "../ui";
import { getCached, setCached } from "../cache";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

/**
 * Where the page gets its channels and schedule. Jellyfin's Live TV and a
 * user's own M3U/XMLTV differ in how they're fetched and played and in nothing
 * else — both hand back the same channel and programme shapes — so the guide
 * below is written against this rather than against either one.
 */
interface GuideSource {
  custom: boolean;
  channels(): Promise<any[]>;
  programs(ids: string[], from: Date, to: Date): Promise<any[]>;
  /** Start a channel. Quiet: the tuning screen is the feedback, not toasts. */
  play(ch: any): Promise<void>;
  /** What to say when there are no channels at all. */
  emptyBody: string;
  /** What to say when there are channels but nothing scheduled. */
  noGuide: string;
}

const jellyfinSource: GuideSource = {
  custom: false,
  channels: () => loadLineup(),
  programs: (ids, from, to) => api.getPrograms(ids, from, to),
  play: (ch) => playChannel(ch),
  emptyBody:
    "This server has a Live TV library but no channels in it. Add a tuner and a guide source in the Jellyfin dashboard, then reload.",
  noGuide:
    "This server has no guide data, so there's nothing to lay out over time. Add a guide source in the Jellyfin dashboard to get a TV Guide.",
};

const customSource: GuideSource = {
  custom: true,
  channels: () => loadLineup(),
  programs: (_ids, from, to) => iptv.getPrograms(from, to),
  play: (ch) => playChannel(ch),
  emptyBody:
    "Your M3U playlist loaded but has no channels in it. Check the address in Settings → Live TV.",
  noGuide:
    "No XMLTV guide is set, or none of its channels matched this playlist. The guide joins on each channel's tvg-id, falling back to its name. Set one in Settings → Live TV.",
};

/**
 * A channel that's been clicked but isn't playing yet. A cold channel can take
 * 20 s to come up, and a toast that fades after three of them left the guide
 * looking idle — so it got clicked again, and again. Instead the player's
 * space goes dark straight away with the channel on it, the way a TV tunes.
 */
let tuning: { ch: any; overlay: HTMLElement; timer: number; cancelled: boolean; opened: boolean } | null = null;

/** Past this, say why it's slow rather than just that it is. */
const TUNING_SLOW_S = 5;
/** Longest the screen waits on the first frame once mpv has the stream. */
const FIRST_FRAME_CAP_MS = 15_000;

/**
 * mpv takes the stream a few seconds before it has a picture to show (about
 * 3 s on a Tunarr channel). Lifting the tuning screen when the player starts
 * would show the guide again for that long; wait for the clock to move.
 */
async function firstFrame(): Promise<void> {
  let done!: () => void;
  const shown = new Promise<void>((r) => (done = r));
  const unlisten = listen<any>("player-status", (ev) => {
    const st = ev.payload;
    if (!st?.active || (st.position > 0 && !st.buffering)) done();
  });
  const cap = window.setTimeout(done, FIRST_FRAME_CAP_MS);
  await shown;
  clearTimeout(cap);
  (await unlisten)();
}

function endTuning(): void {
  if (!tuning) return;
  clearInterval(tuning.timer);
  tuning.overlay.remove();
  tuning = null;
}

function tune(src: GuideSource, ch: any): void {
  // Another click on the channel already on its way changes nothing.
  if (tuning && tuning.ch.Id === ch.Id) return;
  endTuning();
  const started = Date.now();
  const status = el("p", { class: "tuning-status" }, ["Tuning…"]);
  const overlay = el("div", { class: "tuning", role: "status", "aria-live": "polite" }, [
    el("div", { class: "channel-logo tuning-logo" }, [
      art(ch.LogoUrl ?? api.imageUrl(ch, "Primary", 320), () =>
        document.createTextNode(String(ch.ChannelNumber ?? ch.Name ?? "?").slice(0, 4))
      ),
    ]),
    el("h2", { class: "tuning-name" }, [channelLabel(ch)]),
    status,
    el("button", { class: "btn small", onClick: () => cancel() }, [icon("close"), "Cancel"]),
  ]);
  const t = { ch, overlay, timer: 0, cancelled: false, opened: false };
  // A once-a-second text change, not an animation: this can sit on screen for
  // 20 s, and a spinner repaints the whole window every frame (see CLAUDE.md).
  t.timer = window.setInterval(() => {
    const s = Math.round((Date.now() - started) / 1000);
    status.textContent =
      s < TUNING_SLOW_S
        ? `Tuning… ${s} s`
        : `Still tuning… ${s} s — a channel nobody's watching can take a while to start`;
  }, 1000);
  function cancel(): void {
    t.cancelled = true;
    // mpv already has it and is waiting on the first frame.
    if (t.opened && getNowPlaying()?.item === ch) void invoke("player_stop").catch(() => {});
    if (tuning === t) endTuning();
  }
  tuning = t;
  document.getElementById("main")?.append(overlay);
  src
    .play(ch)
    .then(async () => {
      // Cancelled after the stream was asked for: it may have opened anyway.
      if (t.cancelled) {
        if (getNowPlaying()?.item === ch) void invoke("player_stop").catch(() => {});
        return;
      }
      t.opened = true;
      await firstFrame();
    })
    // playItem / playChannelUrl already toast the failure.
    .catch(() => {})
    .finally(() => {
      if (tuning === t) endTuning();
    });
}

/** Horizontal scale of the guide. 30 minutes is the slot every schedule is
 *  built on, and 150px is the narrowest it can be and still fit a programme
 *  title worth reading. */
const PX_PER_MIN = 5;
const SLOT_MIN = 30;
/** How much of the schedule one window holds, and how far the arrows move it.
 *  More hours adds another window's worth to the end, up to a day. */
const WINDOW_MIN = 6 * 60;
const MAX_WINDOW_MIN = 24 * 60;
const SHIFT_MIN = 3 * 60;
/** A window left alone this long comes back at now: the arrows put it where
 *  it was on purpose, but a guide returned to after dinner should show what's
 *  on. */
const RESET_AFTER_MS = 30 * 60_000;
/** How long a click on a programme waits to see whether it is the first half
 *  of a double-click, which tunes instead of opening the details. */
const DOUBLE_CLICK_MS = 260;
/** How far ahead the day-and-time jump reaches; guides rarely hold more. */
const MAX_AHEAD_DAYS = 14;
/** The guide can be walked backwards, but only as far as a server typically
 *  keeps aired entries for — past that every lane comes back empty. */
const MAX_BACK_MIN = 12 * 60;

const fmtTime = (d: Date): string =>
  d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });

const fmtDay = (d: Date): string =>
  d.toLocaleDateString([], { weekday: "short", day: "numeric", month: "short" });

const startOfDay = (ms: number): number => {
  const d = new Date(ms);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
};

/** "Today", "Tomorrow", "Yesterday", or the weekday and date. */
export function dayLabel(d: Date): string {
  const days = Math.round((startOfDay(d.getTime()) - startOfDay(Date.now())) / 86_400_000);
  if (days === 0) return "Today";
  if (days === 1) return "Tomorrow";
  if (days === -1) return "Yesterday";
  return fmtDay(d);
}

/** `yyyy-mm-ddThh:mm` in local time, for a datetime-local input. */
function localInputValue(ms: number): string {
  const d = new Date(ms);
  const p = (n: number): string => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}

/** The half-hour mark at or before `ms` — where a guide window always starts. */
function floorToSlot(ms: number): number {
  const slot = SLOT_MIN * 60_000;
  return Math.floor(ms / slot) * slot;
}

function channelLabel(ch: any): string {
  return `${ch.ChannelNumber ? ch.ChannelNumber + " · " : ""}${ch.Name ?? "Channel"}`;
}

function channelCell(ch: any, onPlay: () => void): HTMLElement {
  return el("button", {
    class: "guide-ch",
    title: `Watch ${ch.Name ?? "channel"}`,
    onClick: onPlay,
  }, [
    el("div", { class: "channel-logo" }, [
      // Channel logos 404 often on scraped guides; fall back to the number.
      // A playlist carries its own logo URL; Jellyfin channels are asked for.
      art(ch.LogoUrl ?? api.imageUrl(ch, "Primary", 160), () =>
        document.createTextNode(String(ch.ChannelNumber ?? ch.Name ?? "?").slice(0, 4))
      ),
    ]),
    el("div", { class: "guide-ch-text" }, [
      el("span", { class: "guide-ch-num" }, [ch.ChannelNumber ? String(ch.ChannelNumber) : ""]),
      el("span", { class: "guide-ch-name" }, [ch.Name ?? "Channel"]),
    ]),
  ]);
}

/** Everything the grid can't show: the synopsis, the flags, and the way in.
 *  With no programme (a channel with nothing in the guide) it is the channel
 *  alone. */
function showProgram(prog: any | null, ch: any, play: (ch: any) => void): void {
  const actions = [
    { label: "Close" },
    { label: `Watch ${ch.Name ?? "channel"}`, primary: true, run: () => play(ch) },
  ];
  if (!prog) {
    openDialog({
      title: channelLabel(ch),
      body: [el("p", {}, ["No guide data for this channel."])],
      actions,
    });
    return;
  }
  const start = new Date(prog.StartDate);
  const end = new Date(prog.EndDate);
  const badges: string[] = [];
  if (prog.IsLive) badges.push("Live");
  if (prog.IsNew) badges.push("New");
  if (prog.IsRepeat) badges.push("Repeat");
  if (prog.OfficialRating) badges.push(prog.OfficialRating);
  const genres: string[] = Array.isArray(prog.Genres) ? prog.Genres.filter(Boolean) : [];

  openDialog({
    title: prog.Name ?? "Programme",
    body: [
      el("p", { class: "guide-dlg-when" }, [
        `${fmtDay(start)} · ${fmtTime(start)} – ${fmtTime(end)} · ${channelLabel(ch)}`,
      ]),
      prog.EpisodeTitle ? el("p", { class: "guide-dlg-ep" }, [prog.EpisodeTitle]) : null,
      badges.length
        ? el("div", { class: "guide-dlg-badges" }, badges.map((b) => el("span", { class: "guide-badge" }, [b])))
        : null,
      el("p", {}, [prog.Overview ?? "No description for this programme."]),
      genres.length ? el("p", { class: "guide-dlg-genres" }, [genres.join(", ")]) : null,
    ].filter(Boolean) as (string | Node)[],
    actions,
  });
}

/** The right-click menu on a channel or a programme cell: the same three
 *  verbs on both, as on the Mac. */
function cellMenu(title: string, onPlay: () => void, onInfo: () => void): MenuAction[] {
  return [
    { label: "Play Channel", icon: "play", run: onPlay },
    { label: "Show Info", run: onInfo },
    {
      label: "Copy Title",
      run: async () => {
        try {
          await navigator.clipboard.writeText(title);
          toast("Title copied", "ok");
        } catch {
          toast("Couldn't reach the clipboard", "error");
        }
      },
    },
  ];
}

/** The plain list the page used to be, kept for servers with channels but no
 *  guide source — a grid of empty lanes says less than a list of channels. */
function channelList(channels: any[], play: (ch: any) => void): HTMLElement {
  const list = el("div", {});
  for (const ch of channels) {
    const prog = ch.CurrentProgram;
    list.append(
      el("div", { class: "channel-row" }, [
        el("div", { class: "channel-logo" }, [
          art(ch.LogoUrl ?? api.imageUrl(ch, "Primary", 160), () =>
            document.createTextNode(String(ch.ChannelNumber ?? ch.Name ?? "?").slice(0, 4))
          ),
        ]),
        el("div", { class: "channel-body" }, [
          el("h4", {}, [channelLabel(ch)]),
          el("p", {}, [
            el("span", { class: "live-dot" }),
            prog ? `${prog.Name}${prog.EpisodeTitle ? ` — ${prog.EpisodeTitle}` : ""}` : "No guide data",
          ]),
        ]),
        el("button", {
          class: "btn small primary",
          onClick: () => play(ch),
        }, [icon("play"), "Watch"]),
      ])
    );
  }
  return list;
}

/** What the page draws from a channel list, ignoring the programme currently
 *  on air — that changes every half hour and the guide fetches it itself. */
function channelSignature(channels: any[]): string {
  return channels
    .map((c) => `${c.Id}:${c.ChannelNumber ?? ""}:${c.Name ?? ""}:${c.LogoUrl ?? c.ImageTags?.Primary ?? ""}`)
    .join(",");
}

export async function renderLiveTv(root: HTMLElement): Promise<void> {
  clear(root);
  const src = iptv.isCustom() ? customSource : jellyfinSource;
  // Re-reads the line-up and the schedule; `aquarium-lineup-changed` (below)
  // then redraws the page from them.
  const refresh = el("button", {
    class: "btn small",
    title: "Read the channels and the guide again",
    onClick: () => {
      refresh.setAttribute("disabled", "");
      refresh.textContent = "Refreshing…";
      refreshNow().catch((e: any) => {
        toast(`Couldn't refresh Live TV: ${e?.message ?? e}`, "error");
        refresh.removeAttribute("disabled");
        refresh.textContent = "Refresh";
      });
    },
  }, ["Refresh"]);
  // The title, the guide's subtitle ("Today · 124 channels") and Refresh. One
  // node, so every repaint below carries all three along.
  const heading = el("div", { class: "section-head guide-page-head" }, [
    el("div", {}, [
      el("h1", { class: "page-title" }, ["Live TV"]),
      el("p", { class: "guide-sub" }, [""]),
    ]),
    el("div", { class: "head-tools" }, [refresh]),
  ]);
  root.append(heading);

  // The channel line-up barely changes, so the last known one draws the guide
  // straight away — the schedule inside it is fetched fresh regardless — and
  // the page is only rebuilt if the line-up itself came back different. The
  // app reads it in the background at launch (see lineup.ts), so this is the
  // usual case even on a first visit. With nothing cached (a new account, or
  // a source just switched over in Settings) the skeleton stands in.
  const cacheKey = lineupKey();
  const cached = getCached<any[]>(cacheKey);
  if (cached?.length) {
    paintLiveTv(root, heading, src, cached);
  } else {
    root.append(skeletonRows(8, "channel-row", "channel-logo"));
  }

  // Settings' Refresh now, or the custom source's refresh interval, read the
  // line-up again: repaint if this page is still the one showing.
  const onChanged = (): void => {
    document.removeEventListener("aquarium-lineup-changed", onChanged);
    if (document.contains(heading)) void renderLiveTv(root);
  };
  document.addEventListener("aquarium-lineup-changed", onChanged);

  // A custom source fails in ways worth reading — a wrong address, a host that
  // won't answer — where Jellyfin's own failure is almost always "no tuner".
  let loadError: string | null = null;
  const channels = await src.channels().catch((e: any) => {
    loadError = e?.message ?? String(e);
    return [] as any[];
  });
  if (!document.contains(heading)) {
    document.removeEventListener("aquarium-lineup-changed", onChanged);
    return; // navigated away while loading
  }

  if (loadError) {
    // A cached guide is still a working guide; the error only replaces a
    // skeleton.
    if (cached?.length) return;
    clear(root);
    root.append(
      heading,
      emptyState({
        icon: "error",
        error: true,
        title: src.custom ? "Couldn't load your playlist" : "Couldn't load Live TV",
        body: loadError,
        action: { label: "Try again", run: () => void renderLiveTv(root) },
      })
    );
    return;
  }

  if (cached?.length && channelSignature(cached) === channelSignature(channels)) return;
  clear(root);
  root.append(heading);
  paintLiveTv(root, heading, src, channels);
}

/** Where the keyboard is in the grid: a row, and the programme in it (null on
 *  a lane with nothing scheduled). Separate from what's playing — moving it
 *  tunes nothing; Enter does. */
interface Selection {
  chId: string;
  /** The programme's start and end, or a point in time on an empty lane. */
  start: number;
  end: number;
}

/** Everything below the heading, for a known channel list. `root` already
 *  holds `heading` and nothing else. */
function paintLiveTv(root: HTMLElement, heading: HTMLElement, src: GuideSource, channels: any[]): void {
  const watch = (ch: any): void => tune(src, ch);
  const subtitle = heading.querySelector<HTMLElement>(".guide-sub");
  if (subtitle) subtitle.textContent = "";
  if (!channels.length) {
    root.append(
      emptyState({
        icon: "tv",
        title: "No Live TV channels",
        body: src.emptyBody,
        action: { label: "Reload", run: () => void renderLiveTv(root) },
      })
    );
    return;
  }

  const ids = channels.map((c) => c.Id);

  const range = el("span", { class: "guide-range" }, [""]);
  const earlier = el("button", {
    class: "btn small icon",
    title: "Earlier — three hours back (Ctrl+←)",
    "aria-label": "Earlier",
  }, [icon("chevron-left")]);
  const later = el("button", {
    class: "btn small icon",
    title: "Later — three hours on (Ctrl+→)",
    "aria-label": "Later",
  }, [icon("chevron-right")]);
  const nowBtn = el("button", { class: "btn small", title: "Back to what's on now (Ctrl+T)" }, ["Now"]);
  const jumpInput = el("input", {
    class: "control guide-jump",
    type: "datetime-local",
    title: "Jump to a day and time",
    "aria-label": "Jump to a day and time",
    step: String(SLOT_MIN * 60),
  }) as HTMLInputElement;
  const moreBtn = el("button", {
    class: "btn small guide-more",
    title: "Load the next six hours of the schedule",
  }, ["More hours", icon("chevron-right", 14)]);
  const filterInput = el("input", {
    class: "control guide-filter",
    type: "search",
    placeholder: "Filter channels",
    "aria-label": "Filter channels",
    spellcheck: "false",
  }) as HTMLInputElement;

  // A fetch that failed with a grid already on screen says so here and leaves
  // the grid alone.
  const banner = el("div", { class: "guide-banner", role: "alert", hidden: "" });
  const head = el("div", { class: "guide-head" });
  const rows = el("div", { class: "guide-rows" });
  const nowLine = el("div", { class: "guide-now" });
  const body = el("div", { class: "guide-body" }, [head, rows, nowLine]);
  // The grid is one stop on the Tab key, not a few thousand: the arrows are
  // what move between programmes inside it. `data-own-arrows` keeps
  // spatial.ts out of the way.
  const scroll = el("div", {
    class: "guide-scroll",
    tabindex: "0",
    role: "grid",
    "aria-label": "TV guide. Arrows move, Enter watches, Space shows details.",
    "data-own-arrows": "",
  }, [body]);
  const guide = el("div", { class: "guide" }, [
    el("div", { class: "guide-toolbar" }, [
      earlier, nowBtn, later, range, jumpInput,
      el("span", { class: "guide-toolbar-gap" }),
      filterInput, moreBtn,
    ]),
    banner,
    scroll,
  ]);

  // Everything drawn against the window: the slot ticks, the lane geometry and
  // the "now" line all read these.
  let windowStart = floorToSlot(Date.now());
  let windowMin = WINDOW_MIN;
  const earliest = (): number => floorToSlot(Date.now()) - MAX_BACK_MIN * 60_000;
  const windowEnd = (): number => windowStart + windowMin * 60_000;

  const offsetPx = (ms: number): number => ((ms - windowStart) / 60_000) * PX_PER_MIN;
  const laneWidth = (): number => windowMin * PX_PER_MIN;

  let programs: any[] = [];
  /** The pending details dialog of a single click on a programme. */
  let infoTimer = 0;
  let filter = "";
  let sel: Selection | null = null;
  /** The drawn rows, by channel, for the keyboard to walk. */
  let drawn: { ch: any; cell: HTMLElement; lane: HTMLElement; blocks: { p: any; el: HTMLElement; s: number; e: number }[] }[] = [];

  /** What is airing on a channel this minute: from the window on screen when
   *  it covers now, else from the line-up's own near schedule. */
  const airing = (ch: any): any | null => {
    const t = Date.now();
    for (const p of programs) {
      if (p.ChannelId === ch.Id && Date.parse(p.StartDate) <= t && Date.parse(p.EndDate) > t) return p;
    }
    return nowNextSync(ch).now;
  };

  const visibleChannels = (): any[] => {
    const q = filter.trim().toLowerCase();
    if (!q) return channels;
    // Programmes on now, by channel, in one pass rather than one per channel.
    const t = Date.now();
    const onNowName = new Map<string, string>();
    for (const p of programs) {
      if (Date.parse(p.StartDate) <= t && Date.parse(p.EndDate) > t) onNowName.set(p.ChannelId, p.Name ?? "");
    }
    return channels.filter((c) => {
      const now = onNowName.get(c.Id) ?? nowNextSync(c).now?.Name ?? "";
      return `${c.ChannelNumber ?? ""} ${c.Name ?? ""} ${c.Group ?? ""} ${now}`.toLowerCase().includes(q);
    });
  };

  /** "Today · 124 channels", or "Today · 12 of 124 channels" while the filter
   *  narrows them; a playlist of the user's own says so. */
  function renderSubtitle(shown: number): void {
    if (!subtitle) return;
    const count = shown === channels.length
      ? `${channels.length} channel${channels.length === 1 ? "" : "s"}`
      : `${shown} of ${channels.length} channels`;
    subtitle.textContent = [dayLabel(new Date(windowStart)), count, src.custom ? "Custom playlist" : null]
      .filter(Boolean)
      .join(" · ");
  }

  function renderHead(): void {
    clear(head);
    const corner = el("div", { class: "guide-corner" }, ["Channel"]);
    const times = el("div", { class: "guide-times" });
    for (let m = 0; m < windowMin; m += SLOT_MIN) {
      const t = new Date(windowStart + m * 60_000);
      // A window that runs past midnight says so where it does.
      const midnight = t.getHours() === 0 && t.getMinutes() === 0;
      const tick = el("div", { class: `guide-tick${midnight ? " day" : ""}` }, [
        midnight ? `${dayLabel(t)} ${fmtTime(t)}` : fmtTime(t),
      ]);
      tick.style.left = `${m * PX_PER_MIN}px`;
      tick.style.width = `${SLOT_MIN * PX_PER_MIN}px`;
      times.append(tick);
    }
    head.append(corner, times);
    const start = new Date(windowStart);
    const end = new Date(windowEnd());
    const endDay = startOfDay(end.getTime() - 1) !== startOfDay(windowStart) ? `${dayLabel(end)} ` : "";
    range.textContent = `${dayLabel(start)} · ${fmtTime(start)} – ${endDay}${fmtTime(end)}`;
    earlier.toggleAttribute("disabled", windowStart <= earliest());
    nowBtn.toggleAttribute("disabled", windowStart === floorToSlot(Date.now()) && windowMin === WINDOW_MIN);
    moreBtn.toggleAttribute("disabled", windowMin >= MAX_WINDOW_MIN);
    moreBtn.title = windowMin >= MAX_WINDOW_MIN
      ? "The guide holds a day at most"
      : "Load the next six hours of the schedule";
    jumpInput.min = localInputValue(earliest());
    jumpInput.max = localInputValue(Date.now() + MAX_AHEAD_DAYS * 86_400_000);
    if (document.activeElement !== jumpInput) jumpInput.value = localInputValue(windowStart);
    body.style.setProperty("--lane-w", `${laneWidth()}px`);
    renderSubtitle(filter.trim() ? drawn.length : channels.length);
  }

  /** Position the red "you are here" line, and hide it when the window being
   *  looked at isn't the one happening. */
  function syncNow(): void {
    const x = offsetPx(Date.now());
    const inside = x >= 0 && x <= laneWidth();
    nowLine.style.display = inside ? "" : "none";
    if (inside) nowLine.style.left = `${x}px`;
    for (const b of Array.from(rows.querySelectorAll<HTMLElement>(".guide-prog"))) {
      const s = Number(b.dataset.start), e = Number(b.dataset.end);
      b.classList.toggle("on-now", Date.now() >= s && Date.now() < e);
    }
  }

  function renderRows(): void {
    clear(rows);
    drawn = [];
    const byChannel = new Map<string, any[]>();
    for (const p of programs) {
      const list = byChannel.get(p.ChannelId);
      if (list) list.push(p);
      else byChannel.set(p.ChannelId, [p]);
    }

    const end = windowEnd();
    const shown = visibleChannels();
    renderSubtitle(shown.length);
    if (!shown.length) {
      rows.append(el("p", { class: "guide-empty" }, [`No channels match “${filter.trim()}”.`]));
    }
    for (const ch of shown) {
      const lane = el("div", { class: "guide-lane" });
      const blocks: { p: any; el: HTMLElement; s: number; e: number }[] = [];
      const progs = (byChannel.get(ch.Id) ?? []).sort(
        (a, b) => Date.parse(a.StartDate) - Date.parse(b.StartDate)
      );
      if (!progs.length) {
        lane.append(el("div", { class: "guide-gap" }, ["No guide data"]));
      }
      for (const p of progs) {
        const s = Date.parse(p.StartDate);
        const e = Date.parse(p.EndDate);
        if (!(e > s)) continue;
        const left = offsetPx(Math.max(s, windowStart));
        const right = offsetPx(Math.min(e, end));
        const block = el("button", {
          class: "guide-prog",
          tabindex: "-1",
          title: `${p.Name ?? ""} · ${fmtTime(new Date(s))} – ${fmtTime(new Date(e))}`,
          // A click selects and, unless a second one follows, opens the
          // details; a double-click tunes. The details are a modal, so they
          // can't open on the first click and still leave a second to land.
          onClick: (ev: MouseEvent) => {
            select({ chId: ch.Id, start: s, end: e }, false);
            clearTimeout(infoTimer);
            // A keyboard "click" (detail 0) has no second half to wait for.
            if (ev.detail === 0) showProgram(p, ch, watch);
            else if (ev.detail === 1) {
              infoTimer = window.setTimeout(() => {
                if (document.contains(block)) showProgram(p, ch, watch);
              }, DOUBLE_CLICK_MS);
            }
          },
          onDblclick: () => {
            clearTimeout(infoTimer);
            watch(ch);
          },
        }, [
          el("span", { class: "guide-prog-title" }, [p.Name ?? "Programme"]),
          el("span", { class: "guide-prog-sub" }, [
            `${fmtTime(new Date(s))}${p.EpisodeTitle ? ` · ${p.EpisodeTitle}` : ""}`,
          ]),
        ]);
        block.dataset.start = String(s);
        block.dataset.end = String(e);
        block.style.left = `${left}px`;
        block.style.width = `${Math.max(2, right - left)}px`;
        attachContextMenu(block, p.Name ?? null, () => {
          select({ chId: ch.Id, start: s, end: e }, false);
          return cellMenu(p.Name ?? "Programme", () => watch(ch), () => showProgram(p, ch, watch));
        });
        lane.append(block);
        blocks.push({ p, el: block, s, e });
      }
      const cell = channelCell(ch, () => watch(ch));
      cell.tabIndex = -1;
      attachContextMenu(cell, channelLabel(ch), () =>
        cellMenu(ch.Name ?? "Channel", () => watch(ch), () => showProgram(airing(ch), ch, watch))
      );
      rows.append(el("div", { class: "guide-row" }, [cell, lane]));
      drawn.push({ ch, cell, lane, blocks });
    }
    syncNow();
    paintSelection(false);
  }

  // ---------- Keyboard selection ----------

  /** The programme on `row` covering `t`, else the nearest one to it. */
  function blockAt(row: (typeof drawn)[number], t: number): (typeof row.blocks)[number] | null {
    let best: (typeof row.blocks)[number] | null = null;
    let bestDist = Infinity;
    for (const b of row.blocks) {
      if (b.s <= t && b.e > t) return b;
      const d = Math.min(Math.abs(b.s - t), Math.abs(b.e - t));
      if (d < bestDist) {
        bestDist = d;
        best = b;
      }
    }
    return best;
  }

  /** Select the programme on a row at a time, or the lane itself if empty. */
  function selectAt(rowIndex: number, t: number, reveal = true): void {
    const row = drawn[rowIndex];
    if (!row) return;
    const b = blockAt(row, t);
    select(b ? { chId: row.ch.Id, start: b.s, end: b.e } : { chId: row.ch.Id, start: t, end: t }, reveal);
  }

  function select(next: Selection | null, reveal = true): void {
    sel = next;
    paintSelection(reveal);
  }

  function paintSelection(reveal: boolean): void {
    for (const x of Array.from(rows.querySelectorAll(".selected"))) x.classList.remove("selected");
    if (!sel) return;
    const row = drawn.find((r) => r.ch.Id === sel!.chId);
    if (!row) return;
    row.cell.classList.add("selected");
    const b = row.blocks.find((x) => x.s === sel!.start && x.e === sel!.end);
    const target = b?.el ?? row.lane;
    target.classList.add("selected");
    if (b) {
      scroll.setAttribute("aria-label",
        `${channelLabel(row.ch)}: ${b.p.Name ?? "Programme"}, ${fmtTime(new Date(b.s))} to ${fmtTime(new Date(b.e))}`);
    }
    if (reveal) target.scrollIntoView({ block: "nearest", inline: "nearest" });
  }

  const rowIndex = (): number => (sel ? drawn.findIndex((r) => r.ch.Id === sel!.chId) : -1);
  /** The time a vertical move keeps to: the selected programme's start,
   *  or now when that was before the window. */
  const anchor = (): number => {
    if (!sel) return Math.max(windowStart, Math.min(Date.now(), windowEnd() - 1));
    return Math.max(windowStart, sel.start);
  };

  /** After the window moves, land the selection back on a programme. */
  let pendingSelect: { row: number; t: number } | null = null;

  function moveSel(dRow: number, dCol: number): void {
    if (!drawn.length) return;
    let i = rowIndex();
    if (i < 0) {
      selectAt(0, anchor());
      return;
    }
    if (dRow) {
      selectAt(Math.max(0, Math.min(drawn.length - 1, i + dRow)), anchor());
      return;
    }
    const row = drawn[i]!;
    const at = row.blocks.findIndex((b) => b.s === sel!.start && b.e === sel!.end);
    const nb = at >= 0 ? row.blocks[at + dCol] : undefined;
    // The next programme along, when it starts (or ends) inside the window.
    if (nb && (dCol > 0 ? nb.s < windowEnd() : nb.e > windowStart)) {
      select({ chId: row.ch.Id, start: nb.s, end: nb.e });
      return;
    }
    // Off the edge: move the window and pick up from where the selection was.
    const t = dCol > 0 ? Math.max(sel!.end, windowEnd()) : Math.min(sel!.start, windowStart) - 1;
    if (dCol < 0 && windowStart <= earliest()) return;
    pendingSelect = { row: i, t };
    shift(dCol * SHIFT_MIN);
  }

  function selectedChannel(): any | null {
    return sel ? drawn.find((r) => r.ch.Id === sel!.chId)?.ch ?? null : null;
  }

  /** Letters typed on the grid: jump to the channel whose name starts with
   *  them. The prefix resets after a second's pause. */
  let typed = "";
  let typedAt = 0;
  function typeSelect(ch: string): void {
    typed = Date.now() - typedAt > 1000 ? ch : typed + ch;
    typedAt = Date.now();
    const q = typed.toLowerCase();
    const i = drawn.findIndex((r) =>
      String(r.ch.Name ?? "").toLowerCase().startsWith(q) || String(r.ch.ChannelNumber ?? "") === q
    );
    if (i >= 0) selectAt(i, anchor());
  }

  scroll.addEventListener("keydown", (ev: KeyboardEvent) => {
    if (ev.altKey || ev.metaKey) return;
    if (ev.ctrlKey) return; // Ctrl+arrows and Ctrl+T are the page's, below.
    if (document.body.classList.contains("video-covered")) return;
    let handled = true;
    switch (ev.key) {
      case "ArrowUp": moveSel(-1, 0); break;
      case "ArrowDown": moveSel(1, 0); break;
      case "ArrowLeft": moveSel(0, -1); break;
      case "ArrowRight": moveSel(0, 1); break;
      case "Home": selectAt(0, anchor()); break;
      case "End": selectAt(drawn.length - 1, anchor()); break;
      case "PageUp": moveSel(-8, 0); break;
      case "PageDown": moveSel(8, 0); break;
      case "Enter": {
        const ch = selectedChannel();
        if (ch) watch(ch);
        else handled = false;
        break;
      }
      case " ": {
        const row = sel ? drawn.find((r) => r.ch.Id === sel!.chId) : null;
        const b = row?.blocks.find((x) => x.s === sel!.start && x.e === sel!.end);
        if (row && b) showProgram(b.p, row.ch, watch);
        else handled = false;
        break;
      }
      case "Escape":
        if (sel) select(null);
        else handled = false;
        break;
      default:
        if (ev.key.length === 1 && /[\p{L}\p{N}]/u.test(ev.key)) typeSelect(ev.key);
        else handled = false;
    }
    if (handled) {
      ev.preventDefault();
      ev.stopPropagation();
    }
  });
  // Focus arriving by Tab lands on what's on now on the first row; arriving
  // by a click on a programme, that programme (its click handler selects it).
  scroll.addEventListener("focus", () => {
    if (!sel) queueMicrotask(() => { if (!sel && document.activeElement === scroll) selectAt(0, anchor()); });
  });
  // A click on a programme or channel focuses the button under it; hand the
  // keyboard back to the grid so the arrows keep walking it.
  rows.addEventListener("click", () => scroll.focus({ preventScroll: true }));

  // ---------- Loading ----------

  let loading = false;
  let again = false;
  /** The window the grid on screen was drawn for; null until a fetch lands. */
  let loaded: { start: number; min: number } | null = null;

  function hideBanner(): void {
    banner.hidden = true;
    clear(banner);
  }

  async function load(): Promise<void> {
    if (loading) {
      again = true;
      return;
    }
    loading = true;
    guide.classList.add("busy");
    renderHead();
    const floorNow = floorToSlot(Date.now());
    try {
      const fetched = await src.programs(ids, new Date(windowStart), new Date(windowEnd()));
      if (!document.contains(guide)) return;
      programs = fetched;
      loaded = { start: windowStart, min: windowMin };
      hideBanner();
      // Nothing scheduled anywhere means no guide source, not an empty evening.
      if (!programs.length && windowStart === floorNow && windowMin === WINDOW_MIN) {
        clear(root);
        if (subtitle) subtitle.textContent = `${channels.length} channel${channels.length === 1 ? "" : "s"}`;
        root.append(
          heading,
          el("p", { class: "guide-note" }, [src.noGuide]),
          channelList(channels, watch)
        );
        return;
      }
      renderRows();
      if (pendingSelect) {
        const p = pendingSelect;
        pendingSelect = null;
        selectAt(Math.min(p.row, drawn.length - 1), p.t);
      }
    } catch (e: any) {
      if (!document.contains(guide)) return;
      pendingSelect = null;
      const why = e?.message ?? String(e);
      if (loaded) {
        // The grid on screen is still a working guide. Put the ruler back on
        // the window it was drawn for, and offer the one that failed again.
        const wanted = { start: windowStart, min: windowMin };
        windowStart = loaded.start;
        windowMin = loaded.min;
        renderHead();
        clear(banner);
        banner.append(
          el("span", {}, [`Couldn't load the guide: ${why}`]),
          el("button", {
            class: "btn small",
            onClick: () => {
              hideBanner();
              windowStart = Math.max(earliest(), wanted.start);
              windowMin = wanted.min;
              void load();
            },
          }, ["Retry"])
        );
        banner.hidden = false;
      } else {
        clear(rows);
        rows.append(
          emptyState({
            icon: "error",
            error: true,
            title: "Couldn't load the guide",
            body: why,
            action: { label: "Try again", run: () => void load() },
          })
        );
      }
    } finally {
      loading = false;
      guide.classList.remove("busy");
      if (again) {
        again = false;
        void load();
      }
    }
  }

  /** Put the window's start at a time, rounded down to the half hour so the
   *  ruler's marks stay on real boundaries. Moving resets More hours. */
  function jumpTo(ms: number): void {
    const start = Math.max(earliest(), floorToSlot(ms));
    if (start === windowStart && windowMin === WINDOW_MIN) return;
    windowStart = start;
    windowMin = WINDOW_MIN;
    scroll.scrollLeft = 0;
    // The selection keeps its row and comes along to the new window — to
    // now when that's in it, else its start — unless an arrow press off the
    // edge already said where it lands.
    if (sel && !pendingSelect && rowIndex() >= 0) {
      const now = Date.now();
      const inWindow = now >= windowStart && now < windowEnd();
      pendingSelect = { row: rowIndex(), t: inWindow ? now : windowStart };
    }
    void load();
  }
  const shift = (minutes: number): void => jumpTo(windowStart + minutes * 60_000);
  const toNow = (): void => {
    if (windowStart === floorToSlot(Date.now()) && windowMin === WINDOW_MIN) {
      scroll.scrollTo({ left: 0, behavior: "smooth" });
      return;
    }
    jumpTo(Date.now());
  };

  earlier.addEventListener("click", () => shift(-SHIFT_MIN));
  later.addEventListener("click", () => shift(SHIFT_MIN));
  nowBtn.addEventListener("click", toNow);
  moreBtn.addEventListener("click", () => {
    if (windowMin >= MAX_WINDOW_MIN) return;
    windowMin = Math.min(MAX_WINDOW_MIN, windowMin + WINDOW_MIN);
    void load();
  });
  jumpInput.addEventListener("change", () => {
    const ms = new Date(jumpInput.value).getTime();
    if (Number.isFinite(ms)) jumpTo(ms);
  });
  filterInput.addEventListener("input", () => {
    filter = filterInput.value;
    renderRows();
  });
  filterInput.addEventListener("keydown", (ev: KeyboardEvent) => {
    // Down from the field goes into what it left.
    if (ev.key === "ArrowDown" || ev.key === "Enter") {
      ev.preventDefault();
      scroll.focus();
      if (!sel && drawn.length) selectAt(0, anchor());
    } else if (ev.key === "Escape" && filterInput.value) {
      ev.preventDefault();
      filterInput.value = "";
      filter = "";
      renderRows();
    }
  });

  // Ctrl+←/→ and Ctrl+T move the window from anywhere on the page, as the
  // toolbar buttons' tooltips say. Not from a text field, where Ctrl+arrows
  // are word jumps.
  const onKey = (ev: KeyboardEvent): void => {
    if (!document.contains(guide)) {
      document.removeEventListener("keydown", onKey);
      return;
    }
    if (!ev.ctrlKey || ev.altKey || ev.metaKey || ev.shiftKey) return;
    // The guide is behind the picture; the keys are the player's.
    if (document.body.classList.contains("video-covered")) return;
    const t = ev.target as HTMLElement | null;
    const inText = !!t && ["INPUT", "TEXTAREA", "SELECT"].includes(t.tagName);
    if (ev.key === "ArrowLeft" && !inText) shift(-SHIFT_MIN);
    else if (ev.key === "ArrowRight" && !inText) shift(SHIFT_MIN);
    else if (ev.key === "t" || ev.key === "T") toNow();
    else return;
    ev.preventDefault();
  };
  document.addEventListener("keydown", onKey);

  // Away from the window (another app, a minimised or hidden window) for half
  // an hour: come back at now. A shorter absence returns where it was left.
  // Leaving the page itself needs nothing — a route change builds the guide
  // afresh, at now.
  let leftAt = 0;
  const onAway = (): void => {
    if (!leftAt) leftAt = Date.now();
  };
  const onBack = (): void => {
    if (document.hidden || !leftAt) return;
    const away = Date.now() - leftAt;
    leftAt = 0;
    if (away >= RESET_AFTER_MS && document.contains(guide)) jumpTo(Date.now());
  };
  const onVisibility = (): void => (document.hidden ? onAway() : onBack());
  window.addEventListener("blur", onAway);
  window.addEventListener("focus", onBack);
  document.addEventListener("visibilitychange", onVisibility);

  renderHead();
  renderSubtitle(channels.length);
  root.append(guide);
  void load();

  // The line only has to move once a minute, and it stops with the page: the
  // guide is replaced wholesale on every route change.
  const tick = window.setInterval(() => {
    if (!document.contains(guide)) {
      clearInterval(tick);
      window.removeEventListener("blur", onAway);
      window.removeEventListener("focus", onBack);
      document.removeEventListener("visibilitychange", onVisibility);
      return;
    }
    syncNow();
  }, 30_000);
}

/** Start a channel from elsewhere (Home's On Now row) with the same tuning
 *  screen the guide shows, from whichever source Live TV is set to. */
export function tuneChannel(ch: any): void {
  tune(iptv.isCustom() ? customSource : jellyfinSource, ch);
}

/**
 * What's on right now, channel by channel, for Home's On Now row: each
 * channel with a programme airing, in channel order, up to `limit`. Empty
 * when there is no Live TV at all.
 */
export async function onNow(limit = 16): Promise<{ channel: any; program: any }[]> {
  const rows = await lineupOnNow(limit);
  return rows.map((r) => ({ channel: r.channel, program: r.now }));
}

/** One On Now card: the programme over its channel, with how far in it is. */
export function onNowCard(channel: any, program: any): HTMLElement {
  const start = Date.parse(program.StartDate ?? "");
  const end = Date.parse(program.EndDate ?? "");
  const now = Date.now();
  const pct = isFinite(start) && isFinite(end) && end > start ? Math.max(0, Math.min(100, ((now - start) / (end - start)) * 100)) : 0;
  const until = isFinite(end) ? new Date(end).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }) : "";
  const img =
    (program.Id && program.ImageTags?.Primary ? api.imageUrl(program, "Primary", 500) : null) ??
    channel.LogoUrl ??
    api.imageUrl(channel, "Primary", 320);
  const title = program.Name ?? channelLabel(channel);
  return el("div", {
    class: "card wide onnow-card",
    role: "button",
    tabindex: "0",
    title: `${channelLabel(channel)} — ${title}`,
    onClick: () => tuneChannel(channel),
    onKeydown: (ev: KeyboardEvent) => {
      if (ev.key === "Enter" || ev.key === " ") {
        ev.preventDefault();
        tuneChannel(channel);
      }
    },
  }, [
    el("div", { class: "card-poster onnow-poster" }, [
      art(img, () => document.createTextNode(String(channel.ChannelNumber ?? channel.Name ?? "?").slice(0, 4))),
      el("div", { class: "card-scrim" }),
      el("div", { class: "time-left onnow-live" }, [el("span", { class: "live-dot" }), "Live"]),
      el("div", { class: "progress-strip" }, [el("div", { style: `width:${pct}%` })]),
    ]),
    el("div", { class: "card-title" }, [title]),
    el("div", { class: "card-sub" }, [`${channelLabel(channel)}${until ? ` · until ${until}` : ""}`]),
  ]);
}
