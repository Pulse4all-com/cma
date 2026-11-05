/**
 * Reports → Flash's parts (addition 0008zn), rendered on the server: the overviews' strip and cards (keys 1 to 9, 0 and
 * Q), the watch strip, the sources' line, an overview's totals, breakdown with inline bars and per-market bars (7.7),
 * the records with their sortable columns, and the Data quality table with each check's trend. Style 7.3 cards, 7.5
 * badges, 7.6 tables (numbers right-aligned, tabular figures), 7.7 Deep Blue bars on light ground; a change is Muted text
 * with an arrow, never a colour that judges it. Ids, statuses, codes, amounts and the CRM's links only.
 */
import type { Route } from "next";
import Link from "next/link";
import type { ReactNode } from "react";
import { HeaderHint } from "@/components/HeaderHint";
import { HintLabel } from "@/components/HintLabel";
import { Badge, Keycap } from "@/components/primitives";
import type { Copy } from "@/lib/copy";
import type { FlashDocRowView, FlashDocumentView, FlashRowsView, FlashSourcesView, FlashWatchItem } from "@/lib/data";
import {
  amountsOf, averageRating, bandRows, barShare, cardStatusHint, cellFilters, changeLineOf, dataQualityRowShown, FLASH_BAND_DIMS, FLASH_DEFINITION_STATUS,
  FLASH_LINKS_LEFT_OUT, FLASH_LIST_COLUMNS, FLASH_FROZEN_COLUMNS, FLASH_LABELLED_DIMS, FLASH_OVERVIEWS, FLASH_RATIOS, FLASH_SOURCES, dimText, fixInOf, labelColumnOf,
  measureHint, measureNotApplicable, moreThanRows, overviewOf, rowsOfSet, setMeasures, splitLine, splitOf, statusTone, type FlashKey, type FlashOverviewDef,
  type FlashStatusSettings,
} from "@/lib/flash";
import { fmtDate, fmtDateTimeShort, fmtLastRead } from "@/lib/time";

type T = Copy["flash"];
type Query = Record<string, string>;

const href = (query: Query) => {
  const qs = new URLSearchParams(query).toString();
  return `/reports/flash${qs ? `?${qs}` : ""}` as Route;
};

export function fmtNumber(n: number, locale: string, digits = 0): string {
  return new Intl.NumberFormat(locale === "nl" ? "nl-NL" : "en-GB", { maximumFractionDigits: digits, minimumFractionDigits: 0 }).format(n);
}

export function fmtAmount(amount: number, currency: string, locale: string): string {
  try {
    return new Intl.NumberFormat(locale === "nl" ? "nl-NL" : "en-GB", { style: "currency", currency, maximumFractionDigits: 2 }).format(amount);
  } catch {
    return `${currency} ${fmtNumber(amount, locale, 2)}`;
  }
}

/** A measure's value: a count or days as a number, an amount per currency (one line per currency), the rating as an average */
export function MeasureValue({ measure, value, reviews, locale }: { measure: string; value: unknown; reviews?: unknown; locale: string }) {
  if (value !== null && typeof value === "object") {
    const list = amountsOf(value);
    if (list.length === 0) return <span>–</span>;
    return <span className="flex flex-col items-end">{list.map((a) => <span key={a.currency}>{fmtAmount(a.amount, a.currency, locale)}</span>)}</span>;
  }
  if (measure === "rating_sum") {
    const avg = averageRating(typeof value === "number" ? value : null, typeof reviews === "number" ? reviews : null);
    return <span>{avg === null ? "–" : fmtNumber(avg, locale, 2)}</span>;
  }
  // a ratio (devices per holding subscription) to two decimals, as the database rounds it; none shows a dash
  return <span>{typeof value === "number" ? fmtNumber(value, locale, FLASH_RATIOS[measure] ? 2 : measure.endsWith("_age_days") ? 1 : 0) : "–"}</span>;
}

/**
 * A measure's (or a band dim's) label with its hint (addition 0008zt): the copy's mh_<key>, and for a figure that counts
 * by status the statuses of the tenant's settings with the tenant's meanings in the reader's language
 */
