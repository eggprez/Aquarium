// DOM helpers shared by the views-media tests (downloads, Live TV, books,
// music): the page shell the views expect, and ways to drive the shared menu
// and dialog components the way a user does.
import { flush } from "./tauri";

/** The bits of index.html the views reach for: the toast stack, `#main` (the
 *  tuning screen hangs there) and a content root to render into. */
export function mountShell(): HTMLElement {
  document.body.innerHTML = "";
  const toasts = document.createElement("div");
  toasts.id = "toasts";
  const main = document.createElement("div");
  main.id = "main";
  const root = document.createElement("div");
  root.id = "content";
  main.append(root);
  document.body.append(main, toasts);
  return root;
}

/** Text of every toast on screen, oldest first. */
export function toasts(): string[] {
  return Array.from(document.querySelectorAll("#toasts .toast")).map((t) => t.textContent ?? "");
}

export function lastToast(): string {
  return toasts().at(-1) ?? "";
}

export function clearToasts(): void {
  document.getElementById("toasts")!.textContent = "";
}

export function click(node: Element | null | undefined, init: MouseEventInit = {}): void {
  if (!node) throw new Error("click: no such element");
  node.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, ...init }));
}

export function dblclick(node: Element | null | undefined): void {
  if (!node) throw new Error("dblclick: no such element");
  node.dispatchEvent(new MouseEvent("dblclick", { bubbles: true, cancelable: true }));
}

/** Dispatch a keydown; returns the event so `defaultPrevented` can be read. */
export function key(node: EventTarget | null | undefined, k: string, init: KeyboardEventInit = {}): KeyboardEvent {
  if (!node) throw new Error("key: no such element");
  const ev = new KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true, ...init });
  node.dispatchEvent(ev);
  return ev;
}

/** Right-click: opens whatever context menu is attached. */
export function rightClick(node: Element | null | undefined): void {
  if (!node) throw new Error("rightClick: no such element");
  node.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }));
}

export function openMenuEl(): HTMLElement | null {
  return document.querySelector<HTMLElement>(".menu");
}

/** Labels of the entries in the open menu (without the Back row). */
export function menuLabels(): string[] {
  const menu = openMenuEl();
  if (!menu) return [];
  return Array.from(menu.querySelectorAll("button[role=menuitem]")).map(
    (b) => b.querySelector(".menu-text")?.textContent ?? ""
  );
}

export function menuTitle(): string | null {
  return openMenuEl()?.querySelector(".menu-label")?.textContent ?? null;
}

/** Click the menu entry whose label is, or starts with, `label`. */
export async function pickMenu(label: string | RegExp): Promise<void> {
  const menu = openMenuEl();
  if (!menu) throw new Error(`pickMenu(${label}): no menu is open`);
  const btn = Array.from(menu.querySelectorAll<HTMLElement>("button[role=menuitem]")).find((b) => {
    const t = b.querySelector(".menu-text")?.textContent ?? "";
    return typeof label === "string" ? t === label || t.startsWith(label) : label.test(t);
  });
  if (!btn) throw new Error(`pickMenu(${label}): not in [${menuLabels().join(" | ")}]`);
  click(btn);
  await flush(30);
}

export function dialogEl(): HTMLElement | null {
  return document.querySelector<HTMLElement>(".dialog-scrim .dialog");
}

export function dialogTitle(): string | null {
  return dialogEl()?.querySelector("h2")?.textContent ?? null;
}

export function dialogButtons(): string[] {
  return Array.from(dialogEl()?.querySelectorAll(".dialog-actions button") ?? []).map((b) => b.textContent ?? "");
}

export async function pickDialog(label: string): Promise<void> {
  const btn = Array.from(dialogEl()?.querySelectorAll<HTMLElement>(".dialog-actions button") ?? []).find(
    (b) => b.textContent === label
  );
  if (!btn) throw new Error(`pickDialog(${label}): not in [${dialogButtons().join(" | ")}]`);
  click(btn);
  await flush(30);
}

/** The first element under `root` matching `selector` whose text contains `text`. */
export function byText<T extends HTMLElement = HTMLElement>(root: ParentNode, selector: string, text: string | RegExp): T | null {
  for (const n of Array.from(root.querySelectorAll<T>(selector))) {
    const t = n.textContent ?? "";
    if (typeof text === "string" ? t.includes(text) : text.test(t)) return n;
  }
  return null;
}

/** Text of every element matching `selector`. */
export function texts(root: ParentNode, selector: string): string[] {
  return Array.from(root.querySelectorAll(selector)).map((n) => n.textContent ?? "");
}

/** Let promise chains settle, including ones that hop through a macrotask
 *  (fake-indexeddb, `setTimeout(0)`). Real timers only. */
export async function settle(rounds = 3): Promise<void> {
  for (let i = 0; i < rounds; i++) {
    await flush(20);
    await new Promise((r) => setTimeout(r, 0));
  }
  await flush(20);
}
