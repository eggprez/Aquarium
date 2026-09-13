// Stale-while-revalidate cache for screen data.
//
// A well-made TV app (Infuse is the reference point) never shows you a
// spinner for a screen you've already opened — the last known page paints
// instantly, and the app quietly checks the server behind it, touching the
// screen again only if something actually changed. This holds the last
// response for a given screen, keyed by whatever the caller uses to name it (a
// route, a route plus its filters, an item id).
//
// Reads are synchronous out of an in-memory map, because every view wants the
// answer at paint time. Behind that map sits IndexedDB: every write is mirrored
// to disk, and `hydrateCache` reads the whole store back into memory before the
// first route of a session, so a cold start paints the same Home the last run
// ended on rather than a skeleton. (localStorage was the obvious alternative
// and is the wrong one — its quota is a few megabytes, and one large library
// grid is more than that.) The image half needs nothing extra — artwork is
// fetched by the webview directly from the Jellyfin server, so its own HTTP
// disk cache already keeps posters warm across restarts.
//
// Every record is stamped with the account it belongs to (server + user id).
// Hydration for one account throws away records left by another, and
// `clearCache` (see `showLogin` in main.ts) empties both halves on sign-out,
// so a new session never paints a previous account's — or a previous
// server's — data before its own request has landed.
//
// None of this touches what happens when the server is unreachable: the
// router still shows the offline screen for server-backed pages, and nothing
// here is consulted for it.

const DB_NAME = "fellyjin-screens";
const STORE = "screens";
const DB_VERSION = 1;

interface Record_ {
  owner: string;
  data: unknown;
  at: number;
}

const store = new Map<string, unknown>();

/** Who the persisted records belong to; null until a session is hydrated. */
let owner: string | null = null;
let hydrated: Promise<void> | null = null;

// ---------- IndexedDB plumbing ----------

let dbPromise: Promise<IDBDatabase | null> | null = null;

function openDb(): Promise<IDBDatabase | null> {
  if (dbPromise) return dbPromise;
  dbPromise = new Promise((resolve) => {
    let req: IDBOpenDBRequest;
    try {
      req = indexedDB.open(DB_NAME, DB_VERSION);
    } catch {
      resolve(null);
      return;
    }
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORE)) db.createObjectStore(STORE);
    };
    req.onsuccess = () => {
      const db = req.result;
      // A version bump from a newer build, or the user clearing site data,
      // closes the handle under us; fall back to memory-only until restart.
      db.onversionchange = () => {
        db.close();
        dbPromise = Promise.resolve(null);
      };
      resolve(db);
    };
    req.onerror = () => resolve(null);
    req.onblocked = () => resolve(null);
  });
  return dbPromise;
}

function promisify<T>(req: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

// Disk writes are serialised so a clear can never be overtaken by a put that
// was issued before it, and vice versa.
let chain: Promise<void> = Promise.resolve();

function enqueue(op: (db: IDBDatabase) => Promise<void>): Promise<void> {
  chain = chain
    .then(async () => {
      const db = await openDb();
      if (!db) return;
      await op(db);
    })
    .catch(() => {
      // Disk is a convenience; the in-memory copy is still correct.
    });
  return chain;
}

function persist(key: string, data: unknown): void {
  if (!owner) return;
  const rec: Record_ = { owner, data, at: Date.now() };
  void enqueue(async (db) => {
    const tx = db.transaction(STORE, "readwrite");
    // A value that can't be structured-cloned (it shouldn't happen — every
    // view caches plain server payloads — but a DOM node smuggled into one
    // would do it) throws synchronously here and is simply not persisted.
    tx.objectStore(STORE).put(rec, key);
    await promisify(tx.objectStore(STORE).count());
  });
}

function unpersist(key: string): void {
  void enqueue(async (db) => {
    const tx = db.transaction(STORE, "readwrite");
    await promisify(tx.objectStore(STORE).delete(key));
  });
}

// ---------- Public API ----------

export function getCached<T>(key: string): T | undefined {
  return store.get(key) as T | undefined;
}

export function setCached<T>(key: string, data: T): void {
  store.set(key, data);
  persist(key, data);
}

export function invalidateCache(key: string): void {
  store.delete(key);
  unpersist(key);
}

export function clearCache(): void {
  store.clear();
  owner = null;
  hydrated = null;
  void enqueue(async (db) => {
    const tx = db.transaction(STORE, "readwrite");
    await promisify(tx.objectStore(STORE).clear());
  });
}

/**
 * Load everything persisted for `forOwner` into memory, and drop whatever was
 * left behind by anyone else. Awaited before the first route of a session so
 * that route finds its cache warm; calling it again for the same owner is a
 * no-op, so the boot sequence can start it early and `showShell` can still
 * await it without a second read.
 */
export function hydrateCache(forOwner: string): Promise<void> {
  if (hydrated && owner === forOwner) return hydrated;
  owner = forOwner;
  hydrated = enqueue(async (db) => {
    const tx = db.transaction(STORE, "readwrite");
    const os = tx.objectStore(STORE);
    const [keys, values] = await Promise.all([
      promisify(os.getAllKeys()),
      promisify(os.getAll() as IDBRequest<Record_[]>),
    ]);
    keys.forEach((k, i) => {
      const rec = values[i];
      if (!rec || typeof k !== "string") return;
      if (rec.owner === forOwner) {
        // Memory wins: a view may already have written something newer
        // during the same boot.
        if (!store.has(k)) store.set(k, rec.data);
      } else {
        os.delete(k);
      }
    });
    await promisify(os.count());
  });
  return hydrated;
}

/**
 * A cheap fingerprint of a list of items — order plus the handful of fields a
 * card or a detail page actually draws (watched state, resume position,
 * favorite star, the image tag). Good enough to catch everything a background
 * refresh needs to react to, without a deep-equal over server payloads that
 * carry dozens of fields no view reads. `null`/`undefined` entries are
 * dropped, so callers can pass in optional values (a series' next-up episode,
 * say) without filtering first.
 */
export function itemSignature(items: (any | null | undefined)[] | null | undefined): string {
  if (!items) return "";
  return items
    .filter((i) => i != null)
    .map((i) => {
      if (typeof i !== "object") return String(i);
      const u = i.UserData ?? {};
      return [
        i.Id,
        u.Played ? 1 : 0,
        u.PlaybackPositionTicks ?? 0,
        u.IsFavorite ? 1 : 0,
        i.ImageTags?.Primary ?? "",
        i.ImageTags?.Backdrop ?? "",
      ].join(":");
    })
    .join(",");
}