export function MeasureLabel({ measure, label, settings, locale, t }: {
  measure: string; label: string; settings: FlashStatusSettings | null | undefined; locale: "en" | "nl"; t: T;
}) {
  const text = measureHint(measure, (t as Record<string, string>)[`mh_${measure}`], settings, locale, t);
  if (!text) return <>{label}</>;
  return <HintLabel label={label}><HeaderHint label={label} text={text} /></HintLabel>;
}

/** A measure that does not apply (left out by the database): said so, never 0 or all, with the reason as its title */
export function NotApplicable({ measure, t }: { measure: string; t: T }) {
  const hint = (t as Record<string, string>)[`na_${measure}`];
  return <span className="font-normal text-p4a-muted" title={hint} data-testid={`flash-na-${measure}`}>{t.notApplicable}</span>;
}

/** The status badge of an overview's definition (7.5): Proposed info, Decided success */
export function DefinitionBadge({ overview, t }: { overview: FlashKey; t: T }) {
  const status = FLASH_DEFINITION_STATUS[overview];
  return <Badge tone={statusTone(status)}>{t[`status_${status}` as keyof T]}</Badge>;
}

/** The overviews as a strip of tabs, each with its key: 1 to 9, 0, Q */
export function FlashStrip({ active, query, t }: { active: FlashKey | null; query: Query; t: T }) {
  return (
    <nav aria-label={t.title} className="mb-6 flex flex-wrap gap-2" data-testid="flash-strip">
      {FLASH_OVERVIEWS.map((o) => (
        <Link key={o.key} href={href({ ...query, o: o.key })} data-shortcut={o.shortcut.toLowerCase()} aria-current={active === o.key ? "page" : undefined}
          className={`inline-flex h-8 items-center gap-2 rounded-button border px-3 text-small font-semibold no-underline ${active === o.key
            ? "border-p4a-deepblue bg-p4a-deepblue text-white" : "border-p4a-border bg-white text-p4a-deepblue hover:bg-p4a-bgblue"}`}>
          <span>{t[`o_${o.key}` as keyof T]}</span>
          <Keycap>{o.shortcut}</Keycap>
        </Link>
      ))}
    </nav>
  );
}

/** Each source's last successful read; a source not set up says so */
export function SourcesLine({ sources, timeZone, locale, t }: { sources: FlashSourcesView; timeZone: string; locale: "en" | "nl"; t: T }) {
  const parts = FLASH_SOURCES.filter((s) => sources[s]).map((s) => {
    const st = sources[s]!;
    const when = !st.setUp ? t.notSetUpShort : st.lastReadAt ? fmtLastRead(st.lastReadAt, new Date(), timeZone, locale) : t.notRead;
    return <span key={s} title={st.adapters.join(", ") || undefined} data-testid={`flash-source-${s}`}>{t[`source_${s}` as keyof T]} {when}</span>;
  });
  if (parts.length === 0) return null;
  return (
    <p className="mb-4 flex flex-wrap items-center gap-x-1 text-small text-p4a-muted" data-testid="flash-sources">
      <span className="font-semibold">{t.sourcesLine}:</span>
      {parts.flatMap((p, i) => (i === 0 ? [p] : [<span key={`dot-${i}`} aria-hidden="true">·</span>, p]))}
    </p>
  );
}

function whereOf(dims: Record<string, string>, unknownMarket: string): string {
  const v = Object.values(dims);
  return v.length === 0 ? "" : v.map((x) => (x === "unknown" ? unknownMarket : x)).join(", ");
}

