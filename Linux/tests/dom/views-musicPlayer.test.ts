// The mini player and Now Playing (src/views/musicPlayer.ts), driven through
// the stand-in audio.ts: what they draw for a song and for a book, and that
// every control asks audio.ts for the right thing.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { flush, mockJellyfin, signIn } from "../helpers/tauri";
import {
  byText,
  click,
  dblclick,
  dialogTitle,
  key,
  lastToast,
  menuLabels,
  menuTitle,
  mountShell,
  pickMenu,
  rightClick,
  settle,
  texts,
} from "../helpers/views-media";
import { book, foreverAnimated, song, TICKS_PER_SEC, type FakeAudio } from "../helpers/views-media-music";

vi.mock("../../src/audio", async () => (await import("../helpers/views-media-music")).fakeAudioModule());

type MP = typeof import("../../src/views/musicPlayer");

let mp: MP;
let audio: FakeAudio;
let lyrics: any;

beforeEach(() => {
  vi.resetModules();
  vi.clearAllMocks();
  lyrics = { __status: 404 };
});

// wireMusicPlayer adds its keyboard handler to the document, which outlives a
// test; take each test's handler off again so the next test sees only its own.
let docListeners: [string, any, any][] = [];
afterEach(() => {
  for (const [t, fn, o] of docListeners) document.removeEventListener(t, fn, o);
  docListeners = [];
});

async function boot(): Promise<void> {
  mountShell();
  const app = document.createElement("div");
  app.id = "app";
  document.body.append(app);
  mockJellyfin([[/^\/Audio\/[^/]+\/Lyrics/, () => lyrics]]);
  await signIn();
  audio = (await import("../../src/audio")) as any;
  audio.__reset();
  mp = await import("../../src/views/musicPlayer");
  const add = document.addEventListener.bind(document);
  const spy = vi.spyOn(document, "addEventListener").mockImplementation((t: any, fn: any, o?: any) => {
    docListeners.push([t, fn, o]);
    add(t, fn, o);
  });
  try {
    await mp.wireMusicPlayer();
  } finally {
    spy.mockRestore();
  }
}

const bar = () => document.getElementById("music-bar")!;
const np = () => document.getElementById("now-playing")!;
const btn = (root: ParentNode, title: string) => root.querySelector<HTMLButtonElement>(`button[title="${title}"]`)!;
const iconOf = (b: Element) => b.querySelector(".ico")!.innerHTML;

const s1 = () => song("s1", { Name: "First", Album: "The Album" });
const s2 = () => song("s2", { Name: "Second" });
const s3 = () => song("s3", { Name: "Third" });

describe("wireMusicPlayer", () => {
  it("puts one hidden mini player in the window, follows audio.ts and shows its errors", async () => {
    await boot();
    expect(bar().parentElement!.id).toBe("main");
    expect(bar().classList.contains("hidden")).toBe(true);
    expect(bar().getAttribute("aria-label")).toBe("Music player");
    await mp.wireMusicPlayer();
    expect(document.querySelectorAll("#music-bar")).toHaveLength(1);
    expect(audio.onChange).toHaveBeenCalledTimes(1);
    const onError = vi.mocked(audio.wireAudio).mock.calls[0]![0] as (m: string) => void;
    onError("mpv crashed");
    expect(lastToast()).toBe("mpv crashed");
  });
});

