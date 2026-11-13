// src/playback.ts: the audio level, the Settings -> Playback preferences, the
// debounced config writes, the sleep timer, the player controls and the
// offline-progress sync.
import { afterEach, describe, expect, it, vi } from "vitest";
import { invokeCalls, onInvoke } from "../helpers/tauri";
import { boot, download, errorToasts, lastPlay, recordEvents, teardown, toasts } from "../helpers/playback";

afterEach(teardown);

const mpv = (): any[][] => invokeCalls("player_mpv_command").map((c) => c.args.cmd);
const saves = (): any[] => invokeCalls("config_save").map((c) => c.args.cfg);

describe("audio level", () => {
  it("opens at 100 when nothing is remembered", async () => {
    const { pb } = await boot();
    expect(pb.getVolume()).toBe(100);
    expect(pb.MAX_VOLUME).toBe(130);
  });

  it("reads the remembered level at start", async () => {
    localStorage.setItem("aquarium.volume", "35");
    const { pb } = await boot();
    expect(pb.getVolume()).toBe(35);
  });

  it("keeps a remembered level of zero", async () => {
    localStorage.setItem("aquarium.volume", "0");
    const { pb } = await boot();
    expect(pb.getVolume()).toBe(0);
  });

  it.each(["", "loud", "-5", "131", "NaN"])("falls back to 100 for a stored %j", async (stored) => {
    localStorage.setItem("aquarium.volume", stored);
    const { pb } = await boot();
    expect(pb.getVolume()).toBe(100);
  });

  it("setVolume clamps to 0-130, rounds, remembers and tells mpv", async () => {
    const { pb } = await boot();
    await pb.playerCtl.setVolume(200);
    expect(pb.getVolume()).toBe(130);
    await pb.playerCtl.setVolume(-3);
    expect(pb.getVolume()).toBe(0);
    await pb.playerCtl.setVolume(41.6);
    expect(pb.getVolume()).toBe(42);
    expect(localStorage.getItem("aquarium.volume")).toBe("42");
    expect(mpv()).toEqual([
      ["set_property", "volume", 130],
      ["set_property", "volume", 0],
      ["set_property", "volume", 42],
    ]);
  });

  it("hands the remembered level to the next mpv session (regression: a session turned down at night came back at full volume)", async () => {
    const { pb } = await boot();
    await pb.playerCtl.setVolume(20);
    await pb.playLocal(download("a"));
    expect(lastPlay().volume).toBe(20);
    // And after a restart of the app.
    const again = await boot();
    await again.pb.playLocal(download("b"));
    expect(lastPlay().volume).toBe(20);
  });

  it("noteVolume follows a change mpv made by itself", async () => {
    const { pb } = await boot();
    pb.noteVolume(63.2);
    expect(pb.getVolume()).toBe(63);
    expect(localStorage.getItem("aquarium.volume")).toBe("63");
  });

  it("noteVolume ignores a level that is not a number, and one that rounds to the current level", async () => {
    const { pb } = await boot();
    pb.noteVolume(NaN);
    pb.noteVolume(Infinity);
    expect(pb.getVolume()).toBe(100);
    pb.noteVolume(100.3);
    expect(localStorage.getItem("aquarium.volume")).toBeNull();
  });

  it("still changes the level when localStorage is full", async () => {
    const { pb } = await boot();
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("QuotaExceededError");
    });
    pb.noteVolume(50);
    expect(pb.getVolume()).toBe(50);
  });
});

