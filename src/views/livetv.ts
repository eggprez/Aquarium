import * as api from "../api";
import * as iptv from "../iptv";
import { playItem, playChannelUrl } from "../playback";
import { el, clear, art, emptyState, icon, openDialog, skeletonRows } from "../ui";
import { getCached, setCached } from "../cache";

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
  play(ch: any): void;
  /** What to say when there are no channels at all. */
  emptyBody: string;
  /** What to say when there are channels but nothing scheduled. */
  noGuide: string;
}

const jellyfinSource: GuideSource = {
  custom: false,
  channels: () => api.getChannels(),
  programs: (ids, from, to) => api.getPrograms(ids, from, to),
  play: (ch) => void playItem(ch, { live: true }),
  emptyBody:
    "This server has a Live TV library but no channels in it. Add a tuner and a guide source in the Jellyfin dashboard, then reload.",
  noGuide:
    "This server has no guide data, so there's nothing to lay out over time. Add a guide source in the Jellyfin dashboard to get a TV Guide.",
};

const customSource: GuideSource = {
  custom: true,
  channels: () => iptv.getChannels(),
  programs: (_ids, from, to) => iptv.getPrograms(from, to),
  play: (ch) => void playChannelUrl(ch),
  emptyBody:
    "Your M3U playlist loaded but has no channels in it. Check the address in Settings → Live TV.",
  noGuide:
    "No XMLTV guide is set, or none of its channels matched this playlist. The guide joins on each channel's tvg-id, falling back to its name. Set one in Settings → Live TV.",
};

/** Horizontal scale of the guide. 30 minutes is the slot every schedule is
 *  built on, and 150px is the narrowest it can be and still fit a programme
 *  title worth reading. */
const PX_PER_MIN = 5;
const SLOT_MIN = 30;
/** How much of the schedule one window holds, and how far the arrows move it. */
const WINDOW_MIN = 6 * 60;
const SHIFT_MIN = 2 * 60;
/** The guide can be walked backwards, but only as far as a server typically
 *  keeps aired entries for — past that every lane comes back empty. */
const MAX_BACK_MIN = 12 * 60;

const fmtTime = (d: Date): string =>
  d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });

const fmtDay = (d: Date): string =>
  d.toLocaleDateString([], { weekday: "short", day: "numeric", month: "short" });

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

/** Everything the grid can't show: the synopsis, the flags, and the way in. */
function showProgram(prog: any, ch: any, play: (ch: any) => void): void {
  const start = new Date(prog.StartDate);
  const end = new Date(prog.EndDate);
  const badges: string[] = [];
  if (prog.IsLive) badges.push("Live");
  if (prog.IsNew) badges.push("New");
  if (prog.IsRepeat) badges.push("Repeat");
  if (prog.OfficialRating) badges.push(prog.OfficialRating);

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
    ].filter(Boolean) as (string | Node)[],
    actions: [
      { label: "Close" },
      { label: `Watch ${ch.Name ?? "channel"}`, primary: true, run: () => play(ch) },
    ],
  });
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
  const heading = el("h1", { class: "page-title" }, ["Live TV"]);
  root.append(heading);

  // The channel line-up barely changes, so the last known one draws the guide
  // straight away — the schedule inside it is fetched fresh regardless — and
  // the page is only rebuilt if the line-up itself came back different. With
  // nothing cached (a first visit on this account, or a source just switched
  // over in Settings) the skeleton stands in.
  const cacheKey = `livetv:${src.custom ? "custom" : "jellyfin"}`;
  const cached = getCached<any[]>(cacheKey);
  if (cached?.length) {
    paintLiveTv(root, heading, src, cached);
  } else {
    root.append(skeletonRows(8, "channel-row", "channel-logo"));
  }

  // A custom source fails in ways worth reading — a wrong address, a host that
  // won't answer — where Jellyfin's own failure is almost always "no tuner".
  let loadError: string | null = null;
  const channels = await src.channels().catch((e: any) => {
    loadError = e?.message ?? String(e);
    return [] as any[];
  });
  if (!document.contains(heading)) return; // navigated away while loading

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

  setCached(cacheKey, channels);
  if (cached?.length && channelSignature(cached) === channelSignature(channels)) return;
  clear(root);
  root.append(heading);
  paintLiveTv(root, heading, src, channels);
}

/** Everything below the heading, for a known channel list. `root` already
 *  holds `heading` and nothing else. */