describe("the mini player", () => {
  it("shows the song, its artist and album, the time and the progress while it plays", async () => {
    await boot();
    audio.__playing([s1(), s2()], 0, {}, { position: 10, duration: 200, paused: false });
    expect(bar().classList.contains("hidden")).toBe(false);
    expect(document.getElementById("content")!.classList.contains("has-music")).toBe(true);
    expect(bar().querySelector(".mb-title")!.textContent).toBe("First");
    expect(bar().querySelector(".mb-sub")!.textContent).toBe("The Band — The Album");
    expect(bar().querySelector(".mb-time")!.textContent).toBe("0:10 / 3:20");
    expect(bar().querySelector<HTMLElement>(".mb-progress-fill")!.style.width).toBe("5%");
    const pauseIcon = iconOf(btn(bar(), "Play/Pause (Space)"));
    audio.__st.status.paused = true;
    audio.__emit();
    expect(iconOf(btn(bar(), "Play/Pause (Space)"))).not.toBe(pauseIcon);
    // No duration: just the position, an empty bar.
    audio.__st.status.duration = 0;
    audio.__emit();
    expect(bar().querySelector(".mb-time")!.textContent).toBe("0:10");
    expect(bar().querySelector<HTMLElement>(".mb-progress-fill")!.style.width).toBe("0px");
  });

  it("redraws the cover and title only when the song changes", async () => {
    await boot();
    audio.__playing([s1(), s2()]);
    const cover = bar().querySelector(".mb-cover")!.firstChild;
    audio.__emit();
    expect(bar().querySelector(".mb-cover")!.firstChild).toBe(cover);
    audio.__st.q.index = 1;
    audio.__emit();
    expect(bar().querySelector(".mb-cover")!.firstChild).not.toBe(cover);
    expect(bar().querySelector(".mb-title")!.textContent).toBe("Second");
  });

  it("hides again when nothing is playing", async () => {
    await boot();
    audio.__playing([s1()]);
    audio.__st.status.active = false;
    audio.__emit();
    expect(bar().classList.contains("hidden")).toBe(true);
    expect(document.getElementById("content")!.classList.contains("has-music")).toBe(false);
  });

  it("drives the queue for a song: previous, play/pause, next, stop", async () => {
    await boot();
    audio.__playing([s1()]);
    click(btn(bar(), "Previous"));
    click(btn(bar(), "Play/Pause (Space)"));
    click(btn(bar(), "Next"));
    click(btn(bar(), "Stop"));
    expect(audio.previous).toHaveBeenCalled();
    expect(audio.togglePause).toHaveBeenCalled();
    expect(audio.next).toHaveBeenCalled();
    expect(audio.stop).toHaveBeenCalled();
  });

  it("skips by seconds for a book, and shows the chapter for its subtitle (regression: 32f1e9f book-only controls)", async () => {
    await boot();
    audio.__st.chapter = { name: "Chapter Two", index: 1, start: 60, end: 120 };
    audio.__playing([book("b1")], 0, { book: true });
    expect(bar().querySelector(".mb-sub")!.textContent).toBe("Chapter Two");
    click(btn(bar(), "Back 15 seconds"));
    click(btn(bar(), "Forward 30 seconds"));
    expect(vi.mocked(audio.skip).mock.calls).toEqual([[-15], [30]]);
    audio.__st.chapter = null;
    audio.__emit();
    expect(bar().querySelector(".mb-sub")!.textContent).toBe("Ann Author");
  });

  it("seeks from a click on the thin line along the top, and not when the length is unknown", async () => {
    await boot();
    audio.__playing([s1()], 0, {}, { duration: 200 });
    const line = bar().querySelector<HTMLElement>(".mb-progress")!;
    line.getBoundingClientRect = () => ({ left: 100, width: 400, top: 0, right: 500, bottom: 2, height: 2, x: 100, y: 0, toJSON() {} }) as DOMRect;
    click(line, { clientX: 200 });
    expect(vi.mocked(audio.seek).mock.calls[0]![0]).toBe(50);
    audio.__st.status.duration = 0;
    click(line, { clientX: 200 });
    expect(audio.seek).toHaveBeenCalledTimes(1);
  });

  it("sets the volume from the slider, mutes from the button, and shows the mute icon", async () => {
    await boot();
    audio.__playing([s1()], 0, {}, { volume: 65 });
    const range = bar().querySelector<HTMLInputElement>(".mu-vol")!;
    expect(range.value).toBe("65");
    expect(range.style.getPropertyValue("--fill")).toBe("50%");
    const volIcon = iconOf(btn(bar(), "Mute"));
    range.value = "130";
    range.dispatchEvent(new Event("input"));
    expect(vi.mocked(audio.setVolume).mock.calls[0]![0]).toBe(130);
    // While the slider is held, a status tick doesn't move it back.
    audio.__emit();
    expect(range.value).toBe("130");
    range.dispatchEvent(new Event("change"));
    audio.__emit();
    expect(range.value).toBe("65");
    click(btn(bar(), "Mute"));
    expect(vi.mocked(audio.setMute).mock.calls[0]![0]).toBe(true);
    audio.__st.status.mute = true;
    audio.__emit();
    expect(iconOf(btn(bar(), "Mute"))).not.toBe(volIcon);
    audio.__st.status.mute = false;
    audio.__st.status.volume = 0;
    audio.__emit();
    expect(iconOf(btn(bar(), "Mute"))).not.toBe(volIcon);
  });

  it("opens Now Playing from the cover, the text and Up Next", async () => {
    await boot();
    audio.__playing([s1(), s2()]);
    click(bar().querySelector(".mb-cover"));
    expect(np().classList.contains("hidden")).toBe(false);
    expect(np().parentElement!.id).toBe("app");
    key(np(), "Escape");
    expect(np().classList.contains("hidden")).toBe(true);
    click(bar().querySelector(".mb-text"));
    expect(np().classList.contains("hidden")).toBe(false);
    click(np().querySelector(".np-close"));
    click(btn(bar(), "Up Next"));
    expect(np().querySelector(".np-tab.active")!.textContent).toBe("Up Next");
    expect(document.querySelectorAll("#now-playing")).toHaveLength(1);
  });
});

