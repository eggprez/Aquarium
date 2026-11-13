// src/cache.ts: the stale-while-revalidate screen cache (memory in front of
// IndexedDB) and the item signature views compare before repainting.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { IDBFactory } from "fake-indexeddb";

type Cache = typeof import("../../src/cache");
let cache: Cache;

beforeEach(async () => {
  // A fresh, empty IndexedDB per test, and a fresh module (a fresh "launch").
  (globalThis as any).indexedDB = new IDBFactory();
  vi.resetModules();
  cache = await import("../../src/cache");
});

afterEach(() => {
  vi.restoreAllMocks();
});

/** A second launch of the app against the same disk. */
async function relaunch(): Promise<Cache> {
  vi.resetModules();
  return import("../../src/cache");
}

/** Everything on disk, as key -> record. */
async function disk(): Promise<Record<string, any>> {
  const db: IDBDatabase = await new Promise((res, rej) => {
    const r = indexedDB.open("aquarium-screens", 1);
    r.onupgradeneeded = () => r.result.createObjectStore("screens");
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  });
  try {
    const tx = db.transaction("screens", "readonly");
    const os = tx.objectStore("screens");
    const [keys, vals] = await Promise.all([
      new Promise<IDBValidKey[]>((res) => (os.getAllKeys().onsuccess = (e: any) => res(e.target.result))),
      new Promise<any[]>((res) => (os.getAll().onsuccess = (e: any) => res(e.target.result))),
    ]);
    const out: Record<string, any> = {};
    keys.forEach((k, i) => (out[String(k)] = vals[i]));
    return out;
  } finally {
    db.close();
  }
}

async function diskKeys(): Promise<string[]> {
  return Object.keys(await disk()).sort();
}

describe("memory reads and writes", () => {
  it("getCached answers synchronously with what setCached stored, and undefined for anything else", () => {
    expect(cache.getCached("home")).toBeUndefined();
    cache.setCached("home", { rows: [1, 2] });
    expect(cache.getCached("home")).toEqual({ rows: [1, 2] });
  });

  it("invalidateCache forgets one key and leaves the rest", () => {
    cache.setCached("a", 1);
    cache.setCached("b", 2);
    cache.invalidateCache("a");
    expect(cache.getCached("a")).toBeUndefined();
    expect(cache.getCached("b")).toBe(2);
  });

  it("clearCache forgets everything in memory", () => {
    cache.setCached("a", 1);
    cache.clearCache();
    expect(cache.getCached("a")).toBeUndefined();
  });
});