/** The open watch findings, one line each, linking to the overview concerned; nothing when none */
export function WatchStrip({ items, query, t, copy, locale }: {
  items: FlashWatchItem[]; query: Query; t: T; copy: Copy; locale: "en" | "nl";
}) {
  if (items.length === 0) return null;
  const n = (x: number | null) => (x === null ? "–" : fmtNumber(x, locale, 1));
  return (
    <section aria-label={t.watchTitle} className="mb-6 rounded-card border border-p4a-warning bg-p4a-warning-surface p-4" data-testid="flash-watch">
      <h2 className="mb-2 text-body font-semibold text-p4a-heading">{t.watchTitle}</h2>
      <ul className="flex flex-col gap-1 text-small text-p4a-body">
        {items.map((w, i) => {
          const def = overviewOf(w.overview ?? "");
          const ov = def ? String(t[`o_${def.key}` as keyof T]) : "";
          const measure = w.measure ? String(t[`m_${w.measure}` as keyof T] ?? w.measure) : "";
          const where = whereOf(w.dims, copy.flash.unknownMarket);
          let text: string;
          switch (w.kind) {
            case "jump": text = t.watch_jump; break;
            case "flow_zero": text = t.watch_flow_zero; break;
            case "dq_rise": text = t.watch_dq_rise; break;
            case "source_stale": text = t.watch_source_stale; break;
            default: text = t.watch_snapshot_missing;
          }
          const source = typeof w.dims.source === "string" ? String(t[`source_${w.dims.source}` as keyof T] ?? w.dims.source) : "";
          text = text.replace("{overview}", ov).replace("{where}", where || copy.flash.allMarkets).replace("{measure}", measure)
            .replace("{previous}", n(w.previous)).replace("{value}", n(w.value)).replace("{source}", source)
            .replace("{age}", n(typeof w.detail.age_minutes === "number" ? w.detail.age_minutes : w.value))
            .replace("{from}", typeof w.detail.missing_from === "string" ? fmtDate(w.detail.missing_from, locale) : "")
            .replace("{to}", typeof w.detail.missing_to === "string" ? fmtDate(w.detail.missing_to, locale) : "");
          const since = t.watchSince.replace("{date}", fmtDate(w.snapshotDate, locale));
          const target = def ? href({ ...query, o: def.key, ...(w.dims.market ? { market: w.dims.market } : {}),
            ...(def.key === "data_quality" && w.dims.check ? { f_check: w.dims.check } : {}) }) : null;
          return (
            <li key={`${w.kind}-${i}`} data-testid={`flash-watch-${w.kind}`}>
              {target ? <Link href={target} className="font-semibold text-p4a-deepblue underline">{text}</Link> : <span>{text}</span>}
              <span className="text-p4a-muted"> · {since}</span>
            </li>
          );
        })}
      </ul>
    </section>
  );
}

/** A landing card: the overview's name and key, its headline figure, the change, the definition's status */
export function FlashCard({ def, setUp, sourceLabel, figure, change, note, query, t, statusSettings, locale }: {
  def: FlashOverviewDef; setUp: boolean; sourceLabel: string; figure: ReactNode; change: string | null; query: Query; t: T;
  /** A line under the change: the figure compared with was counted by an earlier definition (addition 0008zu) */
  note?: string | null;
  /** The statuses the card's figures count and the tenant's meanings (addition 0008zt), for its hint */
  statusSettings?: FlashStatusSettings | null; locale?: "en" | "nl";
}) {
  return (
    <Link href={href({ ...query, o: def.key })} data-shortcut={def.shortcut.toLowerCase()} data-testid={`flash-card-${def.key}`}
      title={cardStatusHint(def.key, `${String(t[`h_${def.key}` as keyof T])} ${t.statusHint.replace("{status}", String(t[`status_${FLASH_DEFINITION_STATUS[def.key]}` as keyof T]))}`,
        statusSettings, locale ?? "en", t)}
      className="flex min-h-36 flex-col gap-2 rounded-card border border-p4a-border bg-white p-5 no-underline hover:bg-p4a-bgblue/50">
      <span className="flex items-center justify-between gap-2">
        <span className="text-body font-semibold text-p4a-heading">{t[`o_${def.key}` as keyof T]}</span>
        <Keycap>{def.shortcut}</Keycap>
      </span>
      <span className="text-caption text-p4a-muted">{t[`m_${def.headline}` as keyof T]}</span>
      {setUp ? (
        <>
          {figure}
          {change !== null ? <span className="text-small text-p4a-muted">{change}</span> : null}
          {note ? <span className="text-small text-p4a-muted" data-testid={`flash-definition-${def.key}`}>{note}</span> : null}
        </>
      ) : (
        <span className="text-small text-p4a-muted" data-testid={`flash-not-set-up-${def.key}`}>{t.notSetUp.replace("{source}", sourceLabel)}</span>
      )}
      <span className="mt-auto"><DefinitionBadge overview={def.key} t={t} /></span>
    </Link>
  );
}

/**
 * A stored figure's line against the one to compare with (lib/flash changeLineOf). The landing writes it As of a date,
 * where a snapshot's figures are each taken once after their date ended and compared as stored, so never "so far"
 */
