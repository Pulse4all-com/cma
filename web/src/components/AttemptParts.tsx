/**
 * Building blocks of Reports → Attempts per deal (addition 0008y; for sales since 0008z, 20 October 2026): the grouping switch
 * (G), the date line with the history's start, won against lost, the bars (the win rate by attempts and by speed to lead,
 * deals by number of attempts, reached per attempt, open deals by time since the last attempt), how complete the calls are,
 * and the figures per group. Server components, plain CSS, no chart library; the figures come from the data layer and
 * lib/attempts arranges them. Pulse4all-Style 7.7: horizontal bars with their values, never a donut or a red stack; the
 * attempt bars in Deep Blue, the time-since-last bars in one neutral hue (Light Blue), never with text on them (7.8);
 * every bar carries its label and value in a title. Tables per 7.6, scrolling sideways inside their card. Ids, codes,
 * counts, links and times only: no customer data. The deals list with each deal's attempts is AttemptDealList.
 */
import Link from "next/link";
import type { Copy, Locale } from "@/lib/copy";
import type {
  AttemptBucket, AttemptFigures, AttemptGroup, AttemptGroupRow, AttemptOutcomeFilter, AttemptOutcomeRow, AttemptsReport, AttemptSpeedBucket,
  SinceLastBucket,
} from "@/lib/data";
import {
  ATTEMPT_GROUPS, ATTEMPTS_BAR_CLASS, fmtAttempts, nextAttemptGroup, noonShare, reachedShare, reachShare, SINCE_LAST_CLASS, speedMinutes, withoutOutcomeShare,
  wonRate,
} from "@/lib/attempts";
import { barShare, fmtBusinessMinutes, fmtCount, fmtShare, fmtTalk } from "@/lib/reports";
import { fmtDate } from "@/lib/time";
import { HeaderHint } from "./HeaderHint";
import { HintLabel } from "./HintLabel";
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
export function AttemptDateLine({ from, to, market, pipelineLabel, attempted, outcome, historyStart, copy, locale }: {
  from: string; to: string; market: string | null; pipelineLabel: string | null; attempted: "all" | "none" | "some"; outcome: AttemptOutcomeFilter;
  historyStart: string | null; copy: Copy; locale: Locale;
}) {
  const t = copy.attempts;
  const parts = [
    `${fmtDate(from, locale)}${from !== to ? ` – ${fmtDate(to, locale)}` : ""}`,
    ...(market ? [t.activeMarket.replace("{market}", market === "unknown" ? copy.reports.unknownMarket : market)] : []),
    ...(pipelineLabel ? [t.activePipeline.replace("{pipeline}", pipelineLabel)] : []),
    ...(attempted !== "all" ? [t[`attempted_${attempted}`]] : []),
    ...(outcome !== "all" ? [t.activeOutcome.replace("{outcome}", t[`outcome_${outcome}`])] : []),
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
        const value = t.reachValue.replace("{pct}", fmtShare(share, locale)).replace("{n}", fmtCount(b.firstReached, locale));
        return { key: String(b.bucket), label: name, share: share ?? 0, value, title: `${name}: ${value}` };
      })} />
  );
}

const wonValue = (b: { won: number; lost: number }, copy: Copy, locale: Locale) => {
  const rate = wonRate(b);
  return rate === null ? copy.attempts.noClosed
    : copy.attempts.wonValue.replace("{pct}", fmtShare(rate, locale)).replace("{won}", fmtCount(b.won, locale)).replace("{closed}", fmtCount(b.won + b.lost, locale));
};

/** Of the deals won or lost, the share won, per number of attempts */
export function WonBars({ buckets, copy, locale }: { buckets: AttemptBucket[]; copy: Copy; locale: Locale }) {
  return (
    <BarList testId="attempts-won" label={copy.attempts.wonTitle} className={ATTEMPTS_BAR_CLASS}
      bars={buckets.map((b) => {
        const value = wonValue(b, copy, locale);
        return { key: String(b.bucket), label: bucketName(b, copy), share: wonRate(b) ?? 0, value, title: `${bucketName(b, copy)}: ${value}` };
      })} />
  );
}

