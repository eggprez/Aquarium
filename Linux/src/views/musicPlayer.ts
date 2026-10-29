// The mini player that stays at the bottom of every page while music or a book
// plays, and the Now Playing view it opens into: cover, scrubber, transport,
// shuffle and repeat, volume, a reorderable Up Next, timed lyrics, a sleep
// timer and Sound Check. For a book: chapters, speed and 15/30 s skips.
//
// Nothing here animates on its own: the scrubber and the lyric highlight move
// when a status tick arrives (once a second) and not in between, so a page
// left playing costs a repaint a second rather than one a frame.
import * as m from "../musicApi";
import * as audio from "../audio";
import { el, clear, art, toast, openActionMenu, type MenuAction } from "../ui";
import { mi, iconButton, musicActions, showSongInfo, type MusicIcon } from "./musicCommon";
import { openMixDialog } from "./music";

let bar: HTMLElement | null = null;
let np: HTMLElement | null = null;

function report(e: any): void {
  toast(e?.message ?? String(e), "error");
}

function subtitleOf(item: any): string {
  if (!item) return "";
  if (item.Type === "AudioBook") {
    const ch = audio.currentChapter();
    return ch ? ch.name : m.artistLine(item);
  }
  return [m.artistLine(item), item.Album].filter(Boolean).join(" — ");
}

function swapIcon(btn: HTMLElement, name: MusicIcon): void {
  const span = btn.querySelector(".ico");
  if (span && (span as any).__icon !== name) {
    span.innerHTML = mi(name).innerHTML;
    (span as any).__icon = name;
  }
}

/** A seek bar: an <input type=range> whose fill is a CSS variable. */
function scrubber(onSeek: (sec: number) => void): { root: HTMLElement; set: (pos: number, dur: number) => void } {
  const range = el("input", { type: "range", class: "mu-scrub", min: "0", max: "1000", step: "1", value: "0", "aria-label": "Position" }) as HTMLInputElement;
  let dragging = false;
  let dur = 0;
  range.addEventListener("input", () => {
    dragging = true;
    range.style.setProperty("--fill", `${Number(range.value) / 10}%`);
  });
  range.addEventListener("change", () => {
    dragging = false;
    if (dur > 0) onSeek((Number(range.value) / 1000) * dur);
  });
  return {
    root: range,
    set: (pos, d) => {
      dur = d;
      if (dragging) return;
      const v = d > 0 ? Math.round((pos / d) * 1000) : 0;
      range.value = String(v);
      range.style.setProperty("--fill", `${v / 10}%`);
    },
  };
}

function sleepActions(): MenuAction[] {
  const book = audio.queueState().book;
  const st = audio.sleepState();
  const left = st.mode === "time" ? Math.max(0, Math.round((st.at - Date.now()) / 60000)) : 0;
  return [
    st.mode !== "off" ? { label: st.mode === "time" ? `Turn off (${left} min left)` : "Turn off", run: () => void audio.setSleep("off") } : null,
    ...[15, 30, 45, 60, 90].map((n) => ({ label: `${n} minutes`, run: () => void audio.setSleep(n).then(() => toast(`Stopping in ${n} minutes`, "ok")) })),
    { label: book ? "End of chapter" : "End of this song", run: () => void audio.setSleep("track").then(() => toast(book ? "Stopping at the end of the chapter" : "Stopping after this song", "ok")) },
  ].filter(Boolean) as MenuAction[];
}

function speedActions(): MenuAction[] {
  const cur = audio.bookSpeed();
  return audio.BOOK_SPEEDS.map((s) => ({ label: `${s}×${s === cur ? "  ✓" : ""}`, run: () => void audio.setSpeed(s) }));
}

