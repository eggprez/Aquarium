import { invoke } from "@tauri-apps/api/core";
import * as api from "../api";
import { el, clear, toast } from "../ui";

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
          onClick: async () => {
            await api.logout();
            onLogout();
          },
        }, ["Sign out"]),
      ]),
    ])
  );

  // Playback block
  const mpvInput = el("input", {
    type: "text",
    placeholder: "auto-detect",
    value: cfg.mpv_path ?? "",
  }) as HTMLInputElement;
  root.append(
    el("div", { class: "settings-block" }, [
      el("h3", {}, ["Playback"]),
      el("div", { class: "settings-row" }, [
        el("div", {}, [
          el("div", { class: "lbl" }, ["mpv binary"]),
          el("div", { class: "sub" }, [`Currently using: ${info.mpv ?? "mpv"}`]),
        ]),
        mpvInput,
      ]),
      el("div", { class: "settings-row" }, [
        el("div", { class: "sub" }, [
          "Video plays embedded in the app window (hardware-decoded mpv). Shortcuts: Space pause · ←/→ seek · f fullscreen · Esc exit. Hover the video for mpv's on-screen controls.",
        ]),
      ]),
      el("div", { class: "settings-row" }, [
        el("div", {}),
        el("button", {
          class: "btn primary",
          onClick: async () => {
            await api.saveConfig({ mpv_path: mpvInput.value.trim() || null });
            toast("Saved", "ok");
          },
        }, ["Save"]),
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
    el("div", { class: "settings-block" }, [
      el("h3", {}, ["About"]),
      el("div", { class: "sub" }, [
        `FellyJin ${info.version ?? ""} — a lightweight Jellyfin client. Playback engine: mpv.`,
      ]),
    ])
  );
}
