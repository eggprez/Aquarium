// Runs before every test file.
//
// The Tauri API is replaced with the in-memory bridge in helpers/tauri.ts, so
// no test can reach a real backend by accident: an `invoke` nobody registered
// a handler for rejects loudly instead of hanging.
import "fake-indexeddb/auto";
import { afterEach, beforeEach, vi } from "vitest";
import { resetTauri } from "./helpers/tauri";

vi.mock("@tauri-apps/api/core", async () => (await import("./helpers/tauri")).coreModule);
vi.mock("@tauri-apps/api/event", async () => (await import("./helpers/tauri")).eventModule);

// jsdom has no layout, no media queries and no observers; the app only needs
// them to exist.
if (typeof window.matchMedia !== "function") {
  (window as any).matchMedia = (q: string) => ({
    matches: false,
    media: q,
    addEventListener() {},
    removeEventListener() {},
    addListener() {},
    removeListener() {},
    dispatchEvent: () => false,
  });
}
class NoopObserver {
  observe() {}
  unobserve() {}
  disconnect() {}
  takeRecords() {
    return [];
  }
}
(globalThis as any).IntersectionObserver ??= NoopObserver;
(globalThis as any).ResizeObserver ??= NoopObserver;
(Element.prototype as any).scrollIntoView ??= function () {};
(Element.prototype as any).scrollTo ??= function () {};
(Element.prototype as any).scrollBy ??= function () {};
(window as any).scrollTo = () => {};
(HTMLElement.prototype as any).animate ??= () => ({ finished: Promise.resolve(), cancel() {}, onfinish: null });
if (!(globalThis as any).CSS) (globalThis as any).CSS = {};
(globalThis as any).CSS.escape ??= (s: string) => String(s).replace(/[^a-zA-Z0-9_-]/g, (c) => "\\" + c);

beforeEach(() => {
  resetTauri();
});

afterEach(() => {
  document.body.innerHTML = "";
  localStorage.clear();
  sessionStorage.clear();
  vi.useRealTimers();
});
