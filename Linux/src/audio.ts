// The music and audiobook queue.
//
// The queue lives here; mpv (src-tauri/src/audio.rs) only ever holds the song
// playing and the one after it. When mpv moves on it says so (`audio-track`)
// and this hands down the next one, which is what keeps the join gapless while
// shuffle, repeat, Play Next and the stations stay ordinary list operations.
//
// Video and music never play together: the backend stops one when the other
// starts, and this module just follows the events.
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import * as api from "./api";
import { artistLine, coverUrl, secondsOf, streamUrl } from "./musicApi";

export type Repeat = "off" | "all" | "one";

export interface AudioStatus {
  active: boolean;
  paused: boolean;
  position: number;
  duration: number;
  item_id: string;
  volume: number;
  mute: boolean;
  speed: number;
  buffering: boolean;
}

/** Something that can keep a queue going when it runs low — a station. */
export interface QueueSource {
  title: string;
  /** More songs to follow `history`. Empty when it has nothing left. */
  more(history: any[], count: number): Promise<any[]>;
}

interface Queue {
  items: any[];
  /** The order before shuffling, to put back when shuffle goes off. */
  original: any[] | null;
  index: number;
  title: string;
  repeat: Repeat;
  source: QueueSource | null;
  /** Audiobooks: skip by seconds, report chapters, keep a speed. */
  book: boolean;
}

const q: Queue = { items: [], original: null, index: -1, title: "", repeat: "off", source: null, book: false };
let status: AudioStatus = {
  active: false, paused: false, position: 0, duration: 0, item_id: "",
  volume: 100, mute: false, speed: 1, buffering: false,
};
/** Which item mpv has queued behind the current one, so the same answer
 *  isn't handed down twice (each hand-down clears mpv's prefetch). */
let queuedNext: string | null | undefined = undefined;
let extending = false;
const listeners = new Set<() => void>();

const VOLUME_KEY = "aquarium.music-volume";
const SPEED_KEY = "aquarium.book-speed";
const REPEAT_KEY = "aquarium.music-repeat";

function readNumber(key: string, fallback: number): number {
  try {
    const v = Number(localStorage.getItem(key));
    return Number.isFinite(v) && v > 0 ? v : fallback;
  } catch {
    return fallback;
  }
}
function writeValue(key: string, v: string): void {
  try {
    localStorage.setItem(key, v);
  } catch {
    // Storage unavailable: the choice lasts this session only.
  }
}

try {
  const r = localStorage.getItem(REPEAT_KEY);
  if (r === "all" || r === "one") q.repeat = r;
} catch {
  // Defaults stand.
}

// ---------- Reading ----------

