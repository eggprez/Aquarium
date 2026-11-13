// Helpers shared by the small-modules tests (iptv, lineup, channels panel,
// cache, blurhash, theme, scroll, spatial).
import { onInvoke } from "./tauri";

/** A promise settled from outside, for holding a request open. */
export function deferred<T>(): {
  promise: Promise<T>;
  resolve: (v: T) => void;
  reject: (e: unknown) => void;
} {
  let resolve!: (v: T) => void;
  let reject!: (e: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

/** An ISO time `min` minutes from `base` (default: now). */
export function isoIn(min: number, base = Date.now()): string {
  return new Date(base + min * 60_000).toISOString();
}

/** An XMLTV timestamp in UTC (`YYYYMMDDhhmmss +0000`) for an epoch time. */
export function xmltvStamp(ms: number): string {
  const d = new Date(ms);
  const p = (n: number, w = 2): string => String(n).padStart(w, "0");
  return (
    `${p(d.getUTCFullYear(), 4)}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}` +
    `${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())} +0000`
  );
}

/**
 * Answer `fetch_source` (the Rust command that downloads and gunzips a
 * playlist or guide) from a map of url to text. A value may be a function, an
 * Error to reject with, or a promise. Returns the list of urls asked for.
 */
export function serveSources(
  sources: Record<string, string | Error | (() => string | Promise<string>)>
): { urls: string[]; agents: string[] } {
  const seen = { urls: [] as string[], agents: [] as string[] };
  onInvoke("fetch_source", async (a: { url: string; userAgent: string }) => {
    seen.urls.push(a.url);
    seen.agents.push(a.userAgent);
    const v = sources[a.url];
    if (v === undefined) throw new Error(`no such source: ${a.url}`);
    if (v instanceof Error) throw v;
    return typeof v === "function" ? await v() : v;
  });
  return seen;
}