export function changeText(value: number | null, previous: number | null, previousOn: string | null, locale: "en" | "nl", t: T): string {
  return changeLineOf(value, previous, previousOn === null ? null : fmtDate(previousOn, locale), false, t, (x) => fmtNumber(x, locale, 1));
}

/** The totals: one tile per measure, the headline first */
export function TotalsRow({ def, doc, locale, t }: { def: FlashOverviewDef; doc: FlashDocumentView; locale: "en" | "nl"; t: T }) {
  const totals = doc.totals ?? {};
  const order = [def.headline, ...def.measures.filter((m) => m !== def.headline)];
  // the headline's split per device-holding status, each in the subscription app's word (addition 0008zu): the document's
  // rows are the market's when one is chosen; none for a snapshot taken before the split was stored
  const split = splitLine(splitOf(def, doc.rows, null, doc.statusSettings?.deviceHoldingStatuses ?? []),
    (x) => fmtNumber(x, locale, 0));
  return (
    <div className="mb-6 grid grid-cols-2 gap-4 md:grid-cols-3 xl:grid-cols-5" data-testid="flash-totals">
      {order.map((m) => (
        <div key={m} className="rounded-card border border-p4a-border bg-white p-5" data-testid={`flash-total-${m}`} data-hint-anchor="">
          <p className="text-caption text-p4a-grey">
            <MeasureLabel measure={m} label={String(t[`m_${m}` as keyof T])} settings={doc.statusSettings} locale={locale} t={t} />
          </p>
          <p className="tabular mt-1 text-title font-bold text-p4a-heading">
            {measureNotApplicable(def.key, doc.totals, m)
              ? <NotApplicable measure={m} t={t} />
              : <MeasureValue measure={m} value={totals[m]} reviews={totals.reviews} locale={locale} />}
          </p>
          {m === def.headline && split ? <p className="tabular mt-1 text-small text-p4a-body" data-testid={`flash-split-${def.key}`}>{split}</p> : null}
        </div>
      ))}
    </div>
  );
}

/**
 * A dim's value as the breakdown shows it: the market's name, a store's, a pipeline's or a stage's label (a stage by its
 * row's pipeline and its own id: lib/flash dimText), else the value itself
 */
function dimLabel(def: FlashOverviewDef, doc: FlashDocumentView, dim: string, dims: Record<string, string>, t: T): string {
  if (dims[dim] === "unknown" && dim === "market") return t.unknownMarket;
  // a segment, an age band without a creation date (addition 0008zt)
  if (dims[dim] === "unknown" && (dim === "segment" || dim === "age_band")) return t.unknownValue;
  // a device's subscription status: the subscription app's word, else no subscription found, else no reference
  if (dim === "subscription_status" && dims[dim] === "not_found") return t.notFound;
  if (dim === "subscription_status" && dims[dim] === "none") return t.noLink;
  return dimText(def.key, doc.labels, dim, dims);
}

/**
 * A breakdown set as a table (7.6): its dims, then each measure, a total row first; the headline (or the first count
 * measure) with an inline bar. A count cell opens its records (the row's dims and the measure as the list's filters)
 */
