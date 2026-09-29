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
} {
  const doc = new DOMParser().parseFromString(text, "text/xml");
  const bad = doc.querySelector("parsererror");
  if (bad) throw new Error("That XMLTV file isn't valid XML");

  const names = new Map<string, string>();
  for (const c of Array.from(doc.getElementsByTagName("channel"))) {
    const id = c.getAttribute("id");
    if (!id) continue;
    const n = c.querySelector("display-name")?.textContent?.trim();
    if (n) names.set(id, n);
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
  return { programs, names };
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

/** Guides change slowly and are expensive to fetch; an hour is well inside the
 *  window where a re-fetch would return the same document. */
const TTL_MS = 60 * 60_000;

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
  return await invoke<string>("fetch_source", { url });
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
    Date.now() - cache.at > TTL_MS;
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
