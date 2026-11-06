/**
 * Building blocks of Customers → Courtesy (addition 0009a, brief B31): the completed calls by outcome, the state of an order,
 * the orders per market and per day, week or month, the order cohorts by age, the completed calls per person and the order
 * list. Server components, plain CSS; Pulse4all-Style 7.5 to 7.7: tables with numbers right-aligned in tabular figures and every
 * header with its hint; the outcomes in Leaf Green (positive), Light Blue (neutral) and Soft Rose with a Deep Blue edge
 * (negative), never with text on Light Blue or Soft Rose: the colour is a swatch or a bar segment and the words stand beside
 * it on white; Not reached is the warning badge, never red. Ids, codes, counts, dates and links only: never a customer's name,
 * email, phone or address.
 */
import type { ReactNode } from "react";
import type { Copy, Locale } from "@/lib/copy";
import type {
  CourtesyCalls, CourtesyCohort, CourtesyCounts, CourtesyGroup, CourtesyMarketCounts, CourtesyOutcome, CourtesyReport, CourtesyState,
} from "@/lib/data";
import { courtesyShare } from "@/lib/courtesy";
import { fmtMonth } from "@/lib/maintenance";
import { fmtCount, fmtShare } from "@/lib/reports";
import { fmtDate, fmtDateTimeShort } from "@/lib/time";
import { HeaderHint } from "./HeaderHint";
import { HintLabel } from "./HintLabel";
import { RecordLink } from "./RecordLink";
import { Badge } from "./primitives";

const th = "h-10 px-2 py-1 align-bottom font-semibold";
const td = "h-10 whitespace-nowrap px-2 tabular text-right";
const row = "border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50";

/** The outcomes' colours (Pulse4all-Style 2): Leaf Green, Light Blue, Soft Rose with a Deep Blue edge; never text on them */
export const OUTCOME_SWATCH: Record<CourtesyOutcome, string> = {
  positive: "bg-p4a-green",
  neutral: "bg-p4a-lightblue",
  negative: "bg-p4a-rose ring-1 ring-inset ring-p4a-deepblue",
};

function Scroll({ testId, label, children }: { testId: string; label: string; children: ReactNode }) {
  return (
    <div className="overflow-x-auto" data-testid={`${testId}-scroll`} role="region" aria-label={label} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid={testId}>{children}</table>
    </div>
  );
}

/** A column: its label, its hint, its value and, for a column on another basis, the classes that set it apart (0009c) */
type Col<T> = [string, string, (r: T) => ReactNode, string?];