describe("playback preferences", () => {
  it("skipInterval accepts 10, 15 and 30 and falls back to 10", async () => {
    expect((await boot({ config: { player_skip_interval: 15 } })).pb.skipInterval()).toBe(15);
    expect((await boot({ config: { player_skip_interval: "30" } })).pb.skipInterval()).toBe(30);
    expect((await boot({ config: { player_skip_interval: 7 } })).pb.skipInterval()).toBe(10);
    const { pb } = await boot();
    expect(pb.skipInterval()).toBe(10);
    expect(pb.SKIP_INTERVALS).toEqual([10, 15, 30]);
  });

  it("hideControlsAfter accepts the offered choices and falls back to 2", async () => {
    expect((await boot({ config: { player_hide_after: 6 } })).pb.hideControlsAfter()).toBe(6);
    expect((await boot({ config: { player_hide_after: 3 } })).pb.hideControlsAfter()).toBe(2);
    const { pb } = await boot();
    expect(pb.hideControlsAfter()).toBe(2);
    expect(pb.HIDE_AFTER_CHOICES).toEqual([2, 4, 6, 10]);
  });

  it("reads a preference where it applies, so a change needs nothing invalidated", async () => {
    const { pb, api } = await boot();
    expect(pb.skipInterval()).toBe(10);
    api.getConfig().player_skip_interval = 30;
    expect(pb.skipInterval()).toBe(30);
  });

  it("showsRemaining is off unless set to true", async () => {
    expect((await boot()).pb.showsRemaining()).toBe(false);
    expect((await boot({ config: { player_show_remaining: "yes" } })).pb.showsRemaining()).toBe(false);
    expect((await boot({ config: { player_show_remaining: true } })).pb.showsRemaining()).toBe(true);
  });

  it("setShowsRemaining takes hold at once and is saved after the debounce", async () => {
    const { pb } = await boot();
    pb.setShowsRemaining(true);
    expect(pb.showsRemaining()).toBe(true);
    expect(saves()).toEqual([]);
    await vi.advanceTimersByTimeAsync(300);
    expect(saves()).toEqual([{ player_show_remaining: true }]);
  });

  it("autoplayNextEnabled and resumeEnabled are on unless turned off", async () => {
    const on = await boot();
    expect(on.pb.autoplayNextEnabled()).toBe(true);
    expect(on.pb.resumeEnabled()).toBe(true);
    const off = await boot({ config: { autoplay_next: false, resume_playback: false } });
    expect(off.pb.autoplayNextEnabled()).toBe(false);
    expect(off.pb.resumeEnabled()).toBe(false);
  });

  it("adaptive quality is on unless turned off, and announces a change", async () => {
    const { pb } = await boot();
    const seen = recordEvents("aquarium-adaptive-changed");
    expect(pb.isAdaptiveEnabled()).toBe(true);
    pb.setAdaptiveEnabled(false);
    expect(pb.isAdaptiveEnabled()).toBe(false);
    expect(localStorage.getItem("aquarium.adaptive")).toBe("off");
    pb.setAdaptiveEnabled(true);
    expect(pb.isAdaptiveEnabled()).toBe(true);
    expect(seen).toHaveLength(2);
  });

  it("setAdaptiveEnabled still announces the change when localStorage is full", async () => {
    const { pb } = await boot();
    const seen = recordEvents("aquarium-adaptive-changed");
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("QuotaExceededError");
    });
    expect(() => pb.setAdaptiveEnabled(false)).not.toThrow();
    expect(seen).toHaveLength(1);
  });
});

