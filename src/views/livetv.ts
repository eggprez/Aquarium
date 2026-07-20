import * as api from "../api";
import { playItem } from "../playback";
import { el, clear, spinner } from "../ui";

export async function renderLiveTv(root: HTMLElement): Promise<void> {
  clear(root);
  root.append(spinner());
  const channels = await api.getChannels().catch(() => []);
  clear(root);
  root.append(el("h1", { class: "page-title" }, ["Live TV"]));

  if (!channels.length) {
    root.append(
      el("div", { class: "empty" }, [
        "No Live TV channels. Configure a tuner and guide in your Jellyfin server dashboard.",
      ])
    );
    return;
  }

  const list = el("div", {});
  for (const ch of channels) {
    const logo = api.imageUrl(ch, "Primary", 160);
    const prog = ch.CurrentProgram;
    const progText = prog
      ? `${prog.Name}${prog.EpisodeTitle ? ` — ${prog.EpisodeTitle}` : ""}`
      : "No guide data";

    list.append(
      el("div", { class: "channel-row" }, [
        el("div", { class: "channel-logo" }, [
          logo ? el("img", { src: logo, loading: "lazy" }) : (ch.ChannelNumber ?? ch.Name ?? "?").slice(0, 4),
        ]),
        el("div", { class: "channel-body" }, [
          el("h4", {}, [`${ch.ChannelNumber ? ch.ChannelNumber + " · " : ""}${ch.Name ?? "Channel"}`]),
          el("p", {}, [el("span", { class: "live-dot" }), progText]),
        ]),
        el("button", {
          class: "btn small primary",
          onClick: () => playItem(ch, { live: true }),
        }, ["▶ Watch"]),
      ])
    );
  }
  root.append(list);
}
