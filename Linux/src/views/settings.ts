import { invoke } from "@tauri-apps/api/core";
import * as api from "../api";
import * as audio from "../audio";
import * as iptv from "../iptv";
import { cachedLineup, loadLineup, refreshNow as refreshLineup } from "../lineup";
import { getMixPoints, presetName } from "../stations";
import { el, clear, toast, openDialog, wordmark } from "../ui";
import {
  isAdaptiveEnabled,
  setAdaptiveEnabled,
  speedCheckEnabled,
  playerCtl,
  PICTURE_CONTROLS,
  AUDIO_DELAY_STEP,
  setLiveSetting,
  downloadPrefsChanged,
  getDownloadConcurrency,
  setDownloadConcurrency,
  MAX_DOWNLOAD_CONCURRENCY,
} from "../playback";
import { getThemePref, setThemePref, type ThemePref } from "../theme";
import { openMixDialog } from "./music";
import { seerrSettingsBlock } from "./seerrSettings";

// ---------- Panes ----------

/**
 * The panes, in the order the Apple app's Settings window has them. The id is
 * what follows `#/settings/` in the address, so a pane can be linked to.
 */
const PANES = [
  ["general", "General"],
  ["account", "Account"],
  ["video", "Video"],
  ["audio", "Audio"],
  ["subtitles", "Subtitles"],
  ["music", "Music"],
  ["livetv", "Live TV"],
  ["storage", "Storage"],
] as const;
type PaneId = (typeof PANES)[number][0];

const PANE_KEY = "aquarium.settings-pane";

function isPane(v: unknown): v is PaneId {
  return PANES.some(([id]) => id === v);
}

/** The pane to open on: the one asked for, else the one in the address, else
 *  the one last looked at. */