describe("saveConfigSoon and setLiveSetting", () => {
  it("coalesces a dragged slider into one config write (regression: one fsync per pixel)", async () => {
    const { pb } = await boot();
    for (let v = 1; v <= 20; v++) {
      pb.saveConfigSoon({ pic_brightness: v });
      await vi.advanceTimersByTimeAsync(50);
    }
    expect(saves()).toEqual([]);
    await vi.advanceTimersByTimeAsync(300);
    expect(saves()).toEqual([{ pic_brightness: 20 }]);
  });

  it("merges different keys that arrive in the same moment", async () => {
    const { pb } = await boot();
    pb.saveConfigSoon({ a: 1 });
    pb.saveConfigSoon({ b: 2 });
    await vi.advanceTimersByTimeAsync(300);
    expect(saves()).toEqual([{ a: 1, b: 2 }]);
  });

  it("starts a new batch after a write", async () => {
    const { pb } = await boot();
    pb.saveConfigSoon({ a: 1 });
    await vi.advanceTimersByTimeAsync(300);
    pb.saveConfigSoon({ b: 2 });
    await vi.advanceTimersByTimeAsync(300);
    expect(saves()).toEqual([{ a: 1 }, { b: 2 }]);
  });

  it("says so when the write fails", async () => {
    const { pb } = await boot();
    onInvoke("config_save", () => {
      throw "disk full";
    });
    pb.saveConfigSoon({ a: 1 });
    await vi.advanceTimersByTimeAsync(300);
    expect(errorToasts()).toEqual(["Couldn't save that setting"]);
  });

  it("setLiveSetting pushes the value to the running player and to config.json", async () => {
    const { pb } = await boot();
    pb.setLiveSetting("pic_contrast", "contrast", 12);
    expect(mpv()).toEqual([["set_property", "contrast", 12]]);
    await vi.advanceTimersByTimeAsync(300);
    expect(saves()).toEqual([{ pic_contrast: 12 }]);
  });

  it("setLiveSetting still saves when nothing is playing (the live half fails silently)", async () => {
    const { pb } = await boot();
    onInvoke("player_mpv_command", () => {
      throw "no player";
    });
    pb.setLiveSetting("pic_gamma", "gamma", -4);
    await vi.advanceTimersByTimeAsync(300);
    expect(saves()).toEqual([{ pic_gamma: -4 }]);
    expect(errorToasts()).toEqual([]);
  });

  it("lists the four picture controls with their mpv properties", async () => {
    const { pb } = await boot();
    expect(pb.PICTURE_CONTROLS.map((c) => [c.key, c.prop])).toEqual([
      ["pic_brightness", "brightness"],
      ["pic_contrast", "contrast"],
      ["pic_saturation", "saturation"],
      ["pic_gamma", "gamma"],
    ]);
  });
});

describe("sleep timer", () => {
  it("has no deadline until one is set", async () => {
    const { pb } = await boot();
    expect(pb.sleepDeadline()).toBeNull();
  });

  it("stops playback when it runs out, and cancels autoplay first so the stop does not start the next episode", async () => {
    const { pb } = await boot();
    const seen = recordEvents("aquarium-sleep-changed", "aquarium-upnext-changed");
    const t0 = Date.now();
    pb.setSleepTimer(30);
    expect(pb.sleepDeadline()).toBe(t0 + 30 * 60_000);
    expect(seen.map((e) => e.type)).toEqual(["aquarium-sleep-changed"]);

    await vi.advanceTimersByTimeAsync(30 * 60_000 - 1);
    expect(invokeCalls("player_stop")).toHaveLength(0);
    await vi.advanceTimersByTimeAsync(1);
    expect(invokeCalls("player_stop")).toHaveLength(1);
    expect(pb.isAutoplayCancelled()).toBe(true);
    expect(pb.sleepDeadline()).toBeNull();
    expect(toasts()).toContain("Sleep timer — playback stopped");
    expect(seen.map((e) => e.type)).toEqual([
      "aquarium-sleep-changed",
      "aquarium-upnext-changed",
      "aquarium-sleep-changed",
    ]);
  });

  it("replaces a timer that is already running", async () => {
    const { pb } = await boot();
    pb.setSleepTimer(10);
    pb.setSleepTimer(60);
    await vi.advanceTimersByTimeAsync(10 * 60_000);
    expect(invokeCalls("player_stop")).toHaveLength(0);
    await vi.advanceTimersByTimeAsync(50 * 60_000);
    expect(invokeCalls("player_stop")).toHaveLength(1);
  });

  it("never runs for less than a minute", async () => {
    const { pb } = await boot();
    const t0 = Date.now();
    pb.setSleepTimer(0);
    expect(pb.sleepDeadline()).toBe(t0 + 60_000);
  });

  it("cancelSleepTimer clears the deadline and nothing stops", async () => {
    const { pb } = await boot();
    const seen = recordEvents("aquarium-sleep-changed");
    pb.setSleepTimer(5);
    pb.cancelSleepTimer();
    expect(pb.sleepDeadline()).toBeNull();
    expect(seen).toHaveLength(2);
    await vi.advanceTimersByTimeAsync(10 * 60_000);
    expect(invokeCalls("player_stop")).toHaveLength(0);
  });

  it("stays quiet when the stop fails because nothing is playing", async () => {
    const { pb } = await boot();
    onInvoke("player_stop", () => {
      throw "no player";
    });
    pb.setSleepTimer(1);
    await vi.advanceTimersByTimeAsync(60_000);
    expect(errorToasts()).toEqual([]);
  });
});

