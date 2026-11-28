// The desktop's ways into the app besides its window (see desktop.rs): the
// launcher's Continue Watching, Shuffle Music and Resume Audiobook, a result
// opened from GNOME Shell's search, and the index that search answers from.
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import * as api from "./api";
import * as m from "./musicApi";
import * as audio from "./audio";
import { playItem } from "./playback";
import { toast } from "./ui";

/** Do what the launcher or the shell's search asked for. */
async function run(action: string): Promise<void> {
  const [name, rest] = action.includes(":") ? [action.slice(0, action.indexOf(":")), action.slice(action.indexOf(":") + 1)] : [action, ""];
  // Nothing here works signed out; the sign-in screen is already up.
  if (!api.getSession()) return;
  try {
    switch (name) {
      case "open":
        location.hash = `#/item/${rest}`;
        break;
      case "search":
        location.hash = `#/search/${encodeURIComponent(rest)}`;
        break;
      case "continue": {
        // What Continue Watching leads with, else what Next Up does.
        const next = (await api.getResume().catch(() => []))[0] ?? (await api.getNextUp().catch(() => []))[0];
        if (next) await playItem(next, { resume: true });
        else toast("Nothing to continue yet", "info");
        break;
      }
      case "shuffle-music": {
        const songs = (await m.music({ types: "Audio", sort: "random", limit: 200 })).Items;
        if (songs.length) await audio.play(songs, 0, { title: "Shuffle", shuffle: true });
        else toast("No music in this library", "info");
        break;
      }
      case "resume-book": {
        const book = (await m.resumeBooks(1))[0];
        if (book) {
          await audio.play([book], 0, {
            book: true,
            title: book.Name,
            startSeconds: m.secondsOf(book.UserData?.PlaybackPositionTicks) || undefined,
          });
        } else {
          toast("No audiobook in progress", "info");
        }
        break;
      }
    }
  } catch (e: any) {
    toast(e?.message ?? String(e), "error");
  }
}

const INDEX_KEY = "aquarium.search-index-at";
/** The library doesn't change by the minute, and the index is every title. */
const INDEX_EVERY = 6 * 60 * 60 * 1000;

/**
 * Write the names of the library's films and shows where GNOME Shell's
 * search can read them, at most every six hours. Titles only: the provider
 * answers with no server and no token.
 */
async function refreshSearchIndex(): Promise<void> {
  const s = api.getSession();
  if (!s || api.isOffline()) return;
  const stamp = `${s.userId}:`;
  try {
    const last = localStorage.getItem(INDEX_KEY) ?? "";
    if (last.startsWith(stamp) && Date.now() - Number(last.slice(stamp.length)) < INDEX_EVERY) return;
  } catch {
    // No storage: refresh every run.
  }
  const items: { id: string; name: string; type: string; year: number | null }[] = [];
  const page = 500;
  for (let start = 0; start < 20000; start += page) {
    const p = new URLSearchParams({
      userId: s.userId,
      Recursive: "true",
      IncludeItemTypes: "Movie,Series",
      SortBy: "SortName",
      Fields: "ProductionYear",
      EnableImages: "false",
      EnableUserData: "false",
      StartIndex: String(start),
      Limit: String(page),
    });
    const r = await api.api(`/Items?${p}`);
    const got: any[] = r?.Items ?? [];
    for (const i of got) {
      if (i?.Id && i?.Name) items.push({ id: i.Id, name: i.Name, type: i.Type ?? "", year: i.ProductionYear ?? null });
    }
    if (got.length < page) break;
  }
  await invoke("search_index_write", { items });
  try {
    localStorage.setItem(INDEX_KEY, `${stamp}${Date.now()}`);
  } catch {
    // Refreshed again next run, that's all.
  }
}

let wired = false;

/** Called once the shell is up: take the action the app was launched with,
 *  listen for ones handed over by later launches, and refresh the index. */
export function startDesktopIntegration(): void {
  if (!wired) {
    wired = true;
    void listen<string>("launch-action", (ev) => void run(String(ev.payload ?? "")));
  }
  void invoke<string | null>("take_launch_action")
    .then((action) => {
      if (action) void run(action);
    })
    .catch(() => {});
  // Behind everything the first screen needs.
  window.setTimeout(() => void refreshSearchIndex().catch(() => {}), 8000);
}