describe("keyboard", () => {
  it("Space plays and pauses when nothing else has the key, and the arrows skip only in Now Playing", async () => {
    await boot();
    expect(key(document.body, " ").defaultPrevented).toBe(false);
    audio.__playing([s1()]);
    expect(key(document.body, " ").defaultPrevented).toBe(true);
    expect(audio.togglePause).toHaveBeenCalledTimes(1);
    key(document.body, "ArrowLeft");
    expect(audio.skip).not.toHaveBeenCalled();
    key(document.body, " ", { ctrlKey: true });
    expect(audio.togglePause).toHaveBeenCalledTimes(1);
    // A focused control keeps its keys.
    const input = document.createElement("input");
    document.body.append(input);
    key(input, " ");
    const role = document.createElement("div");
    role.setAttribute("role", "button");
    document.body.append(role);
    key(role, " ");
    expect(audio.togglePause).toHaveBeenCalledTimes(1);
    mp.openNowPlaying();
    key(document.body, "ArrowLeft");
    key(document.body, "ArrowRight");
    key(document.body, "x");
    expect(vi.mocked(audio.skip).mock.calls).toEqual([[-10], [10]]);
    audio.__st.q.book = true;
    key(document.body, "ArrowLeft");
    key(document.body, "ArrowRight");
    expect(vi.mocked(audio.skip).mock.calls.slice(2)).toEqual([[-15], [30]]);
  });
});