export function onChange(fn: () => void): () => void {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

function changed(): void {
  for (const fn of listeners) {
    try {
      fn();
    } catch (e) {
      console.error(e);
    }
  }
}

export function getStatus(): AudioStatus {
  return status;
}

export function isActive(): boolean {
  return status.active && q.index >= 0;
}

export function current(): any | null {
  return q.items[q.index] ?? null;
}

export function queueState(): Readonly<Queue> {
  return q;
}

/** What plays after the current item, in order (the Up Next list). */
export function upNext(): any[] {
  return q.items.slice(q.index + 1);
}

export function isShuffled(): boolean {
  return q.original != null;
}

/** The chapter of the current audiobook at the playhead. */
export function currentChapter(): { name: string; index: number; start: number; end: number } | null {
  const item = current();
  const chapters: any[] = item?.Chapters ?? [];
  if (!q.book || !chapters.length) return null;
  const pos = status.position;
  let at = 0;
  for (let i = 0; i < chapters.length; i++) {
    if (secondsOf(chapters[i].StartPositionTicks) <= pos + 0.5) at = i;
  }
  const start = secondsOf(chapters[at].StartPositionTicks);
  const end = at + 1 < chapters.length ? secondsOf(chapters[at + 1].StartPositionTicks) : status.duration;
  return { name: chapters[at].Name || `Chapter ${at + 1}`, index: at, start, end };
}

// ---------- Talking to the backend ----------

function trackOf(item: any): any {
  const local = (item as any).__localPath as string | undefined;
  return {
    item_id: item.Id,
    url: local ?? streamUrl(item),
    title: item.Name ?? "",
    artist: artistLine(item),
    album: item.Album ?? (item.Type === "AudioBook" ? item.SeriesName ?? "" : ""),
    album_artist: item.AlbumArtist ?? "",
    art_url: coverUrl(item, 600),
    duration: secondsOf(item.RunTimeTicks),
    track_number: item.IndexNumber ?? null,
    is_local: !!local,
  };
}

function followingIndex(): number | null {
  if (q.index + 1 < q.items.length) return q.index + 1;
  if (q.repeat === "all" && q.items.length) return 0;
  return null;
}

function soundCheck(): string {
  return api.getConfig()?.music_soundcheck === false ? "no" : "track";
}

function publishQueue(): void {
  const entries = q.items.map((i) => {
    const t = trackOf(i);
    t.url = "";
    return t;
  });
  invoke("audio_set_queue", {
    entries,
    index: Math.max(0, q.index),
    canNext: followingIndex() != null || !!q.source,
    canPrev: q.index > 0,
  }).catch(() => {});
}

async function startAt(index: number, startSeconds?: number): Promise<void> {
  const item = q.items[index];
  if (!item) return;
  q.index = index;
  const s = api.getSession();
  const nextIdx = followingIndex();
  const next = nextIdx != null && sleepMode !== "track" ? q.items[nextIdx] : null;
  queuedNext = next?.Id ?? null;
  status = { ...status, active: true, paused: false, position: startSeconds ?? 0, item_id: item.Id, duration: secondsOf(item.RunTimeTicks) };
  changed();
  publishQueue();
  try {
    await invoke("audio_play", {
      req: {
        track: trackOf(item),
        next: next ? trackOf(next) : null,
        start_seconds: startSeconds ?? null,
        volume: readNumber(VOLUME_KEY, 100),
        speed: q.book ? readNumber(SPEED_KEY, 1) : 1,
        replaygain: soundCheck(),
        loop_file: q.repeat === "one",
        server_url: s?.server ?? null,
        user_id: s?.userId ?? null,
        device_id: s?.deviceId ?? null,
      },
    });
  } catch (e: any) {
    status = { ...status, active: false };
    changed();
    throw new Error(String(e?.message ?? e));
  }
  void topUp();
}

/** Hand mpv the item after the current one, if that changed. */
async function handDownNext(): Promise<void> {
  const nextIdx = followingIndex();
  const next = nextIdx != null && sleepMode !== "track" ? q.items[nextIdx] : null;
  const id = next?.Id ?? null;
  if (id === queuedNext) return;
  queuedNext = id;
  await invoke("audio_set_next", { next: next ? trackOf(next) : null }).catch(() => {});
}

/** A station keeps a few songs ahead of the playhead. */
async function topUp(): Promise<void> {
  if (!q.source || extending || q.items.length - q.index > 5) return;
  extending = true;
  try {
    const more = await q.source.more(q.items, 20);
    const have = new Set(q.items.slice(Math.max(0, q.index - 50)).map((i) => i.Id));
    const fresh = more.filter((m) => !have.has(m.Id));
    if (fresh.length) {
      q.items.push(...fresh);
      if (q.original) q.original.push(...fresh);
      publishQueue();
      changed();
      await handDownNext();
    }
  } catch (e) {
    console.error("station top-up", e);
  } finally {
    extending = false;
  }
}

// ---------- Starting things ----------

export interface PlayOptions {
  title?: string;
  shuffle?: boolean;
  source?: QueueSource | null;
  book?: boolean;
  startSeconds?: number;
}

/** Play `items` from `start`, replacing the queue. */
export async function play(items: any[], start = 0, opts: PlayOptions = {}): Promise<void> {
  const list = items.filter((i) => i && i.Id);
  if (!list.length) return;
  q.title = opts.title ?? "";
  q.source = opts.source ?? null;
  q.book = opts.book ?? list[0].Type === "AudioBook";
  if (opts.shuffle) {
    const first = list[Math.max(0, Math.min(start, list.length - 1))];
    const rest = shuffled(list.filter((i) => i !== first));
    q.original = list;
    // "Shuffle" on a page starts anywhere; a song picked with shuffle on
    // starts with that song.
    q.items = start === 0 ? shuffled(list) : [first, ...rest];
    await startAt(0, opts.startSeconds);
  } else {
    q.original = null;
    q.items = list;
    await startAt(Math.max(0, Math.min(start, list.length - 1)), opts.startSeconds);
  }
}

/** Put items straight after the current one. */
export async function playNext(items: any[]): Promise<void> {
  if (!isActive()) return play(items);
  q.items.splice(q.index + 1, 0, ...items);
  if (q.original) q.original.push(...items);
  publishQueue();
  changed();
  await handDownNext();
}

/** Put items at the end of the queue. */
export async function playLater(items: any[]): Promise<void> {
  if (!isActive()) return play(items);
  q.items.push(...items);
  if (q.original) q.original.push(...items);
  publishQueue();
  changed();
  await handDownNext();
}

export async function next(): Promise<void> {
  const i = followingIndex();
  if (i != null) return startAt(i);
  if (q.source) {
    await topUp();
    const j = followingIndex();
    if (j != null) return startAt(j);
  }
  await stop();
}

/** Back to the start of this one, or to the one before if it has barely begun. */
export async function previous(): Promise<void> {
  if (status.position > 3 || q.index <= 0) {
    await seek(0);
    return;
  }
  await startAt(q.index - 1);
}

export async function jump(index: number): Promise<void> {
  if (index >= 0 && index < q.items.length) await startAt(index);
}

export async function stop(): Promise<void> {
  await invoke("audio_stop").catch(() => {});
  q.index = -1;
  q.items = [];
  q.original = null;
  q.source = null;
  status = { ...status, active: false };
  cancelSleep();
  publishQueue();
  changed();
}

// ---------- Editing the queue ----------

/** Remove an Up Next entry (an index into the whole queue). */
export async function removeAt(index: number): Promise<void> {
  if (index <= q.index || index >= q.items.length) return;
  const [gone] = q.items.splice(index, 1);
  if (q.original) {
    const at = q.original.indexOf(gone);
    if (at >= 0) q.original.splice(at, 1);
  }
  publishQueue();
  changed();
  await handDownNext();
}

/** Move an Up Next entry from one place to another (whole-queue indices). */
export async function move(from: number, to: number): Promise<void> {
  if (from <= q.index || to <= q.index || from >= q.items.length || to >= q.items.length || from === to) return;
  const [it] = q.items.splice(from, 1);
  q.items.splice(to, 0, it);
  publishQueue();
  changed();
  await handDownNext();
}

export async function clearUpNext(): Promise<void> {
  q.items.splice(q.index + 1);
  q.original = null;
  q.source = null;
  publishQueue();
  changed();
  await handDownNext();
}

function shuffled<T>(list: T[]): T[] {
  const a = [...list];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

export async function setShuffle(on: boolean): Promise<void> {
  if (on === isShuffled() || q.index < 0) return;
  const cur = q.items[q.index];
  if (on) {
    q.original = [...q.items];
    q.items = [cur, ...shuffled(q.items.filter((_, i) => i !== q.index))];
    q.index = 0;
  } else {
    const orig = q.original ?? q.items;
    q.original = null;
    q.items = orig;
    q.index = Math.max(0, orig.indexOf(cur));
  }
  publishQueue();
  changed();
  await handDownNext();
}

export async function cycleRepeat(): Promise<Repeat> {
  q.repeat = q.repeat === "off" ? "all" : q.repeat === "all" ? "one" : "off";
  writeValue(REPEAT_KEY, q.repeat);
  await invoke("audio_command", { cmd: ["set_property", "loop-file", q.repeat === "one" ? "inf" : "no"] }).catch(() => {});
  publishQueue();
  changed();
  await handDownNext();
  return q.repeat;
}

// ---------- Transport ----------

export async function togglePause(): Promise<void> {
  if (!isActive()) return;
  await invoke("audio_command", { cmd: ["cycle", "pause"] }).catch(() => {});
}

export async function seek(seconds: number): Promise<void> {
  if (!isActive()) return;
  status = { ...status, position: Math.max(0, seconds) };
  changed();
  await invoke("audio_command", { cmd: ["seek", Math.max(0, seconds), "absolute"] }).catch(() => {});
}

export async function skip(delta: number): Promise<void> {
  await seek(Math.min(status.duration || Infinity, status.position + delta));
}

export async function setVolume(v: number): Promise<void> {
  const vol = Math.max(0, Math.min(130, Math.round(v)));
  writeValue(VOLUME_KEY, String(vol || 1));
  status = { ...status, volume: vol };
  await invoke("audio_command", { cmd: ["set_property", "volume", vol] }).catch(() => {});
}

export async function setMute(m: boolean): Promise<void> {
  await invoke("audio_command", { cmd: ["set_property", "mute", m] }).catch(() => {});
}

export const BOOK_SPEEDS = [0.75, 1, 1.1, 1.25, 1.5, 1.75, 2];

export function bookSpeed(): number {
  return readNumber(SPEED_KEY, 1);
}

export async function setSpeed(s: number): Promise<void> {
  writeValue(SPEED_KEY, String(s));
  await invoke("audio_command", { cmd: ["set_property", "speed", s] }).catch(() => {});
}

export async function setSoundCheck(on: boolean): Promise<void> {
  await api.saveConfig({ music_soundcheck: on });
  await invoke("audio_command", { cmd: ["set_property", "replaygain", on ? "track" : "no"] }).catch(() => {});
}

export function soundCheckOn(): boolean {
  return api.getConfig()?.music_soundcheck !== false;
}

// ---------- Sleep timer ----------

let sleepMode: "off" | "time" | "track" = "off";
let sleepAt = 0;
let sleepTimer = 0;

export function sleepState(): { mode: "off" | "time" | "track"; at: number } {
  return { mode: sleepMode, at: sleepAt };
}

function cancelSleep(): void {
  if (sleepTimer) clearTimeout(sleepTimer);
  sleepTimer = 0;
  sleepMode = "off";
  sleepAt = 0;
}

/** Minutes, or "track" for the end of this song (or chapter, in a book). */
export async function setSleep(what: number | "track" | "off"): Promise<void> {
  cancelSleep();
  if (what === "off") {
    // Whatever was held back for "end of track" can follow again.
  } else if (what === "track") {
    sleepMode = "track";
    const ch = currentChapter();
    if (ch) {
      // A book is one long file: stop at the chapter's end instead.
      sleepAt = Date.now() + ((ch.end - status.position) / (status.speed || 1)) * 1000;
      sleepTimer = window.setTimeout(() => void pauseForSleep(), Math.max(1000, sleepAt - Date.now()));
    }
  } else {
    sleepMode = "time";
    sleepAt = Date.now() + what * 60_000;
    sleepTimer = window.setTimeout(() => void pauseForSleep(), what * 60_000);
  }
  await handDownNext();
  changed();
}

async function pauseForSleep(): Promise<void> {
  cancelSleep();
  if (!status.paused) await invoke("audio_command", { cmd: ["set_property", "pause", true] }).catch(() => {});
  await handDownNext();
  changed();
}

// ---------- Events from the backend ----------

let wired = false;

export async function wireAudio(onError: (msg: string) => void): Promise<void> {
  if (wired) return;
  wired = true;
  await listen<any>("audio-status", (ev) => {
    const p = ev.payload ?? {};
    if (p.active === false) {
      const ended = !!p.ended;
      status = { ...status, active: false, paused: false };
      if (ended) {
        // The queue ran out in mpv. Repeat-all and stations are handled before
        // that can happen, so this is the real end.
        q.index = -1;
        q.items = [];
        q.original = null;
        q.source = null;
        if (sleepMode === "track") cancelSleep();
      } else {
        q.index = -1;
      }
      publishQueue();
      changed();
      return;
    }
    status = { ...status, ...p };
    changed();
  });
  await listen<any>("audio-track", (ev) => {
    const id = ev.payload?.item_id;
    if (!id) return;
    if (q.items[q.index]?.Id === id) return;
    const nextIdx = followingIndex();
    if (nextIdx != null && q.items[nextIdx]?.Id === id) q.index = nextIdx;
    else {
      const at = q.items.findIndex((i, n) => n > q.index && i.Id === id);
      if (at >= 0) q.index = at;
    }
    queuedNext = undefined;
    status = { ...status, position: 0, item_id: id, duration: secondsOf(q.items[q.index]?.RunTimeTicks) };
    publishQueue();
    changed();
    void handDownNext().then(topUp);
  });
  await listen<any>("audio-error", (ev) => {
    const item = q.items.find((i) => i.Id === ev.payload?.item_id);
    onError(`Couldn't play ${item?.Name ?? "that track"}${ev.payload?.error ? ` (${ev.payload.error})` : ""}`);
  });
  await listen("audio-next", () => void next());
  await listen("audio-prev", () => void previous());
  await listen<any>("audio-goto", (ev) => void jump(Number(ev.payload?.index ?? -1)));
  // Video took over: the backend stopped us; mirror it.
  await listen<any>("player-status", (ev) => {
    if (ev.payload?.active && status.active) {
      status = { ...status, active: false };
      q.index = -1;
      changed();
    }
  });
}
