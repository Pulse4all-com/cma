/**
 * Assets → Installed base as the "now" view (addition 0009f; Martin, 8 November 2026, D1 to D7), rendered on the server:
 * the filters' line with the serial search, the model donut with its legend (a table, so every figure is text), In the
 * field per market stacked per model in the donut's colours (the style guide's series order, 7.7; 7.8: never colour
 * alone), the panels' row (one open at a time, address state), a breakdown panel with its chart over its table, a list
 * panel with its count, file and pager, and the skeletons shown while a list is read. Everything is server-drawn SVG and
 * HTML, no library. Ids, serials, statuses, codes and the CRM's links only: never a name, email, phone or address.
 */
import Link from "next/link";
import type { Route } from "next";
import type { ReactNode } from "react";
import { BreakdownTable, fmtNumber, RowsTable } from "@/components/FlashParts";
import { HeaderHint } from "@/components/HeaderHint";
import { HintLabel } from "@/components/HintLabel";
import { Button, Card, Keycap, LinkButton, Notice } from "@/components/primitives";
import type { Copy } from "@/lib/copy";
import { CmaDbError, requestDbTrace, type FlashDocumentView, type FlashRowsView } from "@/lib/data";
import { FLASH_ADDRESS, filtersShown, filtersText, listUnavailable, splitKeyLabel, type FlashDocRow, type FlashOverviewDef } from "@/lib/flash";
import {
  breakdownChart, donutArcs, INSTALLED_BASE_ADDRESS, INSTALLED_BASE_HIDDEN_COLUMNS, INSTALLED_BASE_PAGE_ROWS, INSTALLED_BASE_PANELS, INSTALLED_BASE_PATH,
  installedBaseHref, LIST_PANELS, marketStacks, OTHER_KEY, panelSet, seriesClass, widthShare, type BreakdownChart, type InstalledBasePanel, type InstalledBaseState,
  type MarketStack, type Slice,
} from "@/lib/installed-base";
import { fmtPercent } from "@/lib/time";

type Query = Record<string, string>;
type Locale = "en" | "nl";
const href = (query: Query) => installedBaseHref(query) as Route;

/** A hint's mark after a label (as the report pages' header hints) */
function Hint({ label, text, copy }: { label: string; text: string; copy: Copy }) {
  return <HintLabel label={label}><HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} /></HintLabel>;
}

/** A model's name as the register names it; Unknown model and Other from the copy */
export function modelLabel(key: string, labels: FlashDocumentView["labels"], copy: Copy): string {
  if (key === OTHER_KEY) return copy.installedBase.other;
  return splitKeyLabel("installed_base", key, copy.flash, labels);
}

/** The serial search (D7): a plain form, so Enter finds; the page's filters ride along as hidden fields */
export function SerialSearch({ st, copy }: { st: InstalledBaseState; copy: Copy }) {
  const t = copy.installedBase;
  return (
    <form method="get" action={INSTALLED_BASE_PATH} className="flex flex-col gap-2 text-small font-semibold" data-testid="ib-search">
      {Object.entries(st.base).map(([k, v]) => <input key={k} type="hidden" name={k} value={v} />)}
      <label htmlFor="ib-serial" className="flex items-center gap-2" data-hint-anchor="">
        <Hint label={t.searchLabel} text={t.searchHint} copy={copy} /> <Keycap>F</Keycap>
      </label>
      <div className="flex items-center gap-2">
        <input id="ib-serial" name={INSTALLED_BASE_ADDRESS.serial} type="search" defaultValue={st.serial ?? ""} maxLength={100} data-shortcut="f" autoComplete="off"
          className="h-10 w-56 rounded-button border border-p4a-border bg-white px-3 text-body font-normal text-p4a-body focus:border-p4a-deepblue focus:outline-none focus:ring-2 focus:ring-p4a-lightblue" />
        <Button type="submit" variant="outlined" size="md">{t.searchButton}</Button>
        {st.serial ? <Link href={href(st.base)} className="text-small font-semibold text-p4a-deepblue underline" data-testid="ib-search-clear">{t.searchClear}</Link> : null}
      </div>
    </form>
  );
}