describe("stop after this one", () => {
  it("cancelAutoplay and resumeAutoplay flip the flag and announce it", async () => {
    const { pb } = await boot();
    const seen = recordEvents("aquarium-upnext-changed");
    expect(pb.isAutoplayCancelled()).toBe(false);
    pb.cancelAutoplay();
    expect(pb.isAutoplayCancelled()).toBe(true);
    pb.resumeAutoplay();
    expect(pb.isAutoplayCancelled()).toBe(false);
    expect(seen).toHaveLength(2);
  });

  it("is cleared when something new starts playing", async () => {
    const { pb } = await boot();
    pb.cancelAutoplay();
    await pb.playLocal(download("a"));
    expect(pb.isAutoplayCancelled()).toBe(false);
  });
});

describe("playerCtl", () => {
  it("maps each control to its backend command", async () => {
    const { pb } = await boot();
    await pb.playerCtl.pauseToggle();
    await pb.playerCtl.stop();
    await pb.playerCtl.seek(42.5, true);
    await pb.playerCtl.seek(-10, false);
    await pb.playerCtl.setTrack("audio", 2);
    await pb.playerCtl.setTrack("sub", "no");
    expect(invokeCalls("player_pause_toggle")).toHaveLength(1);
    expect(invokeCalls("player_stop")).toHaveLength(1);
    expect(invokeCalls("player_seek").map((c) => c.args)).toEqual([
      { seconds: 42.5, absolute: true },
      { seconds: -10, absolute: false },
    ]);
    expect(invokeCalls("player_set_track").map((c) => c.args)).toEqual([
      { kind: "audio", track: 2 },
      { kind: "sub", track: "no" },
    ]);
  });

  it("setProp uses the IPC name set_property, which the backend maps to mpv_set_property", async () => {
    const { pb } = await boot();
    await pb.playerCtl.setProp("sub-scale", 1.2);
    expect(mpv()).toEqual([["set_property", "sub-scale", 1.2]]);
  });

  it("setProp rejects when nothing is playing", async () => {
    const { pb } = await boot();
    onInvoke("player_mpv_command", () => {
      throw "no player";
    });
    await expect(pb.playerCtl.setProp("brightness", 1)).rejects.toBe("no player");
  });

  it("setMute passes the flag through", async () => {
    const { pb } = await boot();
    await pb.playerCtl.setMute(true);
    expect(mpv()).toEqual([["set_property", "mute", true]]);
  });

  it("setSpeed keeps the speed between 0.25x and 4x", async () => {
    const { pb } = await boot();
    await pb.playerCtl.setSpeed(1.5);
    await pb.playerCtl.setSpeed(0.1);
    await pb.playerCtl.setSpeed(9);
    expect(mpv().map((c) => c[2])).toEqual([1.5, 0.25, 4]);
    expect(pb.SPEEDS).toEqual([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]);
  });

  it("setSubDelay rounds to hundredths so repeated 0.1 s steps do not drift", async () => {
    const { pb } = await boot();
    let d = 0;
    for (let i = 0; i < 3; i++) d += pb.SUB_DELAY_STEP;
    await pb.playerCtl.setSubDelay(d);
    await pb.playerCtl.setSubDelay(-0.25);
    expect(mpv()).toEqual([
      ["set_property", "sub-delay", 0.3],
      ["set_property", "sub-delay", -0.25],
    ]);
  });

  it("setAudioDelay clamps to 10 s either way, applies it now and saves it for the next file", async () => {
    const { pb, api } = await boot();
    await pb.playerCtl.setAudioDelay(3 * pb.AUDIO_DELAY_STEP);
    expect(api.getConfig().audio_delay).toBe(0.15);
    await pb.playerCtl.setAudioDelay(99);
    await pb.playerCtl.setAudioDelay(-99);
    expect(mpv().map((c) => c[2])).toEqual([0.15, 10, -10]);
    await vi.advanceTimersByTimeAsync(300);
    expect(saves()).toEqual([{ audio_delay: -10 }]);
  });
});