export function BreakdownTable({ def, doc, set, query, locale, t }: {
  def: FlashOverviewDef; doc: FlashDocumentView; set: readonly string[]; query: Query; locale: "en" | "nl"; t: T;
}) {
  const rows = rowsOfSet(doc.rows, set);
  const barMeasure = def.countMeasures.includes(def.headline) ? def.headline : def.countMeasures[0] ?? def.headline;
  // the measures the set's rows hold (lib/flash setMeasures: a SKU's orders and units, else every measure)
  const measures = setMeasures(def, set);
  const max = Math.max(0, ...rows.map((r) => (typeof r.measures[barMeasure] === "number" ? (r.measures[barMeasure] as number) : 0)));
  const cellLink = (r: FlashDocRowView, m: string | null) => href({
    ...query, ...Object.fromEntries(Object.entries(cellFilters(r.dims, m)).map(([k, v]) => [k === "measure" ? k : `f_${k}`, v])), page: "1",
  });
  return (
    <div className="overflow-x-auto">
      <table className="w-full border-collapse text-body leading-table" data-testid={`flash-breakdown-${set.join("-")}`}>
        <thead>
          <tr className="bg-p4a-bgblue text-small font-semibold text-p4a-heading">
            {set.map((d) => (
              <th key={d} scope="col" className="px-3 py-2 text-left font-semibold">
                <MeasureLabel measure={d} label={String(t[`d_${d}` as keyof T] ?? d)} settings={doc.statusSettings} locale={locale} t={t} />
              </th>
            ))}
            {measures.map((m) => (
              <th key={m} scope="col" className="px-3 py-2 text-right font-semibold">
                <MeasureLabel measure={m} label={String(t[`m_${m}` as keyof T])} settings={doc.statusSettings} locale={locale} t={t} />
              </th>
            ))}
            <th scope="col" className="w-40 px-3 py-2 font-semibold"><span className="sr-only">{t[`m_${barMeasure}` as keyof T]}</span></th>
          </tr>
        </thead>
        <tbody>
          {!set.includes("sku") ? (
            <tr className="border-b border-p4a-border font-semibold">
              <td className="px-3 py-2" colSpan={set.length}>{t.totalRow}</td>
              {measures.map((m) => (
                <td key={m} className="tabular px-3 py-2 text-right">
                  {measureNotApplicable(def.key, doc.totals, m)
                    ? <NotApplicable measure={m} t={t} />
                    : <MeasureValue measure={m} value={doc.totals?.[m]} reviews={doc.totals?.reviews} locale={locale} />}
                </td>
              ))}
              <td />
            </tr>
          ) : null}
          {rows.map((r, i) => {
            const v = typeof r.measures[barMeasure] === "number" ? (r.measures[barMeasure] as number) : 0;
            return (
              <tr key={i} className="h-10 border-b border-p4a-border even:bg-p4a-offwhite hover:bg-p4a-bgblue/50">
                {set.map((d) => (
                  <td key={d} className="px-3 py-2">
                    <Link href={cellLink(r, null)} className="text-p4a-deepblue underline"
                      title={FLASH_LABELLED_DIMS[def.key]?.[d] && dimLabel(def, doc, d, r.dims, t) !== r.dims[d] ? r.dims[d] : undefined}>{dimLabel(def, doc, d, r.dims, t)}</Link>
                  </td>
                ))}
                {measures.map((m) => (
                  <td key={m} className="tabular px-3 py-2 text-right">
                    {measureNotApplicable(def.key, r.measures, m)
                      ? <NotApplicable measure={m} t={t} />
                      : def.countMeasures.includes(m) && !set.includes("sku")
                      ? <Link href={cellLink(r, m)} className="text-p4a-deepblue underline"><MeasureValue measure={m} value={r.measures[m]} locale={locale} /></Link>
                      : <MeasureValue measure={m} value={r.measures[m]} reviews={r.measures.reviews} locale={locale} />}
                  </td>
                ))}
                <td className="px-3 py-2" aria-hidden="true">
                  <span className="block h-2 rounded-button bg-p4a-deepblue" style={{ width: `${Math.round(barShare(v, max) * 100)}%` }} />
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

/**
 * A band set (addition 0008zt) as a table (7.6): one row per band in band order, of the chosen market or summed over every
 * market (counts added, the ratio worked out again: lib/flash bandRows), the set's measures, the total row; a count cell
 * opens its records (the band and the measure as the list's filters). An age band table ends with the cumulative "More
 * than N months" lines, worked out from its rows
 */
export function BandTable({ def, doc, set, query, locale, t }: {
  def: FlashOverviewDef; doc: FlashDocumentView; set: readonly string[]; query: Query; locale: "en" | "nl"; t: T;
}) {
  const dim = set[1] ?? "";
  const measures = setMeasures(def, set);
  const rows = bandRows(doc.rows, dim, doc.market, measures);
  const cumulative = FLASH_BAND_DIMS[def.key]?.[dim]?.cumulative ?? false;
  const cumulativeMeasure = measures[0] ?? "";
  const label = (band: string) => (band === "unknown" ? t.unknownValue : band);
  const cellLink = (band: string, m: string | null) => href({ ...query, [`f_${dim}`]: band, ...(m ? { measure: m } : {}), page: "1" });
  if (rows.length === 0) return <p className="text-body text-p4a-muted">{t.empty}</p>;
  return (
    <div className="overflow-x-auto">
      <table className="w-full border-collapse text-body leading-table" data-testid={`flash-bands-${dim}`}>
        <thead>
          <tr className="bg-p4a-bgblue text-small font-semibold text-p4a-heading">
            <th scope="col" className="px-3 py-2 text-left font-semibold">
              <MeasureLabel measure={dim} label={String(t[`d_${dim}` as keyof T] ?? dim)} settings={doc.statusSettings} locale={locale} t={t} />
            </th>
            {measures.map((m) => (
              <th key={m} scope="col" className="px-3 py-2 text-right font-semibold">
                <MeasureLabel measure={m} label={String(t[`m_${m}` as keyof T])} settings={doc.statusSettings} locale={locale} t={t} />
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          <tr className="border-b border-p4a-border font-semibold">
            <td className="px-3 py-2">{t.totalRow}</td>
            {measures.map((m) => (
              <td key={m} className="tabular px-3 py-2 text-right"><MeasureValue measure={m} value={doc.totals?.[m]} locale={locale} /></td>
            ))}
          </tr>
          {rows.map((r) => {
            const band = r.dims[dim] ?? "";
            return (
              <tr key={band} className="h-10 border-b border-p4a-border even:bg-p4a-offwhite hover:bg-p4a-bgblue/50" data-testid={`flash-band-${band}`}>
                <td className="px-3 py-2"><Link href={cellLink(band, null)} className="text-p4a-deepblue underline">{label(band)}</Link></td>
                {measures.map((m) => (
                  <td key={m} className="tabular px-3 py-2 text-right">
                    {def.countMeasures.includes(m)
                      ? <Link href={cellLink(band, m)} className="text-p4a-deepblue underline"><MeasureValue measure={m} value={r.measures[m]} locale={locale} /></Link>
                      : <MeasureValue measure={m} value={r.measures[m]} locale={locale} />}
                  </td>
                ))}
              </tr>
            );
          })}
          {cumulative ? moreThanRows(rows, dim, cumulativeMeasure).map((c) => (
            <tr key={`more-${c.months}`} className="h-10 border-b border-p4a-border text-p4a-muted" data-testid={`flash-more-than-${c.months}`}>
              <td className="px-3 py-2">{t.moreThan.replace("{n}", fmtNumber(c.months, locale))}</td>
              <td className="tabular px-3 py-2 text-right">{fmtNumber(c.value, locale)}</td>
              {measures.slice(1).map((m) => <td key={m} />)}
            </tr>
          )) : null}
        </tbody>
      </table>
    </div>
  );
}

/** The headline per market as bars (7.7): Deep Blue on white, the value beside each bar */
export function MarketBars({ def, doc, locale, t }: { def: FlashOverviewDef; doc: FlashDocumentView; locale: string; t: T }) {
  const rows = rowsOfSet(doc.rows, ["market"]);
  const measure = def.countMeasures.includes(def.headline) ? def.headline : def.countMeasures[0] ?? def.headline;
  const max = Math.max(0, ...rows.map((r) => (typeof r.measures[measure] === "number" ? (r.measures[measure] as number) : 0)));
  if (rows.length === 0) return <p className="text-body text-p4a-muted">{t.empty}</p>;
  return (
    <ul className="flex flex-col gap-2" data-testid="flash-market-bars">
      {rows.map((r) => {
        const v = typeof r.measures[measure] === "number" ? (r.measures[measure] as number) : 0;
        return (
          <li key={r.dims.market} className="grid grid-cols-[10rem_1fr_6rem] items-center gap-3 text-small">
            <span>{dimLabel(def, doc, "market", r.dims, t)}</span>
            <span className="h-3 rounded-button bg-p4a-bgblue">
              <span className="block h-3 rounded-button bg-p4a-deepblue" style={{ width: `${Math.round(barShare(v, max) * 100)}%` }} />
            </span>
            <span className="tabular text-right">{fmtNumber(v, locale)}</span>
          </li>
        );
      })}
    </ul>
  );
}

/** The links a column of a list carries (the CRM's only) */
const LINK_OF: Record<string, string> = { contact_id: "contact_url", record_id: "record_url", task_id: "task_url", object_id: "record_url", related_id: "related_url" };

function cellOf(key: string, kind: string, value: unknown, row: Record<string, unknown>, locale: "en" | "nl", timeZone: string, t: T,
  labelled = false): ReactNode {
  if (value === null || value === undefined || value === "") return <span className="text-p4a-muted">–</span>;
  // a pipeline's or a stage's id shows its label (the data layer's <dim>_label: the id where the CMA holds none), the id on hover
  if (labelled) {
    const label = row[labelColumnOf(key)];
    return typeof label === "string" && label !== "" && label !== value ? <span title={String(value)}>{label}</span> : String(value);
  }
  const linkKey = LINK_OF[key];
  const url = linkKey && typeof row[linkKey] === "string" ? (row[linkKey] as string) : null;
  let text: string;
  switch (kind) {
    case "number":
      if (["total_spent", "amount_per_cycle", "total", "amount"].includes(key) && typeof row.currency === "string") {
        text = fmtAmount(Number(value), row.currency, locale);
      } else text = fmtNumber(Number(value), locale, 2);
      break;
    case "date": text = fmtDate(String(value).slice(0, 10), locale); break;
    case "instant": text = fmtDateTimeShort(String(value), timeZone, locale); break;
    case "flag": text = value === true ? t.yes : t.no; break;
    case "list": text = Array.isArray(value) ? value.join(", ") : String(value); break;
    case "refs": text = value && typeof value === "object" ? Object.entries(value as Record<string, unknown>).map(([k, v]) => `${k}: ${String(v)}`).join(", ") : ""; break;
    default: text = key === "fix_in" ? String(t[`fix_${String(value)}` as keyof T] ?? value) : key === "market" && value === "unknown" ? t.unknownMarket : String(value);
  }
  if (text === "") return <span className="text-p4a-muted">–</span>;
  return url ? <a href={url} target="_blank" rel="noreferrer" className="text-p4a-deepblue underline">{text}</a> : text;
}

/** The records: the overview's columns (the links on the ids), sortable on the whitelist, 500 a page */
export function RowsTable({ def, rows, sort, descending, query, locale, timeZone, t }: {
  def: FlashOverviewDef; rows: FlashRowsView; sort: string | null; descending: boolean; query: Query; locale: "en" | "nl"; timeZone: string; t: T;
}) {
  const frozen = rows.mode === "snapshot";
  const columns = (frozen ? FLASH_FROZEN_COLUMNS : FLASH_LIST_COLUMNS[def.key])
    .filter((c) => !c.key.endsWith("_url") && !(FLASH_LINKS_LEFT_OUT[def.key] ?? []).includes(c.key));
  const shown = def.key === "data_quality" && !frozen ? rows.rows.map(dataQualityRowShown) : rows.rows;
  const sortKeyOf = (column: string): string | null => {
    // a month end's frozen list keeps its order (by id): its headers sort nothing
    if (frozen) return null;
    const map: Record<string, string> = { object_id: "object_id", at: "at" };
    return def.sorts.includes(map[column] ?? column) ? map[column] ?? column : null;
  };
  if (shown.length === 0) return <p className="text-body text-p4a-muted" data-testid="flash-rows-empty">{t.empty}</p>;
  return (
    <div className="overflow-x-auto">
      <table className="w-full border-collapse text-body leading-table" data-testid="flash-rows">
        <thead>
          <tr className="bg-p4a-bgblue text-small font-semibold text-p4a-heading">
            {columns.map((c) => {
              const key = sortKeyOf(c.key);
              const label = String(t[`c_${c.key}` as keyof T] ?? t[`d_${c.key}` as keyof T] ?? t[`m_${c.key}` as keyof T] ?? c.key);
              const right = c.kind === "number";
              if (!key) return <th key={c.key} scope="col" className={`px-3 py-2 font-semibold ${right ? "text-right" : "text-left"}`}>{label}</th>;
              const active = sort === key;
              const dir = active && !descending ? "desc" : "asc";
              return (
                <th key={c.key} scope="col" className={`px-3 py-2 font-semibold ${right ? "text-right" : "text-left"}`} aria-sort={active ? (descending ? "descending" : "ascending") : undefined}>
                  <Link href={href({ ...query, sort: key, dir, page: "1" })} className="text-p4a-heading underline">{label}{active ? (descending ? " ↓" : " ↑") : ""}</Link>
                </th>
              );
            })}
          </tr>
        </thead>
        <tbody>
          {shown.map((r, i) => (
            <tr key={i} className="h-10 border-b border-p4a-border even:bg-p4a-offwhite hover:bg-p4a-bgblue/50">
              {columns.map((c) => (
                <td key={c.key} className={`px-3 py-2 ${c.kind === "number" ? "tabular text-right" : ""}`}>
                  {cellOf(c.key, c.kind, r[c.key], r, locale, timeZone, t, !frozen && FLASH_LABELLED_DIMS[def.key]?.[c.key] !== undefined)}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** A small line of a check's findings over the snapshots (7.7: Deep Blue, no gradient) */
function Trend({ points }: { points: number[] }) {
  if (points.length < 2) return <span className="text-p4a-muted">–</span>;
  const w = 96;
  const h = 24;
  const max = Math.max(1, ...points);
  const d = points.map((p, i) => `${i === 0 ? "M" : "L"}${((i / (points.length - 1)) * w).toFixed(1)},${(h - (p / max) * (h - 2) - 1).toFixed(1)}`).join(" ");
  return (
    <svg width={w} height={h} viewBox={`0 0 ${w} ${h}`} aria-hidden="true" className="inline-block text-p4a-deepblue">
      <path d={d} fill="none" stroke="currentColor" strokeWidth="1.5" />
    </svg>
  );
}

/** Data quality: every check with its findings, where it is fixed and its trend; a check opens its records */
export function DataQualityTable({ doc, query, locale, t }: { doc: FlashDocumentView; query: Query; locale: string; t: T }) {
  const perCheck = rowsOfSet(doc.rows, ["check"]);
  const descriptions = doc.labels.check ?? {};
  if (perCheck.length === 0) return <p className="text-body text-p4a-muted" data-testid="flash-dq-none">{t.dqNone}</p>;
  return (
    <div className="overflow-x-auto">
      <table className="w-full border-collapse text-body leading-table" data-testid="flash-dq">
        <thead>
          <tr className="bg-p4a-bgblue text-small font-semibold text-p4a-heading">
            <th scope="col" className="px-3 py-2 text-left font-semibold">{t.dqCheck}</th>
            <th scope="col" className="px-3 py-2 text-right font-semibold">{t.dqFindings}</th>
            <th scope="col" className="px-3 py-2 text-left font-semibold">{t.dqFixIn}</th>
            <th scope="col" className="px-3 py-2 text-left font-semibold">{t.dqTrend}</th>
          </tr>
        </thead>
        <tbody>
          {perCheck.map((r) => {
            const check = r.dims.check ?? "";
            const points = doc.history.filter((h) => h.check === check).map((h) => h.findings);
            return (
              <tr key={check} className="h-10 border-b border-p4a-border even:bg-p4a-offwhite hover:bg-p4a-bgblue/50" data-testid={`flash-dq-${check}`}>
                <td className="px-3 py-2">
                  <Link href={href({ ...query, f_check: check, page: "1" })} className="text-p4a-deepblue underline">{descriptions[check] ?? check}</Link>
                </td>
                <td className="tabular px-3 py-2 text-right"><MeasureValue measure="findings" value={r.measures.findings} locale={locale} /></td>
                <td className="px-3 py-2">{t[`fix_${fixInOf(check)}` as keyof T]}</td>
                <td className="px-3 py-2"><Trend points={points} /></td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

/** An overview's title with the definition's hint (its status named) and, for those who may open it, How this is computed */
export function OverviewHeading({ def, t, more, statusSettings, locale }: {
  def: FlashOverviewDef; t: T; more?: { href: string; label: string };
  /** The statuses the overview's figures count and the tenant's meanings (addition 0008zt), for its hint */
  statusSettings?: FlashStatusSettings | null; locale?: "en" | "nl";
}) {
  const status = String(t[`status_${FLASH_DEFINITION_STATUS[def.key]}` as keyof T]);
  return (
    <div className="mb-4 flex flex-wrap items-center gap-3" data-hint-anchor="">
      <h2 className="text-panel font-semibold text-p4a-heading">
        <HintLabel label={String(t[`o_${def.key}` as keyof T])}>
          <HeaderHint label={String(t[`o_${def.key}` as keyof T])}
            text={cardStatusHint(def.key, `${String(t[`h_${def.key}` as keyof T])} ${t.statusHint.replace("{status}", status)}`, statusSettings, locale ?? "en", t)} more={more} />
        </HintLabel>
      </h2>
      <DefinitionBadge overview={def.key} t={t} />
    </div>
  );
}
