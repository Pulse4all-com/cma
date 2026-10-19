/**
 * Building blocks of Reports → Attempts per deal (addition 0008y, 19 October 2026): the grouping switch (G), the date
 * line with the history's start, the bars (deals by number of attempts, reach per attempt, won rate by attempts, open
 * deals by time since the last attempt), the figures per group and the list of deals. Server components, plain CSS,
 * no chart library; the figures come from the data layer and lib/attempts arranges them. Pulse4all-Style 7.7: horizontal
 * bars with their values, never a donut or a red stack; the attempt bars in Deep Blue, the time-since-last bars in one
 * neutral hue (Light Blue), never with text on them (7.8); every bar carries its label and value in a title. Tables per
 * 7.6, scrolling sideways inside their card. Ids, codes, counts, links and times only: no customer data.
 */
import Link from "next/link";
import type { Copy, Locale } from "@/lib/copy";
import type { AttemptBucket, AttemptGroup, AttemptGroupRow, AttemptListRow, AttemptOutcome, SinceLastBucket } from "@/lib/data";
import { ATTEMPT_GROUPS, ATTEMPTS_BAR_CLASS, fmtAttempts, nextAttemptGroup, reachShare, SINCE_LAST_CLASS, wonRate } from "@/lib/attempts";
import { barShare, fmtCount, fmtShare } from "@/lib/reports";
import { fmtDate, fmtDateTimeShort } from "@/lib/time";
import { HeaderHint } from "./HeaderHint";
import { HintLabel } from "./HintLabel";
import { RecordLink } from "./RecordLink";
import { Keycap } from "./primitives";

const th = "h-10 px-2 py-1 align-bottom font-semibold";
const td = "h-10 whitespace-nowrap px-2 tabular text-right";
const row = "border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50";

/** Day, week, market or pipeline as links; G moves to the next */
export function AttemptGroupSwitch({ group, query, copy }: { group: AttemptGroup; query: Record<string, string>; copy: Copy }) {
  const t = copy.attempts;
  const labels: Record<AttemptGroup, string> = { day: t.day, week: t.week, market: t.market, pipeline: t.pipeline };
  const next = nextAttemptGroup(group);
  return (
    <div className="flex flex-col gap-2 text-small font-semibold">
      <span className="flex items-center gap-2">
        {t.groupBy} <Keycap>G</Keycap>
      </span>
      <nav aria-label={t.groupBy} className="flex flex-wrap gap-2">
        {ATTEMPT_GROUPS.map((g) => (
          <Link
            key={g}
            href={{ pathname: "/reports/attempts", query: { ...query, group: g } }}
            aria-current={g === group ? "page" : undefined}
            data-shortcut={g === next ? "g" : undefined}
            className={[
              "inline-flex h-10 items-center rounded-button border px-4 text-body font-semibold",
              g === group ? "border-p4a-deepblue bg-p4a-deepblue text-white" : "border-p4a-border text-p4a-deepblue hover:bg-p4a-bgblue",
            ].join(" ")}
          >
            {labels[g]}
          </Link>
        ))}
      </nav>
    </div>
  );
}

/** The page's date line: the period and the active filters; under it the history's start in Muted */
export function AttemptDateLine({ from, to, market, pipelineLabel, counted, historyStart, copy, locale }: {
  from: string; to: string; market: string | null; pipelineLabel: string | null; counted: boolean; historyStart: string | null; copy: Copy; locale: Locale;
}) {
  const t = copy.attempts;
  const parts = [
    `${fmtDate(from, locale)}${from !== to ? ` – ${fmtDate(to, locale)}` : ""}`,
    ...(market ? [t.activeMarket.replace("{market}", market === "unknown" ? copy.reports.unknownMarket : market)] : []),
    ...(pipelineLabel ? [t.activePipeline.replace("{pipeline}", pipelineLabel)] : []),
    ...(counted ? [t.activeScope] : []),
  ];
  return (
    <div className="text-right">
      <p className="text-caption text-p4a-grey" data-testid="attempts-date-line">{parts.join(" · ")}</p>
      {historyStart ? <p className="mt-1 text-caption text-p4a-muted" data-testid="attempts-history">{t.historyFrom.replace("{date}", fmtDate(historyStart, locale))}</p> : null}
    </div>
  );
}

/** A card's intro with the info mark that names the figure's definition */
export function AttemptIntro({ text, label, hint, copy }: { text: string; label: string; hint: string; copy: Copy }) {
  return (
    <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted" data-hint-anchor="" data-attempt-intro="">
      <HintLabel label={text}><HeaderHint label={copy.hints.about.replace("{label}", label)} text={hint} /></HintLabel>
    </p>
  );
}

type Bar = { key: string; label: string; share: number; value: string; title: string };