function startingPane(asked?: string): PaneId {
  const fromHash = location.hash.match(/^#\/settings\/([^/?]+)/)?.[1];
  let remembered: string | null = null;
  try {
    remembered = localStorage.getItem(PANE_KEY);
  } catch {
    // No memory of it; General will do.
  }
  for (const v of [asked, fromHash, remembered]) {
    const id = v?.toLowerCase();
    if (isPane(id)) return id;
  }
  return "general";
}

// ---------- Rows and controls ----------

let rowSeq = 0;

/**
 * One labelled setting. Every row on this page is a name, a sentence saying
 * what the setting actually does, and a control — the sentence being the part
 * that stops a settings page from being a list of words you have to guess at.
 * The control is tied to both, so a screen reader announces a switch by the
 * row's name rather than as "switch, on". `extra` goes under the sentence: a
 * status line the row's own button fills in.
 */
function row(label: string, explain: string, control: Node | null, extra: Node | null = null): HTMLElement {
  const id = `set-${++rowSeq}`;
  const lbl = el("div", { class: "lbl", id: `${id}-l` }, [label]);
  const sub = explain ? el("div", { class: "sub", id: `${id}-s` }, [explain]) : null;
  if (control instanceof HTMLElement) {
    const field = control.matches("input, select, [role=radiogroup]")
      ? control
      : control.querySelector("input, select");
    if (field && !field.hasAttribute("aria-label")) {
      field.setAttribute("aria-labelledby", lbl.id);
      if (sub) field.setAttribute("aria-describedby", sub.id);
    }
  }
  return el("div", { class: "settings-row" }, [el("div", {}, [lbl, sub, extra]), control]);
}

/** A sentence on its own at the foot of a block. */
function note(text: string, control: Node | null = null): HTMLElement {
  return el("div", { class: "settings-row" }, [el("div", { class: "sub" }, [text]), control]);
}

function block(title: string, rows: (Node | null)[], cls = ""): HTMLElement {
  return el("div", { class: `settings-block${cls ? ` ${cls}` : ""}` }, [el("h3", {}, [title]), ...rows]);
}

function saveFailed(): void {
  toast("Couldn't save that setting", "error");
}

/** A `<select>` bound to one config key, saved the moment it changes. */
function choice(
  cfg: any,
  key: string,
  options: [value: string, label: string][],
  onPicked?: (value: string) => void
): HTMLSelectElement {
  const select = el("select", {
    class: "control md",
    onChange: (ev: Event) => {
      const value = (ev.target as HTMLSelectElement).value;
      void api.saveConfig({ [key]: value }).catch(saveFailed);
      onPicked?.(value);
    },
  }, options.map(([value, label]) => el("option", { value }, [label]))) as HTMLSelectElement;
  select.value = typeof cfg[key] === "string" ? cfg[key] : options[0]![0];
  return select;
}

/**
 * Battery saver rendering. Stored as "auto" / "on" / "off"; configs from
 * before Automatic existed hold a plain true/false, which still mean on and
 * off. Unset is Automatic.
 */
function batteryRenderChoice(cfg: any): HTMLSelectElement {
  const v = cfg.battery_render;
  const current = v === true || v === "on" ? "on" : v === false || v === "off" ? "off" : "auto";
  const select = choice({ battery_render: current }, "battery_render", [
    ["auto", "Automatic — on battery or power saver"],
    ["off", "Off — best picture"],
    ["on", "Always — lighter on the GPU"],
  ]);
  return select;
}

/**
 * An on/off switch: a real checkbox, so Space flips it and Tab reaches it,
 * drawn as a track and a thumb.
 */
function switchControl(on: boolean, onChange: (on: boolean) => void): HTMLElement {
  const input = el("input", { type: "checkbox", role: "switch", class: "switch-input" }) as HTMLInputElement;
  input.checked = on;
  input.addEventListener("change", () => onChange(input.checked));
  return el("label", { class: "switch" }, [input, el("span", { class: "switch-track", "aria-hidden": "true" })]);
}

/** A switch bound to one true/false config key. */
function toggle(cfg: any, key: string, onPicked?: (value: boolean) => void): HTMLElement {
  return switchControl(cfg[key] === true, (on) => {
    void api.saveConfig({ [key]: on }).catch(saveFailed);
    onPicked?.(on);
  });
}

/**
 * A choice between a few things that are all worth seeing at once. Radio
 * buttons underneath, so the arrow keys move along it.
 */
function segmented<T extends string>(
  options: [value: T, label: string][],
  current: T,
  onPicked: (value: T) => void
): HTMLElement {
  const name = `seg-${++rowSeq}`;
  return el("div", { class: "segmented", role: "radiogroup" }, options.map(([value, label]) => {
    const input = el("input", { type: "radio", name, value }) as HTMLInputElement;
    input.checked = value === current;
    input.addEventListener("change", () => {
      if (input.checked) onPicked(value);
    });
    return el("label", { class: "segment" }, [input, el("span", {}, [label])]);
  }));
}

/**
 * A slider that applies to the running player as it moves and saves once the
 * movement stops. `format` turns the slider's number into what the readout
 * says. `scale` turns it into the value that is stored and sent to mpv, and
 * `unscale` reads a stored value back onto the slider, for a setting shown in
 * other units than it is kept in.
 */
function slider(
  cfg: any,
  key: string,
  prop: string,
  range: { min: number; max: number; step?: number; fallback: number },
  format: (v: number) => string,
  scale: (v: number) => number = (v) => v,
  unscale: (stored: number) => number = (v) => v
): { control: HTMLElement; reset: () => void } {
  const stored = Number(cfg[key]);
  const initial =
    cfg[key] != null && isFinite(stored)
      ? Math.max(range.min, Math.min(range.max, unscale(stored)))
      : range.fallback;
  const readout = el("span", { class: "settings-value" }, [format(initial)]);
  // `pb-range` carries the app's slider look (the two-tone track is drawn from
  // a `--fill` custom property rather than by the browser).
  const input = el("input", {
    type: "range",
    class: "pb-range settings-range",
    min: String(range.min),
    max: String(range.max),
    step: String(range.step ?? 1),
    value: String(initial),
  }) as HTMLInputElement;
  const paint = (v: number): void => {
    const pct = ((v - range.min) / (range.max - range.min)) * 100;
    input.style.setProperty("--fill", `${Math.max(0, Math.min(100, pct))}%`);
    readout.textContent = format(v);
    input.setAttribute("aria-valuetext", format(v));
  };
  paint(initial);
  input.addEventListener("input", () => {
    const v = parseFloat(input.value);
    paint(v);
    setLiveSetting(key, prop, scale(v));
  });
  return {
    control: el("div", { class: "settings-slider" }, [input, readout]),
    reset: () => {
      input.value = String(range.fallback);
      paint(range.fallback);
      setLiveSetting(key, prop, scale(range.fallback));
    },
  };
}

/**
 * Languages offered for the audio and subtitle defaults, as mpv matches them:
 * the values are the language tags carried in the media itself. Several
 * languages have two ISO codes in circulation (French is both `fre` and `fra`)
 * and files in the wild use either, so both are listed — mpv takes a preference
 * list and stops at the first track that matches any entry.
 */
const LANGUAGES: [code: string, name: string][] = [
  ["eng", "English"],
  ["spa", "Spanish"],
  ["fre,fra", "French"],
  ["ger,deu", "German"],
  ["ita", "Italian"],
  ["por", "Portuguese"],
  ["dut,nld", "Dutch"],
  ["swe", "Swedish"],
  ["nor", "Norwegian"],
  ["dan", "Danish"],
  ["fin", "Finnish"],
  ["pol", "Polish"],
  ["cze,ces", "Czech"],
  ["hun", "Hungarian"],
  ["gre,ell", "Greek"],
  ["rus", "Russian"],
  ["ukr", "Ukrainian"],
  ["tur", "Turkish"],
  ["ara", "Arabic"],
  ["heb", "Hebrew"],
  ["hin", "Hindi"],
  ["jpn", "Japanese"],
  ["kor", "Korean"],
  ["chi,zho", "Chinese"],
  ["tha", "Thai"],
  ["vie", "Vietnamese"],
];

/** How the app last saw a stream actually being decoded (see main.ts). */
function lastDecoder(): string | null {
  try {
    return localStorage.getItem("aquarium.hwdec-last");
  } catch {
    return null;
  }
}

const DECODER_NAMES: Record<string, string> = {
  vaapi: "VAAPI (GPU)",
  "vaapi-copy": "VAAPI (GPU, copy-back)",
  nvdec: "NVDEC (GPU)",
  "nvdec-copy": "NVDEC (GPU, copy-back)",
  vulkan: "Vulkan (GPU)",
  drm: "DRM (GPU)",
  no: "Software (CPU)",
};

// The player's remembered Fit / Fill (see `fillOn` in main.ts, which reads the
// same key when a film starts).
const FILL_KEY = "aquarium.fill";

function fillDefault(): boolean {
  try {
    return localStorage.getItem(FILL_KEY) === "1";
  } catch {
    return false;
  }
}

function setFillDefault(on: boolean): void {
  try {
    localStorage.setItem(FILL_KEY, on ? "1" : "0");
  } catch {
    // Not remembered, that's all.
  }
  // Whatever is playing now follows, and so does the player bar's Fill pill.
  void playerCtl.setProp("panscan", on ? 1 : 0).catch(() => {});
  document.getElementById("pb-fill")?.classList.toggle("on", on);
}

/** The picker's steps, in milliseconds: half a second either way. */
const AUDIO_DELAY_MAX_MS = 500;

function audioDelayName(ms: number): string {
  if (ms === 0) return "In step";
  return ms < 0 ? `Sound ${-ms} ms earlier` : `Sound ${ms} ms later`;
}

/**
 * The saved audio delay, the one the player's own − / + buttons move. Its
 * steps are theirs; a value set from the keyboard beyond the half second
 * offered here is listed as well, so opening Settings never changes it.
 */
function audioDelayChoice(cfg: any): HTMLSelectElement {
  const stepMs = Math.round(AUDIO_DELAY_STEP * 1000);
  const saved = Number(cfg.audio_delay);
  const current = isFinite(saved) ? Math.round(saved * 1000) : 0;
  const values: number[] = [];
  for (let ms = -AUDIO_DELAY_MAX_MS; ms <= AUDIO_DELAY_MAX_MS; ms += stepMs) values.push(ms);
  if (!values.includes(current)) {
    values.push(current);
    values.sort((a, b) => a - b);
  }
  const select = el("select", {
    class: "control md",
    onChange: () => {
      // Saves it and, when something is playing, moves the sound there and
      // then; with nothing playing the second half fails, which is fine.
      void playerCtl.setAudioDelay(parseInt(select.value, 10) / 1000).catch(() => {});
    },
  }, values.map((ms) => el("option", { value: String(ms) }, [audioDelayName(ms)]))) as HTMLSelectElement;
  select.value = String(current);
  return select;
}

// Subtitle size is kept as mpv's font size, where 38 is the size a track asks
// for; the slider shows it as a percentage of that, as the Apple app does.
const SUB_FONT_BASE = 38;

/** How downloads behave on this laptop: how many at once, the network they
 *  use, the server's encoder, whether the machine stays up for them, and
 *  where they are kept. */
function downloadsBlock(cfg: any, downloadsDir: string): HTMLElement {
  const changed = (): void => downloadPrefsChanged();
  const parallel = el("select", {
    class: "control md",
    onChange: () => setDownloadConcurrency(parseInt(parallel.value, 10)),
  }, Array.from({ length: MAX_DOWNLOAD_CONCURRENCY }, (_, i) =>
    el("option", { value: String(i + 1) }, [i === 0 ? "1 at a time" : `${i + 1} at a time`])
  )) as HTMLSelectElement;
  parallel.value = String(getDownloadConcurrency());
  return block("Downloads", [
    row(
      "Simultaneous downloads",
      "How many transfers run at once — the Parallel choice on the Downloads page. One at a time is kindest to a server that has to transcode each of them.",
      parallel
    ),
    row(
      "Only download on unmetered connections",
      "Downloads wait while the connection is metered — a phone hotspot, mobile broadband, or a network marked metered in GNOME's settings — and carry on from where they stopped when it isn't.",
      toggle(cfg, "downloads_unmetered_only", changed)
    ),
    row(
      "Transcode one at a time",
      "Converted downloads run one after another so the server's encoder isn't shared between them. Original-quality files still download side by side, up to the limit above.",
      toggle(cfg, "downloads_transcode_serial", changed)
    ),
    row(
      "Keep the laptop awake while downloading",
      "Stops the laptop suspending on idle while a download runs. The screen still dims and locks.",
      // On unless turned off, so the switch reads an unset key as on.
      toggle({ downloads_keep_awake: cfg.downloads_keep_awake !== false }, "downloads_keep_awake", changed)
    ),
    row(
      "Kept in",
      downloadsDir,
      el("button", {
        class: "btn small",
        onClick: () =>
          void invoke("downloads_reveal", { itemIds: [] }).catch((e) =>
            toast(typeof e === "string" ? e : "Couldn't open the downloads folder", "error")
          ),
      }, ["Show in Files"])
    ),
  ]);
}

/**
 * Settings, a pane at a time. `pane` is the part of the address after
 * `#/settings/`; without it the address is read here, and failing that the
 * pane last looked at opens.
 */
export async function renderSettings(root: HTMLElement, onLogout: () => void, pane?: string): Promise<void> {
  clear(root);
  const s = api.getSession();
  const cfg = api.getConfig();
  // Put on the page before the first await, so a render that has since been
  // navigated away from (or overtaken by a newer one) can tell, and stops
  // instead of appending its blocks to someone else's page.
  const title = el("h1", { class: "page-title" }, ["Settings"]);
  root.append(title);
  const info: any = await invoke("app_info").catch(() => ({}));
  if (!document.contains(title)) return;

  // ---------- The pane list and the panes ----------
  const tabs = new Map<PaneId, HTMLButtonElement>();
  const panels = new Map<PaneId, HTMLElement>();
  let shown: PaneId | null = null;

  const show = (id: PaneId, byHand: boolean): void => {
    if (id === shown) return;
    shown = id;
    for (const [pid, tab] of tabs) {
      const on = pid === id;
      tab.classList.toggle("active", on);
      tab.setAttribute("aria-selected", String(on));
      // One stop in the Tab order for the whole list; the arrows move in it.
      tab.tabIndex = on ? 0 : -1;
      panels.get(pid)!.toggleAttribute("hidden", !on);
    }
    try {
      localStorage.setItem(PANE_KEY, id);
    } catch {
      // The pane just isn't remembered.
    }
    if (!byHand) return;
    // The address follows the pane without a navigation of its own: the page
    // is not rebuilt, and Back still leaves Settings in one step.
    history.replaceState(history.state, "", `#/settings/${id}`);
    root.scrollTo({ top: 0, behavior: "instant" as ScrollBehavior });
  };

  const paneList = el("div", { class: "settings-panes", role: "tablist", "aria-label": "Settings" });
  const paneBody = el("div", { class: "settings-pane-body" });
  for (const [id, name] of PANES) {
    const tab = el("button", {
      class: "settings-pane-tab",
      type: "button",
      role: "tab",
      id: `settings-tab-${id}`,
      "aria-controls": `settings-pane-${id}`,
      onClick: () => show(id, true),
    }, [name]) as HTMLButtonElement;
    const panel = el("section", {
      class: "settings-pane",
      role: "tabpanel",
      id: `settings-pane-${id}`,
      "aria-labelledby": `settings-tab-${id}`,
      hidden: "",
    });
    tabs.set(id, tab);
    panels.set(id, panel);
    paneList.append(tab);
    paneBody.append(panel);
  }
  // The list is a column in a wide window and a strip in a narrow one, so
  // either pair of arrows steps through it.
  paneList.addEventListener("keydown", (ev) => {
    const order = PANES.map(([id]) => id);
    const at = order.indexOf(shown ?? "general");
    let to = -1;
    if (ev.key === "ArrowDown" || ev.key === "ArrowRight") to = (at + 1) % order.length;
    else if (ev.key === "ArrowUp" || ev.key === "ArrowLeft") to = (at - 1 + order.length) % order.length;
    else if (ev.key === "Home") to = 0;
    else if (ev.key === "End") to = order.length - 1;
    if (to < 0) return;
    ev.preventDefault();
    show(order[to]!, true);
    tabs.get(order[to]!)!.focus();
  });
  root.append(el("div", { class: "settings-layout" }, [paneList, paneBody]));
  show(startingPane(pane), false);
  const into = (id: PaneId, ...blocks: (Node | null)[]): void => {
    panels.get(id)!.append(...blocks.filter((b): b is Node => b != null));
  };

  // ---------- General ----------
  // Appearance is applied immediately, no Save needed.
  into(
    "general",
    block("Appearance", [
      row(
        "Theme",
        "System follows your desktop's light/dark setting. The video player's own on-screen controls are always dark.",
        segmented<ThemePref>(
          [
            ["auto", "System"],
            ["light", "Light"],
            ["dark", "Dark"],
          ],
          getThemePref(),
          (value) => {
            void setThemePref(value).catch(() => toast("Couldn't save appearance setting", "error"));
          }
        )
      ),
    ]),
    block("Home", [
      row(
        "Hide Continue Watching",
        "Leaves the row of part-watched episodes and films off Home, keeping just Next Up, which lists the next episode of each show you're following. Nothing is forgotten: a title you stopped partway through still resumes from where you left it.",
        toggle(cfg, "hide_continue_watching")
      ),
    ]),
    // Next Up: what the server's Next Up offers, and for how long. Sent with
    // every Next Up request, so the row follows at once.
    block("Next Up", [
      row(
        "Keep shows on Next Up",
        "How long a show stays on Next Up after you last watched anything in it. Past that, Aquarium takes it off Next Up on the server as well, so Jellyfin's other apps stop showing it too; nothing is marked watched. Playing an episode or adding the show to Next Up brings it back. Forever keeps a show for as long as it has an episode left.",
        choice(
          { next_up_days: String(cfg.next_up_days ?? "0") },
          "next_up_days",
          api.NEXT_UP_DAY_CHOICES.map((d) => [String(d), api.nextUpDaysLabel(d)] as [string, string]).sort((a, b) =>
            a[0] === "0" ? 1 : b[0] === "0" ? -1 : Number(a[0]) - Number(b[0])
          )
        )
      ),
      row(
        "Include episodes in progress",
        "Lets Next Up offer an episode you're partway through, as Continue Watching does. Off, a show whose next episode you've started is left to Continue Watching until you finish it.",
        toggle({ next_up_in_progress: cfg.next_up_in_progress !== false }, "next_up_in_progress")
      ),
      row(
        "Include shows you're rewatching",
        "Keeps a show you're watching again on Next Up: after an episode you've already seen, it offers the one after it, watched or not.",
        toggle(cfg, "next_up_rewatching")
      ),
    ]),
    block("Keyboard", [
      note(
        "Video plays embedded in the app window. Shortcuts: Space pause · ←/→ seek · ↑/↓ volume · m mute · [ / ] speed · z / Z subtitle delay · f fullscreen · Esc exit. Media keys on your keyboard control playback too, and the episode appears in your desktop's own media controls. Hover the video for mpv's on-screen controls."
      ),
    ]),
    block(
      "About",
      [
        el("div", { class: "about-row" }, [
          el("img", { src: "/aquarium-logo.svg", alt: "", width: "48", height: "48" }),
          el("div", {}, [
            el("div", { class: "about-name" }, [
              wordmark(),
              el("span", { class: "about-version" }, [info.version ? `v${info.version}` : ""]),
            ]),
            el("div", { class: "sub" }, ["A lightweight Jellyfin client. Playback engine: mpv."]),
          ]),
        ]),
        row(
          "mpv",
          `Running ${info.mpv ?? "libmpv2"}, linked in-process — no separate mpv install needed.`,
          null
        ),
      ],
      "about-block"
    )
  );

  // ---------- Account ----------
  const signOut = async (btn: HTMLButtonElement): Promise<void> => {
    btn.disabled = true;
    btn.textContent = "Signing out…";
    try {
      const res = await api.logout();
      // Signing out only means something if the server agrees. When it
      // can't be reached the token is still live over there, and the
      // user is the one who needs to know that.
      if (!res.revoked) {
        toast(
          res.pending
            ? "Signed out here, but the server couldn't be reached to end the session — Aquarium will keep retrying."
            : "Signed out here, but the session could not be ended on the server. Revoke this device in Jellyfin → Dashboard → Devices.",
          "error"
        );
      }
    } catch {
      toast("Sign out failed", "error");
    }
    onLogout();
  };
  const serverName = s?.server ?? "this server";
  const offline = api.isOffline();
  const pill = (ok: boolean, text: string, dot = false): HTMLElement =>
    el("span", { class: `sync-pill${ok ? " ok" : " warn"}` }, [
      dot ? el("span", { class: "status-dot", "aria-hidden": "true" }) : null,
      text,
    ]);
  into(
    "account",
    block("Server", [
      row(
        s?.server ?? "Not connected",
        s ? `Signed in as ${s.userName}` : "",
        el("button", {
          class: "btn danger",
          onClick: (ev: Event) => {
            const btn = ev.currentTarget as HTMLButtonElement;
            // One click used to end the session. It is asked first now, as
            // anything that needs a password to undo should be.
            openDialog({
              title: `Sign out of ${serverName}?`,
              body: [
                el("p", {}, [
                  "Your session on the server is ended and this account is forgotten on this device. Downloads stay where they are; signing in again asks for the password.",
                ]),
              ],
              actions: [
                { label: "Cancel", primary: true },
                { label: "Sign Out", danger: true, run: () => void signOut(btn) },
              ],
            });
          },
        }, ["Sign out…"])
      ),
      s
        ? row(
            "Status",
            "Whether the server answered the last time Aquarium asked. Offline means the address didn't reply — the server is down, or this computer can't reach it from where it is.",
            pill(!offline, offline ? "Offline" : "Connected", true)
          )
        : null,
      // Whether the link to the server is encrypted. A LAN-only server over
      // plain HTTP is a defensible choice; not knowing which one you have is
      // not, and this used to be invisible.
      row(
        "Connection",
        info.server_secure
          ? "Encrypted (HTTPS). Your password and access token are never sent in the clear."
          : "Unencrypted (HTTP). Anything on the network path can read your access token and what you watch. Put Jellyfin behind HTTPS if it's reachable from outside your home network.",
        pill(!!info.server_secure, info.server_secure ? "HTTPS" : "HTTP")
      ),
      // The server's own id, recorded at sign-in. Re-checked before the app
      // authenticates, so an edited config.json can't quietly redirect the
      // token to somewhere else.
      row(
        "Server identity",
        info.server_pinned
          ? "Pinned. If this address ever answers as a different Jellyfin server, Aquarium stops instead of signing in to it."
          : "Not pinned yet — it will be recorded the next time this server answers.",
        pill(!!info.server_pinned, info.server_pinned ? "Pinned" : "Unpinned")
      ),
      // Where the access token actually lives. It used to be written in
      // plaintext into config.json; it now goes to the desktop keyring, and
      // when that isn't available the user deserves to know it fell back.
      row(
        "Access token",
        info.token_storage === "keyring"
          ? "Stored in your desktop keyring (Secret Service). Never written to the config file, and never sent in a URL."
          : "Your desktop keyring is unavailable, so the token is stored in ~/.config/aquarium/config.json. Unlock or install a keyring (gnome-keyring, KWallet) to secure it.",
        pill(info.token_storage === "keyring", info.token_storage === "keyring" ? "Keyring" : "Config file")
      ),
      // A previous sign-out never got confirmed by the server, so that token is
      // still valid over there. The retry runs at every launch, but the user
      // may want to kill it from the Jellyfin dashboard rather than wait.
      info.revocation_pending
        ? row(
            "Unfinished sign-out",
            "A previous sign-out couldn't reach the server, so that session may still be active on it. Aquarium retries at every launch; to end it now, remove this device in Jellyfin → Dashboard → Devices.",
            pill(false, "Pending")
          )
        : null,
    ])
  );

  // Accounts: everyone signed in on this device, switched between without a
  // password, each with its own token in the keyring.
  const accountsBlock = block("Accounts", []);
  into("account", accountsBlock);
  const drawAccounts = async (): Promise<void> => {
    const list = await api.listAccounts();
    if (!document.contains(accountsBlock)) return;
    accountsBlock.querySelectorAll(".settings-row").forEach((n) => n.remove());
    for (const a of list) {
      const where = a.server_name || a.server.replace(/^https?:\/\//, "");
      const controls = a.current
        ? el("span", { class: "sync-pill ok" }, ["In use"])
        : el("div", { class: "settings-actions" }, [
            el("button", {
              class: "btn small",
              title: "Sign in as this account. Switching is instant and needs no password.",
              onClick: () => document.dispatchEvent(new CustomEvent("aquarium-account-switch", { detail: { key: a.key } })),
            }, ["Switch"]),
            el("button", {
              class: "btn small danger",
              onClick: () =>
                openDialog({
                  title: `Sign ${a.user_name} out of this device?`,
                  body: [el("p", {}, [`Their session on ${where} is ended and the account is removed from this device. The account in use isn't touched.`])],
                  actions: [
                    { label: "Cancel", primary: true },
                    {
                      label: "Sign Out",
                      danger: true,
                      run: async () => {
                        try {
                          const r = await api.forgetAccount(a.key);
                          if (!r.revoked) toast("Removed here, but the server couldn't be reached to end that session.", "error");
                        } catch (e: any) {
                          toast(e.message ?? "Couldn't sign that account out", "error");
                        }
                        void drawAccounts();
                      },
                    },
                  ],
                }),
            }, ["Sign Out of This Device"]),
          ]);
      accountsBlock.append(row(a.user_name || "Unnamed user", where, controls));
    }
    accountsBlock.append(
      row(
        "Add Account…",
        "Sign in to another user on this server, or to a different server, without signing this one out. Switching is instant and needs no password: each account keeps its own token in the keyring.",
        el("button", {
          class: "btn small",
          onClick: () => document.dispatchEvent(new CustomEvent("aquarium-add-account")),
        }, ["Add Account…"])
      )
    );
  };
  await drawAccounts();
  if (!document.contains(title)) return;

  // Requests: a Seerr server beside this Jellyfin server, signed in to with
  // the account in use (views/seerrSettings.ts).
  if (s) into("account", seerrSettingsBlock());

  // Quick Connect, the approving side: a device signing in to this server
  // shows a code, and entering it here signs that device in as this user.
  const qcInput = el("input", {
    class: "control md qc-code",
    type: "text",
    inputmode: "numeric",
    autocomplete: "off",
    placeholder: "6-digit code",
    maxlength: "6",
    "aria-label": "Quick Connect code",
  }) as HTMLInputElement;
  const qcOutcome = el("div", { class: "sub", hidden: "" });
  const qcButton = el("button", { class: "btn small", disabled: "" }, ["Approve…"]) as HTMLButtonElement;
  const qcSay = (text: string, tone: "ok" | "warn" | "bad") => {
    qcOutcome.textContent = text;
    qcOutcome.className = `sub qc-outcome ${tone}`;
    qcOutcome.removeAttribute("hidden");
  };
  qcInput.addEventListener("input", () => {
    // Digits only, and the six of them.
    const digits = qcInput.value.replace(/\D/g, "").slice(0, 6);
    if (digits !== qcInput.value) qcInput.value = digits;
    qcButton.disabled = digits.length !== 6 || api.isOffline();
    qcOutcome.setAttribute("hidden", "");
  });
  const qcConfirm = () => {
    const code = qcInput.value;
    if (code.length !== 6) return;
    openDialog({
      title: `Sign another device in as ${s?.userName ?? "you"}?`,
      body: [el("p", {}, ["Only approve a code you can see on your own device's screen right now. Whoever holds the device showing it gets full access to your account."])],
      actions: [
        { label: "Cancel", primary: true },
        {
          label: `Approve ${code}`,
          run: async () => {
            qcButton.disabled = true;
            try {
              if (await api.authorizeQuickConnect(code)) {
                qcInput.value = "";
                qcSay("The other device is signing in now.", "ok");
              } else {
                qcSay("The server doesn't know that code. Check the digits, or ask for a new code — they expire after ten minutes.", "warn");
              }
            } catch (e: any) {
              qcSay(e.message ?? String(e), "bad");
            }
            qcButton.disabled = qcInput.value.length !== 6;
          },
        },
      ],
    });
  };
  qcButton.addEventListener("click", qcConfirm);
  qcInput.addEventListener("keydown", (ev) => {
    if (ev.key === "Enter") qcConfirm();
  });
  into(
    "account",
    block("Quick Connect", [
      row(
        "Approve a code",
        "Another device signing in to this server — a TV, say — can show a code instead of asking for a password. Enter the code here and it is signed in as you.",
        el("div", { class: "settings-actions" }, [qcInput, qcButton]),
        qcOutcome
      ),
    ])
  );

  // ---------- Video ----------
  // What the last stream was actually decoded with. Asking for hardware
  // decoding and getting it are different things — mpv falls back to the CPU
  // without saying so, and the only symptom is a hot, loud machine.
  const seen = lastDecoder();
  const decoderPill = seen
    ? el("span", { class: `sync-pill${seen === "no" ? " warn" : " ok"}` }, [
        DECODER_NAMES[seen] ?? seen,
      ])
    : el("span", { class: "sync-pill" }, ["Not measured yet"]);

  const pictureSliders = PICTURE_CONTROLS.map((control) => ({
    control,
    ui: slider(
      cfg,
      control.key,
      control.prop,
      { min: -50, max: 50, fallback: 0 },
      (v) => `${v > 0 ? "+" : ""}${Math.round(v)}`
    ),
  }));
  const zoom = slider(
    cfg,
    "video_zoom",
    "video-zoom",
    { min: 0, max: 40, fallback: 0 },
    (v) => `${Math.round(v)}%`,
    // The slider is in percent; mpv's scale, and what is saved, is a fraction.
    (v) => v / 100,
    (stored) => Math.round(stored * 100)
  );
  const aspectChoice = choice(cfg, "video_aspect", [
    ["", "As the file says"],
    ["16:9", "16:9 — widescreen"],
    ["4:3", "4:3 — classic"],
    ["1.85:1", "1.85:1 — flat"],
    ["2.35:1", "2.35:1 — cinemascope"],
    ["2.39:1", "2.39:1 — scope"],
  ]);

  into(
    "video",
    block("Quality", [
      row(
        "Adapt quality automatically",
        "Drops to a smaller stream when playback keeps stalling or the machine can't decode fast enough, and climbs back after the connection has been steady for a while. It never goes above the quality you picked, and never touches downloaded files or Live TV. Off keeps your choice.",
        switchControl(isAdaptiveEnabled(), setAdaptiveEnabled)
      ),
      row(
        "Check the connection first",
        "Times a short download from the server before a stream opens and starts at the quality the connection carries, rather than at the original and stepping down from there. Skipped when you have picked a quality yourself, for the next episode in a run, and for Live TV.",
        toggle({ speed_check: speedCheckEnabled() }, "speed_check")
      ),
    ]),
    block("Picture", [
      row(
        "Framing",
        "Fill is how you put a 2.35:1 film on a 16:9 screen without watching it between black bars. It does cut the edges of the frame off. Also reachable from the player bar, so it can be judged against what's on screen.",
        segmented<"fit" | "fill">(
          [
            ["fit", "Fit"],
            ["fill", "Fill"],
          ],
          fillDefault() ? "fill" : "fit",
          (v) => setFillDefault(v === "fill")
        )
      ),
      ...pictureSliders.map((p) => row(p.control.label, "", p.ui.control)),
      row(
        "Aspect ratio",
        "Override what the file claims. Only needed for material that's tagged wrong — a stretched or squashed picture that no player gets right.",
        aspectChoice
      ),
      row(
        "Zoom",
        "Crops in on the picture about its centre. It does cut the edges of the frame off.",
        zoom.control
      ),
      row(
        "Night mode",
        "Evens out the distance between whispered dialogue and the next explosion, so an action film stays watchable at a volume that won't wake the house. Applies to the next thing that starts playing.",
        toggle(cfg, "night_mode")
      ),
      note(
        "Picture settings apply immediately, and are also reachable from the player bar while something is playing.",
        el("button", {
          class: "btn",
          onClick: () => {
            for (const p of pictureSliders) p.ui.reset();
            zoom.reset();
            aspectChoice.value = "";
            void api.saveConfig({ video_aspect: "" });
            toast("Picture reset", "ok");
          },
        }, ["Reset picture"])
      ),
    ]),
    block("Player", [
      row(
        "Hardware acceleration",
        "Decoding video on the GPU instead of the processor. Automatic prefers VAAPI on AMD and Intel and NVDEC on NVIDIA, and falls back to the processor for anything they can't take. Change this only if a particular file plays badly — Vulkan decode is newer and still produces a black picture with some drivers.",
        choice(cfg, "hwdec", [
          ["auto", "Automatic (recommended)"],
          ["vaapi", "VAAPI — AMD, Intel"],
          ["nvdec", "NVDEC — NVIDIA"],
          ["vulkan", "Vulkan"],
          ["off", "Off — decode on the processor"],
        ])
      ),
      row(
        "Last decoded with",
        seen
          ? "What the most recent stream actually used. Software here, with hardware acceleration set to automatic, means no GPU path would take the file — usually an unusual codec, or drivers without the matching decoder installed."
          : "Play something and this will report which decoder was used, rather than which one was asked for.",
        decoderPill
      ),
      row(
        "Smooth motion",
        "24fps film shown on a 60Hz screen has to hold every other frame for an extra beat, which is the stutter you see on slow camera pans. This resamples playback onto the display's own refresh rate and blends the frames between — noticeably smoother on panning shots, at the cost of some GPU load. Try turning it off if playback stutters or the fans spin up.",
        toggle(cfg, "smooth_motion")
      ),
      row(
        "Battery saver rendering",
        "Draws the picture with the simplest scaler and 8-bit intermediates instead of mpv's default high-quality chain. On a HiDPI screen every scaler pass runs at the panel's full resolution, so this is a real saving on the GPU, and the difference in the picture is hard to see from viewing distance. Automatic switches it on while the computer runs on battery or in power-saver mode, and off again when it doesn't, even partway through a film.",
        batteryRenderChoice(cfg)
      ),
      row(
        "Skip by",
        "How far the two skip buttons jump, along with ← and → and a double-tap on the left or right of the picture.",
        choice({ player_skip_interval: String(cfg.player_skip_interval ?? "10") }, "player_skip_interval", [
          ["10", "10 seconds"],
          ["15", "15 seconds"],
          ["30", "30 seconds"],
        ])
      ),
      row(
        "Hide controls after",
        "How long the controls stay up in fullscreen after the pointer last moved. They never hide while a panel is open or the pointer is over them.",
        choice({ player_hide_after: String(cfg.player_hide_after ?? "2") }, "player_hide_after", [
          ["2", "2 seconds"],
          ["4", "4 seconds"],
          ["6", "6 seconds"],
          ["10", "10 seconds"],
        ])
      ),
      row(
        "Show time remaining",
        "The time at the right of the timeline counts down to the end; off, it shows the whole length. Clicking it in the player flips this too.",
        toggle(cfg, "player_show_remaining")
      ),
    ]),
    block("Playing", [
      row(
        "Resume where I left off",
        "Opens something you have already started at the point you stopped, instead of from the beginning.",
        toggle({ resume_playback: cfg.resume_playback !== false }, "resume_playback")
      ),
      row(
        "Play the next episode automatically",
        "The Up Next card appears over the closing stretch of an episode either way — turning this off just means it won't start on its own.",
        toggle({ autoplay_next: cfg.autoplay_next !== false }, "autoplay_next")
      ),
    ])
  );

  // ---------- Subtitles ----------
  // Which track a file opens with, before anyone touches anything. Applies to
  // the next thing that starts playing, not to what's on screen now.
  const subSize = slider(
    cfg,
    "sub_font_size",
    "sub-font-size",
    { min: 60, max: 180, step: 5, fallback: 100 },
    (v) => `${Math.round(v)}%`,
    (pct) => Math.round(SUB_FONT_BASE * pct) / 100,
    // A size saved before this was a percentage lands on the nearest step,
    // or the end of the range; it is only rewritten if the slider is moved.
    (size) => Math.round(((size / SUB_FONT_BASE) * 100) / 5) * 5
  );
  const subPos = slider(
    cfg,
    "sub_pos",
    "sub-pos",
    { min: 60, max: 100, fallback: 100 },
    (v) => (v >= 99 ? "Bottom" : `${Math.round(100 - v)} up`)
  );
  into(
    "subtitles",
    block("Language", [
      row(
        "Subtitles",
        "“Never” is the setting to pick if you don't use subtitles: it stops them being switched on by a file that ships with them enabled, which no other option here can do. “Forced only” shows just the track that translates signs and the odd line of foreign dialogue, whatever language the sound is in.",
        choice(cfg, "sub_lang", [
          ["", "Only when the file turns them on"],
          ["off", "Never — no subtitles"],
          ["forced", "Forced only — signs and foreign lines"],
          ...LANGUAGES.map(([code, name]) => [code, name] as [string, string]),
        ])
      ),
      row(
        "Forced subtitles",
        "With a subtitle language chosen: when the audio is already in your preferred language, show only the forced track — the one that translates signs and the occasional line of foreign dialogue — instead of subtitling the whole thing.",
        toggle(cfg, "subs_forced_only")
      ),
      note(
        "Changing a track during an episode is remembered for that series on its own, and the next episode opens the same way."
      ),
    ]),
    block("Appearance", [
      row(
        "Size",
        "How large subtitles are drawn, against the size the track asks for. Applies as you drag it, so it can be judged against what's playing.",
        subSize.control
      ),
      row(
        "Position",
        "Lifts subtitles off the bottom edge — useful on a film with burnt-in captions already down there, or when the player bar is in the way.",
        subPos.control
      ),
      row(
        "Background",
        "An outline is mpv's default and disappears into a bright scene now and then. A solid strip behind the text always stays readable, at the cost of covering a band of the picture.",
        choice(cfg, "sub_bg", [
          ["outline", "Outline"],
          ["shadow", "Drop shadow"],
          ["box", "Solid strip"],
        ], (value) => {
          // `choice` has already saved the setting; this only mirrors it onto a
          // running player, using the same three properties prefs.rs passes on
          // the command line for the next one.
          const spec: Record<string, [back: string, border: string, shadow: string]> = {
            outline: ["#00000000", "3", "0"],
            shadow: ["#00000000", "1.5", "2"],
            box: ["#C0000000", "0", "0"],
          };
          const [back, border, shadow] = spec[value] ?? spec.outline!;
          void playerCtl.setProp("sub-back-color", back).catch(() => {});
          void playerCtl.setProp("sub-border-size", border).catch(() => {});
          void playerCtl.setProp("sub-shadow-offset", shadow).catch(() => {});
        })
      ),
    ])
  );

  // ---------- Music ----------
  const mixPreset = el("span", { class: "settings-value" }, [presetName(getMixPoints())]);
  into(
    "music",
    block("Playing", [
      row(
        "Normalize volume",
        "Sound Check: level songs against each other using the loudness measured for each (ReplayGain), so a quiet album isn't followed by a loud one. The same switch as Sound Check in the music player.",
        switchControl(audio.soundCheckOn(), (on) => {
          void audio.setSoundCheck(on).catch(saveFailed);
        })
      ),
    ]),
    block("Stations", [
      row(
        "Mixes",
        "Who builds a mix when you press Instant Mix or start a station. Aquarium's own stations score songs by artist, genre and era (tuned with Station Mix); Jellyfin Instant Mix plays what the server sends, in the server's order.",
        choice(cfg, "music_mix_source", [
          ["aquarium", "Aquarium"],
          ["jellyfin", "Jellyfin Instant Mix"],
        ]),
        note(
          "A Jellyfin server running the AudioMuse-AI plugin answers Instant Mix with AudioMuse's similarity automatically. Without a server connection, Aquarium always uses its own mix from your downloads."
        )
      ),
      row(
        "Station mix",
        "Twenty points to spend on what stations favour — what you star and play most, or what you have never played. Every station uses them.",
        el("div", { class: "settings-actions" }, [
          mixPreset,
          el("button", {
            class: "btn small",
            onClick: () => {
              openMixDialog();
              // The dialog saves for itself and says nothing on closing, so
              // the name beside the button is read again once focus is back
              // here — a moment after, because its Save is still on its way
              // to the config when the dialog hands focus back.
              window.addEventListener(
                "focusin",
                () => {
                  window.setTimeout(() => {
                    mixPreset.textContent = presetName(getMixPoints());
                  }, 400);
                },
                { once: true }
              );
            },
          }, ["Station Mix…"]),
        ])
      ),
    ])
  );

  // ---------- Live TV ----------
  // Either Jellyfin's own Live TV, or the user's own playlist and guide. The
  // second exists because a tuner Jellyfin is unhappy with still works
  // perfectly well when mpv is pointed straight at it.
  const m3uInput = el("input", {
    class: "control lg",
    type: "text",
    placeholder: "https://example.com/playlist.m3u",
    value: cfg.livetv_m3u ?? "",
  }) as HTMLInputElement;

  const xmltvInput = el("input", {
    class: "control lg",
    type: "text",
    placeholder: "https://example.com/guide.xml.gz  (optional)",
    value: cfg.livetv_xmltv ?? "",
  }) as HTMLInputElement;

  const uaInput = el("input", {
    class: "control lg",
    type: "text",
    placeholder: iptv.DEFAULT_USER_AGENT,
    value: cfg.livetv_user_agent ?? "",
    spellcheck: "false",
  }) as HTMLInputElement;
  uaInput.addEventListener("change", () => {
    void api
      .saveConfig({ livetv_user_agent: uaInput.value.trim() || null })
      .then(() => iptv.invalidate())
      .catch(saveFailed);
  });

  const refreshChoice = choice(
    { livetv_refresh_min: String(iptv.refreshMinutes()) },
    "livetv_refresh_min",
    [
      ["0", "Never — only when asked"],
      ["15", "Every 15 minutes"],
      ["30", "Every 30 minutes"],
      ["60", "Every hour"],
      ["180", "Every 3 hours"],
      ["360", "Every 6 hours"],
      ["720", "Every 12 hours"],
      ["1440", "Every 24 hours"],
    ]
  );

  const liveStatus = el("div", { class: "sub" }, [""]);
  const customRows = el("div", { class: "settings-sub" });

  /** "Last read: 124 channels · 98 with artwork · 3,410 programmes in the
   *  guide · 2:14 PM". A column of blank logos has two causes — the artwork
   *  wouldn't load, or the playlist never named any — and this tells them
   *  apart. */
  const lastReadLine = el("div", { class: "sub" }, [""]);
  const syncLastRead = (): void => {
    if (!iptv.isCustom()) {
      const n = cachedLineup()?.length;
      lastReadLine.textContent = n != null ? `${n} channel${n === 1 ? "" : "s"} from the server.` : "";
      return;
    }
    const r = iptv.lastRead();
    if (!r) {
      lastReadLine.textContent = "Not read yet this session — open Live TV, or Refresh now.";
      return;
    }
    const art =
      r.withLogos === 0
        ? "no channel artwork — the playlist has no tvg-logo and the guide no <icon>"
        : r.withLogos < r.channels
          ? `${r.withLogos} with artwork`
          : "all with artwork";
    const when = new Date(r.at).toLocaleString([], { weekday: "short", hour: "numeric", minute: "2-digit" });
    lastReadLine.textContent =
      `Last read: ${r.channels} channel${r.channels === 1 ? "" : "s"} · ${art} · ` +
      `${r.programs.toLocaleString()} programme${r.programs === 1 ? "" : "s"} in the guide · ${when}.`;
  };

  const refreshNow = async (btn: HTMLButtonElement): Promise<void> => {
    btn.disabled = true;
    const was = btn.textContent;
    btn.textContent = "Refreshing…";
    try {
      await refreshLineup();
      syncLastRead();
      toast("Live TV refreshed", "ok");
    } catch (e: any) {
      lastReadLine.textContent = e?.message ?? String(e);
      toast("Couldn't refresh Live TV", "error");
    } finally {
      btn.disabled = false;
      btn.textContent = was;
    }
  };

  /** Load every channel's logo the way the guide does and count what came
   *  back, so "why are my logos blank" has an answer rather than a guess. */
  const artStatus = el("div", { class: "sub" }, [""]);
  const checkArtwork = async (btn: HTMLButtonElement): Promise<void> => {
    btn.disabled = true;
    const was = btn.textContent;
    btn.textContent = "Checking…";
    artStatus.textContent = "";
    try {
      const channels = await loadLineup();
      const r = await probeArtwork(channels, (done, total) => {
        artStatus.textContent = `Checking ${done} of ${total}…`;
      });
      const parts = [`${r.loaded} of ${r.channels} channel logos loaded`];
      if (r.missing) parts.push(`${r.missing} name no logo`);
      if (r.failed.length) {
        const some = r.failed.slice(0, 3).join(", ");
        parts.push(`${r.failed.length} wouldn't load (${some}${r.failed.length > 3 ? ", …" : ""})`);
      }
      artStatus.textContent = parts.join(" · ") + ".";
    } catch (e: any) {
      artStatus.textContent = e?.message ?? String(e);
    } finally {
      btn.disabled = false;
      btn.textContent = was;
    }
  };

  const syncLiveRows = (v: string): void => {
    customRows.style.display = v === "custom" ? "" : "none";
  };

  const sourceSelect = choice(
    cfg,
    "livetv_source",
    [
      ["jellyfin", "Jellyfin's Live TV"],
      ["custom", "My own M3U playlist"],
    ],
    (v) => {
      syncLiveRows(v);
      iptv.invalidate();
      syncLastRead();
      document.dispatchEvent(new CustomEvent("aquarium-nav-refresh"));
    }
  );

  /** Save both addresses, then actually load them and say what came back —
   *  a playlist that saves fine and resolves to nothing is the failure worth
   *  catching here rather than on the Live TV page. */
  const checkSources = async (btn: HTMLButtonElement): Promise<void> => {
    btn.disabled = true;
    const was = btn.textContent;
    btn.textContent = "Checking…";
    liveStatus.textContent = "";
    try {
      await api.saveConfig({
        livetv_m3u: m3uInput.value.trim() || null,
        livetv_xmltv: xmltvInput.value.trim() || null,
      });
      iptv.invalidate();
      const r = await iptv.describe();
      // The guide and the player's Channels panel read the new line-up.
      await refreshLineup().catch(() => {});
      syncLastRead();
      const guide = r.programs
        ? `${r.programs.toLocaleString()} programmes across ${r.matched} of them`
        : "no guide data matched";
      liveStatus.textContent = `${r.channels} channels · ${guide}.`;
      toast("Live TV source loaded", "ok");
    } catch (e: any) {
      liveStatus.textContent = e?.message ?? String(e);
      toast("Couldn't load that source", "error");
    } finally {
      btn.disabled = false;
      btn.textContent = was;
    }
  };

  customRows.append(
    row(
      "M3U playlist",
      "The channel list, as a URL or a path on this machine. Each channel's tvg-id is what the guide is matched on, and tvg-logo is used for its logo. Streams play straight from the addresses in the file — your Jellyfin server isn't involved and never sees them.",
      m3uInput
    ),
    row(
      "XMLTV guide",
      "The schedule, as a URL or a path. Optional: without it you get a channel list rather than a guide. Gzipped files are handled, so a .xml.gz address works as-is. Channels are joined on tvg-id, falling back to matching names.",
      xmltvInput
    ),
    row(
      "User agent",
      `Sent when fetching the playlist, the guide and every channel's stream. Some stream servers serve differently — or not at all — depending on the client they see; a channel that stalls here and plays in VLC is usually this. Empty sends ${iptv.DEFAULT_USER_AGENT}.`,
      uaInput
    ),
    row(
      "Refresh the guide",
      "How often the playlist and guide are read again while the app is open. Never means only when you press Refresh now or change an address.",
      refreshChoice
    ),
    row(
      "Channel artwork",
      "Loads every channel's logo the way the guide does and says how many came back, which ones the playlist never named, and which hosts wouldn't serve them.",
      el("button", {
        class: "btn",
        onClick: (ev: Event) => void checkArtwork(ev.currentTarget as HTMLButtonElement),
      }, ["Check artwork"]),
      artStatus
    ),
    row(
      "Check and load",
      "",
      el("button", {
        class: "btn primary",
        onClick: (ev: Event) => void checkSources(ev.currentTarget as HTMLButtonElement),
      }, ["Load sources"]),
      liveStatus
    )
  );
  syncLiveRows(cfg.livetv_source === "custom" ? "custom" : "jellyfin");
  syncLastRead();

  into(
    "livetv",
    block("Source", [
      row(
        "Source",
        "Where the Live TV page gets its channels and schedule. Your own playlist replaces Jellyfin's Live TV entirely — the guide, the channel list and playback all come from the two files below.",
        sourceSelect
      ),
      customRows,
      row(
        "Channel list and guide",
        "Read the channels and schedule again now, rather than waiting for the next refresh.",
        el("button", {
          class: "btn",
          onClick: (ev: Event) => void refreshNow(ev.currentTarget as HTMLButtonElement),
        }, ["Refresh now"]),
        lastReadLine
      ),
    ])
  );

  // ---------- Storage ----------
  into("storage", downloadsBlock(cfg, info.downloads_dir ?? ""));

  // ---------- Audio ----------
  // Last, because it waits on mpv for the list of outputs and nothing else
  // on the page should wait with it.
  const devices = await invoke<any[]>("audio_devices").catch(() => [] as any[]);
  if (!document.contains(title)) return;
  const deviceOptions: [string, string][] = [
    ["", "Automatic"],
    ...devices
      .filter((d) => d?.name && d.name !== "auto")
      .map((d) => [String(d.name), String(d.description ?? d.name)] as [string, string]),
  ];
  into(
    "audio",
    block("Language", [
      row(
        "Audio",
        "Preferred spoken language. The first track matching it is chosen when a file has more than one; anything without a match opens on whatever the file lists first.",
        choice(cfg, "audio_lang", [
          ["", "Whatever the file lists first"],
          ...LANGUAGES.map(([code, name]) => [code, name] as [string, string]),
        ])
      ),
    ]),
    block("Output", [
      row(
        "Output",
        devices.length
          ? "Which output plays sound — headphones rather than the television, without going through the system settings."
          : "The mpv binary couldn't be asked for the list of outputs, so this is left to the system default.",
        choice(cfg, "audio_device", deviceOptions)
      ),
      row(
        "Downmix to stereo",
        "Fold surround tracks down to two channels. Worth turning on if you listen on headphones or laptop speakers and find dialogue in 5.1 material too quiet — the centre channel it lives on gets mixed in properly rather than dropped.",
        toggle(cfg, "stereo_downmix")
      ),
      row(
        "Audio delay",
        "How far the sound is moved against the picture — the lag a television, soundbar or wireless headset adds, which is the same for everything heard through it. Saved and applied to everything you play; the player's own delay buttons move this same value.",
        audioDelayChoice(cfg)
      ),
      note(
        "Output and downmix apply to the next thing that starts playing; the delay moves what is playing now as well. Night mode is under Video."
      ),
    ])
  );
}

/**
 * Fetch every channel's logo through an `<img>`, as the guide would, a few at
 * a time and each with a deadline: one host that never answers must not hold
 * the report up for the whole line-up.
 */
async function probeArtwork(
  channels: any[],
  progress: (done: number, total: number) => void
): Promise<{ channels: number; loaded: number; missing: number; failed: string[] }> {
  const TIMEOUT_MS = 8000;
  const PARALLEL = 8;
  let loaded = 0, missing = 0, done = 0;
  const failed: string[] = [];
  const urls = channels.map((ch) => (ch.LogoUrl ?? (ch.ImageTags?.Primary ? api.imageUrl(ch, "Primary", 160) : null)) as string | null);

  const one = (url: string): Promise<boolean> =>
    new Promise((resolve) => {
      const img = new Image();
      const timer = window.setTimeout(() => finish(false), TIMEOUT_MS);
      const finish = (ok: boolean): void => {
        clearTimeout(timer);
        img.onload = img.onerror = null;
        resolve(ok);
      };
      img.onload = () => finish(img.naturalWidth > 0);
      img.onerror = () => finish(false);
      img.src = url;
    });

  let next = 0;
  const worker = async (): Promise<void> => {
    while (next < channels.length) {
      const i = next++;
      const url = urls[i];
      if (!url) missing++;
      else if (await one(url)) loaded++;
      else failed.push(channels[i].Name ?? `Channel ${i + 1}`);
      progress(++done, channels.length);
    }
  };
  await Promise.all(Array.from({ length: PARALLEL }, worker));
  return { channels: channels.length, loaded, missing, failed };
}
