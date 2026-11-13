// The music and audiobook queue (src/audio.ts) against the mocked bridge.
//
// mpv only ever holds the playing song and the one after it, so most of what
// is checked here is which `audio_*` command goes down for a queue operation,
// and how the queue follows the `audio-*` events that come back.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  clearInvokeCalls,
  emitEvent,
  flush,
  invokeCalls,
  listenerCount,
  onInvoke,
  onInvokes,
  signIn,
} from "../helpers/tauri";

type Audio = typeof import("../../src/audio");
let audio: Audio;

const SERVER = "http://jf.test:8096";

function song(id: string, extra: Record<string, any> = {}): any {
  return {
    Id: id,
    Name: `Song ${id}`,
    Type: "Audio",
    Album: "The Album",
    AlbumArtist: "The Artist",
    AlbumId: "alb",
    AlbumPrimaryImageTag: "tag",
    RunTimeTicks: 1_800_000_000,
    IndexNumber: 1,
    ...extra,
  };
}

function songs(ids: string): any[] {
  return ids.split("").map((id) => song(id));
}

function book(extra: Record<string, any> = {}): any {
  return {
    Id: "book",
    Name: "The Book",
    Type: "AudioBook",
    SeriesName: "The Series",
    RunTimeTicks: 18_000_000_000,
    Chapters: [
      { Name: "One", StartPositionTicks: 0 },
      { Name: "", StartPositionTicks: 6_000_000_000 },
      { Name: "Three", StartPositionTicks: 12_000_000_000 },
    ],
    ...extra,
  };
}

/** Answer every audio command, sign in, and load a fresh copy of the module. */
async function load(cfg: Record<string, any> = {}): Promise<void> {
  onInvokes({
    audio_play: null,
    audio_set_next: null,
    audio_set_queue: null,
    audio_stop: null,
    audio_command: null,
    downloads_list: [],
  });
  await signIn(cfg);
  audio = await import("../../src/audio");
}

const ids = () => audio.queueState().items.map((i) => i.Id).join("");
const last = (cmd: string) => invokeCalls(cmd).at(-1)?.args;
const commands = () => invokeCalls("audio_command").map((c) => c.args.cmd);
const handedDown = () => invokeCalls("audio_set_next").map((c) => c.args.next?.item_id ?? null);

beforeEach(() => {
  vi.resetModules();
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("reading the queue", () => {
  it("starts with nothing playing", async () => {
    await load();
    expect(audio.isActive()).toBe(false);
    expect(audio.current()).toBeNull();
    expect(audio.upNext()).toEqual([]);
    expect(audio.isShuffled()).toBe(false);
    expect(audio.currentChapter()).toBeNull();
    expect(audio.getStatus()).toMatchObject({ active: false, paused: false, position: 0, volume: 100, speed: 1 });
    expect(audio.queueState()).toMatchObject({ index: -1, repeat: "off", source: null, book: false, offlineMix: false });
    expect(audio.sleepState()).toEqual({ mode: "off", at: 0 });
  });

  it("tells every listener about a change, until it unsubscribes", async () => {
    await load();
    const a = vi.fn();
    const b = vi.fn();
    const offA = audio.onChange(a);
    audio.onChange(b);
    await audio.play(songs("ab"));
    expect(a).toHaveBeenCalled();
    expect(b).toHaveBeenCalled();
    const before = b.mock.calls.length;
    a.mockClear();
    offA();
    await audio.next();
    expect(a).not.toHaveBeenCalled();
    expect(b.mock.calls.length).toBeGreaterThan(before);
  });

  it("keeps telling the other listeners when one of them throws", async () => {
    await load();
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    const after = vi.fn();
    audio.onChange(() => {
      throw new Error("a broken view");
    });
    audio.onChange(after);
    await audio.play(songs("a"));
    expect(after).toHaveBeenCalled();
    expect(err).toHaveBeenCalled();
    expect(audio.isActive()).toBe(true);
  });

  it("lists what follows the current song as Up Next", async () => {
    await load();
    await audio.play(songs("abcd"), 1);
    expect(audio.current().Id).toBe("b");
    expect(audio.upNext().map((i) => i.Id)).toEqual(["c", "d"]);
  });
});

describe("repeat mode across launches", () => {
  it.each(["all", "one"])("comes back as %s when that was the last choice", async (mode) => {
    localStorage.setItem("aquarium.music-repeat", mode);
    await load();
    expect(audio.queueState().repeat).toBe(mode);
  });

  it("ignores a stored value it doesn't know", async () => {
    localStorage.setItem("aquarium.music-repeat", "sometimes");
    await load();
    expect(audio.queueState().repeat).toBe("off");
  });

  it("falls back to off when storage can't be read", async () => {
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("storage is off");
    });
    await load();
    expect(audio.queueState().repeat).toBe("off");
    expect(audio.bookSpeed()).toBe(1);
  });
});