function volumeControl(): { root: HTMLElement; sync: () => void } {
  const btn = iconButton("volume", "Mute", () => void audio.setMute(!audio.getStatus().mute));
  const range = el("input", { type: "range", class: "mu-vol", min: "0", max: "130", step: "1", "aria-label": "Volume" }) as HTMLInputElement;
  let touching = false;
  range.addEventListener("input", () => {
    touching = true;
    range.style.setProperty("--fill", `${(Number(range.value) / 130) * 100}%`);
    void audio.setVolume(Number(range.value));
  });
  range.addEventListener("change", () => (touching = false));
  const sync = () => {
    const st = audio.getStatus();
    swapIcon(btn, st.mute || st.volume === 0 ? "mute" : "volume");
    if (!touching) {
      range.value = String(Math.round(st.volume));
      range.style.setProperty("--fill", `${(st.volume / 130) * 100}%`);
    }
  };
  return { root: el("div", { class: "mu-volume" }, [btn, range]), sync };
}

// ---------- Mini player ----------

function buildBar(): HTMLElement {
  const cover = el("button", { class: "mb-cover", title: "Now Playing", "aria-label": "Open Now Playing", onClick: openNowPlaying });
  const title = el("div", { class: "mb-title" });
  const sub = el("div", { class: "mb-sub" });
  const text = el("button", { class: "mb-text", onClick: openNowPlaying, "aria-label": "Open Now Playing" }, [title, sub]);
  const prev = iconButton("prev", "Previous", () => void (audio.queueState().book ? audio.skip(-15) : audio.previous()));
  const playBtn = iconButton("play", "Play/Pause (Space)", () => void audio.togglePause(), "mb-play");
  const next = iconButton("next", "Next", () => void (audio.queueState().book ? audio.skip(30) : audio.next()));
  const time = el("div", { class: "mb-time" });
  const vol = volumeControl();
  const queueBtn = iconButton("queue", "Up Next", () => openNowPlaying("queue"));
  const stopBtn = iconButton("close", "Stop", () => void audio.stop());
  const progress = el("div", { class: "mb-progress" }, [el("div", { class: "mb-progress-fill" })]);
  // The thin line along the top edge seeks too.
  progress.addEventListener("click", (ev) => {
    const r = progress.getBoundingClientRect();
    const st = audio.getStatus();
    if (st.duration > 0) void audio.seek(((ev.clientX - r.left) / r.width) * st.duration);
  });
  const root = el("div", { id: "music-bar", class: "hidden", role: "region", "aria-label": "Music player" }, [
    progress,
    cover,
    text,
    el("div", { class: "mb-controls" }, [prev, playBtn, next]),
    time,
    vol.root,
    queueBtn,
    stopBtn,
  ]);
  let lastId = "";
  (root as any).__sync = () => {
    const item = audio.current();
    const st = audio.getStatus();
    const active = audio.isActive() && !!item;
    root.classList.toggle("hidden", !active);
    document.getElementById("content")?.classList.toggle("has-music", active);
    if (!active) return;
    const book = audio.queueState().book;
    if (item.Id !== lastId) {
      lastId = item.Id;
      clear(cover);
      cover.append(art(m.coverUrl(item, 120), () => el("div", { class: "noart" }, [mi(book ? "book" : "note", 18)]), { lazy: false }));
      title.textContent = item.Name ?? "";
    }
    sub.textContent = subtitleOf(item);
    swapIcon(prev, book ? "back15" : "prev");
    swapIcon(next, book ? "fwd30" : "next");
    prev.title = book ? "Back 15 seconds" : "Previous";
    next.title = book ? "Forward 30 seconds" : "Next";
    swapIcon(playBtn, st.paused ? "play" : "pause");
    time.textContent = st.duration ? `${m.clock(st.position)} / ${m.clock(st.duration)}` : m.clock(st.position);
    (progress.firstChild as HTMLElement).style.width = st.duration > 0 ? `${Math.min(100, (st.position / st.duration) * 100)}%` : "0";
    vol.sync();
  };
  return root;
}

// ---------- Now Playing ----------

let npTab: "queue" | "lyrics" | "chapters" = "queue";
let lyricsFor = "";
let lyricLines: m.LyricLine[] | null = null;
let queueSig = "";