describe("persistence", () => {
  it("writes nothing to disk before a session has been hydrated (no owner to stamp it with)", async () => {
    cache.setCached("early", 1);
    await cache.hydrateCache("srv|u1");
    expect(await diskKeys()).toEqual([]);
  });

  it("a cold start paints what the last run ended on: records come back for the same account", async () => {
    await cache.hydrateCache("srv|u1");
    cache.setCached("home", { title: "Home" });
    await vi.waitFor(async () => expect(await diskKeys()).toEqual(["home"]));
    const rec = (await disk()).home;
    expect(rec.owner).toBe("srv|u1");
    expect(rec.data).toEqual({ title: "Home" });
    expect(typeof rec.at).toBe("number");

    const next = await relaunch();
    expect(next.getCached("home")).toBeUndefined();
    await next.hydrateCache("srv|u1");
    expect(next.getCached("home")).toEqual({ title: "Home" });
  });

  it("hydrating for another account drops the previous account's records from memory and disk", async () => {
    await cache.hydrateCache("srv|u1");
    cache.setCached("home", "u1's home");
    await vi.waitFor(async () => expect(await diskKeys()).toEqual(["home"]));

    const next = await relaunch();
    await next.hydrateCache("srv|u2");
    expect(next.getCached("home")).toBeUndefined();
    await vi.waitFor(async () => expect(await diskKeys()).toEqual([]));
  });

  it("a record from another server with the same user id is not painted (owner is server plus user)", async () => {
    await cache.hydrateCache("http://a|u1");
    cache.setCached("k", "from a");
    await vi.waitFor(async () => expect(await diskKeys()).toEqual(["k"]));
    const next = await relaunch();
    await next.hydrateCache("http://b|u1");
    expect(next.getCached("k")).toBeUndefined();
  });

  it("memory wins over disk: a value written during the same boot is not overwritten by hydration", async () => {
    await cache.hydrateCache("o");
    cache.setCached("k", "old");
    await vi.waitFor(async () => expect((await disk()).k?.data).toBe("old"));

    const next = await relaunch();
    const h = next.hydrateCache("o");
    next.setCached("k", "new");
    await h;
    expect(next.getCached("k")).toBe("new");
    await vi.waitFor(async () => expect((await disk()).k?.data).toBe("new"));
  });

  it("calling hydrateCache again for the same owner is a no-op that answers the same promise", async () => {
    const a = cache.hydrateCache("o");
    const b = cache.hydrateCache("o");
    expect(b).toBe(a);
    await a;
    const c = cache.hydrateCache("other");
    expect(c).not.toBe(a);
    await c;
  });

  it("invalidateCache also removes the key from disk", async () => {
    await cache.hydrateCache("o");
    cache.setCached("a", 1);
    cache.setCached("b", 2);
    await vi.waitFor(async () => expect(await diskKeys()).toEqual(["a", "b"]));
    cache.invalidateCache("a");
    await vi.waitFor(async () => expect(await diskKeys()).toEqual(["b"]));
  });

  it("clearCache (sign-out) empties disk too, and later writes wait for the next hydrate", async () => {
    await cache.hydrateCache("o");
    cache.setCached("a", 1);
    cache.clearCache();
    // The clear was queued after the put, so it cannot be overtaken by it.
    await vi.waitFor(async () => expect(await diskKeys()).toEqual([]));
    cache.setCached("b", 2);
    // Not persisted: the owner went with the sign-out.
    await cache.hydrateCache("o2");
    expect(await diskKeys()).toEqual([]);
    const next = await relaunch();
    await next.hydrateCache("o");
    expect(next.getCached("a")).toBeUndefined();
  });

  it("a write after a clear is not lost behind it (disk writes are serialised)", async () => {
    await cache.hydrateCache("o");
    cache.clearCache();
    await cache.hydrateCache("o");
    cache.setCached("after", 1);
    await vi.waitFor(async () => expect(await diskKeys()).toEqual(["after"]));
  });

  it("a value that cannot be stored on disk stays in memory and does not break later writes", async () => {
    await cache.hydrateCache("o");
    const bad = { fn: () => 1 };
    cache.setCached("bad", bad);
    cache.setCached("good", 2);
    expect(cache.getCached("bad")).toBe(bad);
    await vi.waitFor(async () => expect(await diskKeys()).toEqual(["good"]));
  });

  it("skips records with a non-string key or no value when hydrating", async () => {
    // Plant junk directly on disk, under the same owner.
    const db: IDBDatabase = await new Promise((res) => {
      const r = indexedDB.open("aquarium-screens", 1);
      r.onupgradeneeded = () => r.result.createObjectStore("screens");
      r.onsuccess = () => res(r.result);
    });
    await new Promise<void>((res) => {
      const tx = db.transaction("screens", "readwrite");
      tx.objectStore("screens").put({ owner: "o", data: "numeric key", at: 0 }, 42);
      tx.objectStore("screens").put(null, "nullrec");
      tx.objectStore("screens").put({ owner: "o", data: "fine", at: 0 }, "ok");
      tx.oncomplete = () => res();
    });
    db.close();
    await cache.hydrateCache("o");
    expect(cache.getCached("ok")).toBe("fine");
    expect(cache.getCached("42")).toBeUndefined();
    expect(cache.getCached("nullrec")).toBeUndefined();
  });
});