describe("play", () => {
  it("does nothing for an empty list", async () => {
    await load();
    await audio.play([]);
    await audio.play([null, {}, { Name: "no id" }]);
    expect(invokeCalls("audio_play")).toHaveLength(0);
    expect(invokeCalls("downloads_list")).toHaveLength(0);
    expect(audio.isActive()).toBe(false);
  });

  it("drops entries that aren't items", async () => {
    await load();
    await audio.play([null, song("a"), {}, song("b")]);
    expect(ids()).toBe("ab");
  });

  it("hands mpv the song and the one after it, and nothing more", async () => {
    await load();
    await audio.play(songs("abc"), 0, { title: "An Album" });
    const req = last("audio_play").req;
    expect(req.track).toEqual({
      item_id: "a",
      url: `${SERVER}/Audio/a/stream?static=true&MediaSourceId=a&DeviceId=device-1`,
      title: "Song a",
      artist: "The Artist",
      album: "The Album",
      album_artist: "The Artist",
      art_url: `${SERVER}/Items/alb/Images/Primary?maxWidth=600&tag=tag&quality=90`,
      duration: 180,
      track_number: 1,
      is_local: false,
    });
    expect(req.next.item_id).toBe("b");
    expect(req).toMatchObject({
      start_seconds: null,
      volume: 100,
      speed: 1,
      replaygain: "track",
      loop_file: false,
      server_url: SERVER,
      user_id: "user-1",
      device_id: "device-1",
    });
    expect(audio.queueState().title).toBe("An Album");
    expect(audio.isActive()).toBe(true);
    expect(audio.getStatus()).toMatchObject({ active: true, paused: false, position: 0, item_id: "a", duration: 180 });
  });

  it("sends no next song for the last one", async () => {
    await load();
    await audio.play(songs("ab"), 1);
    expect(last("audio_play").req.next).toBeNull();
  });

  it("starts from the song asked for, held inside the list", async () => {
    await load();
    await audio.play(songs("abc"), 2);
    expect(audio.current().Id).toBe("c");
    await audio.play(songs("abc"), 99);
    expect(audio.current().Id).toBe("c");
    await audio.play(songs("abc"), -4);
    expect(audio.current().Id).toBe("a");
  });

  it("resumes partway in when told where", async () => {
    await load();
    await audio.play([book()], 0, { startSeconds: 432 });
    expect(last("audio_play").req.start_seconds).toBe(432);
    expect(audio.getStatus().position).toBe(432);
  });

  it("publishes the whole queue for MPRIS, without stream addresses", async () => {
    await load();
    await audio.play(songs("abc"), 1);
    const sent = last("audio_set_queue");
    expect(sent.entries.map((e: any) => e.item_id)).toEqual(["a", "b", "c"]);
    expect(sent.entries.every((e: any) => e.url === "")).toBe(true);
    expect(sent).toMatchObject({ index: 1, canNext: true, canPrev: true });
  });

  it("says there is no next or previous for a single song", async () => {
    await load();
    await audio.play(songs("a"));
    expect(last("audio_set_queue")).toMatchObject({ index: 0, canNext: false, canPrev: false });
    expect(audio.upNext()).toEqual([]);
  });

  it("uses the remembered volume", async () => {
    localStorage.setItem("aquarium.music-volume", "42");
    await load();
    await audio.play(songs("a"));
    expect(last("audio_play").req.volume).toBe(42);
  });

  it("falls back to full volume when the remembered one is nonsense", async () => {
    localStorage.setItem("aquarium.music-volume", "loud");
    await load();
    await audio.play(songs("a"));
    expect(last("audio_play").req.volume).toBe(100);
  });

  it("keeps the book speed for books only", async () => {
    localStorage.setItem("aquarium.book-speed", "1.5");
    await load();
    await audio.play(songs("a"));
    expect(last("audio_play").req.speed).toBe(1);
    expect(audio.queueState().book).toBe(false);
    await audio.play([book()]);
    expect(last("audio_play").req.speed).toBe(1.5);
    expect(audio.queueState().book).toBe(true);
  });

  it("lets the caller say whether it is a book", async () => {
    localStorage.setItem("aquarium.book-speed", "2");
    await load();
    await audio.play(songs("a"), 0, { book: true });
    expect(last("audio_play").req.speed).toBe(2);
    await audio.play([book()], 0, { book: false });
    expect(last("audio_play").req.speed).toBe(1);
  });

  it("files a book under its series when it has no album", async () => {
    await load();
    await audio.play([book()]);
    expect(last("audio_play").req.track.album).toBe("The Series");
    await audio.play([song("a", { Album: undefined, Name: undefined, AlbumArtist: undefined, IndexNumber: undefined })]);
    expect(last("audio_play").req.track).toMatchObject({ album: "", title: "", album_artist: "", track_number: null });
  });

  it("turns Sound Check off when the setting says so", async () => {
    await load({ music_soundcheck: false });
    expect(audio.soundCheckOn()).toBe(false);
    await audio.play(songs("a"));
    expect(last("audio_play").req.replaygain).toBe("no");
  });

  it("plays a downloaded song from disk even when started from a server page", async () => {
    await load();
    onInvoke("downloads_list", [
      { item_id: "a", status: "complete", path: "/music/a.flac" },
      { item_id: "b", status: "downloading", path: "/music/b.part" },
      { item_id: "c", status: "complete", path: "" },
      null,
    ]);
    await audio.play(songs("abc"));
    const req = last("audio_play").req;
    expect(req.track).toMatchObject({ url: "/music/a.flac", is_local: true });
    expect(req.next).toMatchObject({ item_id: "b", is_local: false });
    expect(req.next.url).toContain("/Audio/b/stream");
  });

  it("still plays when the downloads can't be listed", async () => {
    await load();
    onInvoke("downloads_list", () => {
      throw new Error("no downloads folder");
    });
    await audio.play(songs("a"));
    expect(last("audio_play").req.track.is_local).toBe(false);
  });

  it("reports a song mpv refused and is no longer active", async () => {
    await load();
    onInvoke("audio_play", () => {
      throw new Error("no audio device");
    });
    await expect(audio.play(songs("a"))).rejects.toThrow("no audio device");
    expect(audio.isActive()).toBe(false);
  });

  it("reports a refusal that arrives as a bare string", async () => {
    await load();
    onInvoke("audio_play", () => {
      throw "mpv would not start";
    });
    await expect(audio.play(songs("a"))).rejects.toThrow("mpv would not start");
  });

  it("marks a queue built from downloads while offline", async () => {
    await load();
    await audio.play(songs("ab"), 0, { offlineMix: true });
    expect(audio.queueState().offlineMix).toBe(true);
    await audio.play(songs("ab"));
    expect(audio.queueState().offlineMix).toBe(false);
  });
});