export function openNowPlaying(tab?: "queue" | "lyrics" | "chapters" | MouseEvent): void {
  if (typeof tab === "string") npTab = tab;
  if (!np) {
    np = buildNowPlaying();
    document.getElementById("app")?.append(np);
  }
  np.classList.remove("hidden");
  queueSig = "";
  sync();
  // The play button, so Space keeps meaning play/pause.
  (np.querySelector(".np-play") as HTMLElement | null)?.focus();
}

function closeNowPlaying(): void {
  np?.classList.add("hidden");
}

function buildNowPlaying(): HTMLElement {
  const backdrop = el("div", { class: "np-backdrop" });
  const cover = el("div", { class: "np-cover" });
  const title = el("h1", { class: "np-title" });
  const sub = el("div", { class: "np-sub" });
  const chapter = el("div", { class: "np-chapter" });
  const scrub = scrubber((sec) => void audio.seek(sec));
  const tPos = el("span");
  const tLeft = el("span");
  const shuffle = iconButton("shuffle", "Shuffle", () => void audio.setShuffle(!audio.isShuffled()), "np-toggle");
  const prev = iconButton("prev", "Previous", () => void audio.previous());
  const back = iconButton("back15", "Back 15 seconds", () => void audio.skip(-15));
  const playBtn = iconButton("play", "Play/Pause", () => void audio.togglePause(), "np-play");
  const fwd = iconButton("fwd30", "Forward 30 seconds", () => void audio.skip(30));
  const next = iconButton("next", "Next", () => void audio.next());
  const repeat = iconButton("repeat", "Repeat", () => void audio.cycleRepeat(), "np-toggle");
  const vol = volumeControl();
  const speed = el("button", { class: "btn small np-speed", onClick: (ev: MouseEvent) => openActionMenu(ev.currentTarget as HTMLElement, "Speed", speedActions(), { fixed: true }) });
  const sleepBtn = iconButton("sleep", "Sleep timer", (ev) => openActionMenu(ev.currentTarget as HTMLElement, "Sleep Timer", sleepActions(), { fixed: true }), "np-toggle");
  const soundCheck = el("button", {
    class: "btn small np-sc",
    title: "Sound Check: play every song at the same loudness (ReplayGain)",
    onClick: () => void audio.setSoundCheck(!audio.soundCheckOn()).then(sync).catch(report),
  }, ["Sound Check"]);
  const more = iconButton("more", "More", () => {
    const item = audio.current();
    if (!item) return;
    openActionMenu(more, item.Name ?? null, [
      ...musicActions(item).filter((a) => a && a.label !== "Play" && a.label !== "Play Next" && a.label !== "Play Later"),
      item.Type === "Audio" ? null : { label: "Details", run: () => { closeNowPlaying(); location.hash = `#/books/book/${item.Id}`; } },
      { label: "Station Mix…", run: openMixDialog },
      { label: "Stop", icon: "close", run: () => { void audio.stop(); closeNowPlaying(); } },
    ], { fixed: true });
  });
  const tabs = el("div", { class: "np-tabs", role: "tablist" });
  const panel = el("div", { class: "np-panel" });
  const closeBtn = iconButton("down", "Close (Esc)", closeNowPlaying, "np-close");

  const left = el("div", { class: "np-left" }, [
    cover,
    el("div", { class: "np-meta" }, [title, sub, chapter]),
    el("div", { class: "np-scrub" }, [scrub.root, el("div", { class: "np-times" }, [tPos, tLeft])]),
    el("div", { class: "np-transport" }, [shuffle, prev, back, playBtn, fwd, next, repeat]),
    el("div", { class: "np-extras" }, [vol.root, speed, soundCheck, sleepBtn, more]),
  ]);
  const root = el("div", { id: "now-playing", class: "hidden", role: "dialog", "aria-label": "Now Playing" }, [
    backdrop,
    closeBtn,
    el("div", { class: "np-body" }, [left, el("div", { class: "np-right" }, [tabs, panel])]),
  ]);

  // Up Next keeps its scroll and drag state across ticks; it is rebuilt only
  // when the queue itself changes.
  const drawPanel = (force = false) => {
    const q = audio.queueState();
    const item = audio.current();
    const book = q.book;
    const want = book && npTab === "lyrics" ? "chapters" : !book && npTab === "chapters" ? "queue" : npTab;
    if (want !== npTab) npTab = want;
    const tabList: [typeof npTab, string][] = book ? [["chapters", "Chapters"], ["queue", "Up Next"]] : [["queue", "Up Next"], ["lyrics", "Lyrics"]];
    clear(tabs);
    for (const [k, label] of tabList) {
      tabs.append(el("button", {
        class: `np-tab${npTab === k ? " active" : ""}`,
        role: "tab",
        "aria-selected": npTab === k ? "true" : "false",
        onClick: () => { npTab = k; queueSig = ""; drawPanel(true); },
      }, [label]));
    }
    const sig = `${npTab}|${q.index}|${q.items.map((i) => i.Id).join(",")}|${item?.Id}|${lyricLines ? lyricLines.length : -1}`;
    if (!force && sig === queueSig) return;
    queueSig = sig;
    clear(panel);
    if (npTab === "queue") panel.append(upNextList());
    else if (npTab === "lyrics") panel.append(lyricsView());
    else panel.append(chaptersView());
    highlight();
  };

  const highlight = () => {
    const pos = audio.getStatus().position;
    if (npTab === "lyrics" && lyricLines?.some((l) => l.start != null)) {
      let at = -1;
      lyricLines.forEach((l, i) => {
        if (l.start != null && l.start <= pos + 0.25) at = i;
      });
      panel.querySelectorAll<HTMLElement>(".np-lyric").forEach((n, i) => {
        const on = i === at;
        if (on && !n.classList.contains("current")) {
          n.classList.add("current");
          n.scrollIntoView({ block: "center", behavior: "smooth" });
        } else if (!on) n.classList.remove("current");
      });
    }
    if (npTab === "chapters") {
      const ch = audio.currentChapter();
      panel.querySelectorAll<HTMLElement>(".np-chapter-row").forEach((n, i) => n.classList.toggle("current", ch?.index === i));
    }
  };

  let lastCover = "";
  (root as any).__sync = () => {
    const item = audio.current();
    if (!item) {
      if (!audio.isActive()) closeNowPlaying();
      return;
    }
    const st = audio.getStatus();
    const q = audio.queueState();
    const book = q.book;
    if (item.Id !== lastCover) {
      lastCover = item.Id;
      const url = m.coverUrl(item, 900);
      clear(cover);
      cover.append(art(url, () => el("div", { class: "noart" }, [mi(book ? "book" : "note", 80)]), { lazy: false }));
      backdrop.style.backgroundImage = url ? `url("${url}")` : "";
      title.textContent = item.Name ?? "";
      clear(sub);
      const artist = item.AlbumArtists?.[0] ?? item.ArtistItems?.[0];
      sub.append(
        artist?.Id && !book ? el("a", { class: "mu-link", href: `#/music/artist/${artist.Id}`, onClick: closeNowPlaying }, [m.artistLine(item)]) : m.artistLine(item),
        item.Album && item.AlbumId ? " — " : "",
        item.Album && item.AlbumId ? el("a", { class: "mu-link", href: `#/music/album/${item.AlbumId}`, onClick: closeNowPlaying }, [item.Album]) : ""
      );
      if (!book && lyricsFor !== item.Id) {
        lyricsFor = item.Id;
        lyricLines = null;
        void m.lyrics(item.Id).then((l) => {
          if (lyricsFor === item.Id) {
            lyricLines = l ?? [];
            drawPanel();
          }
        });
      }
    }
    chapter.textContent = book ? audio.currentChapter()?.name ?? "" : q.title ? `Playing from ${q.title}` : "";
    scrub.set(st.position, st.duration);
    tPos.textContent = m.clock(st.position);
    tLeft.textContent = st.duration ? `-${m.clock(Math.max(0, st.duration - st.position))}` : "";
    swapIcon(playBtn, st.paused ? "play" : "pause");
    shuffle.classList.toggle("on", audio.isShuffled());
    swapIcon(repeat, q.repeat === "one" ? "repeatOne" : "repeat");
    repeat.classList.toggle("on", q.repeat !== "off");
    repeat.title = q.repeat === "off" ? "Repeat: off" : q.repeat === "all" ? "Repeat: all" : "Repeat: this song";
    for (const b of [shuffle, prev, next, repeat]) b.toggleAttribute("hidden", book);
    for (const b of [back, fwd]) b.toggleAttribute("hidden", !book);
    speed.toggleAttribute("hidden", !book);
    speed.textContent = `${audio.bookSpeed()}×`;
    soundCheck.toggleAttribute("hidden", book);
    soundCheck.classList.toggle("active", audio.soundCheckOn());
    sleepBtn.classList.toggle("on", audio.sleepState().mode !== "off");
    vol.sync();
    drawPanel();
    highlight();
  };

  root.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape") {
      ev.preventDefault();
      ev.stopPropagation();
      closeNowPlaying();
    }
  });
  return root;
}

