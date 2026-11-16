// Helpers for the api.ts suites.
//
// The mocked bridge is built the first time something imports
// `@tauri-apps/api/core`, from whichever copy of helpers/tauri.ts exists at
// that moment, and is then kept across `vi.resetModules()`. Importing it here,
// before any reset, pins it to the same copy the test file imports, so
// `onInvoke` and `invokeCalls` keep reaching the bridge a freshly imported
// `src/api` talks to.
import "@tauri-apps/api/core";
import { onTestFinished, vi } from "vitest";
import { invokeCalls } from "./tauri";

export { flush, invokeCalls, mockJellyfin, onInvoke, signIn, signedInConfig } from "./tauri";

/** A clean module registry, so the next `signIn()` gets a clean `src/api`. */
export function fresh(): void {
  vi.resetModules();
}

/** The field list every grid query in api.ts asks for. */
export const ITEM_FIELDS =
  "PrimaryImageAspectRatio,Overview,Genres,MediaSources,UserData,SeriesPrimaryImage,ChildCount,RecursiveItemCount,ProductionYear,RunTimeTicks,OfficialRating,CommunityRating,ParentId";

/** What the detail page adds to it. */
export const DETAIL_FIELDS = `${ITEM_FIELDS},People,Studios,Taglines,ProviderIds`;

export interface ParsedPath {
  route: string;
  query: URLSearchParams;
  /** The query as a plain object (last value wins). */
  params: Record<string, string>;
}

/** Split a request path into its route and decoded query. */
export function parsePath(path: string): ParsedPath {
  const i = path.indexOf("?");
  const route = i < 0 ? path : path.slice(0, i);
  const query = new URLSearchParams(i < 0 ? "" : path.slice(i + 1));
  return { route, query, params: Object.fromEntries(query.entries()) };
}

export interface JfCall {
  path: string;
  method: string;
  body: any;
}

/** Every `jf_request` made so far, in order. */
export function jfCalls(): JfCall[] {
  return invokeCalls("jf_request").map((c) => c.args as JfCall);
}

/** The details of every `name` event dispatched on `document` during this test. */
export function capture(name: string): any[] {
  const seen: any[] = [];
  const h = (e: Event): void => {
    seen.push((e as CustomEvent).detail);
  };
  document.addEventListener(name, h);
  onTestFinished(() => document.removeEventListener(name, h));
  return seen;
}

/** An episode as `/Shows/{id}/Episodes` returns it, as far as Next Up reads it. */
export function episode(
  id: string,
  season: number,
  number: number,
  userData: Record<string, any> = {},
  extra: Record<string, any> = {}
): any {
  return {
    Id: id,
    Type: "Episode",
    SeriesId: "series-1",
    ParentIndexNumber: season,
    IndexNumber: number,
    UserData: { Played: false, PlayCount: 0, PlaybackPositionTicks: 0, ...userData },
    ...extra,
  };
}
