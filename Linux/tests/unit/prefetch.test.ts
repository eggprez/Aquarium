// src/prefetch.ts: warming the item page while a card holds focus or the
// pointer, debounced so passing over a row fetches nothing.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { fetchItemData } = vi.hoisted(() => ({ fetchItemData: vi.fn() }));
vi.mock("../../src/views/item", () => ({ fetchItemData }));

const added: Array<[string, any]> = [];
let spy: { mockRestore(): void } | null = null;

beforeEach(async () => {
  vi.resetModules();
  vi.clearAllMocks();
  vi.useFakeTimers();
  fetchItemData.mockResolvedValue({});
  // Each test wires a fresh module; take the last one's listeners off again.
  const original = document.addEventListener.bind(document);
  spy = vi.spyOn(document, "addEventListener").mockImplementation((t: any, fn: any, o?: any) => {
    added.push([t, fn]);
    original(t, fn, o);
  });
  const { wirePrefetch } = await import("../../src/prefetch");
  wirePrefetch();
  document.body.innerHTML = `
    <div class="row">
      <a class="card" data-item-id="a" tabindex="0"><span class="title">A</span><button class="play">Play</button></a>
      <a class="card" data-item-id="b" tabindex="0"><span class="title">B</span></a>
      <a class="card" data-item-id="c" tabindex="0"></a>
    </div>
    <button id="elsewhere">Elsewhere</button>`;
});

afterEach(() => {
  for (const [t, fn] of added.splice(0)) document.removeEventListener(t, fn);
  spy?.mockRestore();
});

const card = (id: string): HTMLElement => document.querySelector<HTMLElement>(`[data-item-id="${id}"]`)!;
const fire = (target: Element, type: string, relatedTarget: Element | null = null): void => {
  const Ctor: any = type.startsWith("focus") ? FocusEvent : (window as any).PointerEvent ?? MouseEvent;
  target.dispatchEvent(new Ctor(type, { bubbles: true, relatedTarget }));
};

describe("wirePrefetch", () => {
  it("fetches a focused card's item after it has held focus for 220 ms", async () => {
    fire(card("a"), "focusin");
    await vi.advanceTimersByTimeAsync(219);
    expect(fetchItemData).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    expect(fetchItemData).toHaveBeenCalledWith("a");
  });

  it("arrowing quickly across a row fetches only the card it stops on", async () => {
    for (const id of ["a", "b", "c"]) {
      fire(card(id), "focusin");
      await vi.advanceTimersByTimeAsync(100);
    }
    await vi.advanceTimersByTimeAsync(300);
    expect(fetchItemData.mock.calls).toEqual([["c"]]);
  });

  it("focus arriving from a child of the card (the title) finds the card", async () => {
    fire(card("b").querySelector(".title")!, "pointerover");
    await vi.advanceTimersByTimeAsync(220);
    expect(fetchItemData).toHaveBeenCalledWith("b");
  });

  it("a second event for the card already pending does not restart the wait", async () => {
    fire(card("a"), "pointerover");
    await vi.advanceTimersByTimeAsync(200);
    fire(card("a").querySelector(".title")!, "pointerover");
    await vi.advanceTimersByTimeAsync(20);
    expect(fetchItemData).toHaveBeenCalledTimes(1);
  });

  it("leaving the card before the wait is over cancels the fetch", async () => {
    fire(card("a"), "pointerover");
    await vi.advanceTimersByTimeAsync(100);
    fire(card("a"), "pointerout", document.getElementById("elsewhere"));
    await vi.advanceTimersByTimeAsync(500);
    expect(fetchItemData).not.toHaveBeenCalled();
  });

  it("losing focus to somewhere else cancels the fetch", async () => {
    fire(card("a"), "focusin");
    fire(card("a"), "focusout", document.getElementById("elsewhere"));
    await vi.advanceTimersByTimeAsync(500);
    expect(fetchItemData).not.toHaveBeenCalled();
  });

  it("moving onto the play button inside the card does not cancel it (regression: a stray pointerout on the way to a child)", async () => {
    fire(card("a"), "pointerover");
    fire(card("a"), "pointerout", card("a").querySelector(".play"));
    fire(card("a"), "focusout", card("a").querySelector(".play"));
    await vi.advanceTimersByTimeAsync(220);
    expect(fetchItemData).toHaveBeenCalledWith("a");
  });

  it("a card the keyboard is still on stays warm after the pointer leaves it", async () => {
    card("a").focus();
    fire(card("a"), "pointerover");
    fire(card("a"), "pointerout", document.getElementById("elsewhere"));
    await vi.advanceTimersByTimeAsync(220);
    expect(fetchItemData).toHaveBeenCalledWith("a");
  });

  it("events away from any card are ignored", async () => {
    fire(document.getElementById("elsewhere")!, "focusin");
    fire(document.getElementById("elsewhere")!, "pointerout");
    fire(document.getElementById("elsewhere")!, "focusout");
    await vi.advanceTimersByTimeAsync(500);
    expect(fetchItemData).not.toHaveBeenCalled();
  });

  it("a cancel with nothing pending is harmless, and the same card can be warmed again after", async () => {
    fire(card("b"), "pointerout", null);
    fire(card("b"), "pointerover");
    fire(card("b"), "pointerout", null);
    fire(card("b"), "pointerover");
    await vi.advanceTimersByTimeAsync(220);
    expect(fetchItemData.mock.calls).toEqual([["b"]]);
  });

  // Vitest fails the run on an unhandled rejection, so passing is the check.
  it("a failed prefetch is swallowed", async () => {
    fetchItemData.mockRejectedValueOnce(new Error("offline"));
    fire(card("a"), "focusin");
    await vi.advanceTimersByTimeAsync(220);
    await Promise.resolve();
    expect(fetchItemData).toHaveBeenCalled();
  });

  it("an event whose target is not an element (the document) is ignored", async () => {
    document.dispatchEvent(new FocusEvent("focusin", { bubbles: true }));
    await vi.advanceTimersByTimeAsync(500);
    expect(fetchItemData).not.toHaveBeenCalled();
  });
});