function upNextList(): HTMLElement {
  const q = audio.queueState();
  const wrap = el("div", { class: "np-queue" });
  const upcoming = audio.upNext();
  wrap.append(el("div", { class: "np-queue-head" }, [
    el("span", {}, [q.source ? `${q.title} · keeps going` : q.title ? `Playing from ${q.title}` : "Up Next"]),
    upcoming.length ? el("button", { class: "btn small", onClick: () => void audio.clearUpNext() }, ["Clear"]) : null,
  ]));
  if (!upcoming.length) {
    wrap.append(el("p", { class: "np-empty" }, [q.repeat === "all" ? "The queue starts again after this." : "Nothing after this. Play Next and Play Later add songs here."]));
    return wrap;
  }
  upcoming.forEach((s, n) => {
    const index = q.index + 1 + n;
    const row = el("div", { class: "np-qrow", draggable: "true", tabindex: "0", title: "Drag to reorder · double-click to play" }, [
      el("div", { class: "mu-grip" }, [mi("grip", 16)]),
      el("div", { class: "np-qart" }, [art(m.coverUrl(s, 80), () => el("div", { class: "noart" }, [mi("note", 14)]))]),
      el("div", { class: "mu-song-text" }, [
        el("div", { class: "mu-song-title" }, [s.Name ?? ""]),
        el("div", { class: "mu-song-sub" }, [m.artistLine(s)]),
      ]),
      iconButton("close", "Remove from Up Next", (ev) => { ev.stopPropagation(); void audio.removeAt(index); }),
    ]);
    row.addEventListener("dblclick", () => void audio.jump(index));
    row.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter") void audio.jump(index);
      if (ev.key === "Delete") void audio.removeAt(index);
      // Alt+↑/↓ moves an entry for anyone not using a mouse.
      if (ev.altKey && ev.key === "ArrowUp") { ev.preventDefault(); void audio.move(index, index - 1); }
      if (ev.altKey && ev.key === "ArrowDown") { ev.preventDefault(); void audio.move(index, index + 1); }
    });
    row.addEventListener("dragstart", (ev) => {
      ev.dataTransfer?.setData("text/plain", String(index));
      row.classList.add("dragging");
    });
    row.addEventListener("dragend", () => row.classList.remove("dragging"));
    row.addEventListener("dragover", (ev) => { ev.preventDefault(); row.classList.add("drop-target"); });
    row.addEventListener("dragleave", () => row.classList.remove("drop-target"));
    row.addEventListener("drop", (ev) => {
      ev.preventDefault();
      row.classList.remove("drop-target");
      const from = Number(ev.dataTransfer?.getData("text/plain"));
      if (Number.isFinite(from)) void audio.move(from, index);
    });
    row.addEventListener("contextmenu", (ev) => {
      ev.preventDefault();
      openActionMenu({ x: ev.clientX, y: ev.clientY }, s.Name ?? null, [
        { label: "Play Now", icon: "play", run: () => void audio.jump(index) },
        { label: "Move to Top", run: () => void audio.move(index, q.index + 1) },
        { label: "Remove from Up Next", icon: "trash", run: () => void audio.removeAt(index) },
        s.Type === "Audio" ? { label: "Song Info", run: () => void showSongInfo(s) } : null,
      ]);
    });
    wrap.append(row);
  });
  return wrap;
}