/** The panels' row (D4): one link each, the open one marked and linking to the page without it (a click hides it) */
export function PanelTabs({ st, copy }: { st: InstalledBaseState; copy: Copy }) {
  const t = copy.installedBase;
  const names: Record<InstalledBasePanel, string> = {
    breakdown: t.panelBreakdown, subscription: t.panelSubscription, records: t.panelRecords, past_due: t.panelPastDue, unlinked: t.panelUnlinked,
  };
  // a serial search shows its results in place of a panel: no panel is marked open
  const open = st.serial ? null : st.panel;
  return (
    <nav aria-label={t.panelsLabel} className="flex flex-wrap items-center gap-2" data-testid="ib-panels">
      <span className="text-small font-semibold text-p4a-heading">{t.panelsLabel}</span>
      {INSTALLED_BASE_PANELS.map((p) => (
        <Link key={p} href={href(open === p ? st.base : { ...st.base, [INSTALLED_BASE_ADDRESS.panel]: p })} aria-current={open === p ? "page" : undefined}
          title={open === p ? t.hidePanel : undefined} data-testid={`ib-panel-${p}`}
          className={`inline-flex h-8 items-center gap-2 rounded-button border px-3 text-small font-semibold no-underline ${open === p
            ? "border-p4a-deepblue bg-p4a-deepblue text-white" : "border-p4a-border bg-white text-p4a-deepblue hover:bg-p4a-bgblue"}`}>
          {names[p]}
        </Link>
      ))}
    </nav>
  );
}

/** A ring with its slices, the total in its centre; an empty ring at 0 */
function Ring({ slices, total, locale, label, size = 176 }: { slices: readonly Slice[]; total: number; locale: Locale; label: string; size?: number }) {
  const arcs = donutArcs(slices, size);
  const c = size / 2;
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} role="img" aria-label={label} className="shrink-0">
      {total <= 0 ? <circle cx={c} cy={c} r={c - 15} fill="none" stroke="currentColor" strokeWidth="30" className="text-p4a-bgblue" /> : null}
      {arcs.filter((a) => a.d !== "").map((a) => (
        <path key={a.slice.key} d={a.d} fill="currentColor" className={seriesClass(a.slice.colour)}>
          <title>{`${a.slice.key}: ${fmtNumber(a.slice.value, locale)}`}</title>
        </path>
      ))}
      <text x={c} y={c} textAnchor="middle" dominantBaseline="central" fill="currentColor" className="tabular text-p4a-heading" fontSize="28" fontWeight="700">
        {fmtNumber(total, locale)}
      </text>
    </svg>
  );
}

/** A slice's or a bar's colour swatch, with the figure in text beside it wherever it is used */
function Swatch({ colour }: { colour: number }) {
  return <span aria-hidden="true" className={`inline-block h-3 w-3 shrink-0 rounded-[2px] bg-current ${seriesClass(colour)}`} />;
}

/**
 * The model donut (D2): In the field per model, the total in the centre, a legend with each model's count and share as a
 * table (7.6), so the figures are text. The slices are the donut's colours for the per-market stacks too
 */