describe("shuffle", () => {
  it("Shuffle on a page starts anywhere and remembers the page's order", async () => {
    await load();
    vi.spyOn(Math, "random").mockReturnValue(0);
    const list = songs("abcd");
    await audio.play(list, 0, { shuffle: true });
    expect(ids()).toBe("bcda");
    expect(audio.current().Id).toBe("b");
    expect(audio.isShuffled()).toBe(true);
    expect(audio.queueState().original!.map((i) => i.Id).join("")).toBe("abcd");
  });

  it("a song picked with shuffle on plays first", async () => {
    await load();
    vi.spyOn(Math, "random").mockReturnValue(0);
    await audio.play(songs("abcd"), 2, { shuffle: true });
    expect(ids()).toBe("cbda");
    expect(audio.current().Id).toBe("c");
    expect(last("audio_play").req.track.item_id).toBe("c");
  });

  it("plays every song exactly once whatever the luck", async () => {
    await load();
    await audio.play(songs("abcdefgh"), 3, { shuffle: true });
    expect(ids().split("").sort().join("")).toBe("abcdefgh");
    expect(audio.current().Id).toBe("d");
  });

  it("shuffles a single song into itself", async () => {
    await load();
    await audio.play(songs("a"), 0, { shuffle: true });
    expect(ids()).toBe("a");
    expect(audio.isShuffled()).toBe(true);
    await audio.setShuffle(false);
    expect(ids()).toBe("a");
    expect(audio.current().Id).toBe("a");
  });

  it("turning it on keeps the current song playing and shuffles the rest behind it", async () => {
    await load();
    vi.spyOn(Math, "random").mockReturnValue(0);
    await audio.play(songs("abcd"), 1);
    clearInvokeCalls();
    await audio.setShuffle(true);
    expect(ids()).toBe("bcda");
    expect(audio.queueState().index).toBe(0);
    expect(audio.current().Id).toBe("b");
    expect(invokeCalls("audio_play")).toHaveLength(0);
    expect(last("audio_set_queue")).toMatchObject({ index: 0, canPrev: false, canNext: true });
  });

  it("turning it off puts the order back and stays on the current song", async () => {
    await load();
    vi.spyOn(Math, "random").mockReturnValue(0);
    await audio.play(songs("abcd"), 1);
    await audio.setShuffle(true);
    await audio.jump(2);
    expect(audio.current().Id).toBe("d");
    clearInvokeCalls();
    await audio.setShuffle(false);
    expect(ids()).toBe("abcd");
    expect(audio.queueState().index).toBe(3);
    expect(audio.isShuffled()).toBe(false);
    // d is last in the album's order, so nothing follows it any more.
    expect(handedDown()).toEqual([null]);
  });

  it("hands down the new next song when the shuffle changes it", async () => {
    await load();
    vi.spyOn(Math, "random").mockReturnValue(0);
    await audio.play(songs("abcd"), 0);
    clearInvokeCalls();
    await audio.setShuffle(true);
    // a stays; [b, c, d] shuffles to [c, d, b].
    expect(ids()).toBe("acdb");
    expect(handedDown()).toEqual(["c"]);
  });

  it("does nothing when it is already that way, or nothing is playing", async () => {
    await load();
    await audio.setShuffle(true);
    expect(audio.isShuffled()).toBe(false);
    expect(invokeCalls("audio_set_queue")).toHaveLength(0);
    await audio.play(songs("abc"));
    clearInvokeCalls();
    await audio.setShuffle(false);
    expect(invokeCalls()).toHaveLength(0);
  });

  it("songs added while shuffled are still there when shuffle goes off", async () => {
    await load();
    vi.spyOn(Math, "random").mockReturnValue(0);
    await audio.play(songs("abc"), 0, { shuffle: true });
    await audio.playNext([song("x")]);
    await audio.playLater([song("y")]);
    await audio.setShuffle(false);
    expect(ids()).toBe("abcxy");
  });

  it("a song removed while shuffled stays gone when shuffle goes off", async () => {
    await load();
    vi.spyOn(Math, "random").mockReturnValue(0);
    await audio.play(songs("abcd"), 0);
    await audio.setShuffle(true);
    expect(ids()).toBe("acdb");
    await audio.removeAt(2);
    await audio.setShuffle(false);
    expect(ids()).toBe("abc");
    expect(audio.current().Id).toBe("a");
  });
});

describe("adding to the queue", () => {
  it("Play Next starts playing when nothing is", async () => {
    await load();
    await audio.playNext(songs("ab"));
    expect(audio.current().Id).toBe("a");
    expect(invokeCalls("audio_play")).toHaveLength(1);
  });

  it("Play Next goes straight after the current song and is handed to mpv", async () => {
    await load();
    await audio.play(songs("abc"));
    clearInvokeCalls();
    await audio.playNext([song("x"), song("y")]);
    expect(ids()).toBe("axybc");
    expect(handedDown()).toEqual(["x"]);
    expect(invokeCalls("audio_play")).toHaveLength(0);
    expect(last("audio_set_queue").entries).toHaveLength(5);
  });

  it("Play Next uses a downloaded copy", async () => {
    await load();
    await audio.play(songs("ab"));
    onInvoke("downloads_list", [{ item_id: "x", status: "complete", path: "/music/x.mp3" }]);
    await audio.playNext([song("x")]);
    expect(last("audio_set_next").next).toMatchObject({ item_id: "x", url: "/music/x.mp3", is_local: true });
  });

  it("Play Later starts playing when nothing is", async () => {
    await load();
    await audio.playLater(songs("ab"));
    expect(audio.current().Id).toBe("a");
  });

  it("Play Later goes to the end", async () => {
    await load();
    await audio.play(songs("abc"));
    await audio.playLater([song("x")]);
    expect(ids()).toBe("abcx");
  });

  it("does not hand the same next song down twice (regression: each hand-down clears mpv's prefetch)", async () => {
    await load();
    await audio.play(songs("abc"));
    clearInvokeCalls();
    await audio.playLater([song("x")]);
    await audio.move(2, 3);
    await audio.removeAt(3);
    expect(invokeCalls("audio_set_next")).toHaveLength(0);
  });

  it("Play Later after the last song gives mpv something to follow it", async () => {
    await load();
    await audio.play(songs("a"));
    clearInvokeCalls();
    await audio.playLater([song("x")]);
    expect(handedDown()).toEqual(["x"]);
    expect(last("audio_set_queue").canNext).toBe(true);
  });
});

describe("replaceUpNext (Instant Mix from the song that's on)", () => {
  it("plays the list when nothing is playing", async () => {
    await load();
    await audio.replaceUpNext(songs("xy"), { title: "A Mix" });
    expect(audio.current().Id).toBe("x");
    expect(audio.queueState().title).toBe("A Mix");
  });

  it("keeps the current song playing and replaces everything after it", async () => {
    await load();
    await audio.play(songs("abcd"), 1, { title: "An Album" });
    clearInvokeCalls();
    await audio.replaceUpNext([song("x"), song("b"), null, song("y")], { title: "b Mix" });
    expect(ids()).toBe("abxy");
    expect(audio.current().Id).toBe("b");
    expect(invokeCalls("audio_play")).toHaveLength(0);
    expect(handedDown()).toEqual(["x"]);
    expect(audio.queueState().title).toBe("b Mix");
  });

  it("keeps the old title when none is given, and drops shuffle and the old station", async () => {
    await load();
    const source = { title: "s", more: vi.fn(async () => []) };
    await audio.play(songs("abcdefgh"), 0, { title: "An Album", shuffle: true, source });
    await audio.replaceUpNext(songs("xy"));
    expect(audio.queueState().title).toBe("An Album");
    expect(audio.isShuffled()).toBe(false);
    expect(audio.queueState().source).toBeNull();
  });

  it("marks an offline mix, and unmarks it when the next mix is not one", async () => {
    await load();
    await audio.play(songs("ab"));
    await audio.replaceUpNext(songs("xy"), { offlineMix: true });
    expect(audio.queueState().offlineMix).toBe(true);
    await audio.replaceUpNext(songs("xy"));
    expect(audio.queueState().offlineMix).toBe(false);
  });

  it("keeps the mix going from its station", async () => {
    await load();
    await audio.play(songs("ab"));
    const source = { title: "s", more: vi.fn(async () => [song("p"), song("q")]) };
    await audio.replaceUpNext(songs("xy"), { source });
    await flush();
    expect(source.more).toHaveBeenCalledTimes(1);
    expect(ids()).toBe("axypq");
  });
});

