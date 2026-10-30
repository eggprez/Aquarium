/**
 * A Live TV source made of an M3U playlist and an XMLTV guide, standing in for
 * Jellyfin's own Live TV.
 *
 * The channels and programmes handed back here are shaped like the Jellyfin
 * ones the guide already draws (`Id`/`Name`/`ChannelNumber`, `StartDate`/
 * `EndDate`), so the view doesn't need to know which source it is looking at.
 * The one addition is `StreamUrl`, which is what makes a channel playable
 * without a server in the middle.
 */
import { invoke } from "@tauri-apps/api/core";
import * as api from "./api";

export interface IptvChannel {
  Id: string;
  Name: string;
  ChannelNumber: string;
  /** Straight from the playlist — the guide draws it instead of asking Jellyfin. */
  LogoUrl: string | null;
  /** What mpv is pointed at. */
  StreamUrl: string;
  /** The playlist's `group-title`, kept for the channel's tooltip. */
  Group: string;
  /** `tvg-id`, the key the XMLTV guide is joined on. */
  GuideId: string;
  Custom: true;
}

export interface IptvProgram {
  ChannelId: string;
  Name: string;
  Overview: string;
  EpisodeTitle: string;
  StartDate: string;
  EndDate: string;
}

export function isCustom(): boolean {
  return api.getConfig()?.livetv_source === "custom";
}

export function sourceUrls(): { m3u: string; xmltv: string } {
  const cfg = api.getConfig() ?? {};
  return {
    m3u: String(cfg.livetv_m3u ?? "").trim(),
    xmltv: String(cfg.livetv_xmltv ?? "").trim(),
  };
}

/**
 * What an empty User-Agent setting sends: the client string of a widely
 * deployed open-source player, which most stream servers have a rule for.
 * Some vary what they serve (bitrate, container, a redirect target) by the
 * client they see, and a stream that stalls under one string and plays under
 * another is usually this.
 */
export const DEFAULT_USER_AGENT = "VLC/3.0.20 LibVLC/3.0.20";

/** The User-Agent for the playlist, the guide and every stream from them. */
export function iptvUserAgent(): string {
  const v = String(api.getConfig()?.livetv_user_agent ?? "").trim();
  return v || DEFAULT_USER_AGENT;
}

/** Re-read the playlist and guide this often; 0 means only when asked. */
export const DEFAULT_REFRESH_MIN = 180;

export function refreshMinutes(): number {
  const v = api.getConfig()?.livetv_refresh_min;
  const n = v == null || v === "" ? DEFAULT_REFRESH_MIN : Number(v);
  return Number.isFinite(n) && n >= 0 ? n : DEFAULT_REFRESH_MIN;
}

// ---------- M3U ----------

const ATTR_RE = /([\w-]+)="([^"]*)"/g;

function attrs(line: string): Record<string, string> {
  const out: Record<string, string> = {};
  let m: RegExpExecArray | null;
  ATTR_RE.lastIndex = 0;
  while ((m = ATTR_RE.exec(line))) out[m[1]!.toLowerCase()] = m[2]!;
  return out;
}

/**
 * Extended M3U: an `#EXTINF` line carrying attributes and a display name, then
 * the stream URL on the next line that isn't a directive. Other `#` lines
 * (`#EXTVLCOPT`, `#EXTGRP`, comments) sit between the two often enough that
 * skipping them is the whole trick.
 */
export function parseM3u(text: string): IptvChannel[] {
  const out: IptvChannel[] = [];
  const lines = text.split(/\r?\n/);
  let pending: { a: Record<string, string>; name: string } | null = null;
  let group = "";

  for (const raw of lines) {
    const line = raw.trim();
    if (!line) continue;

    if (line.toUpperCase().startsWith("#EXTINF")) {
      const comma = line.indexOf(",");
      pending = {
        a: attrs(line),
        name: comma >= 0 ? line.slice(comma + 1).trim() : "",
      };
      continue;
    }
    if (line.toUpperCase().startsWith("#EXTGRP:")) {
      group = line.slice(8).trim();
      continue;
    }
    if (line.startsWith("#")) continue;

    if (pending) {
      const a = pending.a;
      const name = pending.name || a["tvg-name"] || "Channel";
      out.push({
        Id: `iptv:${out.length}`,
        Name: name,
        ChannelNumber: a["tvg-chno"] ?? String(out.length + 1),
        LogoUrl: a["tvg-logo"] || null,
        StreamUrl: line,
        Group: a["group-title"] ?? group,
        GuideId: a["tvg-id"] ?? "",
        Custom: true,
      });
      pending = null;
    }
  }
  return out;
}

