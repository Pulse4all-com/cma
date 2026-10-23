/**
 * The metric catalog's pure logic (Configuration → Metrics): the registry of metric keys per page,
 * the page's gate, the anchor links the tile hints use, and the filter rule of the catalog page.
 * The catalog itself lives in docs/metrics/catalog.json; web/scripts/metrics-doc.mjs copies it into
 * src/lib/metrics-catalog.json for the build (the Docker build's context is web/) and generates
 * docs/metrics/METRICS.md from it; web/verify/metrics.mjs keeps the three in step.
 * No runtime imports, so the verifier runs this module with Node's type stripping.
 */

/** One entry of the catalog, as docs/metrics/schema.json defines it */
export interface MetricEntry {
  key: string;
  surface: "welcome" | "live" | "dashboard" | "report" | "configuration" | "agent" | "export" | "api";
  page: string;
  tile: string | null;
  title: { en: string; nl: string | null };
  definition: string;
  formula: string;
  unit: string;
  grain: readonly string[];
  sources: readonly {
    table: string;
    columns: readonly string[];
    owner: string;
    fed_by: string;
    cadence: string;
  }[];
  filters: readonly string[];
  time: string;
  comparison: string | null;
  settings: readonly { key: string; default: string; pulse4all: string }[];
  permissions: { anyOf: readonly string[]; perPerson: "email" | "orders" | "attempts" | "deals" | null };
  refresh: string;
  computed_in: {
    sql: readonly { object: string; migration: string }[];
    ts: readonly { file: string; export: string }[];
  };
  verify_sql: string | null;
  fixture_check: string;
  prerequisites: readonly { item: string; check: string | null }[];
  docs: readonly string[];
  status: readonly ("verified" | "discrepancy" | "ambiguous" | "prerequisite_missing" | "cadence_unconfirmed")[];
  notes: string;
}

export interface MetricCatalog {
  _about: string;
  entries: readonly MetricEntry[];
}

/** The permission that shows the page, the rail item and the tile hints' link */
export const METRICS_PERMISSION = "tenant.configure";

/** The catalog page's answer for a set of permissions: the page for the holder, a real 403 for everyone else */
export function metricsPageStatus(permissions: readonly string[]): 200 | 403 {
  return permissions.includes(METRICS_PERMISSION) ? 200 : 403;
}

/** The anchor of an entry on the catalog page: /configuration/metrics#calls.outbound_connected_share */
export function metricsHref(key: string): string {
  return `/configuration/metrics#${key}`;
}

/**
 * "How this is computed" on a tile's hint: the link for a person who may open the catalog page,
 * nothing for anyone else (the page would answer their 403)
 */
export function metricsMore(permissions: readonly string[], key: string, label: string): { href: string; label: string } | undefined {
  return permissions.includes(METRICS_PERMISSION) ? { href: metricsHref(key), label } : undefined;
}

/**
 * The metric keys each page shows, the registry web/verify/metrics.mjs checks against the catalog:
 * every key here must have a catalog entry, and every catalog entry on a page surface (welcome, live,
 * dashboard, report, agent) must be registered under its page. A new figure on a page is added here
 * and in docs/metrics/catalog.json in the same change, or verify:metrics fails the build.
 */
export const PAGE_METRIC_KEYS: Readonly<Record<string, readonly string[]>> = {};

/** Every registered key, flat, for the uniqueness and coverage checks */
export function registeredKeys(): string[] {
  return Object.values(PAGE_METRIC_KEYS).flat();
}

/** The filters of the catalog page; empty strings mean "all" */
export interface MetricsFilter {
  q: string;
  page: string;
  surface: string;
  owner: string;
  status: string;
}

/** The facts of one card the filter looks at (the card carries them as data attributes) */
export interface MetricCardFacts {
  key: string;
  page: string;
  surface: string;
  owners: readonly string[];
  statuses: readonly string[];
  text: string;
}

export function cardFacts(e: Pick<MetricEntry, "key" | "page" | "surface" | "sources" | "status" | "tile" | "definition">): MetricCardFacts {
  return {
    key: e.key,
    page: e.page,
    surface: e.surface,
    owners: [...new Set(e.sources.map((s) => s.owner))],
    statuses: e.status,
    text: `${e.key} ${e.tile ?? ""} ${e.definition}`.toLowerCase(),
  };
}

/** True when the card stays visible under these filters; the words of q must all occur */
export function matchesFilter(card: MetricCardFacts, f: MetricsFilter): boolean {
  if (f.page && card.page !== f.page) return false;
  if (f.surface && card.surface !== f.surface) return false;
  if (f.owner && !card.owners.includes(f.owner)) return false;
  if (f.status && !card.statuses.includes(f.status)) return false;
  const words = f.q.toLowerCase().split(/\s+/).filter(Boolean);
  return words.every((w) => card.text.includes(w));
}

/** The filter choices the catalog offers, each list in first-seen order */
export function filterChoices(entries: readonly Pick<MetricEntry, "page" | "surface" | "sources" | "status">[]): {
  pages: string[]; surfaces: string[]; owners: string[]; statuses: string[];
} {
  const seen = { pages: new Set<string>(), surfaces: new Set<string>(), owners: new Set<string>(), statuses: new Set<string>() };
  for (const e of entries) {
    seen.pages.add(e.page);
    seen.surfaces.add(e.surface);
    for (const s of e.sources) seen.owners.add(s.owner);
    for (const s of e.status) seen.statuses.add(s);
  }
  return {
    pages: [...seen.pages], surfaces: [...seen.surfaces], owners: [...seen.owners], statuses: [...seen.statuses],
  };
}

/** The entries grouped by page in the catalog's order, for the page's sections */
export function entriesByPage<T extends Pick<MetricEntry, "page">>(entries: readonly T[]): { page: string; entries: T[] }[] {
  const out: { page: string; entries: T[] }[] = [];
  for (const e of entries) {
    const last = out.find((g) => g.page === e.page);
    if (last) last.entries.push(e);
    else out.push({ page: e.page, entries: [e] });
  }
  return out;
}