describe("next, previous and jump", () => {
  it("next plays the following song", async () => {
    await load();
    await audio.play(songs("abc"));
    await audio.next();
    expect(audio.current().Id).toBe("b");
    expect(last("audio_play").req.track.item_id).toBe("b");
    expect(last("audio_play").req.next.item_id).toBe("c");
  });

  it("next at the end of the queue stops and empties it", async () => {
    await load();
    await audio.play(songs("ab"), 1);
    await audio.next();
    expect(invokeCalls("audio_stop")).toHaveLength(1);
    expect(audio.isActive()).toBe(false);
    expect(audio.queueState()).toMatchObject({ index: -1, items: [] });
  });

  it("next on an empty queue is harmless", async () => {
    await load();
    await audio.next();
    expect(audio.isActive()).toBe(false);
    expect(invokeCalls("audio_play")).toHaveLength(0);
  });

  it("next at the end goes round to the start with Repeat All", async () => {
    await load();
    await audio.play(songs("ab"), 1);
    await audio.cycleRepeat();
    await audio.next();
    expect(audio.current().Id).toBe("a");
    expect(invokeCalls("audio_stop")).toHaveLength(0);
  });

  it("next at the end of a station asks it for more", async () => {
    await load();
    let ready = false;
    const source = { title: "s", more: vi.fn(async () => (ready ? [song("x"), song("y")] : [])) };
    await audio.play(songs("a"), 0, { source });
    await flush();
    expect(ids()).toBe("a");
    ready = true;
    await audio.next();
    expect(audio.current().Id).toBe("x");
    expect(invokeCalls("audio_stop")).toHaveLength(0);
  });

  it("next stops when the station has nothing left", async () => {
    await load();
    const source = { title: "s", more: vi.fn(async () => []) };
    await audio.play(songs("a"), 0, { source });
    await flush();
    await audio.next();
    expect(audio.isActive()).toBe(false);
    expect(audio.queueState().source).toBeNull();
  });

  it("previous goes back a song when this one has barely begun", async () => {
    await load();
    await audio.wireAudio(() => {});
    await audio.play(songs("abc"), 1);
    emitEvent("audio-status", { position: 2.5 });
    await audio.previous();
    expect(audio.current().Id).toBe("a");
  });

  it("previous restarts the song once it is under way", async () => {
    await load();
    await audio.wireAudio(() => {});
    await audio.play(songs("abc"), 1);
    emitEvent("audio-status", { position: 30 });
    clearInvokeCalls();
    await audio.previous();
    expect(audio.current().Id).toBe("b");
    expect(commands()).toEqual([["seek", 0, "absolute"]]);
    expect(invokeCalls("audio_play")).toHaveLength(0);
  });

  it("previous on the first song restarts it", async () => {
    await load();
    await audio.play(songs("abc"));
    clearInvokeCalls();
    await audio.previous();
    expect(audio.current().Id).toBe("a");
    expect(commands()).toEqual([["seek", 0, "absolute"]]);
  });

  it("jump plays the entry picked, and ignores one that isn't there", async () => {
    await load();
    await audio.play(songs("abc"));
    await audio.jump(2);
    expect(audio.current().Id).toBe("c");
    clearInvokeCalls();
    await audio.jump(3);
    await audio.jump(-1);
    expect(audio.current().Id).toBe("c");
    expect(invokeCalls("audio_play")).toHaveLength(0);
  });
});

describe("stop", () => {
  it("empties the queue, forgets the station and tells MPRIS", async () => {
    await load();
    const source = { title: "s", more: vi.fn(async () => []) };
    await audio.play(songs("abc"), 0, { shuffle: true, source, offlineMix: true });
    await audio.stop();
    expect(invokeCalls("audio_stop")).toHaveLength(1);
    expect(audio.queueState()).toMatchObject({ index: -1, items: [], original: null, source: null, offlineMix: false });
    expect(audio.getStatus().active).toBe(false);
    expect(last("audio_set_queue")).toMatchObject({ entries: [], index: 0, canNext: false, canPrev: false });
  });

  it("clears the queue even when the backend fails to stop", async () => {
    await load();
    await audio.play(songs("ab"));
    onInvoke("audio_stop", () => {
      throw new Error("already gone");
    });
    await audio.stop();
    expect(audio.isActive()).toBe(false);
    expect(audio.current()).toBeNull();
  });
});