function paintLiveTv(root: HTMLElement, heading: HTMLElement, src: GuideSource, channels: any[]): void {
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
    title: "Earlier",
    "aria-label": "Earlier",
  }, [icon("chevron-left")]);
  const later = el("button", {
    class: "btn small icon",
    title: "Later",
    "aria-label": "Later",
  }, [icon("chevron-right")]);
  const nowBtn = el("button", { class: "btn small" }, ["Now"]);

  const head = el("div", { class: "guide-head" });
  const rows = el("div", { class: "guide-rows" });
  const nowLine = el("div", { class: "guide-now" });
  const body = el("div", { class: "guide-body" }, [head, rows, nowLine]);
  const scroll = el("div", { class: "guide-scroll" }, [body]);
  const guide = el("div", { class: "guide" }, [
    el("div", { class: "guide-toolbar" }, [earlier, nowBtn, later, range]),
    scroll,
  ]);

  // Everything drawn against the window: the slot ticks, the lane geometry and
  // the "now" line all read this one number.
  let windowStart = floorToSlot(Date.now());
  const floorNow = floorToSlot(Date.now());

  const offsetPx = (ms: number): number => ((ms - windowStart) / 60_000) * PX_PER_MIN;
  const laneWidth = WINDOW_MIN * PX_PER_MIN;

  function renderHead(): void {
    clear(head);
    const corner = el("div", { class: "guide-corner" }, ["Channel"]);
    const times = el("div", { class: "guide-times" });
    for (let m = 0; m < WINDOW_MIN; m += SLOT_MIN) {
      const t = new Date(windowStart + m * 60_000);
      const tick = el("div", { class: "guide-tick" }, [fmtTime(t)]);
      tick.style.left = `${m * PX_PER_MIN}px`;
      tick.style.width = `${SLOT_MIN * PX_PER_MIN}px`;
      times.append(tick);
    }
    head.append(corner, times);
    const end = new Date(windowStart + WINDOW_MIN * 60_000);
    range.textContent = `${fmtDay(new Date(windowStart))} · ${fmtTime(new Date(windowStart))} – ${fmtTime(end)}`;
    earlier.toggleAttribute("disabled", windowStart <= floorNow - MAX_BACK_MIN * 60_000);
  }

  /** Position the red "you are here" line, and hide it when the window being
   *  looked at isn't the one happening. */
  function syncNow(): void {
    const x = offsetPx(Date.now());
    const inside = x >= 0 && x <= laneWidth;
    nowLine.style.display = inside ? "" : "none";
    if (inside) nowLine.style.left = `${x}px`;
    for (const b of Array.from(rows.querySelectorAll<HTMLElement>(".guide-prog"))) {
      const s = Number(b.dataset.start), e = Number(b.dataset.end);
      b.classList.toggle("on-now", Date.now() >= s && Date.now() < e);
    }
  }

  function renderRows(programs: any[]): void {
    clear(rows);
    const byChannel = new Map<string, any[]>();
    for (const p of programs) {
      const list = byChannel.get(p.ChannelId);
      if (list) list.push(p);
      else byChannel.set(p.ChannelId, [p]);
    }

    const windowEnd = windowStart + WINDOW_MIN * 60_000;
    for (const ch of channels) {
      const lane = el("div", { class: "guide-lane" });
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
        const right = offsetPx(Math.min(e, windowEnd));
        const block = el("button", {
          class: "guide-prog",
          title: `${p.Name ?? ""} · ${fmtTime(new Date(s))} – ${fmtTime(new Date(e))}`,
          onClick: () => showProgram(p, ch, src.play),
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
        lane.append(block);
      }
      rows.append(
        el("div", { class: "guide-row" }, [
          channelCell(ch, () => src.play(ch)),
          lane,
        ])
      );
    }
    syncNow();
  }

  let loading = false;
  async function load(): Promise<void> {
    if (loading) return;
    loading = true;
    guide.classList.add("busy");
    renderHead();
    try {
      const programs = await src.programs(
        ids,
        new Date(windowStart),
        new Date(windowStart + WINDOW_MIN * 60_000)
      );
      if (!document.contains(guide)) return;
      // Nothing scheduled anywhere means no guide source, not an empty evening.
      if (!programs.length && windowStart === floorNow) {
        clear(root);
        root.append(
          heading,
          el("p", { class: "guide-note" }, [src.noGuide]),
          channelList(channels, src.play)
        );
        return;
      }
      renderRows(programs);
    } catch (e: any) {
      clear(rows);
      rows.append(
        emptyState({
          icon: "error",
          error: true,
          title: "Couldn't load the guide",
          body: e?.message ?? String(e),
          action: { label: "Try again", run: () => void load() },
        })
      );
    } finally {
      loading = false;
      guide.classList.remove("busy");
    }
  }

  const shift = (minutes: number): void => {
    windowStart = Math.max(floorNow - MAX_BACK_MIN * 60_000, windowStart + minutes * 60_000);
    void load();
  };
  earlier.addEventListener("click", () => shift(-SHIFT_MIN));
  later.addEventListener("click", () => shift(SHIFT_MIN));
  nowBtn.addEventListener("click", () => {
    if (windowStart === floorToSlot(Date.now())) {
      scroll.scrollTo({ left: 0, behavior: "smooth" });
      return;
    }
    windowStart = floorToSlot(Date.now());
    void load();
  });

  body.style.setProperty("--lane-w", `${laneWidth}px`);
  root.append(guide);
  void load();

  // The line only has to move once a minute, and it stops with the page: the
  // guide is replaced wholesale on every route change.
  const tick = window.setInterval(() => {
    if (!document.contains(guide)) {
      clearInterval(tick);
      return;
    }
    syncNow();
  }, 30_000);
}
