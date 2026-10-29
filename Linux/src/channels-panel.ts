/**
 * Live TV inside the player: the Channels panel in the player bar, the
 * programme lines under the channel's name, and channel up/down.
 *
 * Kept out of main.ts so the bar itself only has to call in: the panel fills a
 * `.pb-panel` it is handed, and the title lines are a pure function of what's
 * playing and the schedule lineup.ts already holds.
 */
import * as api from "./api";
import { art, el, icon } from "./ui";
import { getNowPlaying } from "./playback";
import {
  cachedLineup,
  fmtClock,
  isChannel,
  loadLineup,
  nearSchedule,
  nowNextSync,
  playChannel,
  progressOf,
} from "./lineup";

const channelLabel = (ch: any): string =>
  `${ch.ChannelNumber ? ch.ChannelNumber + " · " : ""}${ch.Name ?? "Channel"}`;

function logo(ch: any, width: number): HTMLElement {
  return el("div", { class: "pb-ch-logo" }, [
    art(ch.LogoUrl ?? api.imageUrl(ch, "Primary", width), () =>
      document.createTextNode(String(ch.ChannelNumber ?? ch.Name ?? "?").slice(0, 4)),
      { lazy: false }
    ),
  ]);
}

/** A channel asked for from inside the player that hasn't started yet, and
 *  the last one that failed — both said in the title, since the picture
 *  covers everything a toast could be drawn on. */
let switching: { ch: any; started: number } | null = null;
let failed: { ch: any; msg: string; at: number } | null = null;
const FAILED_SHOWN_MS = 10_000;

/**
 * The player bar's two title lines while a channel plays: the channel, then
 * what's on and what's coming up. `null` when what's playing isn't a channel.
 */
export function liveTitleLines(item: any): { line1: string; line2: string; tip: string } | null {
  if (switching) {
    const s = Math.round((Date.now() - switching.started) / 1000);
    const line1 = channelLabel(switching.ch);
    return { line1, line2: s >= 2 ? `Tuning… ${s} s` : "Tuning…", tip: line1 };
  }
  if (failed && Date.now() - failed.at < FAILED_SHOWN_MS) {
    return {
      line1: channelLabel(failed.ch),
      line2: `Couldn't tune: ${failed.msg}`,
      tip: failed.msg,
    };
  }
  if (!isChannel(item)) return null;
  const line1 = channelLabel(item);
  const { now, next } = nowNextSync(item);
  const parts: string[] = [];
  const tip: string[] = [line1];
  if (now) {
    parts.push(now.Name ?? "On now");
    tip.push(`On now: ${now.Name ?? ""}${now.EpisodeTitle ? ` — ${now.EpisodeTitle}` : ""} (${fmtClock(now.StartDate)} – ${fmtClock(now.EndDate)})`);
  }
  if (next) {
    parts.push(`Coming up ${fmtClock(next.StartDate)} ${next.Name ?? ""}`.trim());
    tip.push(`Coming up: ${next.Name ?? ""} at ${fmtClock(next.StartDate)}`);
  }
  return { line1, line2: parts.join(" · "), tip: tip.join("\n") };
}

/** Change to `ch` without leaving the player. The old channel plays on until
 *  the new one is ready, the way a TV changes channel. */
export function switchChannel(ch: any): void {
  const playing = getNowPlaying()?.item;
  if (playing && playing.Id === ch.Id) return;
  if (switching?.ch.Id === ch.Id) return;
  failed = null;
  const mine = { ch, started: Date.now() };
  switching = mine;
  playChannel(ch, { continuation: true })
    .catch((e: any) => {
      if (switching === mine) failed = { ch, msg: e?.message ?? String(e), at: Date.now() };
    })
    .finally(() => {
      if (switching === mine) switching = null;
    });
}

/** Channel up (+1) or down (−1) from the one playing, wrapping at the ends. */
export function stepChannel(dir: 1 | -1): boolean {
  const item = switching?.ch ?? getNowPlaying()?.item;
  const lineup = cachedLineup();
  if (!isChannel(item) || !lineup?.length) return false;
  const i = lineup.findIndex((c) => c.Id === item.Id);
  const next = lineup[(i + dir + lineup.length) % lineup.length];
  if (next) switchChannel(next);
  return true;
}

/**
 * Fill the Channels panel: the line-up as a strip of tiles — logo, number,
 * name, and what's on with how far through it is — scrolled so the playing
 * channel is in view. `close` shuts the panel.
 */
export function fillChannelsPanel(panel: HTMLElement, close: () => void): void {
  panel.classList.add("pb-queue", "pb-channels");
  const note = el("span", { class: "pb-panel-note" }, ["Loading channels…"]);
  const cached = cachedLineup();
  if (cached?.length) draw(cached);
  else panel.append(note);

  void loadLineup()
    .then(async (channels) => {
      if (!panel.isConnected) return;
      // The schedule first, so the tiles come up with their programmes.
      await nearSchedule().catch(() => {});
      if (!panel.isConnected) return;
      note.remove();
      if (!channels.length) {
        panel.append(el("span", { class: "pb-panel-note" }, ["No channels"]));
        return;
      }
      draw(channels);
    })
    .catch((e) => {
      if (!panel.isConnected) return;
      note.textContent = `Couldn't load channels: ${e?.message ?? e}`;
    });

  function draw(channels: any[]): void {
    panel.querySelector(".pb-queue-strip")?.remove();
    const current = getNowPlaying()?.item?.Id;
    const strip = el("div", { class: "pb-queue-strip", role: "list" });
    let currentTile: HTMLElement | null = null;
    for (const ch of channels) {
      const playing = ch.Id === current;
      const { now } = nowNextSync(ch);
      const bar = el("span", { class: "pb-ch-progress" }, [el("span")]);
      if (now) (bar.firstChild as HTMLElement).style.width = `${Math.round(progressOf(now) * 100)}%`;
      const tile = el("button", {
        class: `pb-queue-tile pb-ch-tile${playing ? " playing" : ""}`,
        role: "listitem",
        title: `${channelLabel(ch)}${now ? `\nOn now: ${now.Name} (until ${fmtClock(now.EndDate)})` : ""}`,
        "aria-current": playing ? "true" : null,
        onClick: () => {
          close();
          switchChannel(ch);
        },
      }, [
        logo(ch, 160),
        el("div", { class: "pb-queue-text" }, [
          el("span", { class: "pb-ch-name" }, [
            ch.ChannelNumber ? el("span", { class: "pb-ch-num" }, [String(ch.ChannelNumber)]) : null,
            ch.Name ?? "Channel",
          ]),
          el("span", { class: `pb-queue-status${playing ? " live" : ""}` }, [
            playing ? "Watching" : now ? now.Name ?? "" : "",
          ]),
          now ? bar : null,
        ]),
      ]);
      if (playing) currentTile = tile;
      strip.append(tile);
    }
    // Before the close button, which toggleBarPanel appends after building.
    const closeBtn = panel.querySelector(".pb-panel-close");
    if (closeBtn) panel.insertBefore(strip, closeBtn);
    else panel.append(strip);
    strip.addEventListener("wheel", (ev: WheelEvent) => {
      if (Math.abs(ev.deltaY) <= Math.abs(ev.deltaX)) return;
      ev.preventDefault();
      strip.scrollLeft += ev.deltaY;
    }, { passive: false });
    if (currentTile) {
      const t = currentTile as HTMLElement;
      strip.style.scrollBehavior = "auto";
      strip.scrollLeft = Math.max(0, t.offsetLeft - strip.offsetLeft - 4);
      strip.style.scrollBehavior = "";
    }
  }
}