describe("editing Up Next", () => {
  it("removes an upcoming entry", async () => {
    await load();
    await audio.play(songs("abcd"));
    await audio.removeAt(2);
    expect(ids()).toBe("abd");
    expect(last("audio_set_queue").entries.map((e: any) => e.item_id)).toEqual(["a", "b", "d"]);
  });

  it("removing the song mpv has queued hands down the one that now follows", async () => {
    await load();
    await audio.play(songs("abc"));
    clearInvokeCalls();
    await audio.removeAt(1);
    expect(handedDown()).toEqual(["c"]);
    await audio.removeAt(1);
    expect(handedDown()).toEqual(["c", null]);
    expect(last("audio_set_queue").canNext).toBe(false);
  });

  it("leaves the playing song and the ones before it alone", async () => {
    await load();
    await audio.play(songs("abcd"), 2);
    clearInvokeCalls();
    await audio.removeAt(2);
    await audio.removeAt(0);
    await audio.removeAt(4);
    await audio.removeAt(-1);
    expect(ids()).toBe("abcd");
    expect(audio.current().Id).toBe("c");
    expect(invokeCalls()).toHaveLength(0);
  });

  it("reorders upcoming entries", async () => {
    await load();
    await audio.play(songs("abcde"));
    await audio.move(4, 2);
    expect(ids()).toBe("abecd");
    await audio.move(1, 3);
    expect(ids()).toBe("aecbd");
  });

  it("moving a song into the next slot hands it down", async () => {
    await load();
    await audio.play(songs("abcd"));
    clearInvokeCalls();
    await audio.move(3, 1);
    expect(ids()).toBe("adbc");
    expect(handedDown()).toEqual(["d"]);
  });

  it("refuses a move that touches the playing song or leaves the queue", async () => {
    await load();
    await audio.play(songs("abcd"), 1);
    clearInvokeCalls();
    await audio.move(1, 3);
    await audio.move(3, 1);
    await audio.move(0, 2);
    await audio.move(2, 0);
    await audio.move(2, 2);
    await audio.move(2, 4);
    await audio.move(4, 2);
    expect(ids()).toBe("abcd");
    expect(invokeCalls()).toHaveLength(0);
  });

  it("Clear drops everything after the current song, and the station with it", async () => {
    await load();
    const source = { title: "s", more: vi.fn(async () => []) };
    await audio.play(songs("abcdefgh"), 1, { shuffle: true, source, offlineMix: true });
    const playing = audio.current().Id;
    clearInvokeCalls();
    await audio.clearUpNext();
    expect(audio.current().Id).toBe(playing);
    expect(audio.upNext()).toEqual([]);
    expect(audio.queueState()).toMatchObject({ original: null, source: null, offlineMix: false });
    expect(handedDown()).toEqual([null]);
    expect(last("audio_set_queue").canNext).toBe(false);
  });
});

describe("repeat", () => {
  it("cycles off, all, one and back, and remembers the choice", async () => {
    await load();
    await audio.play(songs("ab"));
    expect(await audio.cycleRepeat()).toBe("all");
    expect(localStorage.getItem("aquarium.music-repeat")).toBe("all");
    expect(await audio.cycleRepeat()).toBe("one");
    expect(localStorage.getItem("aquarium.music-repeat")).toBe("one");
    expect(await audio.cycleRepeat()).toBe("off");
    expect(localStorage.getItem("aquarium.music-repeat")).toBe("off");
    expect(commands()).toEqual([
      ["set_property", "loop-file", "no"],
      ["set_property", "loop-file", "inf"],
      ["set_property", "loop-file", "no"],
    ]);
  });

  it("still cycles when the choice can't be stored or the backend is away", async () => {
    await load();
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("storage is full");
    });
    onInvoke("audio_command", () => {
      throw new Error("no core");
    });
    expect(await audio.cycleRepeat()).toBe("all");
    expect(audio.queueState().repeat).toBe("all");
  });

  it("Repeat All on the last song queues the first one behind it", async () => {
    await load();
    await audio.play(songs("abc"), 2);
    expect(last("audio_set_queue").canNext).toBe(false);
    clearInvokeCalls();
    await audio.cycleRepeat();
    expect(handedDown()).toEqual(["a"]);
    expect(last("audio_set_queue").canNext).toBe(true);
    // Through One to Off: the first song is taken back.
    await audio.cycleRepeat();
    await audio.cycleRepeat();
    expect(handedDown()).toEqual(["a", null]);
  });

  it("a song started with Repeat One loops in mpv", async () => {
    localStorage.setItem("aquarium.music-repeat", "one");
    await load();
    await audio.play(songs("ab"));
    expect(last("audio_play").req.loop_file).toBe(true);
  });

  it("a song started with Repeat All on the last entry is followed by the first", async () => {
    localStorage.setItem("aquarium.music-repeat", "all");
    await load();
    await audio.play(songs("abc"), 2);
    expect(last("audio_play").req.next.item_id).toBe("a");
    expect(last("audio_play").req.loop_file).toBe(false);
  });
});

describe("transport", () => {
  it("does nothing with no song on", async () => {
    await load();
    await audio.togglePause();
    await audio.seek(10);
    await audio.skip(30);
    expect(invokeCalls("audio_command")).toHaveLength(0);
  });

  it("toggles pause", async () => {
    await load();
    await audio.play(songs("a"));
    await audio.togglePause();
    expect(commands()).toEqual([["cycle", "pause"]]);
  });

  it("seeks, showing the new place at once", async () => {
    await load();
    await audio.play(songs("a"));
    const seen = vi.fn();
    audio.onChange(seen);
    await audio.seek(61.5);
    expect(audio.getStatus().position).toBe(61.5);
    expect(seen).toHaveBeenCalled();
    await audio.seek(-5);
    expect(audio.getStatus().position).toBe(0);
    expect(commands()).toEqual([
      ["seek", 61.5, "absolute"],
      ["seek", 0, "absolute"],
    ]);
  });

  it("skips by seconds, staying inside the song", async () => {
    await load();
    await audio.play(songs("a"));
    await audio.seek(100);
    await audio.skip(30);
    expect(audio.getStatus().position).toBe(130);
    await audio.skip(500);
    expect(audio.getStatus().position).toBe(180);
    await audio.skip(-1000);
    expect(audio.getStatus().position).toBe(0);
  });

  it("skips freely when the length isn't known", async () => {
    await load();
    await audio.play([song("a", { RunTimeTicks: 0 })]);
    await audio.skip(45);
    expect(audio.getStatus().position).toBe(45);
  });

  it("sets the volume within mpv's range and remembers it", async () => {
    await load();
    await audio.setVolume(55.4);
    expect(audio.getStatus().volume).toBe(55);
    expect(localStorage.getItem("aquarium.music-volume")).toBe("55");
    await audio.setVolume(400);
    expect(audio.getStatus().volume).toBe(130);
    await audio.setVolume(-3);
    expect(audio.getStatus().volume).toBe(0);
    expect(commands()).toEqual([
      ["set_property", "volume", 55],
      ["set_property", "volume", 130],
      ["set_property", "volume", 0],
    ]);
  });

  it("a volume turned right down does not come back at full on the next song", async () => {
    await load();
    await audio.setVolume(0);
    await audio.play(songs("a"));
    expect(last("audio_play").req.volume).toBe(1);
  });

  it("mutes and unmutes", async () => {
    await load();
    await audio.setMute(true);
    await audio.setMute(false);
    expect(commands()).toEqual([
      ["set_property", "mute", true],
      ["set_property", "mute", false],
    ]);
  });

  it("sets and remembers the book speed", async () => {
    await load();
    expect(audio.bookSpeed()).toBe(1);
    await audio.setSpeed(1.25);
    expect(audio.bookSpeed()).toBe(1.25);
    expect(commands()).toEqual([["set_property", "speed", 1.25]]);
  });

  it("offers book speeds in rising order, normal speed among them", () => {
    return load().then(() => {
      expect(audio.BOOK_SPEEDS).toContain(1);
      expect([...audio.BOOK_SPEEDS].sort((a, b) => a - b)).toEqual(audio.BOOK_SPEEDS);
    });
  });

  it("saves Sound Check and applies it to the song that's on", async () => {
    await load();
    expect(audio.soundCheckOn()).toBe(true);
    await audio.setSoundCheck(false);
    expect(last("config_save")).toEqual({ cfg: { music_soundcheck: false } });
    expect(audio.soundCheckOn()).toBe(false);
    await audio.setSoundCheck(true);
    expect(audio.soundCheckOn()).toBe(true);
    expect(commands()).toEqual([
      ["set_property", "replaygain", "no"],
      ["set_property", "replaygain", "track"],
    ]);
  });

  it("survives the backend refusing a command", async () => {
    await load();
    await audio.play(songs("a"));
    onInvoke("audio_command", () => {
      throw new Error("no core");
    });
    await audio.togglePause();
    await audio.seek(5);
    await audio.setVolume(50);
    await audio.setMute(true);
    await audio.setSpeed(2);
    expect(audio.getStatus().position).toBe(5);
  });
});