/** Of the deals won or lost, the share won, per bucket of business minutes to the first attempt; never attempted last, no business hours apart */
export function SpeedWonBars({ speed, copy, locale }: { speed: AttemptsReport["speedBuckets"]; copy: Copy; locale: Locale }) {
  const t = copy.attempts;
  const bars: Bar[] = speed.buckets.map((b: AttemptSpeedBucket) => {
    const name = t.speedLabel.replace("{bucket}", b.label);
    const value = wonValue(b, copy, locale);
    return { key: b.label, label: name, share: wonRate(b) ?? 0, value, title: `${name}: ${value}` };
  });
  const never = wonValue(speed.none, copy, locale);
  bars.push({ key: "never", label: t.speedNever, share: wonRate(speed.none) ?? 0, value: never, title: `${t.speedNever}: ${never}` });
  return (
    <>
      <BarList testId="attempts-speed-won" label={t.speedTitle} className={ATTEMPTS_BAR_CLASS} bars={bars} />
      {speed.noHours > 0 ? <p className="mt-3 text-small text-p4a-muted" data-testid="attempts-speed-no-hours">{t.speedNoHours.replace("{n}", fmtCount(speed.noHours, locale))}</p> : null}
    </>
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

/** Speed to lead in business minutes as Speed to lead writes it ("12 min", "2:05"); a dash without */
export function fmtSpeed(seconds: number | null, locale: Locale): string {
  return fmtBusinessMinutes(speedMinutes(seconds), locale);
}

/**
 * Won against lost (Kira's comparison): one row each with the deals, the average and median attempts, the median speed to
 * lead, called before the next noon, reached at least once and the average talk time in contact; the deals not decided
 * beside the table
 */
export function OutcomesTable({ outcomes, hints, copy, locale }: {
  outcomes: AttemptsReport["outcomes"]; hints: Record<string, string>; copy: Copy; locale: Locale;
}) {
  const t = copy.attempts;
  const n = (x: number) => fmtCount(x, locale);
  const hint = (label: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
  const share = (part: number, whole: number) => fmtShare(whole === 0 ? null : part / whole, locale);
  const cols: [string, string, (r: AttemptOutcomeRow) => string][] = [
    [t.colDeals, hints.atOcDeals!, (r) => n(r.deals)],
    [t.colAvgAttempts, hints.atOcAvg!, (r) => fmtAttempts(r.avgAttempts, locale)],
    [t.colMedianAttempts, hints.atOcMedian!, (r) => fmtAttempts(r.medianAttempts, locale)],
    [t.colMedianSpeed, hints.atOcSpeed!, (r) => fmtSpeed(r.medianSpeedSeconds, locale)],
    [t.colNoon, hints.atOcNoon!, (r) => share(r.calledBeforeNoon, r.noonKnown)],
    [t.colReached, hints.atOcReached!, (r) => share(r.reachedDeals, r.deals)],
    [t.colTalk, hints.atOcTalk!, (r) => fmtTalk(r.avgTalkReachedSeconds, locale)],
  ];
  const decided = outcomes.rows.some((r) => r.deals > 0);
  return (
    <div className="flex flex-col gap-4">
      {decided ? (
        <div className="overflow-x-auto" data-testid="attempts-outcomes-scroll" role="region" aria-label={t.outcomesTitle} tabIndex={0}>
          <table className="w-full border-collapse text-body leading-table" data-testid="attempts-outcomes">
            <thead>
              <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
                <th className={th}><HintLabel label={t.colOutcome}>{hint(t.colOutcome, hints.atOcOutcome!)}</HintLabel></th>
                {cols.map(([label, text]) => <th key={label} className={`${th} text-right`}><HintLabel label={label}>{hint(label, text)}</HintLabel></th>)}
              </tr>
            </thead>
            <tbody>
              {outcomes.rows.map((r) => (
                <tr key={r.outcome} className={row} data-testid="attempts-outcome-row" data-outcome={r.outcome}>
                  <td className="h-10 whitespace-nowrap px-2 font-semibold">{t[`outcome_${r.outcome}`]}</td>
                  {cols.map(([label, , value]) => <td key={label} className={td}>{value(r)}</td>)}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : <p className="text-body text-p4a-muted">{t.noDecided}</p>}
      <p className="text-small text-p4a-muted" data-testid="attempts-not-decided">
        <span className="font-semibold text-p4a-body">{t.notDecided.replace("{n}", n(outcomes.notDecided))}</span>
        {" · "}
        {t.notDecidedDetail.replace("{open}", n(outcomes.open)).replace("{ordered}", n(outcomes.ordered)).replace("{unknown}", n(outcomes.unknown))}
      </p>
    </div>
  );
}

/** How complete the calls are: the attempts without an outcome (a share) and the calls logged without a telephony call, each with its hint */
export function QualityFigures({ figures, hints, copy, locale }: { figures: AttemptFigures; hints: Record<string, string>; copy: Copy; locale: Locale }) {
  const t = copy.attempts;
  const about = (label: string) => copy.hints.about.replace("{label}", label);
  const items: { key: string; label: string; value: string; hint: string }[] = [
    { key: "without-outcome", label: t.withoutOutcome, hint: hints.atWithoutOutcome!,
      value: t.withoutOutcomeValue.replace("{pct}", fmtShare(withoutOutcomeShare(figures), locale)).replace("{n}", fmtCount(figures.attemptsWithoutOutcome, locale))
        .replace("{attempts}", fmtCount(figures.attempts, locale)) },
    { key: "logged-without", label: t.loggedWithout, hint: hints.atLoggedWithout!,
      value: t.loggedWithoutValue.replace("{n}", fmtCount(figures.loggedWithoutAircall, locale)) },
  ];
  return (
    <dl className="flex flex-col gap-3" data-testid="attempts-quality">
      {items.map((i) => (
        <div key={i.key} className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 border-b border-p4a-border pb-3 last:border-b-0" data-testid={`attempts-quality-${i.key}`}>
          <dt className="flex items-start text-small font-semibold text-p4a-body" data-hint-anchor="">
            {i.label}
            <HeaderHint label={about(i.label)} text={i.hint} />
          </dt>
          <dd className="tabular text-body text-p4a-heading">{i.value}</dd>
        </div>
      ))}
    </dl>
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
  const cols: [string, string, (r: AttemptGroupRow) => string][] = [
    [t.deals, hints.atGroupDeals!, (r) => n(r.deals)], [t.attempted, hints.atGroupAttempted!, (r) => n(r.attempted)],
    [t.attemptsCol, hints.atGroupAttempts!, (r) => n(r.attempts)], [t.avgCol, hints.atGroupAvg!, (r) => fmtAttempts(r.avgAttempts, locale)],
    [t.medianCol, hints.atGroupMedian!, (r) => fmtAttempts(r.medianAttempts, locale)], [t.reachedCol, hints.atGroupReached!, (r) => n(r.reachedDeals)],
    [t.firstReachCol, hints.atGroupFirst!, (r) => n(r.firstReached)], [t.openNeverCol, hints.atGroupOpenNever!, (r) => n(r.openNeverAttempted)],
    [t.wonCol, hints.atGroupWon!, (r) => n(r.won)], [t.lostCol, hints.atGroupLost!, (r) => n(r.lost)], [t.orderedCol, hints.atGroupOrdered!, (r) => n(r.ordered)],
  ];
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
              {cols.map(([label, , value]) => <td key={label} className={td}>{value(r)}</td>)}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** The reached share of a set of deals, for the tile and per agent */
export function fmtReachedShare(f: Pick<AttemptFigures, "reachedDeals" | "deals">, locale: Locale): string {
  return fmtShare(reachedShare(f), locale);
}

/** Called before the next business noon, of the deals whose answer is known */
export function fmtNoonShare(f: Pick<AttemptFigures, "calledBeforeNoon" | "noonKnown">, locale: Locale): string {
  return fmtShare(noonShare(f), locale);
}