function lyricsView(): HTMLElement {
  const wrap = el("div", { class: "np-lyrics" });
  if (lyricLines == null) {
    wrap.append(el("p", { class: "np-empty" }, ["Looking for lyrics…"]));
    return wrap;
  }
  if (!lyricLines.length) {
    wrap.append(el("p", { class: "np-empty" }, ["No lyrics for this song. The server finds them in an .lrc file beside the song or in its tags."]));
    return wrap;
  }
  const timed = lyricLines.some((l) => l.start != null);
  wrap.classList.toggle("timed", timed);
  for (const l of lyricLines) {
    const line = el(timed && l.start != null ? "button" : "p", { class: "np-lyric" }, [l.text || "♪"]);
    if (timed && l.start != null) line.addEventListener("click", () => void audio.seek(l.start!));
    wrap.append(line);
  }
  return wrap;
}

function chaptersView(): HTMLElement {
  const item = audio.current();
  const chapters: any[] = item?.Chapters ?? [];
  const wrap = el("div", { class: "np-chapters" });
  if (!chapters.length) {
    wrap.append(el("p", { class: "np-empty" }, ["This book has no chapter marks."]));
    return wrap;
  }
  chapters.forEach((c, i) => {
    const start = m.secondsOf(c.StartPositionTicks);
    wrap.append(el("button", { class: "np-chapter-row", onClick: () => void audio.seek(start) }, [
      el("span", {}, [c.Name || `Chapter ${i + 1}`]),
      el("span", { class: "np-chapter-time" }, [m.clock(start)]),
    ]));
  });
  return wrap;
}