describe("audiobook chapters", () => {
  it("has no chapter for music, or for a book without any", async () => {
    await load();
    await audio.play([song("a", { Chapters: [{ Name: "x", StartPositionTicks: 0 }] })]);
    expect(audio.currentChapter()).toBeNull();
    await audio.play([book({ Chapters: [] })]);
    expect(audio.currentChapter()).toBeNull();
  });

  it("finds the chapter at the playhead", async () => {
    await load();
    await audio.wireAudio(() => {});
    await audio.play([book()]);
    emitEvent("audio-status", { position: 30, duration: 1800 });
    expect(audio.currentChapter()).toEqual({ name: "One", index: 0, start: 0, end: 600 });
    emitEvent("audio-status", { position: 700 });
    expect(audio.currentChapter()).toEqual({ name: "Chapter 2", index: 1, start: 600, end: 1200 });
    emitEvent("audio-status", { position: 1500 });
    expect(audio.currentChapter()).toEqual({ name: "Three", index: 2, start: 1200, end: 1800 });
  });

  it("counts the last half second of a chapter as the next one", async () => {
    await load();
    await audio.wireAudio(() => {});
    await audio.play([book()]);
    emitEvent("audio-status", { position: 599.4 });
    expect(audio.currentChapter()!.index).toBe(0);
    emitEvent("audio-status", { position: 599.6 });
    expect(audio.currentChapter()!.index).toBe(1);
  });
});

describe("sleep timer", () => {
  it("pauses after the minutes asked for", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-11-12T22:00:00Z"));
    await load();
    await audio.play(songs("ab"));
    await audio.setSleep(10);
    expect(audio.sleepState()).toEqual({ mode: "time", at: Date.now() + 600_000 });
    await vi.advanceTimersByTimeAsync(599_999);
    expect(commands()).toEqual([]);
    await vi.advanceTimersByTimeAsync(1);
    expect(commands()).toEqual([["set_property", "pause", true]]);
    expect(audio.sleepState()).toEqual({ mode: "off", at: 0 });
  });

  it("does not pause again what is already paused", async () => {
    vi.useFakeTimers();
    await load();
    await audio.wireAudio(() => {});
    await audio.play(songs("ab"));
    await audio.setSleep(1);
    emitEvent("audio-status", { paused: true });
    await vi.advanceTimersByTimeAsync(60_000);
    expect(commands()).toEqual([]);
    expect(audio.sleepState().mode).toBe("off");
  });

  it("a new timer replaces the old one, and Off cancels it", async () => {
    vi.useFakeTimers();
    await load();
    await audio.play(songs("ab"));
    await audio.setSleep(5);
    await audio.setSleep(20);
    await vi.advanceTimersByTimeAsync(5 * 60_000);
    expect(commands()).toEqual([]);
    await audio.setSleep("off");
    expect(audio.sleepState()).toEqual({ mode: "off", at: 0 });
    await vi.advanceTimersByTimeAsync(60 * 60_000);
    expect(commands()).toEqual([]);
  });

  it("End of Track holds back the next song, and Off lets it follow again", async () => {
    await load();
    await audio.play(songs("abc"));
    clearInvokeCalls();
    await audio.setSleep("track");
    expect(audio.sleepState().mode).toBe("track");
    expect(handedDown()).toEqual([null]);
    await audio.setSleep("off");
    expect(handedDown()).toEqual([null, "b"]);
  });

  it("a song started under End of Track has nothing queued behind it", async () => {
    await load();
    await audio.play(songs("abc"));
    await audio.setSleep("track");
    await audio.jump(1);
    expect(last("audio_play").req.next).toBeNull();
  });

  it("End of Track ends with the queue's end and is then over", async () => {
    await load();
    await audio.wireAudio(() => {});
    await audio.play(songs("abc"));
    await audio.setSleep("track");
    emitEvent("audio-status", { active: false, ended: true });
    expect(audio.sleepState().mode).toBe("off");
    expect(audio.isActive()).toBe(false);
  });

  it("End of Track in a book stops at the chapter's end, allowing for the speed", async () => {
    vi.useFakeTimers();
    await load();
    await audio.wireAudio(() => {});
    await audio.play([book()]);
    emitEvent("audio-status", { position: 100, duration: 1800, speed: 2 });
    const t0 = Date.now();
    await audio.setSleep("track");
    expect(audio.sleepState()).toEqual({ mode: "track", at: t0 + 250_000 });
    await vi.advanceTimersByTimeAsync(249_999);
    expect(commands()).toEqual([]);
    await vi.advanceTimersByTimeAsync(1);
    expect(commands()).toEqual([["set_property", "pause", true]]);
    expect(audio.sleepState().mode).toBe("off");
  });

  it("End of Track at the very end of a chapter still waits a second", async () => {
    vi.useFakeTimers();
    await load();
    await audio.wireAudio(() => {});
    await audio.play([book()]);
    emitEvent("audio-status", { position: 599.45, duration: 1800, speed: 0 });
    await audio.setSleep("track");
    await vi.advanceTimersByTimeAsync(999);
    expect(commands()).toEqual([]);
    await vi.advanceTimersByTimeAsync(1);
    expect(commands()).toEqual([["set_property", "pause", true]]);
  });

  it("stopping cancels the timer", async () => {
    vi.useFakeTimers();
    await load();
    await audio.play(songs("ab"));
    await audio.setSleep(1);
    await audio.stop();
    expect(audio.sleepState()).toEqual({ mode: "off", at: 0 });
    await vi.advanceTimersByTimeAsync(120_000);
    expect(commands()).toEqual([]);
  });
});