export function ModelDonut({ slices, total, labels, locale, copy }: {
  slices: readonly Slice[]; total: number; labels: FlashDocumentView["labels"]; locale: Locale; copy: Copy;
}) {
  const t = copy.installedBase;
  const name = (s: Slice) => modelLabel(s.key, labels, copy);
  const aria = `${t.splitTitle}: ${slices.map((s) => `${name(s)} ${fmtNumber(s.value, locale)}`).join(", ")}`;
  return (
    <div className="flex flex-wrap items-center gap-8" data-testid="ib-donut">
      <Ring slices={slices} total={total} locale={locale} label={aria} />
      <table className="min-w-72 border-collapse text-body leading-table" data-testid="ib-donut-legend">
        <thead>
          <tr className="bg-p4a-bgblue text-small font-semibold text-p4a-heading">
            <th scope="col" className="px-3 py-2 text-left font-semibold">{t.legendModel}</th>
            <th scope="col" className="px-3 py-2 text-right font-semibold">{t.legendCount}</th>
            <th scope="col" className="px-3 py-2 text-right font-semibold">{t.legendShare}</th>
          </tr>
        </thead>
        <tbody>
          {slices.map((s) => (
            <tr key={s.key} className="h-10 border-b border-p4a-border even:bg-p4a-offwhite" data-testid={`ib-slice-${s.key}`}>
              <td className="px-3 py-2">
                <span className="flex items-center gap-2" title={s.key === OTHER_KEY ? t.otherHint.replace("{n}", String(s.keys.length)) : s.key}>
                  <Swatch colour={s.colour} />{name(s)}
                </span>
              </td>
              <td className="tabular px-3 py-2 text-right">{fmtNumber(s.value, locale)}</td>
              <td className="tabular px-3 py-2 text-right">{fmtPercent(total > 0 ? s.share : null, locale)}</td>
            </tr>
          ))}
          <tr className="h-10 font-semibold">
            <td className="px-3 py-2">{copy.flash.totalRow}</td>
            <td className="tabular px-3 py-2 text-right">{fmtNumber(total, locale)}</td>
            <td className="tabular px-3 py-2 text-right">{fmtPercent(total > 0 ? 1 : null, locale)}</td>
          </tr>
        </tbody>
      </table>
    </div>
  );
}

/** In the field per market (D2): one bar per market, stacked per model in the donut's colours, the total beside it and the parts in text under it */
export function MarketStacks({ stacks, labels, locale, copy, marketName }: {
  stacks: readonly MarketStack[]; labels: FlashDocumentView["labels"]; locale: Locale; copy: Copy; marketName: (code: string) => string;
}) {
  const max = Math.max(0, ...stacks.map((s) => s.total));
  if (stacks.length === 0) return <p className="text-body text-p4a-muted">{copy.flash.empty}</p>;
  return (
    <ul className="flex flex-col gap-3" data-testid="ib-market-stacks">
      {stacks.map((s) => (
        <li key={s.market} className="grid grid-cols-[10rem_1fr_6rem] items-center gap-x-3 gap-y-1 text-small" data-testid={`ib-market-${s.market}`}>
          <span>{marketName(s.market)}</span>
          <span className="flex h-3 overflow-hidden rounded-button bg-p4a-bgblue" aria-hidden="true">
            {s.parts.map((p) => (
              <span key={p.key} className={`block h-3 bg-current ${seriesClass(p.colour)}`} style={{ width: `${Math.round(widthShare(p.value, max) * 1000) / 10}%` }}
                title={`${modelLabel(p.key, labels, copy)} ${fmtNumber(p.value, locale)}`} />
            ))}
          </span>
          <span className="tabular text-right">{fmtNumber(s.total, locale)}</span>
          <span className="tabular col-span-2 col-start-2 text-caption text-p4a-grey">
            {s.parts.map((p) => `${modelLabel(p.key, labels, copy)} ${fmtNumber(p.value, locale)}`).join(" · ")}
          </span>
        </li>
      ))}
    </ul>
  );
}

