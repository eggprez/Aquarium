// Someone from a cast list: who they are, and what of theirs is in the
// library. The Apple app's PersonView; a cast name used to run a title
// search for itself instead.
import * as api from "../api";
import { el, clear, art, noartIcon, itemCard, emptyState, errorState, skeletonGrid } from "../ui";
import { getCached, setCached, itemSignature } from "../cache";

interface PersonData {
  person: any;
  items: any[];
}

function day(value: any): string | null {
  const t = Date.parse(value);
  return isFinite(t) ? new Date(t).toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" }) : null;
}

function paint(root: HTMLElement, d: PersonData): void {
  clear(root);
  const p = d.person;
  const born = day(p.PremiereDate);
  const died = day(p.EndDate);
  const place = (p.ProductionLocations ?? [])[0];
  const facts = [
    born ? (died ? `${born} – ${died}` : `Born ${born}`) : null,
    place ?? null,
  ].filter(Boolean) as string[];

  const bio = p.Overview ? el("p", { class: "person-bio clamped" }, [p.Overview]) : null;
  const more = bio
    ? el("button", {
        class: "person-more",
        onClick: () => {
          const open = bio.classList.toggle("clamped");
          more!.textContent = open ? "Read more" : "Show less";
        },
      }, ["Read more"])
    : null;

  root.append(
    el("div", { class: "person-head" }, [
      el("div", { class: "person-portrait" }, [
        art(api.imageUrl(p, "Primary", 400), () => noartIcon("people", 40), { lazy: false, hash: api.imageHash(p, "Primary") }),
      ]),
      el("div", { class: "person-info" }, [
        el("h1", { class: "page-title" }, [p.Name ?? ""]),
        facts.length ? el("div", { class: "person-facts" }, [facts.join("  ·  ")]) : null,
        bio,
        more,
      ]),
    ])
  );
  // Only offer "Read more" when the text is actually cut short.
  if (bio && more) requestAnimationFrame(() => {
    if (bio.scrollHeight <= bio.clientHeight + 2) more.remove();
  });

  const films = d.items.filter((i) => i.Type === "Movie");
  const shows = d.items.filter((i) => i.Type === "Series");
  for (const [label, items] of [["Films", films], ["Shows", shows]] as [string, any[]][]) {
    if (!items.length) continue;
    root.append(
      el("div", { class: "section" }, [
        el("div", { class: "section-head" }, [el("h2", {}, [`${label} · ${items.length}`])]),
        el("div", { class: "card-grid" }, items.map((i) => itemCard(i))),
      ])
    );
  }
  if (!films.length && !shows.length) {
    root.append(emptyState({
      icon: "library",
      title: `Nothing with ${p.Name ?? "them"} here`,
      body: "They are credited on something that has since left the library.",
    }));
  }
}

export async function renderPerson(root: HTMLElement, id: string): Promise<void> {
  clear(root);
  const page = el("div", {});
  root.append(page);
  const key = `person:${id}`;
  const cached = getCached<PersonData>(key);
  if (cached) paint(page, cached);
  else page.append(skeletonGrid(12));
  try {
    const [person, items] = await Promise.all([api.getItem(id), api.getPersonItems(id)]);
    if (!document.contains(page)) return;
    const fresh = { person, items };
    const sig = (d: PersonData): string => `${d.person?.Name}:${(d.person?.Overview ?? "").length}:${itemSignature(d.items)}`;
    if (!cached || sig(cached) !== sig(fresh)) paint(page, fresh);
    setCached(key, fresh);
  } catch (e) {
    if (!document.contains(page) || cached) return;
    clear(page);
    page.append(errorState("This page didn't load", e, () => void renderPerson(root, id)));
  }
}