describe("stations keep the queue topped up", () => {
  it("asks for more when five or fewer songs are left", async () => {
    await load();
    const source = { title: "s", more: vi.fn(async () => [song("x"), song("y")]) };
    await audio.play(songs("abcde"), 0, { source });
    await flush();
    expect(source.more).toHaveBeenCalledTimes(1);
    expect(source.more.mock.calls[0][1]).toBe(20);
    expect(ids()).toBe("abcdexy");
    expect(last("audio_set_queue").entries).toHaveLength(7);
  });

  it("leaves a well-stocked queue alone", async () => {
    await load();
    const source = { title: "s", more: vi.fn(async () => [song("x")]) };
    await audio.play(songs("abcdef"), 0, { source });
    await flush();
    expect(source.more).not.toHaveBeenCalled();
    expect(last("audio_set_queue").canNext).toBe(true);
  });

  it("a station on its last song still offers Next", async () => {
    await load();
    const source = { title: "s", more: vi.fn(async () => []) };
    await audio.play(songs("a"), 0, { source });
    expect(last("audio_set_queue").canNext).toBe(true);
  });

  it("skips songs already in the queue", async () => {
    await load();
    const source = { title: "s", more: vi.fn(async () => [song("b"), song("x"), song("a")]) };
    await audio.play(songs("ab"), 0, { source });
    await flush();
    expect(ids()).toBe("abx");
  });

  it("gives mpv the first new song when the queue had run to its end", async () => {
    await load();
    const source = { title: "s", more: vi.fn(async () => [song("x")]) };
    await audio.play(songs("a"), 0, { source });
    await flush();
    expect(handedDown()).toEqual(["x"]);
  });

  it("adds to the unshuffled order too", async () => {
    await load();
    const source = { title: "s", more: vi.fn(async () => [song("x")]) };
    await audio.play(songs("abc"), 0, { source, shuffle: true });
    await flush();
    expect(audio.queueState().original!.map((i) => i.Id).join("")).toBe("abcx");
  });

  it("carries on when the station fails", async () => {
    await load();
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    const source = {
      title: "s",
      more: vi
        .fn()
        .mockRejectedValueOnce(new Error("server away"))
        .mockResolvedValue([song("x")]),
    };
    await audio.play(songs("ab"), 0, { source });
    await flush();
    expect(err).toHaveBeenCalled();
    expect(ids()).toBe("ab");
    expect(audio.isActive()).toBe(true);
    // The failure does not block the next try.
    await audio.next();
    await flush();
    expect(ids()).toBe("abx");
  });

  it("asks once at a time", async () => {
    await load();
    let release: (v: any[]) => void = () => {};
    const source = { title: "s", more: vi.fn(() => new Promise<any[]>((r) => (release = r))) };
    await audio.play(songs("ab"), 0, { source });
    await audio.jump(1);
    await flush();
    expect(source.more).toHaveBeenCalledTimes(1);
    release([song("x")]);
    await flush();
    expect(ids()).toBe("abx");
  });

  it("tops up as mpv moves through the queue", async () => {
    await load();
    await audio.wireAudio(() => {});
    const source = { title: "s", more: vi.fn(async () => [song("x")]) };
    await audio.play(songs("abcdefg"), 0, { source });
    await flush();
    expect(source.more).not.toHaveBeenCalled();
    emitEvent("audio-track", { item_id: "b" });
    await flush();
    expect(source.more).not.toHaveBeenCalled();
    emitEvent("audio-track", { item_id: "c" });
    await flush();
    expect(source.more).toHaveBeenCalledTimes(1);
    expect(ids()).toBe("abcdefgx");
  });
});