/** A breakdown's chart of its totals (D4): a donut at five categories or fewer, else bars sorted by size; the figures in text either way */
export function BreakdownChartView({ chart, name, locale, title }: { chart: BreakdownChart; name: (key: string) => string; locale: Locale; title: string }) {
  if (chart.items.length === 0) return null;
  if (chart.kind === "donut") {
    const slices: Slice[] = chart.items.map((i) => ({ key: i.key, keys: [i.key], value: i.value, share: i.share, colour: i.colour }));
    return (
      <div className="mb-6 flex flex-wrap items-center gap-8" data-testid="ib-breakdown-chart" data-kind="donut">
        <Ring slices={slices} total={chart.total} locale={locale} label={`${title}: ${chart.items.map((i) => `${name(i.key)} ${fmtNumber(i.value, locale)}`).join(", ")}`} size={144} />
        <ul className="flex flex-col gap-1 text-small">
          {chart.items.map((i) => (
            <li key={i.key} className="flex items-center gap-2">
              <Swatch colour={i.colour} /><span>{name(i.key)}</span>
              <span className="tabular">{fmtNumber(i.value, locale)}</span>
              <span className="tabular text-p4a-muted">{fmtPercent(chart.total > 0 ? i.share : null, locale)}</span>
            </li>
          ))}
        </ul>
      </div>
    );
  }
  const max = Math.max(0, ...chart.items.map((i) => i.value));
  return (
    <ul className="mb-6 flex flex-col gap-2" data-testid="ib-breakdown-chart" data-kind="bars" aria-label={title}>
      {chart.items.map((i) => (
        <li key={i.key} className="grid grid-cols-[12rem_1fr_6rem] items-center gap-3 text-small">
          <span>{name(i.key)}</span>
          <span className="h-3 rounded-button bg-p4a-bgblue" aria-hidden="true">
            <span className="block h-3 rounded-button bg-p4a-deepblue" style={{ width: `${Math.round(widthShare(i.value, max) * 100)}%` }} />
          </span>
          <span className="tabular text-right">{fmtNumber(i.value, locale)}</span>
        </li>
      ))}
    </ul>
  );
}

/** The words of a dim's value in a breakdown (a model by its register name, a status by the catalog's, the market's name) */
export function dimName(def: FlashOverviewDef, dim: string, key: string, labels: FlashDocumentView["labels"], copy: Copy): string {
  const t = copy.flash;
  if (dim === "market") return key === "unknown" ? t.unknownMarket : labels.market?.[key] ?? key;
  if (dim === "model") return modelLabel(key, labels, copy);
  if (dim === "subscription_status") return key === "not_found" ? t.notFound : key === "none" ? t.noLink : key;
  if (dim === "status" && key === "unknown") return copy.installedBase.unknownStatus;
  return labels[dim]?.[key] ?? key;
}

/**
 * A breakdown panel (D4): the set's chart over its table (the cells link to the records panel with the row's filters),
 * and the breakdown's file. A set the page filters cannot narrow says so instead
 */
export function BreakdownPanel({ panel, def, doc, rows, unavailable, query, fileQuery, locale, copy }: {
  panel: InstalledBasePanel; def: FlashOverviewDef; doc: FlashDocumentView; rows: readonly FlashDocRow[]; unavailable: boolean; query: Query;
  fileQuery: URLSearchParams; locale: Locale; copy: Copy;
}) {
  const t = copy.flash;
  const set = panelSet(panel, def);
  if (!set) return null;
  const title = `${t.breakdown}: ${set.filter((d) => d !== "market").map((d) => String(t[`d_${d}` as keyof typeof t] ?? d)).join(", ")}`;
  if (unavailable) {
    return <Card title={title}><p className="text-body text-p4a-muted" data-testid={`ib-set-unavailable-${panel}`}>{copy.installedBase.filterUnavailableSet}</p></Card>;
  }
  // the chart: the leading dim after the market (the status, the subscription status), the devices per value
  const dim = set.find((d) => d !== "market") ?? set[0]!;
  const measure = "devices";
  const chart = breakdownChart(rows, set, dim, measure);
  const chartTitle = copy.installedBase.chartTitle.replace("{measure}", String(t[`m_${measure}` as keyof typeof t])).replace("{dim}", String(t[`d_${dim}` as keyof typeof t] ?? dim));
  const shown: FlashDocumentView = { ...doc, rows: rows as FlashDocumentView["rows"] };
  return (
    <Card title={title}>
      <BreakdownChartView chart={chart} name={(k) => dimName(def, dim, k, doc.labels, copy)} locale={locale} title={chartTitle} />
      <BreakdownTable def={def} doc={shown} set={set} query={query} locale={locale} t={t} path={INSTALLED_BASE_PATH} />
      <div className="mt-4 flex justify-end">
        <LinkButton href={`/api/v1/reports/flash/file?${fileQuery.toString()}`} download data-testid="flash-download-breakdown"
          title={t.downloadHint.replace("{n}", fmtNumber(doc.settings.fileMaxRows, locale))}>{t.downloadBreakdown}</LinkButton>
      </div>
    </Card>
  );
}