// ---------- Wiring ----------

function sync(): void {
  (bar as any)?.__sync?.();
  if (np && !np.classList.contains("hidden")) (np as any).__sync?.();
}

function isTyping(t: EventTarget | null): boolean {
  const n = t as HTMLElement | null;
  return !!n && (["INPUT", "TEXTAREA", "SELECT", "BUTTON", "A"].includes(n.tagName) || n.isContentEditable || n.getAttribute?.("role") === "button");
}

/** Put the mini player in the window and keep it in step. Called once. */
export async function wireMusicPlayer(): Promise<void> {
  if (bar) return;
  bar = buildBar();
  document.getElementById("main")?.append(bar);
  audio.onChange(sync);
  await audio.wireAudio((msg) => toast(msg, "error"));
  // Space and the arrows drive music when nothing else claims them. The video
  // player's own handler runs only while a video is active, and the two never
  // are at once.
  document.addEventListener("keydown", (ev) => {
    if (!audio.isActive() || ev.ctrlKey || ev.metaKey || ev.altKey) return;
    const inNp = np && !np.classList.contains("hidden");
    // A focused control keeps its own keys (Space presses a button).
    if (isTyping(ev.target)) return;
    if (ev.key === " ") {
      ev.preventDefault();
      void audio.togglePause();
    } else if (inNp && ev.key === "ArrowLeft") {
      ev.preventDefault();
      void audio.skip(audio.queueState().book ? -15 : -10);
    } else if (inNp && ev.key === "ArrowRight") {
      ev.preventDefault();
      void audio.skip(audio.queueState().book ? 30 : 10);
    }
  });
}