/** Horizontal bars with their values beside them, in one colour */
function BarList({ bars, className, testId, label }: { bars: Bar[]; className: string; testId: string; label: string }) {
  return (
    <ul className="flex flex-col gap-2" data-testid={testId} aria-label={label}>
      {bars.map((b) => (
        <li key={b.key} className="grid grid-cols-[9rem_minmax(0,1fr)_7.5rem] items-center gap-3 text-small" title={b.title} data-bar-row={b.key}>
          <span className="truncate font-semibold text-p4a-body">{b.label}</span>
          <span className="block h-3 overflow-hidden rounded-full bg-p4a-neutral-surface">
            <span className={`block h-3 rounded-full ${className}`} style={{ width: `${(b.share * 100).toFixed(1)}%` }} />
          </span>
          <span className="tabular text-right text-p4a-muted">{b.value}</span>
        </li>
      ))}
    </ul>
  );
}

const bucketName = (b: AttemptBucket, copy: Copy) =>
  b.bucket === 0 ? copy.attempts.noAttempt : b.bucket === 1 && !b.label.endsWith("+") ? copy.attempts.oneAttempt : copy.attempts.attemptsLabel.replace("{n}", b.label);

/** Deals by number of attempts, 0 to the top bucket */
export function BucketBars({ buckets, copy, locale }: { buckets: AttemptBucket[]; copy: Copy; locale: Locale }) {
  const largest = Math.max(0, ...buckets.map((b) => b.deals));
  return (
    <BarList testId="attempts-buckets" label={copy.attempts.bucketsTitle} className={ATTEMPTS_BAR_CLASS}
      bars={buckets.map((b) => ({ key: String(b.bucket), label: bucketName(b, copy), share: barShare(b.deals, largest), value: fmtCount(b.deals, locale),
        title: `${bucketName(b, copy)}: ${fmtCount(b.deals, locale)}` }))} />
  );
}

/** Of the deals attempted, the share first reached on each attempt (1 to the top bucket) */
export function ReachBars({ buckets, attempted, copy, locale }: { buckets: AttemptBucket[]; attempted: number; copy: Copy; locale: Locale }) {
  const t = copy.attempts;
  const tries = buckets.filter((b) => b.bucket > 0);
  return (
    <BarList testId="attempts-reach" label={t.reachTitle} className={ATTEMPTS_BAR_CLASS}
      bars={tries.map((b) => {
        const share = reachShare(b, attempted);
        const name = t.attemptLabel.replace("{n}", b.label);
        const value = t.reachValue.replace("{pct}", fmtShare(share, locale)).replace("{n}", fmtCount(b.firstConnected, locale));
        return { key: String(b.bucket), label: name, share: share ?? 0, value, title: `${name}: ${value}` };
      })} />
  );
}

/** Of the closed deals with an outcome, the share won, per number of attempts */
export function WonBars({ buckets, copy, locale }: { buckets: AttemptBucket[]; copy: Copy; locale: Locale }) {
  const t = copy.attempts;
  return (
    <BarList testId="attempts-won" label={t.wonTitle} className={ATTEMPTS_BAR_CLASS}
      bars={buckets.map((b) => {
        const rate = wonRate(b);
        const value = rate === null ? t.noClosed
          : t.wonValue.replace("{pct}", fmtShare(rate, locale)).replace("{won}", fmtCount(b.won, locale)).replace("{closed}", fmtCount(b.won + b.lost, locale));
        return { key: String(b.bucket), label: bucketName(b, copy), share: rate ?? 0, value, title: `${bucketName(b, copy)}: ${value}` };
      })} />
  );
}

/** The open deals by business days since their last attempt, in one neutral hue; a market without business hours apart */
export function SinceLastBars({ buckets, noHours, copy, locale }: { buckets: SinceLastBucket[]; noHours: number; copy: Copy; locale: Locale }) {
  const t = copy.attempts;
  const largest = Math.max(0, ...buckets.map((b) => b.deals));
  return (
    <>
      <BarList testId="attempts-since-last" label={t.sinceTitle} className={SINCE_LAST_CLASS}
        bars={buckets.map((b) => {
          const name = t.sinceLabel.replace("{bucket}", b.label);
          return { key: b.label, label: name, share: barShare(b.deals, largest), value: fmtCount(b.deals, locale), title: `${name}: ${fmtCount(b.deals, locale)}` };
        })} />
      {noHours > 0 ? <p className="mt-3 text-small text-p4a-muted" data-testid="attempts-no-hours">{t.noHours.replace("{n}", fmtCount(noHours, locale))}</p> : null}
    </>
  );
}