describe("events from the backend", () => {
  it("listens once however often it is wired", async () => {
    await load();
    await audio.wireAudio(() => {});
    await audio.wireAudio(() => {});
    for (const ev of ["audio-status", "audio-track", "audio-error", "audio-next", "audio-prev", "audio-goto", "player-status"]) {
      expect(listenerCount(ev), ev).toBe(1);
    }
  });

  it("audio-status updates what is shown", async () => {
    await load();
    await audio.wireAudio(() => {});
    await audio.play(songs("ab"));
    const seen = vi.fn();
    audio.onChange(seen);
    emitEvent("audio-status", { position: 12, paused: true, volume: 80, mute: true, buffering: true });
    expect(audio.getStatus()).toMatchObject({ active: true, position: 12, paused: true, volume: 80, mute: true, buffering: true, item_id: "a" });
    expect(seen).toHaveBeenCalledTimes(1);
    emitEvent("audio-status", undefined);
    expect(audio.getStatus().position).toBe(12);
  });

  it("the queue running out in mpv is the end: everything is cleared", async () => {
    await load();
    await audio.wireAudio(() => {});
    const source = { title: "s", more: vi.fn(async () => []) };
    await audio.play(songs("abcdefg"), 6, { source, shuffle: true, offlineMix: true });
    clearInvokeCalls();
    emitEvent("audio-status", { active: false, ended: true });
    expect(audio.isActive()).toBe(false);
    expect(audio.getStatus()).toMatchObject({ active: false, paused: false });
    expect(audio.queueState()).toMatchObject({ index: -1, items: [], original: null, source: null, offlineMix: false });
    expect(last("audio_set_queue")).toMatchObject({ entries: [], canNext: false, canPrev: false });
  });

  it("a stop that is not the end leaves the list but nothing current", async () => {
    await load();
    await audio.wireAudio(() => {});
    await audio.play(songs("abc"), 1);
    emitEvent("audio-status", { active: false, ended: false });
    expect(audio.isActive()).toBe(false);
    expect(audio.current()).toBeNull();
    expect(ids()).toBe("abc");
  });

  it("audio-track moves the queue on and hands down the song after", async () => {
    await load();
    await audio.wireAudio(() => {});
    await audio.play(songs("abc"));
    emitEvent("audio-status", { position: 179 });
    clearInvokeCalls();
    emitEvent("audio-track", { item_id: "b" });
    await flush();
    expect(audio.current().Id).toBe("b");
    expect(audio.getStatus()).toMatchObject({ item_id: "b", position: 0, duration: 180 });
    expect(handedDown()).toEqual(["c"]);
    expect(last("audio_set_queue")).toMatchObject({ index: 1, canPrev: true, canNext: true });
    expect(invokeCalls("audio_play")).toHaveLength(0);
  });

  it("audio-track for the last song hands down nothing", async () => {
    await load();
    await audio.wireAudio(() => {});
    await audio.play(songs("ab"));
    clearInvokeCalls();
    emitEvent("audio-track", { item_id: "b" });
    await flush();
    expect(handedDown()).toEqual([null]);
  });

  it("audio-track for the song already current changes nothing (the echo of play)", async () => {
    await load();
    await audio.wireAudio(() => {});
    await audio.play(songs("abc"));
    clearInvokeCalls();
    const seen = vi.fn();
    audio.onChange(seen);
    emitEvent("audio-track", { item_id: "a" });
    emitEvent("audio-track", {});
    emitEvent("audio-track", undefined);
    await flush();
    expect(audio.queueState().index).toBe(0);
    expect(seen).not.toHaveBeenCalled();
    expect(invokeCalls()).toHaveLength(0);
  });

  it("audio-track wraps to the first song under Repeat All", async () => {
    localStorage.setItem("aquarium.music-repeat", "all");
    await load();
    await audio.wireAudio(() => {});
    await audio.play(songs("abc"), 2);
    clearInvokeCalls();
    emitEvent("audio-track", { item_id: "a" });
    await flush();
    expect(audio.queueState().index).toBe(0);
    expect(handedDown()).toEqual(["b"]);
  });

  it("audio-track for a song further on finds it", async () => {
    await load();
    await audio.wireAudio(() => {});
    await audio.play(songs("abcd"));
    emitEvent("audio-track", { item_id: "d" });
    await flush();
    expect(audio.queueState().index).toBe(3);
  });

  it("audio-track for a song that is not ahead leaves the place alone", async () => {
    await load();
    await audio.wireAudio(() => {});
    await audio.play(songs("abcd"), 2);
    emitEvent("audio-track", { item_id: "a" });
    emitEvent("audio-track", { item_id: "zzz" });
    await flush();
    expect(audio.queueState().index).toBe(2);
  });

  // BUG: src/audio.ts:583. The backend sends `audio-track` both when `play`
  // starts a song and when mpv moves on to the queued one, and the handler
  // drops any event whose id is the current song's. With Repeat All on a
  // one-song queue the "next" song is the same song, so the move is taken for
  // the echo, nothing is handed down, and playback ends after the second pass.
  it.fails("Repeat All on a single song keeps it going round (BUG: stops after the second pass)", async () => {
    localStorage.setItem("aquarium.music-repeat", "all");
    await load();
    await audio.wireAudio(() => {});
    await audio.play(songs("a"));
    expect(last("audio_play").req.next.item_id).toBe("a");
    // The echo of `play`, then mpv reaching the queued copy.
    emitEvent("audio-track", { item_id: "a" });
    clearInvokeCalls();
    emitEvent("audio-track", { item_id: "a" });
    await flush();
    expect(handedDown()).toEqual(["a"]);
  });

  // BUG: src/audio.ts:583, the same early return. A playlist can hold a song
  // twice running; when mpv moves from the first copy to the second the queue
  // does not advance and the song after them is never handed down.
  it.fails("moves on through the same song queued twice running (BUG: the queue stays on the first copy)", async () => {
    await load();
    await audio.wireAudio(() => {});
    await audio.play([song("a"), song("a"), song("b")]);
    emitEvent("audio-track", { item_id: "a" });
    clearInvokeCalls();
    emitEvent("audio-track", { item_id: "a" });
    await flush();
    expect(audio.queueState().index).toBe(1);
    expect(handedDown()).toEqual(["b"]);
  });

  it("audio-error names the song that failed", async () => {
    await load();
    const onError = vi.fn();
    await audio.wireAudio(onError);
    await audio.play(songs("ab"));
    emitEvent("audio-error", { item_id: "b", error: "404" });
    expect(onError).toHaveBeenLastCalledWith("Couldn't play Song b (404)");
    emitEvent("audio-error", { item_id: "b" });
    expect(onError).toHaveBeenLastCalledWith("Couldn't play Song b");
    emitEvent("audio-error", { item_id: "gone", error: "" });
    expect(onError).toHaveBeenLastCalledWith("Couldn't play that track");
    emitEvent("audio-error", undefined);
    expect(onError).toHaveBeenCalledTimes(4);
  });

  it("the desktop's Next and Previous drive the queue", async () => {
    await load();
    await audio.wireAudio(() => {});
    await audio.play(songs("abc"));
    emitEvent("audio-next");
    await flush();
    expect(audio.current().Id).toBe("b");
    emitEvent("audio-prev");
    await flush();
    expect(audio.current().Id).toBe("a");
  });

  it("the desktop's track list can jump to an entry", async () => {
    await load();
    await audio.wireAudio(() => {});
    await audio.play(songs("abc"));
    emitEvent("audio-goto", { index: 2 });
    await flush();
    expect(audio.current().Id).toBe("c");
    emitEvent("audio-goto", {});
    emitEvent("audio-goto", undefined);
    emitEvent("audio-goto", { index: "nope" });
    await flush();
    expect(audio.current().Id).toBe("c");
  });

  it("video taking over stops the music here too", async () => {
    await load();
    await audio.wireAudio(() => {});
    await audio.play(songs("abc"), 1);
    const seen = vi.fn();
    audio.onChange(seen);
    emitEvent("player-status", { active: false });
    expect(audio.isActive()).toBe(true);
    emitEvent("player-status", { active: true });
    expect(audio.isActive()).toBe(false);
    expect(audio.getStatus().active).toBe(false);
    expect(audio.current()).toBeNull();
    expect(seen).toHaveBeenCalledTimes(1);
    // Already stopped: a second report is not news.
    emitEvent("player-status", { active: true });
    expect(seen).toHaveBeenCalledTimes(1);
  });
});
