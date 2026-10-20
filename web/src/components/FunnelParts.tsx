/**
 * Building blocks of Reports → Funnel (addition 0008zb, 20 October 2026; backlog CMA-043, CMA-048): the grouping switch
 * (G: week or day, for the lost deals per period), the date line with the histories' start, the stages per pipeline, the
 * figures per pipeline, the lost reasons (the real reasons, the data-quality reasons apart, no reason as its own row),
 * per market and per source with their top reasons, per day or week, the lost deals without a reason, and deals per
 * person. Server components, plain CSS, no chart library; the figures come from the data layer and lib/funnel arranges
 * them. Pulse4all-Style 7.5 to 7.7: horizontal bars with their values, never a donut or a red stack; the stages and the
 * real reasons in Deep Blue, the data-quality and no-reason bars in one neutral hue (Light Blue), never with text on them
 * (7.8); every bar carries its label and value in a title. Tables per 7.6, scrolling sideways inside their card, every
 * header with its hint. Ids, codes, counts, links and times only: no customer data; a deal row links to the customer
 * records by its id.
 */
import Link from "next/link";
import type { ReactNode } from "react";
import type { Copy, Locale } from "@/lib/copy";
import type { DealPerson, FunnelGroup, FunnelPipelineRow, FunnelStageRow, LostGroupRow, LostListRow, LostPeriodRow, LostReasonRow } from "@/lib/data";
import { fmtAmount, fmtDays, FUNNEL_BAR_CLASS, FUNNEL_GROUPS, FUNNEL_NEUTRAL_CLASS, nextFunnelGroup, periodReasonColumns } from "@/lib/funnel";
import { barShare, fmtCount, fmtShare } from "@/lib/reports";
import { fmtDate, fmtDateTimeShort } from "@/lib/time";
import { HeaderHint } from "./HeaderHint";
import { HintLabel } from "./HintLabel";
import { RecordLink } from "./RecordLink";
import { Keycap } from "./primitives";

const th = "h-10 px-2 py-1 align-bottom font-semibold";
const td = "h-10 whitespace-nowrap px-2 tabular text-right";
const row = "border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50";

type Hint = (label: string, text: string) => ReactNode;
const hintOf = (copy: Copy): Hint => (label, text) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;

