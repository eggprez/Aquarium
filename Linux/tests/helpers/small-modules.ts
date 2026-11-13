// Helpers shared by the small-modules tests (iptv, lineup, channels panel,
// cache, blurhash, theme, scroll, spatial).
import { vi } from "vitest";
import { onInvoke } from "./tauri";

const B83 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~";

/** `value` in BlurHash's base 83, `length` digits wide. */
export function base83(value: number, length: number): string {
  let out = "";
  for (let i = 1; i <= length; i++) {
    const digit = Math.floor(value / Math.pow(83, length - i)) % 83;
    out += B83[digit];
  }
  return out;
}

/**
 * jsdom has no canvas. Install a 2D context that keeps what is drawn: `last`
 * is the pixel data of the latest `putImageData`, `renders` counts them and
 * `size` is the canvas width. `toDataURL` answers `data:image/png;fake-<n>`.
 * Restore with `vi.restoreAllMocks()`.
 */
export function fakeCanvas(opts: { toDataURLThrows?: boolean } = {}): {
  renders: number;
  last: Uint8ClampedArray | null;
  size: number;
} {
  const state = { renders: 0, last: null as Uint8ClampedArray | null, size: 0 };
  vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockImplementation(function (this: HTMLCanvasElement) {
    const canvas = this;
    return {
      createImageData: (w: number, h: number) => ({ width: w, height: h, data: new Uint8ClampedArray(w * h * 4) }),
      putImageData: (img: { data: Uint8ClampedArray }) => {
        state.renders++;
        state.last = img.data;
        state.size = canvas.width;
      },
    } as any;
  } as any);
  vi.spyOn(HTMLCanvasElement.prototype, "toDataURL").mockImplementation(() => {
    if (opts.toDataURLThrows) throw new Error("tainted");
    return `data:image/png;fake-${state.renders}`;
  });
  return state;
}

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