// ---------- XMLTV ----------

/** `20260817183000 +0100`, with the offset and the seconds both optional. */
const XMLTV_TIME = /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})?(?:\s*([+-])(\d{2}):?(\d{2}))?/;

export function xmltvTime(raw: string): number {
  const m = XMLTV_TIME.exec((raw ?? "").trim());
  if (!m) return NaN;
  const [, y, mo, d, h, mi, se, sign, oh, om] = m;
  const secs = se ? +se : 0;
  if (!sign) {
    // XMLTV allows the offset to be left off, in which case the time is the
    // broadcaster's local one. Ours is the only local clock we have.
    return new Date(+y!, +mo! - 1, +d!, +h!, +mi!, secs).getTime();
  }
  const offset = (+oh! * 60 + +om!) * 60_000 * (sign === "-" ? -1 : 1);
  return Date.UTC(+y!, +mo! - 1, +d!, +h!, +mi!, secs) - offset;
}

const textOf = (parent: Element, tag: string): string =>
  parent.querySelector(tag)?.textContent?.trim() ?? "";

/**
 * Parse an XMLTV document into programmes keyed by the channel id they name.
 *
 * Also returns the display names each channel id was given, so a playlist whose
 * `tvg-id` values don't line up with the guide can still be joined on name.
 */
export function parseXmltv(text: string): {
  programs: Map<string, IptvProgram[]>;
  names: Map<string, string>;
  /** `<icon src>` per channel id, for playlists that name no tvg-logo. */
  icons: Map<string, string>;
} {
  const doc = new DOMParser().parseFromString(text, "text/xml");
  const bad = doc.querySelector("parsererror");
  if (bad) throw new Error("That XMLTV file isn't valid XML");

  const names = new Map<string, string>();
  const icons = new Map<string, string>();
  for (const c of Array.from(doc.getElementsByTagName("channel"))) {
    const id = c.getAttribute("id");
    if (!id) continue;
    const n = c.querySelector("display-name")?.textContent?.trim();
    if (n) names.set(id, n);
    const icon = c.querySelector("icon")?.getAttribute("src")?.trim();
    if (icon) icons.set(id, icon);
  }

  const programs = new Map<string, IptvProgram[]>();
  for (const p of Array.from(doc.getElementsByTagName("programme"))) {
    const chan = p.getAttribute("channel");
    if (!chan) continue;
    const s = xmltvTime(p.getAttribute("start") ?? "");
    const e = xmltvTime(p.getAttribute("stop") ?? "");
    if (!isFinite(s) || !isFinite(e) || !(e > s)) continue;
    const entry: IptvProgram = {
      ChannelId: chan,
      Name: textOf(p, "title") || "Programme",
      Overview: textOf(p, "desc"),
      EpisodeTitle: textOf(p, "sub-title"),
      StartDate: new Date(s).toISOString(),
      EndDate: new Date(e).toISOString(),
    };
    const list = programs.get(chan);
    if (list) list.push(entry);
    else programs.set(chan, [entry]);
  }
  return { programs, names, icons };
}

// ---------- Loading and caching ----------

interface Loaded {
  m3u: string;
  xmltv: string;
  channels: IptvChannel[];
  /** Programmes keyed by our channel Id, already joined to the playlist. */
  programs: Map<string, IptvProgram[]>;
  at: number;
  /** How many channels the guide had anything to say about. */
  matched: number;
}

let cache: Loaded | null = null;
let inflight: Promise<Loaded> | null = null;

/** Whether the loaded copy is older than the refresh interval allows. With the
 *  interval at 0 only a changed address or an explicit reload re-reads it. */
function aged(c: Loaded): boolean {
  const min = refreshMinutes();
  return min > 0 && Date.now() - c.at > min * 60_000;
}

const norm = (s: string): string => s.toLowerCase().replace(/[^a-z0-9]/g, "");