/** The figures per group: a date, a Monday, a market or a pipeline */
export function AttemptGroupTable({ rows, group, hints, copy, locale }: {
  rows: AttemptGroupRow[]; group: AttemptGroup; hints: Record<string, string>; copy: Copy; locale: Locale;
}) {
  const t = copy.attempts;
  const n = (x: number) => fmtCount(x, locale);
  const hint = (label: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
  const first = { day: t.day, week: t.week, market: t.market, pipeline: t.pipeline }[group];
  const labelOf = (r: AttemptGroupRow) => group === "day" ? fmtDate(r.groupKey, locale, "compact")
    : group === "week" ? t.weekLabel.replace("{week}", fmtDate(r.groupKey, locale, "short"))
    : group === "market" ? (r.groupKey === "unknown" ? copy.reports.unknownMarket : r.groupKey) : r.label ?? r.groupKey;
  const cols: [string, string][] = [[t.deals, hints.atGroupDeals!], [t.attempted, hints.atGroupAttempted!], [t.attemptsCol, hints.atGroupAttempts!],
    [t.avgCol, hints.atGroupAvg!], [t.medianCol, hints.atGroupMedian!], [t.connectedCol, hints.atGroupFirst!], [t.openNeverCol, hints.atGroupOpenNever!],
    [t.wonCol, hints.atGroupWon!], [t.lostCol, hints.atGroupLost!]];
  return (
    <div className="overflow-x-auto" data-testid="attempts-groups-scroll" role="region" aria-label={t.byGroup} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid="attempts-groups">
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={th}><HintLabel label={first}>{hint(first, hints.atGroup!)}</HintLabel></th>
            {cols.map(([label, text]) => <th key={label} className={`${th} text-right`}><HintLabel label={label}>{hint(label, text)}</HintLabel></th>)}
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.groupKey} className={row}>
              <td className="h-10 max-w-[14rem] overflow-hidden text-ellipsis whitespace-nowrap px-2 font-semibold" title={labelOf(r)}>{labelOf(r)}</td>
              <td className={td}>{n(r.deals)}</td>
              <td className={td}>{n(r.attempted)}</td>
              <td className={td}>{n(r.attempts)}</td>
              <td className={td}>{fmtAttempts(r.avgAttempts, locale)}</td>
              <td className={td}>{fmtAttempts(r.medianAttempts, locale)}</td>
              <td className={td}>{n(r.firstReached)}</td>
              <td className={td}>{n(r.openNeverAttempted)}</td>
              <td className={td}>{n(r.won)}</td>
              <td className={td}>{n(r.lost)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

const OUTCOME_KEY: Record<AttemptOutcome, "outcome_open" | "outcome_won" | "outcome_lost" | "outcome_unknown"> = {
  open: "outcome_open", won: "outcome_won", lost: "outcome_lost", unknown: "outcome_unknown",
};

/** The deals of the period in the list's order: the deal, pipeline, market, created, outcome, attempts, the link */
export function AttemptListTable({ rows, hints, copy, locale, timeZone }: {
  rows: AttemptListRow[]; hints: Record<string, string>; copy: Copy; locale: Locale; timeZone: string;
}) {
  const t = copy.attempts;
  const n = (x: number) => fmtCount(x, locale);
  const hint = (label: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
  const cell = "h-10 whitespace-nowrap px-2";
  return (
    <div className="relative overflow-x-auto" data-testid="attempts-list-scroll" role="region" aria-label={t.listTitle} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid="attempts-list">
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={th}><HintLabel label={t.deal}>{hint(t.deal, hints.atDeal!)}</HintLabel></th>
            <th className={th}><HintLabel label={t.pipeline}>{hint(t.pipeline, hints.atPipeline!)}</HintLabel></th>
            <th className={th}><HintLabel label={t.market}>{hint(t.market, hints.atMarket!)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.created}>{hint(t.created, hints.atCreated!)}</HintLabel></th>
            <th className={th}><HintLabel label={t.outcome}>{hint(t.outcome, hints.atOutcome!)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.attemptsCol}>{hint(t.attemptsCol, hints.atAttempts!)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.connected}>{hint(t.connected, hints.atConnected!)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.firstConnected}>{hint(t.firstConnected, hints.atFirstConnected!)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.lastAttempt}>{hint(t.lastAttempt, hints.atLastAttempt!)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.daysSince}>{hint(t.daysSince, hints.atDaysSince!)}</HintLabel></th>
            <th className={th}><span className="sr-only">{t.open}</span>{hint(t.open, hints.atOpenLink!)}</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={`${r.connectionId}:${r.dealSourceId}`} className={row} data-testid="attempts-row" data-outcome={r.outcome}>
              <td className={`${cell} font-semibold tabular`}>{r.dealSourceId}</td>
              <td className={`${cell} max-w-[14rem] overflow-hidden text-ellipsis`} title={r.pipelineLabel ?? undefined}>{r.pipelineLabel ?? "–"}</td>
              <td className={cell}>{r.market === "unknown" ? copy.reports.unknownMarket : r.market}</td>
              <td className={td} title={fmtDateTimeShort(r.createdAt, timeZone, locale)}>{fmtDateTimeShort(r.createdAt, timeZone, locale)}</td>
              <td className={cell}>{t[OUTCOME_KEY[r.outcome]]}</td>
              <td className={td}>{n(r.attempts)}</td>
              <td className={td}>{n(r.connected)}</td>
              <td className={td}>{r.firstConnectedAttempt === null ? "–" : n(r.firstConnectedAttempt)}</td>
              <td className={td}>{r.lastAttemptAt ? fmtDateTimeShort(r.lastAttemptAt, timeZone, locale) : "–"}</td>
              <td className={td}>{r.isClosed ? "" : r.businessDaysSinceLast === null ? "–" : n(r.businessDaysSinceLast)}</td>
              <td className="h-10 px-2 text-right"><RecordLink url={r.recordUrl} label={`${t.open} ${r.dealSourceId}`} /></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
