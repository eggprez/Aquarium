import * as api from "../api";
import { el, clear, spinner, section, cardRow } from "../ui";

export async function renderHome(root: HTMLElement): Promise<void> {
  clear(root);
  root.append(spinner());

  const [resume, nextUp, views] = await Promise.all([
    api.getResume().catch(() => []),
    api.getNextUp().catch(() => []),
    api.getViews().catch(() => []),
  ]);

  clear(root);
  root.append(el("h1", { class: "page-title" }, ["Home"]));

  if (resume.length) {
    root.append(section("Continue Watching", cardRow(resume, { wide: true })));
  }
  if (nextUp.length) {
    root.append(section("Next Up", cardRow(nextUp, { wide: true })));
  }

  const mediaViews = views.filter((v: any) =>
    ["movies", "tvshows", "homevideos", "musicvideos", null, undefined].includes(v.CollectionType)
  );
  const latestSections = await Promise.all(
    mediaViews.map(async (v: any) => {
      const latest = await api.getLatest(v.Id).catch(() => []);
      return { view: v, latest };
    })
  );
  for (const { view, latest } of latestSections) {
    if (!latest.length) continue;
    root.append(
      section(`Latest in ${view.Name}`, cardRow(latest), () => {
        location.hash = `#/lib/${view.Id}`;
      })
    );
  }

  if (!resume.length && !nextUp.length && !latestSections.some((s) => s.latest.length)) {
    root.append(el("div", { class: "empty" }, ["Your libraries look empty. Add media in Jellyfin to get started."]));
  }
}