function Head<T>({ first, firstHint, cols, copy }: { first: string; firstHint: string; cols: Col<T>[]; copy: Copy }) {
  const hint = (label: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
  return (
    <thead>
      <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
        <th className={th}><HintLabel label={first}>{hint(first, firstHint)}</HintLabel></th>
        {cols.map(([label, text, , apart]) => (
          <th key={label} className={`${th} text-right${apart ? ` ${apart}` : ""}`}><HintLabel label={label}>{hint(label, text)}</HintLabel></th>
        ))}
      </tr>
    </thead>
  );
}

/** The left edge of a column counted on another basis than the columns before it (Per market's calls by call date) */
const APART = "border-l border-p4a-border";

const marketName = (m: string, copy: Copy) => (m === "unknown" ? copy.reports.unknownMarket : m);

/** A swatch in an outcome's colour, beside its words (the colour is never the only signal) */
export function OutcomeSwatch({ outcome }: { outcome: CourtesyOutcome }) {
  return <span aria-hidden="true" className={`inline-block h-3 w-3 shrink-0 rounded-sm ${OUTCOME_SWATCH[outcome]}`} />;
}

/** The completed calls by outcome: one bar of three segments (no text on them) and the legend with the counts beside it */
export function CourtesyOutcomes({ calls, copy, locale }: { calls: CourtesyCalls; copy: Copy; locale: Locale }) {
  const t = copy.courtesy;
  const n = (x: number) => fmtCount(x, locale);
  const parts: [CourtesyOutcome, number][] = [["positive", calls.positive], ["neutral", calls.neutral], ["negative", calls.negative]];
  const label = (o: CourtesyOutcome) => t[`outcome_${o}`];
  return (
    <div data-testid="courtesy-outcomes">
      <div className="flex h-4 w-full overflow-hidden rounded-button bg-p4a-neutral-surface" role="img"
        aria-label={parts.map(([o, x]) => t.outcomeTitle.replace("{label}", label(o)).replace("{n}", n(x))).join(", ")}>
        {parts.map(([o, x]) => (x > 0 ? (
          <span key={o} className={`h-full ${OUTCOME_SWATCH[o]}`} style={{ width: `${(100 * x) / Math.max(1, calls.calls)}%` }}
            title={t.outcomeTitle.replace("{label}", label(o)).replace("{n}", n(x))} data-outcome={o} />
        ) : null))}
      </div>
      <ul className="mt-3 flex flex-wrap gap-x-6 gap-y-2 text-body">
        {parts.map(([o, x]) => (
          <li key={o} className="flex items-center gap-2" data-testid={`courtesy-outcome-${o}`}>
            <OutcomeSwatch outcome={o} />
            <span>{label(o)}</span>
            <span className="tabular font-semibold">{n(x)}</span>
            <span className="tabular text-p4a-muted">{fmtShare(courtesyShare(x, calls.calls), locale)}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}

/** An order's state: Not reached as the warning badge; Completed with its outcome's swatch; the others as quiet badges */
export function CourtesyStateLabel({ state, outcome, copy }: { state: CourtesyState | null; outcome: CourtesyOutcome | null; copy: Copy }) {
  const t = copy.courtesy;
  if (state === null) return <Badge tone="neutral">{t.state_no_contact}</Badge>;
  if (state === "not_reached") return <Badge tone="warning">{t.state_not_reached}</Badge>;
  if (state === "completed" && outcome) {
    return (
      <span className="inline-flex items-center gap-2 text-caption font-semibold">
        <OutcomeSwatch outcome={outcome} />
        {t.state_completed}, {t[`outcome_${outcome}`].toLowerCase()}
      </span>
    );
  }
  return <Badge tone={state === "attempted" ? "info" : "neutral"}>{t[`state_${state}`]}</Badge>;
}

/** The counts' columns every table of orders shares, by order date: orders, of which completed, completion share, not reached, no contact */
function countCols<T extends CourtesyCounts>(copy: Copy, hints: Record<string, string>, locale: Locale): Col<T>[] {
  const t = copy.courtesy;
  const n = (x: number) => fmtCount(x, locale);
  return [[t.colOrders, hints.ctColOrders!, (r) => n(r.orders)], [t.colCompleted, hints.ctColCompleted!, (r) => n(r.completed)],
    [t.colShare, hints.ctColShare!, (r) => fmtShare(courtesyShare(r.completed, r.orders), locale)],
    [t.colNotReached, hints.ctColNotReached!, (r) => (r.notReached > 0 ? <Badge tone="warning">{n(r.notReached)}</Badge> : n(r.notReached))],
    [t.colNoContact, hints.ctColNoContact!, (r) => n(r.noContact)]];
}

/**
 * Per market (unknown last): the period's courtesy orders by order date with their state now, then, set apart, the courtesy
 * calls completed in the period by call date, each in the market of the earliest courtesy order it completed (addition
 * 0009c); the total row under them, whose calls equal the tile
 */
export function CourtesyMarkets({ rows, total, hints, copy, locale }: {
  rows: CourtesyReport["byMarket"]; total: CourtesyMarketCounts | null; hints: Record<string, string>; copy: Copy; locale: Locale;
}) {
  const t = copy.courtesy;
  const n = (x: number) => fmtCount(x, locale);
  const cols: Col<CourtesyMarketCounts>[] = [...countCols<CourtesyMarketCounts>(copy, hints, locale),
    [t.colCallsInPeriod, hints.ctColCallsInPeriod!, (r) => n(r.calls), APART]];
  return (
    <Scroll testId="courtesy-markets" label={t.marketCard}>
      <Head first={t.colMarket} firstHint={hints.ctMarkets!} cols={cols} copy={copy} />
      <tbody>
        {rows.map((r) => (
          <tr key={r.market} className={row} data-market={r.market}>
            <td className="h-10 whitespace-nowrap px-2 font-semibold">{marketName(r.market, copy)}</td>
            {cols.map(([label, , value, apart]) => <td key={label} className={`${td}${apart ? ` ${apart}` : ""}`}>{value(r)}</td>)}
          </tr>
        ))}
      </tbody>
      {total ? (
        <tfoot>
          <tr className="text-p4a-body" data-testid="courtesy-markets-total">
            <td className="h-10 whitespace-nowrap px-2 font-semibold">{copy.reports.total}</td>
            {cols.map(([label, , value, apart]) => <td key={label} className={`${td} font-semibold${apart ? ` ${apart}` : ""}`}>{value(total)}</td>)}
          </tr>
        </tfoot>
      ) : null}
    </Scroll>
  );
}

/** A day, week or month in words */
function periodLabel(key: string, group: CourtesyGroup, copy: Copy, locale: Locale): string {
  if (group === "month") return fmtMonth(key, locale);
  if (group === "week") return copy.courtesy.week + " " + fmtDate(key, locale, "compact");
  return fmtDate(key, locale, "compact");
}

/** The period's courtesy orders by order date per day, ISO week or month (empty ones too), each with its markets on the lines below; no call column (0009c) */
export function CourtesyPeriods({ rows, group, hints, copy, locale }: {
  rows: CourtesyReport["byGroup"]; group: CourtesyGroup; hints: Record<string, string>; copy: Copy; locale: Locale;
}) {
  const t = copy.courtesy;
  const cols = countCols<CourtesyCounts>(copy, hints, locale);
  return (
    <Scroll testId="courtesy-periods" label={group === "day" ? t.periodCardDay : group === "week" ? t.periodCardWeek : t.periodCardMonth}>
      <Head first={t.colPeriod} firstHint={hints.ctColPeriod!} cols={cols} copy={copy} />
      <tbody>
        {rows.flatMap((r) => [
          <tr key={r.key} className={row}>
            <td className="h-10 whitespace-nowrap px-2 font-semibold">{periodLabel(r.key, group, copy, locale)}</td>
            {cols.map(([label, , value]) => <td key={label} className={td}>{value(r)}</td>)}
          </tr>,
          ...(r.markets.length > 1 ? r.markets.map((m) => (
            <tr key={`${r.key}:${m.market}`} className={`${row} text-small text-p4a-muted`}>
              <td className="h-8 whitespace-nowrap py-1 pl-6 pr-2">{marketName(m.market, copy)}</td>
              {cols.map(([label, , value]) => <td key={label} className={`${td} h-8`}>{value(m)}</td>)}
            </tr>
          )) : []),
        ])}
      </tbody>
    </Scroll>
  );
}

/** The order cohorts, newest first: per age the share completed by then, its count in the cell's title; a dash before maturity */
export function CourtesyCohorts({ cohorts, ages, hints, copy, locale }: {
  cohorts: CourtesyCohort[]; ages: number[]; hints: Record<string, string>; copy: Copy; locale: Locale;
}) {
  const t = copy.courtesy;
  const n = (x: number) => fmtCount(x, locale);
  const hint = (label: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
  return (
    <Scroll testId="courtesy-cohorts" label={t.cohortCard}>
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          <th className={th}><HintLabel label={t.colCohort}>{hint(t.colCohort, hints.ctColCohort!)}</HintLabel></th>
          <th className={`${th} text-right`}><HintLabel label={t.colOrders}>{hint(t.colOrders, hints.ctColOrders!)}</HintLabel></th>
          {ages.map((a) => {
            const label = t.colAge.replace("{n}", String(a));
            return <th key={a} className={`${th} text-right`}><HintLabel label={label}>{hint(label, hints.ctColAge!)}</HintLabel></th>;
          })}
        </tr>
      </thead>
      <tbody>
        {cohorts.map((c) => (
          <tr key={c.key} className={row}>
            <td className="h-10 whitespace-nowrap px-2 font-semibold" title={`${fmtDate(c.start, locale, "compact")} – ${fmtDate(c.end, locale, "compact")}`}>
              {c.label}{c.partial ? <span className="ml-2 text-small font-normal text-p4a-muted">{copy.leadCohorts.partial}</span> : null}
            </td>
            <td className={td}>{n(c.orders)}</td>
            {c.ages.map((a) => (
              <td key={a.age} className={td}
                title={a.completed === null ? t.immature.replace("{n}", String(a.age))
                  : t.cellTitle.replace("{completed}", n(a.completed)).replace("{orders}", n(c.orders)).replace("{n}", String(a.age))}>
                {a.completed === null ? "–" : fmtShare(courtesyShare(a.completed, c.orders), locale)}
              </td>
            ))}
          </tr>
        ))}
      </tbody>
    </Scroll>
  );
}

/** The completed calls of the period per person, by name, never ranked; the calls without a person last */
export function CourtesyPeople({ rows, hints, copy, locale }: {
  rows: NonNullable<CourtesyReport["perPerson"]>; hints: Record<string, string>; copy: Copy; locale: Locale;
}) {
  const t = copy.courtesy;
  const n = (x: number) => fmtCount(x, locale);
  const cols: Col<CourtesyCalls>[] = [[t.colCalls, hints.ctColCalls!, (r) => n(r.calls)], [t.colPositive, hints.ctColOutcome!, (r) => n(r.positive)],
    [t.colNeutral, hints.ctColOutcome!, (r) => n(r.neutral)], [t.colNegative, hints.ctColOutcome!, (r) => n(r.negative)]];
  return (
    <Scroll testId="courtesy-people" label={t.personCard}>
      <Head first={t.colPerson} firstHint={hints.ctColPerson!} cols={cols} copy={copy} />
      <tbody>
        {rows.map((r) => (
          <tr key={r.userId ?? "none"} className={row}>
            <td className={`h-10 whitespace-nowrap px-2 ${r.userId === null ? "text-p4a-muted" : "font-semibold"}`}>{r.userId === null ? t.notLinked : r.name ?? t.notLinked}</td>
            {cols.map(([label, , value]) => <td key={label} className={td}>{value(r)}</td>)}
          </tr>
        ))}
      </tbody>
    </Scroll>
  );
}

/** The order list: ids, dates, counts, the state and the contact's link; never a name, email, phone or address */
export function CourtesyList({ list, hints, copy, locale, timeZone }: {
  list: CourtesyReport["list"]; hints: Record<string, string>; copy: Copy; locale: Locale; timeZone: string;
}) {
  const t = copy.courtesy;
  const n = (x: number) => fmtCount(x, locale);
  const hint = (label: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
  const heads: [string, string, boolean][] = [
    [t.colStore, hints.ctColStore!, false], [t.colOrder, hints.ctColOrder!, false], [t.colMarket, hints.ctColMarket!, false],
    [t.colCreated, hints.ctColCreated!, false], [t.colDue, hints.ctColDue!, false], [t.colDaysPastDue, hints.ctColDaysPastDue!, true],
    [t.colAttempts, hints.ctColAttempts!, true], [t.colLastAttempt, hints.ctColLastAttempt!, false], [t.colState, hints.ctColState!, false],
    [t.colContact, hints.ctColContact!, false],
  ];
  return (
    <>
      <Scroll testId="courtesy-list" label={t.listCard}>
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            {heads.map(([label, text, right]) => (
              <th key={label} className={`${th}${right ? " text-right" : ""}`}><HintLabel label={label}>{hint(label, text)}</HintLabel></th>
            ))}
          </tr>
        </thead>
        <tbody>
          {list.rows.map((r) => (
            <tr key={r.orderId} className={row} data-state={r.state ?? "no_contact"}>
              <td className="h-10 whitespace-nowrap px-2">{r.storeName ?? r.store}</td>
              <td className="h-10 whitespace-nowrap px-2 tabular">{r.orderName}</td>
              <td className="h-10 whitespace-nowrap px-2">{marketName(r.market, copy)}</td>
              <td className="h-10 whitespace-nowrap px-2 tabular">{fmtDate(r.businessDate, locale, "compact")}</td>
              <td className="h-10 whitespace-nowrap px-2 tabular">{fmtDate(r.dueDate, locale, "compact")}</td>
              <td className={td}>{r.daysPastDue === null ? "–" : n(r.daysPastDue)}</td>
              <td className={td}>{r.attempts === null ? "–" : n(r.attempts)}</td>
              <td className="h-10 whitespace-nowrap px-2 tabular">{r.lastAttemptAt ? fmtDateTimeShort(r.lastAttemptAt, timeZone, locale) : "–"}</td>
              <td className="h-10 whitespace-nowrap px-2"><CourtesyStateLabel state={r.state} outcome={r.outcome} copy={copy} /></td>
              <td className="h-10 px-2"><RecordLink url={r.recordUrl} label={r.recordUrl ? t.openContact : t.noLink} /></td>
            </tr>
          ))}
        </tbody>
      </Scroll>
      <p className="mt-2 text-small text-p4a-muted" data-testid="courtesy-showing">
        {t.showing.replace("{n}", n(list.rows.length)).replace("{total}", n(list.total))}
      </p>
    </>
  );
}
