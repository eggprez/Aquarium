import { invoke } from "@tauri-apps/api/core";
import * as api from "../api";
import * as iptv from "../iptv";
import { el, clear, toast } from "../ui";
import {
  isAdaptiveEnabled,
  setAdaptiveEnabled,
  playerCtl,
  PICTURE_CONTROLS,
  setLiveSetting,
} from "../playback";
import { getThemePref, setThemePref, type ThemePref } from "../theme";

/**
 * One labelled setting. Every row on this page is a name, a sentence saying
 * what the setting actually does, and a control — the sentence being the part
 * that stops a settings page from being a list of words you have to guess at.
 */
function row(label: string, explain: string, control: Node | null): HTMLElement {
  return el("div", { class: "settings-row" }, [
    el("div", {}, [
      el("div", { class: "lbl" }, [label]),
      el("div", { class: "sub" }, [explain]),
    ]),
    control,
  ]);
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
      void api.saveConfig({ [key]: value }).catch(() => toast("Couldn't save that setting", "error"));
      onPicked?.(value);
    },
  }, options.map(([value, label]) => el("option", { value }, [label]))) as HTMLSelectElement;
  select.value = typeof cfg[key] === "string" ? cfg[key] : options[0]![0];
  return select;
}

/** A checkbox-style toggle bound to one config key. */
function toggle(
  cfg: any,
  key: string,
  labels: [off: string, on: string],
  onPicked?: (value: boolean) => void
): HTMLSelectElement {
  const select = el("select", {
    class: "control md",
    onChange: (ev: Event) => {
      const on = (ev.target as HTMLSelectElement).value === "on";
      void api.saveConfig({ [key]: on }).catch(() => toast("Couldn't save that setting", "error"));
      onPicked?.(on);
    },
  }, [
    el("option", { value: "off" }, [labels[0]]),
    el("option", { value: "on" }, [labels[1]]),
  ]) as HTMLSelectElement;
  select.value = cfg[key] === true ? "on" : "off";
  return select;
}

/**
 * A slider that applies to the running player as it moves and saves once the
 * movement stops. `format` turns the raw number into what the readout says.
 */
