// An in-memory stand-in for the Tauri bridge.
//
//   onInvoke("jf_request", ({ path }) => ({ status: 200, body: {...} }))
//   emitEvent("player-status", {...})   // what Rust's app.emit would deliver
//   invokeCalls("jf_request")           // every call made, in order
//
// setup.ts points `@tauri-apps/api/core` and `/event` at this file, and
// resets it before every test.
import { vi } from "vitest";

export type InvokeHandler = (args: any, cmd: string) => any;

interface Call {
  cmd: string;
  args: any;
}

const handlers = new Map<string, InvokeHandler>();
let fallback: InvokeHandler | null = null;
const calls: Call[] = [];
const listeners = new Map<string, Set<(e: { event: string; payload: any; id: number }) => void>>();

/** Fire-and-forget commands, answered quietly unless a test overrides them. */
const QUIET: Record<string, any> = { ui_log: null };

export const invoke = vi.fn(async (cmd: string, args?: any): Promise<any> => {
  calls.push({ cmd, args });
  const h = handlers.get(cmd);
  if (h) return await h(args ?? {}, cmd);
  if (fallback) return await fallback(args ?? {}, cmd);
  if (cmd in QUIET) return QUIET[cmd];
  throw new Error(`unmocked invoke: ${cmd}`);
});

export const listen = vi.fn(async (event: string, cb: (e: any) => void): Promise<() => void> => {
  let set = listeners.get(event);
  if (!set) listeners.set(event, (set = new Set()));
  set.add(cb);
  return () => {
    set!.delete(cb);
  };
});

export const once = vi.fn(async (event: string, cb: (e: any) => void): Promise<() => void> => {
  const off = await listen(event, (e: any) => {
    off();
    cb(e);
  });
  return off;
});

export const emit = vi.fn(async (event: string, payload?: any): Promise<void> => {
  emitEvent(event, payload);
});

export const convertFileSrc = vi.fn(
  (path: string, protocol = "asset") => `${protocol}://localhost/${encodeURIComponent(path)}`
);

export const coreModule = { invoke, convertFileSrc, isTauri: () => true };
export const eventModule = { listen, once, emit };

/** Answer a command. A function gets the args object; anything else is returned as is. */
export function onInvoke(cmd: string, handler: InvokeHandler | unknown): void {
  handlers.set(cmd, typeof handler === "function" ? (handler as InvokeHandler) : () => handler);
}

/** The handler registered for a command, to wrap it. */
export function invokeHandler(cmd: string): InvokeHandler | undefined {
  return handlers.get(cmd);
}

/** Answer several commands at once: `{ cmd: handlerOrValue }`. */
export function onInvokes(map: Record<string, InvokeHandler | unknown>): void {
  for (const [k, v] of Object.entries(map)) onInvoke(k, v);
}

/** Answer anything not otherwise registered (null removes it). */
export function onAnyInvoke(handler: InvokeHandler | null): void {
  fallback = handler;
}

/** Deliver a backend event to every `listen`er, as `app.emit` would. */
export function emitEvent(event: string, payload?: any): void {
  for (const cb of [...(listeners.get(event) ?? [])]) cb({ event, payload, id: 0 });
}

export function listenerCount(event: string): number {
  return listeners.get(event)?.size ?? 0;
}

/** Calls made so far; all of them, or those to one command. */
export function invokeCalls(cmd?: string): Call[] {
  return cmd ? calls.filter((c) => c.cmd === cmd) : [...calls];
}

export function clearInvokeCalls(): void {
  calls.length = 0;
}

export interface JfArgs {
  path: string;
  method: string;
  body: any;
}

/**
 * Route `jf_request` by path. Each entry is `[prefix | RegExp, value | fn]`;
 * the first match wins and its value (or the function's result) becomes the
 * body of a 200. Return `{ __status: n, body }` for another status. Anything
 * unmatched answers `fallbackStatus` (404).
 */
export function mockJellyfin(
  routes: Array<[string | RegExp, any]>,
  opts: { fallbackStatus?: number } = {}
): void {
  onInvoke("jf_request", async (args: JfArgs) => {
    for (const [match, value] of routes) {
      const hit = typeof match === "string" ? args.path.startsWith(match) : match.test(args.path);
      if (!hit) continue;
      const out = typeof value === "function" ? await value(args) : value;
      if (out && typeof out === "object" && "__status" in out) {
        return { status: out.__status, body: out.body ?? null };
      }
      return { status: 200, body: out };
    }
    return { status: opts.fallbackStatus ?? 404, body: null };
  });
}

/** The paths `jf_request` was called with, optionally only one method. */
export function jfPaths(method?: string): string[] {
  return invokeCalls("jf_request")
    .filter((c) => !method || c.args.method === method)
    .map((c) => c.args.path as string);
}

/** A signed-in config, as `config_load` returns it. */
export function signedInConfig(extra: Record<string, any> = {}): Record<string, any> {
  return {
    server: "http://jf.test:8096",
    has_token: true,
    user_id: "user-1",
    user_name: "tester",
    device_id: "device-1",
    ...extra,
  };
}

/**
 * Sign the api module in against the mock bridge and return it. `config_save`
 * is answered (and merged into what `config_load` returns) unless the test has
 * registered its own.
 */
export async function signIn(extra: Record<string, any> = {}): Promise<typeof import("../../src/api")> {
  const cfg = signedInConfig(extra);
  onInvoke("config_load", () => ({ ...cfg }));
  if (!handlers.has("config_save")) {
    onInvoke("config_save", (a: { cfg: Record<string, any> }) => {
      Object.assign(cfg, a.cfg);
      return null;
    });
  }
  const api = await import("../../src/api");
  await api.loadConfig();
  return api;
}

export function resetTauri(): void {
  handlers.clear();
  listeners.clear();
  fallback = null;
  calls.length = 0;
  invoke.mockClear();
  listen.mockClear();
  once.mockClear();
  emit.mockClear();
  convertFileSrc.mockClear();
}

/** Let queued promise callbacks run (several turns, for chained awaits). */
export async function flush(turns = 10): Promise<void> {
  for (let i = 0; i < turns; i++) await Promise.resolve();
}

/** Wait (in real time) until `cond` holds; throws after `ms`. */
export async function waitFor(cond: () => boolean, ms = 2000): Promise<void> {
  const t0 = Date.now();
  while (!cond()) {
    if (Date.now() - t0 > ms) throw new Error("waitFor: condition not met");
    await new Promise((r) => setTimeout(r, 5));
  }
}