/** Week or day as links; G moves to the next */
export function FunnelGroupSwitch({ pathname, group, query, copy }: {
  pathname: "/reports/funnel" | "/reports/cancellations"; group: FunnelGroup; query: Record<string, string>; copy: Copy;
}) {
  const t = copy.funnel;
  const labels: Record<FunnelGroup, string> = { week: t.week, day: t.day };
  const next = nextFunnelGroup(group);
  return (
    <div className="flex flex-col gap-2 text-small font-semibold">
      <span className="flex items-center gap-2">
        {t.groupBy} <Keycap>G</Keycap>
      </span>
      <nav aria-label={t.groupBy} className="flex flex-wrap gap-2">
        {FUNNEL_GROUPS.map((g) => (
          <Link
            key={g}
            href={{ pathname, query: { ...query, group: g } }}
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

/** The page's date line: the period and the active filters; under it where the histories start, in Muted */
export function FunnelDateLine({ from, to, parts, history, copy, locale, testId }: {
  from: string; to: string; parts: string[]; history: string[]; copy: Copy; locale: Locale; testId: string;
}) {
  void copy;
  const line = [`${fmtDate(from, locale)}${from !== to ? ` – ${fmtDate(to, locale)}` : ""}`, ...parts];
  return (
    <div className="text-right">
      <p className="text-caption text-p4a-grey" data-testid={`${testId}-date-line`}>{line.join(" · ")}</p>
      {history.length > 0 ? <p className="mt-1 text-caption text-p4a-muted" data-testid={`${testId}-history`}>{history.join(" · ")}</p> : null}
    </div>
  );
}

/** A card's intro with the info mark that names the figure's definition */
export function FunnelIntro({ text, label, hint, copy }: { text: string; label: string; hint: string; copy: Copy }) {
  return (
    <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted" data-hint-anchor="" data-funnel-intro="">
      <HintLabel label={text}><HeaderHint label={copy.hints.about.replace("{label}", label)} text={hint} /></HintLabel>
    </p>
  );
}

export type Bar = { key: string; label: string; share: number; value: string; title: string };

/** Horizontal bars with their values beside them, in one colour */
export function BarList({ bars, className, testId, label }: { bars: Bar[]; className: string; testId: string; label: string }) {
  return (
    <ul className="flex flex-col gap-2" data-testid={testId} aria-label={label}>
      {bars.map((b) => (
        <li key={b.key} className="grid grid-cols-[minmax(6rem,12rem)_minmax(0,1fr)_7.5rem] items-center gap-3 text-small" title={b.title} data-bar-row={b.key}>
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

/** A table that scrolls sideways inside its card, as a named region */
function Scroll({ testId, label, children }: { testId: string; label: string; children: ReactNode }) {
  return (
    <div className="overflow-x-auto" data-testid={`${testId}-scroll`} role="region" aria-label={label} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid={testId}>{children}</table>
    </div>
  );
}

/**
 * One pipeline's stages: the deals that entered each stage in the period as bars, then the table with still there, moved
 * on, the median and 80th percentile of days in the stage, reached won and entered in the previous period. A stage whose
 * times are not read says so instead of figures
 */
export function StageCard({ stages, hints, copy, locale }: { stages: FunnelStageRow[]; hints: Record<string, string>; copy: Copy; locale: Locale }) {
  const t = copy.funnel;
  const n = (x: number | null) => (x === null ? "–" : fmtCount(x, locale));
  const hint = hintOf(copy);
  const timed = stages.filter((s) => s.readsTimes);
  const largest = Math.max(0, ...timed.map((s) => s.entered ?? 0));
  const cols: [string, string, (s: FunnelStageRow) => string][] = [
    [t.colEntered, hints.fnColEntered!, (s) => n(s.entered)],
    [t.colStillThere, hints.fnColStillThere!, (s) => n(s.stillThere)],
    [t.colMovedOn, hints.fnColMovedOn!, (s) => n(s.movedOn)],
    [t.colMedianDays, hints.fnColMedianDays!, (s) => fmtDays(s.medianDays, locale, t)],
    [t.colP80Days, hints.fnColP80Days!, (s) => fmtDays(s.p80Days, locale, t)],
    [t.colReachedWon, hints.fnColReachedWon!, (s) => (s.reachedWon === null || s.wonShare === null ? "–" : t.reachedValue.replace("{pct}", fmtShare(s.wonShare, locale)).replace("{n}", n(s.reachedWon)))],
    [t.colPrevious, hints.fnColPrevious!, (s) => n(s.enteredPrevious)],
  ];
  return (
    <div className="flex flex-col gap-4" data-testid="funnel-stage-card" data-pipeline={stages[0]?.pipeline}>
      {timed.length > 0 ? (
        <BarList testId="funnel-entered" label={t.enteredBars} className={FUNNEL_BAR_CLASS}
          bars={timed.map((s) => ({ key: s.stageId, label: s.label, share: barShare(s.entered, largest), value: n(s.entered), title: `${s.label}: ${n(s.entered)}` }))} />
      ) : null}
      <Scroll testId="funnel-stages" label={t.stagesCard}>
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={th}><HintLabel label={t.colStage}>{hint(t.colStage, hints.fnColStage!)}</HintLabel></th>
            {cols.map(([label, text]) => <th key={label} className={`${th} text-right`}><HintLabel label={label}>{hint(label, text)}</HintLabel></th>)}
          </tr>
        </thead>
        <tbody>
          {stages.map((s) => (
            <tr key={s.stageId} className={`${row} ${s.readsTimes ? "" : "text-p4a-muted"}`} data-testid="funnel-stage-row" data-stage={s.stageId} data-reads={s.readsTimes ? "1" : "0"}>
              <td className="h-10 max-w-[16rem] overflow-hidden text-ellipsis whitespace-nowrap px-2 font-semibold" title={s.label}>{s.label}</td>
              {s.readsTimes ? cols.map(([label, , value]) => <td key={label} className={td}>{value(s)}</td>)
                : <td colSpan={cols.length} className="h-10 whitespace-nowrap px-2 text-small">{t.timesOff}</td>}
            </tr>
          ))}
        </tbody>
      </Scroll>
    </div>
  );
}

/** The figures per pipeline and in total: created, won, lost, the win rate and the median days to won and to lost; each pipeline links to its Attempts per deal */
export function PipelineTable({ rows, total, hints, copy, locale, attemptsHref }: {
  rows: FunnelPipelineRow[]; total: { current: FunnelPipelineRow["current"] }; hints: Record<string, string>; copy: Copy; locale: Locale;
  attemptsHref: (pipeline: string | null) => { pathname: "/reports/attempts"; query: Record<string, string> };
}) {
  const t = copy.funnel;
  const n = (x: number) => fmtCount(x, locale);
  const hint = hintOf(copy);
  const cols: [string, string, (r: FunnelPipelineRow["current"]) => string][] = [
    [t.colCreated, hints.fnColCreated!, (r) => n(r.created)], [t.colWon, hints.fnColWon!, (r) => n(r.won)], [t.colLost, hints.fnColLost!, (r) => n(r.lost)],
    [t.colWinRate, hints.fnColWinRate!, (r) => fmtShare(r.winRate, locale)], [t.colDaysWon, hints.fnColDaysWon!, (r) => fmtDays(r.medianDaysToWon, locale, t)],
    [t.colDaysLost, hints.fnColDaysLost!, (r) => fmtDays(r.medianDaysToLost, locale, t)],
  ];
  return (
    <Scroll testId="funnel-pipelines" label={t.pipelinesCard}>
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          <th className={th}><HintLabel label={t.colPipeline}>{hint(t.colPipeline, hints.fnColPipeline!)}</HintLabel></th>
          {cols.map(([label, text]) => <th key={label} className={`${th} text-right`}><HintLabel label={label}>{hint(label, text)}</HintLabel></th>)}
          <th className={`${th} text-right`}><HintLabel label={t.colAttempts}>{hint(t.colAttempts, hints.fnColAttempts!)}</HintLabel></th>
        </tr>
      </thead>
      <tbody>
        {rows.map((r) => (
          <tr key={r.key} className={row} data-testid="funnel-pipeline-row">
            <td className="h-10 max-w-[16rem] overflow-hidden text-ellipsis whitespace-nowrap px-2 font-semibold" title={r.label}>{r.label}</td>
            {cols.map(([label, , value]) => <td key={label} className={td}>{value(r.current)}</td>)}
            <td className={td}><Link href={attemptsHref(r.key)} className="font-semibold text-p4a-deepblue underline-offset-2 hover:underline">{t.attemptsLinkShort}</Link></td>
          </tr>
        ))}
        {rows.length > 1 ? (
          <tr className={`${row} font-semibold`} data-testid="funnel-pipeline-total">
            <td className="h-10 whitespace-nowrap px-2">{t.total}</td>
            {cols.map(([label, , value]) => <td key={label} className={td}>{value(total.current)}</td>)}
            <td className={td}><Link href={attemptsHref(null)} className="font-semibold text-p4a-deepblue underline-offset-2 hover:underline">{t.attemptsLinkShort}</Link></td>
          </tr>
        ) : null}
      </tbody>
    </Scroll>
  );
}

/** The real reasons, each with its share of the lost deals that have a real reason; no reason as its own row in the neutral hue, its share of every lost deal */
export function ReasonBars({ reasons, noReason, copy, locale }: {
  reasons: LostReasonRow[]; noReason: { deals: number; share: number | null }; copy: Copy; locale: Locale;
}) {
  const t = copy.funnel;
  const value = (share: number | null, deals: number) => t.reasonValue.replace("{pct}", fmtShare(share, locale)).replace("{n}", fmtCount(deals, locale));
  return (
    <div className="flex flex-col gap-4">
      {reasons.length === 0 ? <p className="text-body text-p4a-muted">{t.noRealReason}</p> : (
        <BarList testId="funnel-reasons" label={t.reasonsCard} className={FUNNEL_BAR_CLASS}
          bars={reasons.map((r) => ({ key: r.value, label: r.label, share: r.share ?? 0, value: value(r.share, r.deals), title: `${r.label}: ${value(r.share, r.deals)}` }))} />
      )}
      <div className="border-t border-p4a-border pt-4">
        <BarList testId="funnel-no-reason" label={t.noReasonRow} className={FUNNEL_NEUTRAL_CLASS}
          bars={[{ key: "none", label: t.noReasonRow, share: noReason.share ?? 0, value: value(noReason.share, noReason.deals),
            title: `${t.noReasonRow}: ${t.noReasonOfLost.replace("{value}", value(noReason.share, noReason.deals))}` }]} />
      </div>
    </div>
  );
}

/** The data-quality reasons, each with its share of every lost deal, in the neutral hue */
export function DataQualityBars({ reasons, copy, locale }: { reasons: LostReasonRow[]; copy: Copy; locale: Locale }) {
  const t = copy.funnel;
  if (reasons.length === 0) return <p className="text-body text-p4a-muted">{t.noDq}</p>;
  const value = (r: LostReasonRow) => t.reasonValue.replace("{pct}", fmtShare(r.share, locale)).replace("{n}", fmtCount(r.deals, locale));
  return (
    <BarList testId="funnel-dq" label={t.dqCard} className={FUNNEL_NEUTRAL_CLASS}
      bars={reasons.map((r) => ({ key: r.value, label: r.label, share: r.share ?? 0, value: value(r), title: `${r.label}: ${value(r)}` }))} />
  );
}

/** The lost deals per market or per source channel, with the top 3 real reasons */
export function LostGroupTable({ rows, by, hints, copy, locale }: {
  rows: LostGroupRow[]; by: "market" | "source"; hints: Record<string, string>; copy: Copy; locale: Locale;
}) {
  const t = copy.funnel;
  const n = (x: number) => fmtCount(x, locale);
  const hint = hintOf(copy);
  const first = by === "market" ? t.colMarket : t.colSource;
  const labelOf = (k: string | null) => (by === "market" ? (k === "unknown" ? copy.reports.unknownMarket : k ?? "") : k ?? t.noSource);
  const cols: [string, string, (r: LostGroupRow) => string][] = [
    [t.colLost, hints.fnColGroupLost!, (r) => n(r.lost)], [t.colReal, hints.fnColReal!, (r) => n(r.real)],
    [t.colNoReason, hints.fnColNoReason!, (r) => n(r.noReason)], [t.colDq, hints.fnColDq!, (r) => n(r.dataQuality)],
  ];
  return (
    <Scroll testId={`funnel-by-${by}`} label={by === "market" ? t.marketCard : t.sourceCard}>
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          <th className={th}><HintLabel label={first}>{hint(first, by === "market" ? hints.fnColMarket! : hints.fnColSource!)}</HintLabel></th>
          {cols.map(([label, text]) => <th key={label} className={`${th} text-right`}><HintLabel label={label}>{hint(label, text)}</HintLabel></th>)}
          <th className={th}><HintLabel label={t.colTop}>{hint(t.colTop, hints.fnColTop!)}</HintLabel></th>
        </tr>
      </thead>
      <tbody>
        {rows.map((r) => (
          <tr key={r.key ?? "none"} className={row}>
            <td className="h-10 max-w-[12rem] overflow-hidden text-ellipsis whitespace-nowrap px-2 font-semibold" title={labelOf(r.key)}>{labelOf(r.key)}</td>
            {cols.map(([label, , value]) => <td key={label} className={td}>{value(r)}</td>)}
            <td className="h-10 whitespace-nowrap px-2 text-small text-p4a-muted">
              {r.top.length === 0 ? "–" : r.top.map((x) => t.topItem.replace("{label}", x.label).replace("{n}", n(x.deals))).join(" · ")}
            </td>
          </tr>
        ))}
      </tbody>
    </Scroll>
  );
}

/** The lost deals per day or week: lost, real, no reason, data quality, then the most frequent real reasons as columns and the rest as Other */
export function LostPeriodTable({ rows, reasons, keys, group, hints, copy, locale }: {
  rows: LostPeriodRow[]; reasons: LostReasonRow[]; keys: string[]; group: FunnelGroup; hints: Record<string, string>; copy: Copy; locale: Locale;
}) {
  const t = copy.funnel;
  const n = (x: number) => fmtCount(x, locale);
  const hint = hintOf(copy);
  const { columns, other } = periodReasonColumns(reasons, 5);
  const byKey = new Map(rows.map((r) => [r.key, r]));
  const empty: LostPeriodRow = { key: "", lost: 0, real: 0, noReason: 0, dataQuality: 0, reasons: {} };
  const first = group === "week" ? t.week : t.day;
  const labelOf = (k: string) => (group === "week" ? t.weekLabel.replace("{week}", fmtDate(k, locale, "short")) : fmtDate(k, locale, "compact"));
  return (
    <Scroll testId="funnel-by-period" label={group === "week" ? t.periodCardWeek : t.periodCardDay}>
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          <th className={th}><HintLabel label={first}>{hint(first, hints.fnColPeriod!)}</HintLabel></th>
          {[[t.colLost, hints.fnColGroupLost!], [t.colReal, hints.fnColReal!], [t.colNoReason, hints.fnColNoReason!], [t.colDq, hints.fnColDq!]].map(([label, text]) => (
            <th key={label} className={`${th} text-right`}><HintLabel label={label!}>{hint(label!, text!)}</HintLabel></th>
          ))}
          {columns.map((c) => (
            <th key={c.value} className={`${th} max-w-[10rem] text-right`}><HintLabel label={c.label}>{hint(c.label, hints.fnColReason!.replace("{reason}", c.label))}</HintLabel></th>
          ))}
          {other.length > 0 ? <th className={`${th} text-right`}><HintLabel label={t.colOther}>{hint(t.colOther, hints.fnColOther!)}</HintLabel></th> : null}
        </tr>
      </thead>
      <tbody>
        {keys.map((k) => {
          const r = byKey.get(k) ?? empty;
          return (
            <tr key={k} className={row}>
              <td className="h-10 whitespace-nowrap px-2 font-semibold">{labelOf(k)}</td>
              <td className={td}>{n(r.lost)}</td>
              <td className={td}>{n(r.real)}</td>
              <td className={td}>{n(r.noReason)}</td>
              <td className={td}>{n(r.dataQuality)}</td>
              {columns.map((c) => <td key={c.value} className={td}>{n(r.reasons[c.value] ?? 0)}</td>)}
              {other.length > 0 ? <td className={td}>{n(other.reduce((s, v) => s + (r.reasons[v] ?? 0), 0))}</td> : null}
            </tr>
          );
        })}
      </tbody>
    </Scroll>
  );
}

/** The lost deals without a reason, newest close first: the deal's id, its pipeline, market, creation and close, and its link */
export function LostList({ rows, hints, copy, locale, timeZone }: { rows: LostListRow[]; hints: Record<string, string>; copy: Copy; locale: Locale; timeZone: string }) {
  const t = copy.funnel;
  const hint = hintOf(copy);
  const cols: [string, string][] = [[t.colDeal, hints.fnColDeal!], [t.colPipeline, hints.fnColPipeline!], [t.colMarket, hints.fnColMarket!],
    [t.colCreatedAt, hints.fnColCreatedAt!], [t.colClosedAt, hints.fnColClosedAt!]];
  return (
    <Scroll testId="funnel-lost-list" label={t.listTitle}>
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          {cols.map(([label, text]) => <th key={label} className={th}><HintLabel label={label}>{hint(label, text)}</HintLabel></th>)}
          <th className={th}><span className="sr-only">{t.colLink}</span></th>
        </tr>
      </thead>
      <tbody>
        {rows.map((r) => (
          <tr key={r.dealId} className={row} data-testid="funnel-lost-row">
            <td className="h-10 whitespace-nowrap px-2 tabular">{r.dealSourceId}</td>
            <td className="h-10 max-w-[14rem] overflow-hidden text-ellipsis whitespace-nowrap px-2" title={r.pipelineLabel}>{r.pipelineLabel}</td>
            <td className="h-10 whitespace-nowrap px-2">{r.market === "unknown" ? copy.reports.unknownMarket : r.market}</td>
            <td className="h-10 whitespace-nowrap px-2 tabular">{fmtDateTimeShort(r.createdAt, timeZone, locale)}</td>
            <td className="h-10 whitespace-nowrap px-2 tabular">{fmtDateTimeShort(r.closedAt, timeZone, locale)}</td>
            <td className="h-10 px-2 text-right"><RecordLink url={r.recordUrl} label={t.openRecord.replace("{id}", r.dealSourceId)} /></td>
          </tr>
        ))}
      </tbody>
    </Scroll>
  );
}

/** Per deal owner by name, never ranked: won, lost, the amount won per currency (one line each, never added up), won without an amount */
export function DealsPerPersonTable({ rows, total, hints, copy, locale }: { rows: DealPerson[]; total: DealPerson; hints: Record<string, string>; copy: Copy; locale: Locale }) {
  const t = copy.funnel;
  const n = (x: number) => fmtCount(x, locale);
  const hint = hintOf(copy);
  const nameOf = (p: DealPerson) => p.kind === "total" ? t.total : p.kind === "person" ? p.name ?? p.userId ?? ""
    : p.unlinkedOwners === null || p.unlinkedOwners === 0 ? t.notLinkedNone : p.unlinkedOwners === 1 ? t.notLinkedOne : t.notLinkedMany.replace("{n}", n(p.unlinkedOwners));
  const amount = (a: DealPerson["amounts"][number]) => (a.currency === null ? t.noCurrency.replace("{amount}", fmtAmount(a.amount, null, locale)) : fmtAmount(a.amount, a.currency, locale));
  const amounts = (p: DealPerson) => (p.amounts.length === 0 ? "–" : p.amounts.map(amount).join(" · "));
  const cols: [string, string, (p: DealPerson) => string][] = [
    [t.colWon, hints.fnColPersonWon!, (p) => n(p.won)], [t.colLost, hints.fnColPersonLost!, (p) => n(p.lost)],
    [t.colAmount, hints.fnColAmount!, amounts], [t.colNoAmount, hints.fnColNoAmount!, (p) => n(p.wonWithoutAmount)],
  ];
  return (
    <Scroll testId="funnel-people" label={t.personTitle}>
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          <th className={th}><HintLabel label={t.colPerson}>{hint(t.colPerson, hints.fnColPerson!)}</HintLabel></th>
          {cols.map(([label, text]) => <th key={label} className={`${th} text-right`}><HintLabel label={label}>{hint(label, text)}</HintLabel></th>)}
        </tr>
      </thead>
      <tbody>
        {[...rows, total].map((p) => (
          <tr key={p.kind === "person" ? p.userId! : p.kind} className={`${row} ${p.kind === "total" ? "font-semibold" : ""}`} data-testid="funnel-person-row" data-kind={p.kind}>
            <td className={`h-10 max-w-[14rem] overflow-hidden text-ellipsis whitespace-nowrap px-2 ${p.kind === "notLinked" ? "text-p4a-muted" : "font-semibold"}`} title={nameOf(p)}>{nameOf(p)}</td>
            {cols.map(([label, , value]) => <td key={label} className={td}>{value(p)}</td>)}
          </tr>
        ))}
      </tbody>
    </Scroll>
  );
}