/** A list's place while it is read (7.3: calm blocks, no spinner), sized like a page of rows; its words for a screen reader */
export function ListSkeleton({ label, rows = 8 }: { label: string; rows?: number }) {
  return (
    <div aria-busy="true" data-testid="ib-list-loading">
      <span className="sr-only">{label}</span>
      <div className="mb-4 h-4 w-56 animate-pulse rounded-input bg-p4a-border" aria-hidden="true" />
      {Array.from({ length: rows }, (_, i) => <div key={i} className="mb-2 h-8 animate-pulse rounded-input bg-p4a-bgblue" aria-hidden="true" />)}
    </div>
  );
}

/** The list's read as it ended: its rows, or the error it raised (the boundary decides) */
export interface ListRead {
  rows: FlashRowsView | null;
  error: unknown;
}

/**
 * A list panel or the serial search's results (D5, D6, D7): the count, the file (X, every column), the note that says what
 * the list counts, the table without the file-only columns, 50 rows a page with the sorts, and the pager. The read was
 * started with the document's (lib/db/client streamed); the first paint never waits for it. Under CMA_DB_TRACE the
 * request's total cost is written after the read, as a Flash overview's records write it
 */
export async function ListPanel({ title, note, read, def, st, query, fileQuery, labels, fileMaxRows, storedFigures, me, copy }: {
  title: string; note: string | null; read: Promise<ListRead>; def: FlashOverviewDef; st: InstalledBaseState; query: Query; fileQuery: URLSearchParams;
  labels: FlashDocumentView["labels"]; fileMaxRows: number; storedFigures: boolean; me: { locale: Locale; timeZone: string }; copy: Copy;
}) {
  const t = copy.flash;
  const ib = copy.installedBase;
  const locale = me.locale;
  const r = await read;
  const dbTrace = requestDbTrace();
  const trace = dbTrace ? <meta name="cma-db" content={dbTrace} /> : null;
  const unavailable = r.error !== null && r.error instanceof CmaDbError && listUnavailable(r.error.sqlState);
  if (r.error !== null && !unavailable) throw r.error;
  const rows = r.rows;
  if (unavailable || !rows) {
    return <Card title={title}>{trace}<div data-testid="flash-rows-unavailable"><Notice tone="info">{t.rowsNotAvailable}</Notice></div></Card>;
  }
  const totalPages = Math.max(1, Math.ceil(rows.total / INSTALLED_BASE_PAGE_ROWS));
  const link = (q: Query) => href(q);
  const count = rows.total === 1 ? ib.oneOf.replace("{shown}", fmtNumber(rows.rows.length, locale))
    : ib.listOf.replace("{shown}", fmtNumber(rows.rows.length, locale)).replace("{total}", fmtNumber(rows.total, locale));
  return (
    <Card title={title}>
      {trace}
      {note ? <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{note}</p> : null}
      <div className="mb-4 flex flex-wrap items-center justify-between gap-4 text-small">
        <span className="text-p4a-muted" data-testid="flash-rows-count">{st.serial && rows.total === 0 ? ib.searchNone : count}</span>
        <LinkButton href={`/api/v1/reports/flash/file?${fileQuery.toString()}`} download shortcut="X" data-shortcut="x" data-testid="flash-download"
          title={t.downloadHint.replace("{n}", fmtNumber(fileMaxRows, locale))}>{t.download}</LinkButton>
      </div>
      {storedFigures && rows.rows.length > 0 ? <p className="-mt-2 mb-4 text-caption text-p4a-grey" data-testid="flash-rows-live">{t.rowsLive}</p> : null}
      {rows.rows.length === 0 && st.serial ? <p className="text-body text-p4a-muted" data-testid="ib-search-none">{ib.searchNone}</p> : (
        <RowsTable def={def} rows={rows} sort={st.sort} descending={st.descending} query={{ ...query, page: String(st.pageNo) }} locale={locale} timeZone={me.timeZone} t={t}
          path={INSTALLED_BASE_PATH} labels={labels} hidden={INSTALLED_BASE_HIDDEN_COLUMNS} />
      )}
      {totalPages > 1 ? (
        <div className="mt-4 flex items-center gap-4 text-small" data-testid="ib-pager">
          {st.pageNo > 1 ? <Link href={link({ ...query, page: String(st.pageNo - 1) })} className="font-semibold text-p4a-deepblue underline">{t.previousPage}</Link> : null}
          <span className="text-p4a-muted">{ib.pageOf.replace("{page}", String(st.pageNo)).replace("{pages}", String(totalPages))}</span>
          {st.pageNo < totalPages ? <Link href={link({ ...query, page: String(st.pageNo + 1) })} className="font-semibold text-p4a-deepblue underline">{t.nextPage}</Link> : null}
        </div>
      ) : null}
    </Card>
  );
}