function join(channels: IptvChannel[], parsed: ReturnType<typeof parseXmltv>): {
  programs: Map<string, IptvProgram[]>;
  matched: number;
} {
  // Name is the fallback key: plenty of playlists ship a tvg-id that matches
  // nothing in the guide they're distributed alongside.
  const byName = new Map<string, string>();
  for (const [id, name] of parsed.names) {
    const k = norm(name);
    if (k && !byName.has(k)) byName.set(k, id);
  }

  const out = new Map<string, IptvProgram[]>();
  let matched = 0;
  for (const ch of channels) {
    const guideId =
      (ch.GuideId && parsed.programs.has(ch.GuideId) && ch.GuideId) ||
      byName.get(norm(ch.Name)) ||
      "";
    // The guide's own artwork stands in for a logo the playlist didn't name.
    const guideIcon = parsed.icons.get(guideId || ch.GuideId);
    if (!ch.LogoUrl && guideIcon) ch.LogoUrl = guideIcon;
    const progs = guideId ? parsed.programs.get(guideId) : undefined;
    if (!progs?.length) continue;
    out.set(
      ch.Id,
      progs.map((p) => ({ ...p, ChannelId: ch.Id }))
    );
    matched++;
  }
  return { programs: out, matched };
}

async function fetchText(url: string): Promise<string> {
  return await invoke<string>("fetch_source", { url, userAgent: iptvUserAgent() });
}

async function loadFresh(m3u: string, xmltv: string): Promise<Loaded> {
  if (!m3u) throw new Error("No M3U playlist address is set");
  const channels = parseM3u(await fetchText(m3u));
  if (!channels.length) {
    throw new Error("That playlist has no channels in it");
  }

  let programs = new Map<string, IptvProgram[]>();
  let matched = 0;
  if (xmltv) {
    // A broken guide shouldn't cost the channel list: without it the page
    // falls back to the plain list, which is still usable.
    try {
      const joined = join(channels, parseXmltv(await fetchText(xmltv)));
      programs = joined.programs;
      matched = joined.matched;
    } catch (e) {
      void invoke("ui_log", { msg: `iptv: guide failed: ${(e as any)?.message ?? e}` });
    }
  }
  return { m3u, xmltv, channels, programs, at: Date.now(), matched };
}

/** The parsed source, fetching it only when the addresses changed, the cache
 *  aged out, or a reload was asked for. Concurrent callers share one fetch. */
export async function load(force = false): Promise<Loaded> {
  const { m3u, xmltv } = sourceUrls();
  const stale =
    !cache ||
    cache.m3u !== m3u ||
    cache.xmltv !== xmltv ||
    aged(cache);
  if (!force && !stale && cache) return cache;
  if (inflight && !force) return inflight;

  inflight = loadFresh(m3u, xmltv)
    .then((r) => {
      cache = r;
      return r;
    })
    .finally(() => {
      inflight = null;
    });
  return inflight;
}

export function invalidate(): void {
  cache = null;
}

/** Whether the next `load()` will go back to the network. */
export function isDue(): boolean {
  if (!cache) return true;
  const { m3u, xmltv } = sourceUrls();
  return cache.m3u !== m3u || cache.xmltv !== xmltv || aged(cache);
}

/** What the playlist and guide produced the last time they were read, for
 *  Settings' "Last read" line. `null` before the first read this run. */
export function lastRead(): {
  at: number;
  channels: number;
  withLogos: number;
  matched: number;
  programs: number;
} | null {
  if (!cache) return null;
  let programs = 0;
  for (const l of cache.programs.values()) programs += l.length;
  return {
    at: cache.at,
    channels: cache.channels.length,
    withLogos: cache.channels.filter((c) => !!c.LogoUrl).length,
    matched: cache.matched,
    programs,
  };
}

export async function getChannels(force = false): Promise<IptvChannel[]> {
  return (await load(force)).channels;
}

/** Guide entries overlapping [from, to). Everything is already in memory, so
 *  unlike the Jellyfin path this is a filter rather than a request. */
export async function getPrograms(from: Date, to: Date): Promise<IptvProgram[]> {
  const { programs } = await load();
  const a = from.getTime();
  const b = to.getTime();
  const out: IptvProgram[] = [];
  for (const list of programs.values()) {
    for (const p of list) {
      if (Date.parse(p.EndDate) > a && Date.parse(p.StartDate) < b) out.push(p);
    }
  }
  return out;
}

/** Counts for the Settings page to report after a check. */
export async function describe(force = true): Promise<{
  channels: number;
  matched: number;
  programs: number;
}> {
  const r = await load(force);
  let programs = 0;
  for (const l of r.programs.values()) programs += l.length;
  return { channels: r.channels.length, matched: r.matched, programs };
}