describe("when IndexedDB is unavailable, the cache is memory-only", () => {
  it("indexedDB.open throwing", async () => {
    vi.spyOn(indexedDB, "open").mockImplementation(() => {
      throw new Error("disabled");
    });
    await expect(cache.hydrateCache("o")).resolves.toBeUndefined();
    cache.setCached("a", 1);
    cache.invalidateCache("x");
    cache.clearCache();
    cache.setCached("b", 2);
    expect(cache.getCached("b")).toBe(2);
  });

  it.each(["onerror", "onblocked"])("the open request firing %s", async (which) => {
    const req: any = {};
    vi.spyOn(indexedDB, "open").mockReturnValue(req);
    const h = cache.hydrateCache("o");
    await vi.waitFor(() => expect(typeof req[which]).toBe("function"));
    req[which]();
    await expect(h).resolves.toBeUndefined();
    cache.setCached("a", 1);
    expect(cache.getCached("a")).toBe(1);
  });

  it("a version change from elsewhere closes the handle and later writes stay in memory", async () => {
    await cache.hydrateCache("o");
    cache.setCached("before", 1);
    await vi.waitFor(async () => expect(await diskKeys()).toEqual(["before"]));
    // A newer build (or a site-data wipe) opens the database at version 2.
    const db2: IDBDatabase = await new Promise((res, rej) => {
      const r = indexedDB.open("aquarium-screens", 2);
      r.onsuccess = () => res(r.result);
      r.onerror = () => rej(r.error);
    });
    db2.close();
    cache.setCached("after", 2);
    expect(cache.getCached("after")).toBe(2);
    // Give the queued write every chance to land; it must not.
    await new Promise((r) => setTimeout(r, 30));
    const keys: string[] = await new Promise((res) => {
      const r = indexedDB.open("aquarium-screens", 2);
      r.onsuccess = () => {
        const os = r.result.transaction("screens", "readonly").objectStore("screens");
        os.getAllKeys().onsuccess = (e: any) => {
          res(e.target.result.map(String));
          r.result.close();
        };
      };
    });
    expect(keys).toEqual(["before"]);
  });
});

describe("itemSignature", () => {
  const ep = (over: any = {}) => ({
    Id: "e1",
    Name: "Pilot",
    Overview: "long text",
    UserData: { Played: false, PlaybackPositionTicks: 0, IsFavorite: false },
    ImageTags: { Primary: "p1" },
    ...over,
  });

  it("answers an empty string for no list", () => {
    expect(cache.itemSignature(null)).toBe("");
    expect(cache.itemSignature(undefined)).toBe("");
    expect(cache.itemSignature([])).toBe("");
  });

  it("drops null and undefined entries, so optional values can be passed straight in", () => {
    expect(cache.itemSignature([null, ep(), undefined])).toBe(cache.itemSignature([ep()]));
  });

  it("stringifies non-object entries", () => {
    expect(cache.itemSignature(["a", 3])).toBe("a,3");
  });

  it("an item with no UserData or ImageTags still has a signature", () => {
    expect(cache.itemSignature([{ Id: "x" }])).toBe("x:0:0:0::");
  });

  // The Linux/CLAUDE.md invariant: views paint from getCached, then repaint
  // only when the fresh response's signature differs from the cached one.
  describe("the repaint rule: signature changes exactly when something drawn changes (invariant)", () => {
    const base = (items: any[]): string => cache.itemSignature(items);
    it.each([
      ["watched state", ep({ UserData: { Played: true } })],
      ["resume position", ep({ UserData: { PlaybackPositionTicks: 5 } })],
      ["favourite star", ep({ UserData: { IsFavorite: true } })],
      ["primary image tag", ep({ ImageTags: { Primary: "p2" } })],
      ["backdrop image tag", ep({ ImageTags: { Primary: "p1", Backdrop: "b" } })],
      ["item id", ep({ Id: "e2" })],
    ])("changes with the %s", (_what, changed) => {
      expect(base([changed])).not.toBe(base([ep()]));
    });

    it("changes with the order of the items", () => {
      const a = ep({ Id: "a" });
      const b = ep({ Id: "b" });
      expect(base([a, b])).not.toBe(base([b, a]));
    });

    it("does not change for fields no card draws (name, overview, server noise)", () => {
      expect(base([ep({ Name: "Renamed", Overview: "x", Etag: "zz", DateLastSaved: "now" })])).toBe(base([ep()]));
    });

    it("a view following the pattern repaints only on change", async () => {
      await cache.hydrateCache("o");
      const paints: string[] = [];
      const show = (items: any[]): void => {
        const cached = cache.getCached<any[]>("route");
        if (cached) paints.push("cached");
        if (cached && cache.itemSignature(cached) === cache.itemSignature(items)) return;
        cache.setCached("route", items);
        paints.push("fresh");
      };
      show([ep()]);
      show([ep({ Overview: "edited" })]);
      show([ep({ UserData: { Played: true } })]);
      expect(paints).toEqual(["fresh", "cached", "cached", "fresh"]);
    });
  });
});