/** The list a panel or a search reads, if any: its filters beside the page's, and the words of its card */
export function listOf(st: InstalledBaseState, copy: Copy): { kind: InstalledBasePanel | "search"; filters: Record<string, string>; title: string; note: string | null } | null {
  const ib = copy.installedBase;
  const t = copy.flash;
  const serial = st.serial ?? st.filters.serial ?? null;
  if (serial) return { kind: "search", filters: { ...st.filters, serial }, title: ib.searchTitle.replace("{serial}", serial), note: null };
  if (!st.panel || !LIST_PANELS.includes(st.panel)) return null;
  if (st.panel === "past_due") return { kind: st.panel, filters: { ...st.filters, measure: "components_past_due" }, title: ib.panelPastDue, note: ib.pastDueNote };
  if (st.panel === "unlinked") return { kind: st.panel, filters: { ...st.filters, without_subscription_ref: "true" }, title: ib.panelUnlinked, note: ib.unlinkedNote };
  // the records: their own filters named in the title, as Flash's records card names them
  const own = Object.fromEntries(Object.entries(st.filters).filter(([k]) => k !== "market" && !(k in st.pageFilters)));
  const named = Object.keys(own).length > 0;
  return { kind: "records", filters: st.filters, title: named ? t.rowsFor.replace("{filter}", filtersText(null, null, null, filtersShown("installed_base", own, null))) : ib.panelRecords, note: null };
}

/** The file's query of a list: every filter the list read, as the file route takes them (f_<key>, measure, the sort) */
export function listFileQuery(st: InstalledBaseState, filters: Record<string, string>): URLSearchParams {
  return new URLSearchParams({ overview: "installed_base", ...(st.market ? { market: st.market } : {}),
    ...Object.fromEntries(Object.entries(filters).filter(([k]) => k !== "market" && k !== "measure").map(([k, v]) => [`${FLASH_ADDRESS.filterPrefix}${k}`, v])),
    ...(filters.measure ? { measure: filters.measure } : {}), sort: st.sort, dir: st.descending ? "desc" : "asc" });
}

/** The breakdown file's query: the market and the page filters, which narrow it as they narrow the figures on screen */
export function breakdownFileQuery(st: InstalledBaseState): URLSearchParams {
  return new URLSearchParams({ overview: "installed_base", part: "breakdown", ...(st.market ? { market: st.market } : {}),
    ...Object.fromEntries(Object.entries(st.pageFilters).map(([k, v]) => [`${FLASH_ADDRESS.filterPrefix}${k}`, v])) });
}

/** The stacks per market from the document's rows, in the donut's colours */
export function stacksOf(def: FlashOverviewDef, rows: readonly FlashDocRow[], slices: readonly Slice[]): MarketStack[] {
  const set = def.sets.find((s) => s.includes("model") && s.includes("status")) ?? [];
  return marketStacks(rows, set, def.headline, slices);
}

/** A card's title with its hint */
export function TitledCard({ title, hint, copy, children, testId }: { title: string; hint: string; copy: Copy; children: ReactNode; testId?: string }) {
  return (
    <section className="rounded-card border border-p4a-border bg-white p-6" data-testid={testId}>
      <h2 className="mb-4 text-panel font-semibold text-p4a-heading" data-hint-anchor=""><Hint label={title} text={hint} copy={copy} /></h2>
      {children}
    </section>
  );
}