describe("titles and labels", () => {
  it("itemTitle names an episode by series, season and episode", async () => {
    const { pb } = await boot();
    expect(
      pb.itemTitle({ Type: "Episode", SeriesName: "Firefly", ParentIndexNumber: 1, IndexNumber: 3, Name: "Bushwhacked" })
    ).toBe("Firefly Season 1, Episode 3 · Bushwhacked");
  });

  it("itemTitle leaves the numbers out when either is missing (season 0 still counts)", async () => {
    const { pb } = await boot();
    expect(pb.itemTitle({ Type: "Episode", SeriesName: "Sherlock", Name: "Unaired Pilot" })).toBe("Sherlock · Unaired Pilot");
    expect(
      pb.itemTitle({ Type: "Episode", SeriesName: "Sherlock", ParentIndexNumber: 0, IndexNumber: 1, Name: "Special" })
    ).toBe("Sherlock Season 0, Episode 1 · Special");
  });

  it("itemTitle uses the plain name for anything else, and the app name when there is none", async () => {
    const { pb } = await boot();
    expect(pb.itemTitle({ Type: "Movie", Name: "Sintel" })).toBe("Sintel");
    expect(pb.itemTitle({ Type: "Episode", Name: "Orphan" })).toBe("Orphan");
    expect(pb.itemTitle({})).toBe("Aquarium");
  });

  it("downloadedLabel names the downloaded copy's quality", async () => {
    const { pb } = await boot();
    expect(pb.downloadedLabel("720p · 4.5 Mbps")).toBe("Downloaded · 720p · 4.5 Mbps");
  });
});

describe("syncOfflineProgress", () => {
  it("does nothing when signed out", async () => {
    const { pb } = await boot({ signedIn: false });
    await pb.syncOfflineProgress(true);
    expect(invokeCalls("progress_pending")).toHaveLength(0);
  });

  it("with nothing queued, says so only when asked to", async () => {
    const { pb } = await boot();
    onInvoke("progress_pending", 0);
    const seen = recordEvents("aquarium-progress-queue");
    await pb.syncOfflineProgress();
    expect(toasts()).toEqual([]);
    await pb.syncOfflineProgress(true);
    expect(toasts()).toEqual(["Nothing to sync — all progress is up to date"]);
    expect(invokeCalls("progress_sync")).toHaveLength(0);
    expect(seen).toHaveLength(0);
  });

  it("syncs with no arguments (the backend holds the server, user and token) and reports the count", async () => {
    const { pb } = await boot();
    onInvoke("progress_pending", 2);
    onInvoke("progress_sync", { synced: 2, failed: 0 });
    const seen = recordEvents("aquarium-progress-queue");
    await pb.syncOfflineProgress();
    expect(invokeCalls("progress_sync")[0]!.args).toBeUndefined();
    expect(toasts()).toEqual(["Synced 2 item(s) to Jellyfin"]);
    expect(errorToasts()).toEqual([]);
    expect(seen).toHaveLength(1);
  });

  it("reports failures as an error", async () => {
    const { pb } = await boot();
    onInvoke("progress_pending", 3);
    onInvoke("progress_sync", { synced: 1, failed: 2 });
    await pb.syncOfflineProgress();
    expect(errorToasts()).toEqual(["Synced 1 item(s) to Jellyfin, 2 failed"]);
  });

  it("stays quiet about a background sync that moved nothing", async () => {
    const { pb } = await boot();
    onInvoke("progress_pending", 1);
    onInvoke("progress_sync", { synced: 0, failed: 1 });
    await pb.syncOfflineProgress();
    expect(toasts()).toEqual([]);
    await pb.syncOfflineProgress(true);
    expect(errorToasts()).toEqual(["Synced 0 item(s) to Jellyfin, 1 failed"]);
  });

  it("an unreachable server is reported only when the user asked for the sync, and the sidebar count is refreshed either way", async () => {
    const { pb } = await boot();
    onInvoke("progress_pending", 1);
    onInvoke("progress_sync", () => {
      throw "offline|unreachable";
    });
    const seen = recordEvents("aquarium-progress-queue");
    await pb.syncOfflineProgress();
    expect(toasts()).toEqual([]);
    await pb.syncOfflineProgress(true);
    expect(errorToasts()).toEqual(["Sync failed — server unreachable?"]);
    expect(seen).toHaveLength(2);
  });
});