describe("Now Playing", () => {
  it("opens on Up Next for music with the play button focused, and shows what plays and from where", async () => {
    await boot();
    audio.__playing([s1(), s2(), s3()], 0, { title: "The Album" }, { position: 30, duration: 200 });
    mp.openNowPlaying();
    expect(texts(np(), ".np-tab")).toEqual(["Up Next", "Lyrics"]);
    expect(np().querySelector(".np-tab.active")!.getAttribute("aria-selected")).toBe("true");
    expect(document.activeElement).toBe(np().querySelector(".np-play"));
    expect(np().querySelector(".np-title")!.textContent).toBe("First");
    expect(np().querySelector(".np-sub")!.textContent).toBe("The Band — The Album");
    expect(np().querySelector(".np-chapter")!.textContent).toBe("Playing from The Album");
    const times = texts(np(), ".np-times span");
    expect(times).toEqual(["0:30", "-2:50"]);
    expect(np().querySelector<HTMLInputElement>(".mu-scrub")!.value).toBe("150");
    expect(texts(np(), ".np-qrow .mu-song-title")).toEqual(["Second", "Third"]);
    expect(np().querySelector(".np-queue-title")!.textContent).toBe("Playing from The Album");
    // The links close the view on the way out.
    click(np().querySelector(".np-sub a[href='#/music/artist/ar1']"));
    expect(np().classList.contains("hidden")).toBe(true);
  });

  it("has no links for a song without an artist id or album, and no time left without a length", async () => {
    await boot();
    audio.__playing([song("x", { AlbumArtists: [], ArtistItems: [], AlbumId: undefined, Album: undefined, AlbumArtist: "Someone" })], 0, {}, { duration: 0 });
    mp.openNowPlaying();
    expect(np().querySelector(".np-sub a")).toBeNull();
    expect(np().querySelector(".np-sub")!.textContent).toBe("Someone");
    expect(texts(np(), ".np-times span")[1]).toBe("");
    expect(np().querySelector(".np-chapter")!.textContent).toBe("");
  });

  it("opens a book on its chapters, with the book's controls in place of the music ones (regression: 32f1e9f Now Playing opens a book on its chapters)", async () => {
    await boot();
    const b = book("b1", { Chapters: [{ Name: "One", StartPositionTicks: 0 }, { StartPositionTicks: 600 * TICKS_PER_SEC }] });
    audio.__st.chapter = { name: "One", index: 0, start: 0, end: 600 };
    audio.__playing([b], 0, { book: true });
    mp.openNowPlaying();
    expect(texts(np(), ".np-tab")).toEqual(["Chapters", "Up Next"]);
    expect(np().querySelector(".np-tab.active")!.textContent).toBe("Chapters");
    expect(texts(np(), ".np-chapter-row span:first-child")).toEqual(["One", "Chapter 2"]);
    expect(texts(np(), ".np-chapter-time")).toEqual(["0:00", "10:00"]);
    expect(np().querySelectorAll(".np-chapter-row.current")).toHaveLength(1);
    expect(np().querySelector(".np-chapter")!.textContent).toBe("One");
    for (const t of ["Shuffle", "Previous", "Next"]) expect(btn(np(), t).hasAttribute("hidden")).toBe(true);
    expect(btn(np(), "Repeat: off").hasAttribute("hidden")).toBe(true);
    for (const t of ["Back 15 seconds", "Forward 30 seconds"]) expect(btn(np(), t).hasAttribute("hidden")).toBe(false);
    expect(np().querySelector(".np-speed")!.hasAttribute("hidden")).toBe(false);
    expect(np().querySelector(".np-speed")!.textContent).toBe("1×");
    expect(np().querySelector(".np-sc")!.hasAttribute("hidden")).toBe(true);
    expect(btn(np(), "Instant Mix").hasAttribute("hidden")).toBe(true);
    expect(np().querySelector(".np-sub a")).toBeNull();
    click(np().querySelectorAll(".np-chapter-row")[1]!);
    expect(vi.mocked(audio.seek).mock.calls[0]![0]).toBe(600);
    click(btn(np(), "Back 15 seconds"));
    click(btn(np(), "Forward 30 seconds"));
    expect(vi.mocked(audio.skip).mock.calls).toEqual([[-15], [30]]);
    // Lyrics isn't a book's tab: asking for it lands on Chapters. No lyrics are fetched.
    mp.openNowPlaying("lyrics");
    expect(np().querySelector(".np-tab.active")!.textContent).toBe("Chapters");
    expect(np().querySelector(".np-lyrics")).toBeNull();
  });

  it("says when a book has no chapter marks, and puts music back on Up Next after a book", async () => {
    await boot();
    audio.__playing([book("b1")], 0, { book: true });
    mp.openNowPlaying();
    expect(np().querySelector(".np-chapters .np-empty")!.textContent).toBe("This book has no chapter marks.");
    audio.__playing([s1()], 0, { book: false });
    mp.openNowPlaying();
    expect(np().querySelector(".np-tab.active")!.textContent).toBe("Up Next");
    // A book's Chapters tab asked of music lands on Up Next.
    mp.openNowPlaying("chapters");
    expect(np().querySelector(".np-tab.active")!.textContent).toBe("Up Next");
  });

  it("finds timed lyrics, highlights the line being sung and seeks to a line clicked", async () => {
    lyrics = { Lyrics: [{ Text: "Hello", Start: 0 }, { Text: "", Start: 50_000_000 }, { Text: "World", Start: 100_000_000 }] };
    await boot();
    audio.__playing([s1()], 0, {}, { position: 6 });
    mp.openNowPlaying("lyrics");
    expect(np().querySelector(".np-lyrics .np-empty")!.textContent).toBe("Looking for lyrics…");
    await settle();
    expect(np().querySelector(".np-lyrics.timed")).not.toBeNull();
    expect(texts(np(), "button.np-lyric")).toEqual(["Hello", "♪", "World"]);
    expect(texts(np(), ".np-lyric.current")).toEqual(["♪"]);
    audio.__st.status.position = 9.8;
    audio.__emit();
    expect(texts(np(), ".np-lyric.current")).toEqual(["World"]);
    click(np().querySelectorAll("button.np-lyric")[0]!);
    expect(vi.mocked(audio.seek).mock.calls[0]![0]).toBe(0);
    // Leaving and coming back to the tab rebuilds it.
    click(byText(np(), ".np-tab", "Up Next"));
    expect(np().querySelector(".np-lyrics")).toBeNull();
    click(byText(np(), ".np-tab", "Lyrics"));
    expect(np().querySelector(".np-lyrics")).not.toBeNull();
  });

  it("shows plain lyrics as text, and says when a song has none", async () => {
    lyrics = { Lyrics: [{ Text: "Just words" }] };
    await boot();
    audio.__playing([s1(), s2()]);
    mp.openNowPlaying("lyrics");
    await settle();
    expect(np().querySelector(".np-lyrics.timed")).toBeNull();
    expect(texts(np(), "p.np-lyric")).toEqual(["Just words"]);
    lyrics = { __status: 404 };
    audio.__st.q.index = 1;
    audio.__emit();
    await settle();
    expect(np().querySelector(".np-lyrics .np-empty")!.textContent).toMatch(/^No lyrics for this song/);
  });

  it("ignores lyrics that arrive after the song moved on", async () => {
    let release!: (v: any) => void;
    lyrics = new Promise((r) => (release = r));
    await boot();
    audio.__playing([s1(), s2()]);
    mp.openNowPlaying("lyrics");
    lyrics = { Lyrics: [{ Text: "Second's words" }] };
    audio.__st.q.index = 1;
    audio.__emit();
    await settle();
    release({ Lyrics: [{ Text: "First's words" }] });
    await settle();
    expect(texts(np(), ".np-lyric")).toEqual(["Second's words"]);
  });

  it("keeps Up Next in place across ticks and rebuilds it only when the queue changes", async () => {
    await boot();
    audio.__playing([s1(), s2(), s3()]);
    mp.openNowPlaying();
    const list = np().querySelector(".np-queue");
    audio.__st.status.position = 12;
    audio.__emit();
    expect(np().querySelector(".np-queue")).toBe(list);
    audio.__st.q.items = [s1(), s3()];
    audio.__emit();
    expect(np().querySelector(".np-queue")).not.toBe(list);
    expect(texts(np(), ".np-qrow .mu-song-title")).toEqual(["Third"]);
  });

  it("works each Up Next row: double-click and Enter play, Delete and × remove, Alt+arrows and drops move", async () => {
    await boot();
    audio.__playing([s1(), s2(), s3()]);
    mp.openNowPlaying();
    const rows = () => Array.from(np().querySelectorAll<HTMLElement>(".np-qrow"));
    dblclick(rows()[1]);
    key(rows()[0], "Enter");
    key(rows()[0], "Delete");
    expect(key(rows()[1], "ArrowUp", { altKey: true }).defaultPrevented).toBe(true);
    key(rows()[0], "ArrowDown", { altKey: true });
    key(rows()[0], "ArrowDown");
    click(rows()[1]!.querySelector("button[title='Remove from Up Next']"));
    expect(vi.mocked(audio.jump).mock.calls).toEqual([[2], [1]]);
    expect(vi.mocked(audio.removeAt).mock.calls).toEqual([[1], [2]]);
    expect(vi.mocked(audio.move).mock.calls).toEqual([[2, 1], [1, 2]]);
    const store = new Map<string, string>();
    const fire = (n: HTMLElement, type: string) => {
      const ev = new Event(type, { bubbles: true, cancelable: true }) as any;
      ev.dataTransfer = { setData: (k: string, v: string) => store.set(k, v), getData: (k: string) => store.get(k) ?? "" };
      n.dispatchEvent(ev);
      return ev;
    };
    fire(rows()[1]!, "dragstart");
    expect(rows()[1]!.classList.contains("dragging")).toBe(true);
    expect(fire(rows()[0]!, "dragover").defaultPrevented).toBe(true);
    expect(rows()[0]!.classList.contains("drop-target")).toBe(true);
    fire(rows()[0]!, "dragleave");
    fire(rows()[1]!, "dragend");
    expect(rows()[1]!.classList.contains("dragging")).toBe(false);
    fire(rows()[1]!, "dragstart");
    fire(rows()[0]!, "drop");
    expect(vi.mocked(audio.move).mock.calls.at(-1)).toEqual([2, 1]);
    expect(rows()[0]!.classList.contains("drop-target")).toBe(false);
  });

  it("offers Play Now, Move to Top, Remove and Song Info on an Up Next row's menu", async () => {
    mockJellyfin([[/^\/Items\/s3\?/, song("s3")]]);
    await boot();
    mockJellyfin([[/^\/Items\/s3\?/, song("s3")], [/Lyrics/, { __status: 404 }]]);
    audio.__playing([s1(), s2(), s3()]);
    mp.openNowPlaying();
    const row = () => np().querySelectorAll<HTMLElement>(".np-qrow")[1]!;
    rightClick(row());
    expect(menuTitle()).toBe("Third");
    expect(menuLabels()).toEqual(["Play Now", "Move to Top", "Remove from Up Next", "Song Info"]);
    await pickMenu("Play Now");
    rightClick(row());
    await pickMenu("Move to Top");
    rightClick(row());
    await pickMenu("Remove from Up Next");
    expect(vi.mocked(audio.jump).mock.calls).toEqual([[2]]);
    expect(vi.mocked(audio.move).mock.calls).toEqual([[2, 1]]);
    expect(vi.mocked(audio.removeAt).mock.calls).toEqual([[2]]);
    rightClick(row());
    await pickMenu("Song Info");
    await settle();
    expect(dialogTitle()).toBe("Song Info");
  });

  it("leaves Song Info off a book part's Up Next menu", async () => {
    await boot();
    audio.__playing([book("b1"), book("b2")], 0, { book: true });
    mp.openNowPlaying("queue");
    rightClick(np().querySelector(".np-qrow"));
    expect(menuLabels()).toEqual(["Play Now", "Move to Top", "Remove from Up Next"]);
  });

  it("titles Up Next by where it came from, notes an offline mix, and clears it", async () => {
    await boot();
    audio.__playing([s1(), s2()], 0, { title: "Jazz Station", source: { title: "x" }, offlineMix: true });
    mp.openNowPlaying();
    expect(np().querySelector(".np-queue-title span")!.textContent).toBe("Jazz Station · keeps going");
    expect(np().querySelector(".np-offline-mix")!.textContent).toBe("Offline — mixed from your downloads");
    click(byText(np(), ".np-queue-head button", "Clear"));
    expect(audio.clearUpNext).toHaveBeenCalled();
    audio.__playing([s1()], 0, { title: "", source: null, offlineMix: false, repeat: "off" });
    expect(np().querySelector(".np-queue-title")!.textContent).toBe("Up Next");
    expect(np().querySelector(".np-queue-head button")).toBeNull();
    expect(np().querySelector(".np-queue .np-empty")!.textContent).toBe("Nothing after this. Play Next and Play Later add songs here.");
    audio.__st.q.repeat = "all";
    audio.__st.q.items = [s1()];
    mp.openNowPlaying();
    expect(np().querySelector(".np-queue .np-empty")!.textContent).toBe("The queue starts again after this.");
  });

  it("drives the transport, shuffle and repeat, and shows their state", async () => {
    await boot();
    audio.__playing([s1(), s2()]);
    mp.openNowPlaying();
    const repeat = () => np().querySelector<HTMLButtonElement>(".np-transport button[title^='Repeat']")!;
    expect(repeat().title).toBe("Repeat: off");
    click(btn(np(), "Shuffle"));
    click(btn(np(), "Previous"));
    click(btn(np(), "Next"));
    click(np().querySelector(".np-play"));
    click(repeat());
    expect(vi.mocked(audio.setShuffle).mock.calls[0]![0]).toBe(true);
    expect(audio.previous).toHaveBeenCalled();
    expect(audio.next).toHaveBeenCalled();
    expect(audio.togglePause).toHaveBeenCalled();
    expect(audio.cycleRepeat).toHaveBeenCalled();
    audio.__st.q.original = [];
    audio.__st.q.repeat = "all";
    audio.__emit();
    expect(btn(np(), "Shuffle").classList.contains("on")).toBe(true);
    expect(repeat().title).toBe("Repeat: all");
    expect(repeat().classList.contains("on")).toBe(true);
    const allIcon = iconOf(repeat());
    audio.__st.q.repeat = "one";
    audio.__emit();
    expect(repeat().title).toBe("Repeat: this song");
    expect(iconOf(repeat())).not.toBe(allIcon);
    click(btn(np(), "Shuffle"));
    expect(vi.mocked(audio.setShuffle).mock.calls[1]![0]).toBe(false);
  });

  it("seeks from the scrubber when it's let go, holding still while dragged", async () => {
    await boot();
    audio.__playing([s1()], 0, {}, { position: 0, duration: 200 });
    mp.openNowPlaying();
    const scrub = np().querySelector<HTMLInputElement>(".mu-scrub")!;
    scrub.value = "500";
    scrub.dispatchEvent(new Event("input"));
    expect(scrub.style.getPropertyValue("--fill")).toBe("50%");
    audio.__st.status.position = 20;
    audio.__emit();
    expect(scrub.value).toBe("500");
    scrub.dispatchEvent(new Event("change"));
    expect(vi.mocked(audio.seek).mock.calls[0]![0]).toBe(100);
    audio.__emit();
    expect(scrub.value).toBe("100");
    audio.__st.status.duration = 0;
    audio.__emit();
    expect(scrub.value).toBe("0");
    scrub.dispatchEvent(new Event("change"));
    expect(audio.seek).toHaveBeenCalledTimes(1);
  });

  it("sets a book's speed from its menu", async () => {
    await boot();
    audio.__playing([book("b1")], 0, { book: true });
    mp.openNowPlaying();
    click(np().querySelector(".np-speed"));
    expect(menuTitle()).toBe("Speed");
    expect(menuLabels()).toContain("1×  ✓");
    await pickMenu("1.5×");
    expect(vi.mocked(audio.setSpeed).mock.calls[0]![0]).toBe(1.5);
    audio.__emit();
    expect(np().querySelector(".np-speed")!.textContent).toBe("1.5×");
  });

  it("turns Sound Check on and off and shows which", async () => {
    await boot();
    audio.__playing([s1()]);
    mp.openNowPlaying();
    const sc = np().querySelector<HTMLButtonElement>(".np-sc")!;
    expect(sc.hasAttribute("hidden")).toBe(false);
    click(sc);
    await settle();
    expect(vi.mocked(audio.setSoundCheck).mock.calls[0]![0]).toBe(true);
    expect(sc.classList.contains("active")).toBe(true);
    vi.mocked(audio.setSoundCheck).mockRejectedValueOnce(new Error("no replaygain"));
    click(sc);
    await settle();
    expect(lastToast()).toBe("no replaygain");
  });

  it("sets a sleep timer, says how long is left, and turns it off", async () => {
    await boot();
    audio.__playing([s1()]);
    mp.openNowPlaying();
    const sleep = btn(np(), "Sleep timer");
    click(sleep);
    expect(menuTitle()).toBe("Sleep Timer");
    expect(menuLabels()).toEqual(["15 minutes", "30 minutes", "45 minutes", "60 minutes", "90 minutes", "End of this song"]);
    await pickMenu("30 minutes");
    await settle();
    expect(vi.mocked(audio.setSleep).mock.calls[0]![0]).toBe(30);
    expect(lastToast()).toBe("Stopping in 30 minutes");
    click(sleep);
    await pickMenu("End of this song");
    await settle();
    expect(lastToast()).toBe("Stopping after this song");
    audio.__st.sleep = { mode: "time", at: Date.now() + 12 * 60_000 + 1000 };
    audio.__emit();
    expect(sleep.classList.contains("on")).toBe(true);
    click(sleep);
    expect(menuLabels()[0]).toBe("Turn off (12 min left)");
    await pickMenu("Turn off");
    expect(vi.mocked(audio.setSleep).mock.calls.at(-1)![0]).toBe("off");
    audio.__st.sleep = { mode: "track", at: 0 };
    audio.__st.q.book = true;
    click(sleep);
    expect(menuLabels()[0]).toBe("Turn off");
    expect(menuLabels().at(-1)).toBe("End of chapter");
    await pickMenu("End of chapter");
    await settle();
    expect(lastToast()).toBe("Stopping at the end of the chapter");
    audio.__st.sleep = { mode: "time", at: Date.now() - 5000 };
    click(sleep);
    expect(menuLabels()[0]).toBe("Turn off (0 min left)");
  });

  it("Instant Mix is held down while the mix is built, and only offered for a song", async () => {
    await boot();
    audio.__playing([s1()]);
    mp.openNowPlaying();
    const mix = btn(np(), "Instant Mix");
    expect(mix.hasAttribute("hidden")).toBe(false);
    click(mix);
    expect(mix.disabled).toBe(true);
    await settle();
    expect(mix.disabled).toBe(false);
    audio.__playing([{ Id: "v", Type: "MusicVideo", Name: "Clip" }]);
    expect(mix.hasAttribute("hidden")).toBe(true);
  });

  it("More offers the song's menu without the Play entries, Station Mix and Stop", async () => {
    await boot();
    audio.__playing([s1()]);
    mp.openNowPlaying();
    click(btn(np(), "More"));
    expect(menuTitle()).toBe("First");
    const labels = menuLabels();
    expect(labels).not.toContain("Play");
    expect(labels).not.toContain("Play Next");
    expect(labels).not.toContain("Play Later");
    expect(labels).not.toContain("Details");
    expect(labels.slice(-2)).toEqual(["Station Mix…", "Stop"]);
    await pickMenu("Station Mix…");
    expect(dialogTitle()).toBe("Station Mix");
    click(btn(np(), "More"));
    await pickMenu("Stop");
    expect(audio.stop).toHaveBeenCalled();
    expect(np().classList.contains("hidden")).toBe(true);
  });

  it("More on a book goes to its Details page", async () => {
    await boot();
    audio.__playing([book("b1")], 0, { book: true });
    mp.openNowPlaying();
    click(btn(np(), "More"));
    await pickMenu("Details");
    expect(location.hash).toBe("#/books/book/b1");
    expect(np().classList.contains("hidden")).toBe(true);
  });

  it("More does nothing with nothing playing, and the view closes itself when playback ends", async () => {
    await boot();
    audio.__playing([s1()]);
    mp.openNowPlaying();
    audio.__st.q.index = -1;
    click(btn(np(), "More"));
    expect(document.querySelector(".menu")).toBeNull();
    audio.__st.status.active = false;
    audio.__emit();
    expect(np().classList.contains("hidden")).toBe(true);
    // With the item gone but playback still said to be on, it stays as it was.
    audio.__st.status.active = true;
    audio.__st.q.index = 0;
    mp.openNowPlaying();
    audio.__st.q.index = 5;
    audio.__emit();
    expect(np().classList.contains("hidden")).toBe(false);
  });

  it("other keys inside Now Playing are left alone", async () => {
    await boot();
    audio.__playing([s1()]);
    mp.openNowPlaying();
    expect(key(np(), "a").defaultPrevented).toBe(false);
    expect(np().classList.contains("hidden")).toBe(false);
  });

  it("nothing on the persistent mini player or Now Playing animates forever (Linux/CLAUDE.md)", async () => {
    await boot();
    audio.__playing([s1(), s2()], 0, {}, { position: 1, duration: 200 });
    mp.openNowPlaying();
    await flush();
    expect(foreverAnimated(document)).toEqual([]);
  });
});
