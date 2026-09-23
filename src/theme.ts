// Light/dark appearance. The preference lives in config.json as `theme`
// ("auto" | "light" | "dark") and is applied by setting data-theme on <html>;
// styles.css holds both palettes.
//
// "auto" follows the desktop. The system value comes from the XDG portal via
// the `system_color_scheme` command rather than matchMedia, because WebKitGTK
// only reports prefers-color-scheme from the *GTK theme*, which doesn't track
// GNOME's dark-style toggle; matchMedia is kept as a fallback for when the
// portal isn't available.
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import * as api from "./api";

export type ThemePref = "auto" | "light" | "dark";
type Resolved = "light" | "dark";

// Mirrored to localStorage so the inline script in index.html can set the
// theme before first paint — otherwise light-mode users get a dark flash
// while config.json is read over IPC.
const CACHE_KEY = "aquarium.theme.resolved";

let pref: ThemePref = "auto";
/// Desktop preference, or null when the system expresses none.
let systemScheme: Resolved | null = null;

export function normalizePref(v: unknown): ThemePref {
  return v === "light" || v === "dark" ? v : "auto";
}

function fromMediaQuery(): Resolved {
  if (window.matchMedia?.("(prefers-color-scheme: light)").matches) return "light";
  if (window.matchMedia?.("(prefers-color-scheme: dark)").matches) return "dark";
  return "dark"; // Aquarium's own default
}

function resolved(): Resolved {
  if (pref !== "auto") return pref;
  return systemScheme ?? fromMediaQuery();
}

function apply(): void {
  const theme = resolved();
  document.documentElement.dataset.theme = theme;
  try {
    localStorage.setItem(CACHE_KEY, theme);
  } catch {
    /* private mode / storage disabled — only costs us the no-flash startup */
  }
}

function setSystem(value: string): void {
  systemScheme = value === "dark" ? "dark" : value === "light" ? "light" : null;
}

export function getThemePref(): ThemePref {
  return pref;
}

/// Apply and persist a new preference.
export async function setThemePref(next: ThemePref): Promise<void> {
  pref = normalizePref(next);
  apply();
  await api.saveConfig({ theme: pref });
}

export async function initTheme(): Promise<void> {
  pref = normalizePref(api.getConfig().theme);
  try {
    setSystem(await invoke<string>("system_color_scheme"));
  } catch {
    systemScheme = null;
  }
  apply();

  // The desktop flipped light/dark while we're running.
  listen<string>("system-color-scheme", (ev) => {
    setSystem(ev.payload);
    if (pref === "auto") apply();
  }).catch(() => {});

  // Fallback path: no portal, but WebKit saw the GTK theme change.
  window
    .matchMedia?.("(prefers-color-scheme: dark)")
    .addEventListener("change", () => {
      if (pref === "auto" && systemScheme === null) apply();
    });
}