function slider(
  cfg: any,
  key: string,
  prop: string,
  range: { min: number; max: number; step?: number; fallback: number },
  format: (v: number) => string,
  scale: (v: number) => number = (v) => v
): { control: HTMLElement; reset: () => void } {
  const start = Number(cfg[key]);
  const initial = isFinite(start) ? start : range.fallback;
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
    "aria-label": key,
  }) as HTMLInputElement;
  const paint = (v: number): void => {
    const pct = ((v - range.min) / (range.max - range.min)) * 100;
    input.style.setProperty("--fill", `${Math.max(0, Math.min(100, pct))}%`);
    readout.textContent = format(v);
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
    return localStorage.getItem("fellyjin.hwdec-last");
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

export async function renderSettings(root: HTMLElement, onLogout: () => void): Promise<void> {
  clear(root);
  const s = api.getSession();
  const cfg = api.getConfig();
  const info: any = await invoke("app_info").catch(() => ({}));

  root.append(el("h1", { class: "page-title" }, ["Settings"]));

  // Server block
  root.append(
    el("div", { class: "settings-block" }, [
      el("h3", {}, ["Server"]),
      el("div", { class: "settings-row" }, [
        el("div", {}, [
          el("div", { class: "lbl" }, [s?.server ?? "Not connected"]),
          el("div", { class: "sub" }, [s ? `Signed in as ${s.userName}` : ""]),
        ]),
        el("button", {
          class: "btn danger",
          onClick: async (ev: Event) => {
            const btn = ev.currentTarget as HTMLButtonElement;
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
                    ? "Signed out here, but the server couldn't be reached to end the session — FellyJin will keep retrying."
                    : "Signed out here, but the session could not be ended on the server. Revoke this device in Jellyfin → Dashboard → Devices.",
                  "error"
                );
              }
            } catch {
              toast("Sign out failed", "error");
            }
            onLogout();
          },
        }, ["Sign out"]),
      ]),
      // Whether the link to the server is encrypted. A LAN-only server over
      // plain HTTP is a defensible choice; not knowing which one you have is
      // not, and this used to be invisible.
      el("div", { class: "settings-row" }, [
        el("div", {}, [
          el("div", { class: "lbl" }, ["Connection"]),
          el("div", { class: "sub" }, [
            info.server_secure
              ? "Encrypted (HTTPS). Your password and access token are never sent in the clear."
              : "Unencrypted (HTTP). Anything on the network path can read your access token and what you watch. Put Jellyfin behind HTTPS if it's reachable from outside your home network.",
          ]),
        ]),
        el("span", {
          class: `sync-pill${info.server_secure ? " ok" : " warn"}`,
        }, [info.server_secure ? "HTTPS" : "HTTP"]),
      ]),
      // The server's own id, recorded at sign-in. Re-checked before the app
      // authenticates, so an edited config.json can't quietly redirect the
      // token to somewhere else.
      el("div", { class: "settings-row" }, [
        el("div", {}, [
          el("div", { class: "lbl" }, ["Server identity"]),
          el("div", { class: "sub" }, [
            info.server_pinned
              ? "Pinned. If this address ever answers as a different Jellyfin server, FellyJin stops instead of signing in to it."
              : "Not pinned yet — it will be recorded the next time this server answers.",
          ]),
        ]),
        el("span", {
          class: `sync-pill${info.server_pinned ? " ok" : " warn"}`,
        }, [info.server_pinned ? "Pinned" : "Unpinned"]),
      ]),
      // Where the access token actually lives. It used to be written in
      // plaintext into config.json; it now goes to the desktop keyring, and
      // when that isn't available the user deserves to know it fell back.
      el("div", { class: "settings-row" }, [
        el("div", {}, [
          el("div", { class: "lbl" }, ["Access token"]),
          el("div", { class: "sub" }, [
            info.token_storage === "keyring"
              ? "Stored in your desktop keyring (Secret Service). Never written to the config file, and never sent in a URL."
              : "Your desktop keyring is unavailable, so the token is stored in ~/.config/fellyjin/config.json. Unlock or install a keyring (gnome-keyring, KWallet) to secure it.",
          ]),
        ]),
        el("span", {
          class: `sync-pill${info.token_storage === "keyring" ? " ok" : " warn"}`,
        }, [info.token_storage === "keyring" ? "Keyring" : "Config file"]),
      ]),
      // A previous sign-out never got confirmed by the server, so that token is
      // still valid over there. The retry runs at every launch, but the user
      // may want to kill it from the Jellyfin dashboard rather than wait.
      info.revocation_pending
        ? el("div", { class: "settings-row" }, [
            el("div", {}, [
              el("div", { class: "lbl" }, ["Unfinished sign-out"]),
              el("div", { class: "sub" }, [
                "A previous sign-out couldn't reach the server, so that session may still be active on it. FellyJin retries at every launch; to end it now, remove this device in Jellyfin → Dashboard → Devices.",
              ]),
            ]),
            el("span", { class: "sync-pill warn" }, ["Pending"]),
          ])
        : null,
    ])
  );

  // Appearance block — applied immediately, no Save needed.
  const themeSelect = el("select", {
    class: "control md",
    onChange: async (ev: Event) => {
      const value = (ev.target as HTMLSelectElement).value as ThemePref;
      try {
        await setThemePref(value);
      } catch {
        toast("Couldn't save appearance setting", "error");
      }
    },
  }, [
    el("option", { value: "auto" }, ["Match system"]),
    el("option", { value: "light" }, ["Light"]),
    el("option", { value: "dark" }, ["Dark"]),
  ]) as HTMLSelectElement;
  themeSelect.value = getThemePref();
  root.append(
    el("div", { class: "settings-block" }, [
      el("h3", {}, ["Appearance"]),
      el("div", { class: "settings-row" }, [
        el("div", {}, [
          el("div", { class: "lbl" }, ["Theme"]),
          el("div", { class: "sub" }, [
            "Match system follows your desktop's light/dark setting. The video player's own on-screen controls are always dark.",
          ]),
        ]),
        themeSelect,
      ]),
    ])
  );

  // Playback block
  const adaptiveSelect = el("select", {
    class: "control md",
    onChange: (ev: Event) => {
      setAdaptiveEnabled((ev.target as HTMLSelectElement).value === "auto");
    },
  }, [
    el("option", { value: "auto" }, ["Adapt automatically"]),
    el("option", { value: "off" }, ["Keep my choice"]),
  ]) as HTMLSelectElement;
  adaptiveSelect.value = isAdaptiveEnabled() ? "auto" : "off";

  // What the last stream was actually decoded with. Asking for hardware
  // decoding and getting it are different things — mpv falls back to the CPU
  // without saying so, and the only symptom is a hot, loud machine.
  const seen = lastDecoder();
  const decoderPill = seen
    ? el("span", { class: `sync-pill${seen === "no" ? " warn" : " ok"}` }, [
        DECODER_NAMES[seen] ?? seen,
      ])
    : el("span", { class: "sync-pill" }, ["Not measured yet"]);

  root.append(
    el("div", { class: "settings-block" }, [
      el("h3", {}, ["Playback"]),
      row(
        "Streaming quality",
        "Adapting drops to a smaller stream when playback keeps stalling or the machine can't decode fast enough, and climbs back after the connection has been steady for a while. It never goes above the quality you picked, and never touches downloaded files or Live TV.",
        adaptiveSelect
      ),
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
        toggle(cfg, "smooth_motion", ["Off", "On — match the display"])
      ),
      row(
        "Battery saver rendering",
        "Draws the picture with the simplest scaler and 8-bit intermediates instead of mpv's default high-quality chain. On a HiDPI screen every scaler pass runs at the panel's full resolution, so this is a real saving on the GPU, and the difference in the picture is hard to see from viewing distance. Applies from the next thing you play.",
        toggle(cfg, "battery_render", ["Off — best picture", "On — lighter on the GPU"])
      ),
      row(
        "mpv",
        `Running ${info.mpv ?? "libmpv2"}, linked in-process — no separate mpv install needed.`,
        null
      ),
      el("div", { class: "settings-row" }, [
        el("div", { class: "sub" }, [
          "Video plays embedded in the app window. Shortcuts: Space pause · ←/→ seek · ↑/↓ volume · m mute · [ / ] speed · z / Z subtitle delay · f fullscreen · Esc exit. Media keys on your keyboard control playback too, and the episode appears in your desktop's own media controls. Hover the video for mpv's on-screen controls.",
        ]),
      ]),
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

  const liveStatus = el("div", { class: "sub" }, [""]);
  const customRows = el("div", { class: "settings-sub" });

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
      document.dispatchEvent(new CustomEvent("fellyjin-nav-refresh"));
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
    el("div", { class: "settings-row" }, [
      el("div", {}, [
        el("div", { class: "lbl" }, ["Check and load"]),
        liveStatus,
      ]),
      el("button", {
        class: "btn primary",
        onClick: (ev: Event) => void checkSources(ev.currentTarget as HTMLButtonElement),
      }, ["Load sources"]),
    ])
  );
  syncLiveRows(cfg.livetv_source === "custom" ? "custom" : "jellyfin");

  root.append(
    el("div", { class: "settings-block" }, [
      el("h3", {}, ["Live TV"]),
      row(
        "Source",
        "Where the Live TV page gets its channels and schedule. Your own playlist replaces Jellyfin's Live TV entirely — the guide, the channel list and playback all come from the two files below.",
        sourceSelect
      ),
      customRows,
    ])
  );

  // ---------- Languages ----------
  // Which track a file opens with, before anyone touches anything. Applies to
  // the next thing that starts playing, not to what's on screen now.
  root.append(
    el("div", { class: "settings-block" }, [
      el("h3", {}, ["Languages"]),
      row(
        "Audio",
        "Preferred spoken language. The first track matching it is chosen when a file has more than one; anything without a match opens on whatever the file lists first.",
        choice(cfg, "audio_lang", [
          ["", "Whatever the file lists first"],
          ...LANGUAGES.map(([code, name]) => [code, name] as [string, string]),
        ])
      ),
      row(
        "Subtitles",
        "“Never” is the setting to pick if you don't use subtitles: it stops them being switched on by a file that ships with them enabled, which no other option here can do.",
        choice(cfg, "sub_lang", [
          ["", "Only when the file turns them on"],
          ["off", "Never — no subtitles"],
          ...LANGUAGES.map(([code, name]) => [code, name] as [string, string]),
        ])
      ),
      row(
        "Forced subtitles",
        "When the audio is already in your preferred language, show only the forced track — the one that translates signs and the occasional line of foreign dialogue — instead of subtitling the whole thing.",
        toggle(cfg, "subs_forced_only", ["Off", "On — forced only"])
      ),
      el("div", { class: "settings-row" }, [
        el("div", { class: "sub" }, [
          "Changing a track during an episode is remembered for that series on its own, and the next episode opens the same way.",
        ]),
      ]),
    ])
  );

  // ---------- Subtitle appearance ----------
  const subSize = slider(
    cfg,
    "sub_font_size",
    "sub-font-size",
    { min: 20, max: 80, fallback: 38 },
    (v) => `${Math.round(v)}`
  );
  const subPos = slider(
    cfg,
    "sub_pos",
    "sub-pos",
    { min: 60, max: 100, fallback: 100 },
    (v) => (v >= 99 ? "Bottom" : `${Math.round(100 - v)} up`)
  );
  root.append(
    el("div", { class: "settings-block" }, [
      el("h3", {}, ["Subtitles"]),
      row("Size", "Applies as you drag it, so it can be judged against what's playing.", subSize.control),
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

  // ---------- Audio ----------
  const devices = await invoke<any[]>("audio_devices").catch(() => [] as any[]);
  const deviceOptions: [string, string][] = [
    ["", "Automatic"],
    ...devices
      .filter((d) => d?.name && d.name !== "auto")
      .map((d) => [String(d.name), String(d.description ?? d.name)] as [string, string]),
  ];
  root.append(
    el("div", { class: "settings-block" }, [
      el("h3", {}, ["Audio"]),
      row(
        "Output",
        devices.length
          ? "Which output plays sound — headphones rather than the television, without going through the system settings."
          : "The mpv binary couldn't be asked for the list of outputs, so this is left to the system default.",
        choice(cfg, "audio_device", deviceOptions)
      ),
      row(
        "Night mode",
        "Evens out the distance between whispered dialogue and the next explosion, so an action film stays watchable at a volume that won't wake the house.",
        toggle(cfg, "night_mode", ["Off", "On — even out loud scenes"])
      ),
      row(
        "Downmix to stereo",
        "Fold surround tracks down to two channels. Worth turning on if you listen on headphones or laptop speakers and find dialogue in 5.1 material too quiet — the centre channel it lives on gets mixed in properly rather than dropped.",
        toggle(cfg, "stereo_downmix", ["Off — keep surround", "On — stereo"])
      ),
      el("div", { class: "settings-row" }, [
        el("div", { class: "sub" }, ["Audio settings apply to the next thing that starts playing."]),
      ]),
    ])
  );

  // ---------- Picture ----------
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
    // The slider is in percent; mpv's scale is a fraction.
    (v) => v / 100
  );
  root.append(
    el("div", { class: "settings-block" }, [
      el("h3", {}, ["Picture"]),
      ...pictureSliders.map((s) =>
        row(s.control.label, "", s.ui.control)
      ),
      row(
        "Aspect ratio",
        "Override what the file claims. Only needed for material that's tagged wrong — a stretched or squashed picture that no player gets right.",
        choice(cfg, "video_aspect", [
          ["", "As the file says"],
          ["16:9", "16:9 — widescreen"],
          ["4:3", "4:3 — classic"],
          ["2.35:1", "2.35:1 — cinemascope"],
        ])
      ),
      row(
        "Zoom",
        "Crops in on the picture, which is how you fill a 16:9 screen with a 2.35:1 film instead of watching it between black bars. It does cut the edges of the frame off.",
        zoom.control
      ),
      el("div", { class: "settings-row" }, [
        el("div", { class: "sub" }, [
          "Picture settings apply immediately, and are also reachable from the player bar while something is playing.",
        ]),
        el("button", {
          class: "btn",
          onClick: () => {
            for (const s of pictureSliders) s.ui.reset();
            zoom.reset();
            void api.saveConfig({ video_aspect: "" });
            toast("Picture reset", "ok");
          },
        }, ["Reset picture"]),
      ]),
    ])
  );

  // Storage block
  root.append(
    el("div", { class: "settings-block" }, [
      el("h3", {}, ["Storage"]),
      el("div", { class: "settings-row" }, [
        el("div", {}, [
          el("div", { class: "lbl" }, ["Downloads folder"]),
          el("div", { class: "sub" }, [info.downloads_dir ?? ""]),
        ]),
      ]),
    ])
  );

  root.append(
    el("div", { class: "settings-block about-block" }, [
      el("h3", {}, ["About"]),
      el("div", { class: "about-row" }, [
        el("img", { src: "/fellyjin-logo.png", alt: "", width: "48", height: "48" }),
        el("div", {}, [
          el("div", { class: "about-name" }, [
            el("span", { class: "wordmark" }, [el("span", {}, ["Felly"]), el("b", {}, ["Jin"])]),
            el("span", { class: "about-version" }, [info.version ? `v${info.version}` : ""]),
          ]),
          el("div", { class: "sub" }, [
            "A lightweight Jellyfin client. Playback engine: mpv.",
          ]),
        ]),
      ]),
    ])
  );
}
