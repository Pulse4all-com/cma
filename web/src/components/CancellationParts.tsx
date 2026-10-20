/**
 * Building blocks of Reports → Cancellations (addition 0008zb, 20 October 2026; backlog CMA-049 without CCL): the requests
 * per market (bars and table), per day or week and market, the reasons when the kind's record type maps one, and the
 * newest requests with their links. It counts the request (the ticket of the kind), never the contract. Server
 * components, plain CSS; Pulse4all-Style 7.5 to 7.7 as Reports → Funnel: horizontal bars in Deep Blue, the requests
 * without a reason in the neutral hue, never a red stack; every header with its hint. Ids, codes, counts, links and times
 * only: no customer data; a request links to the customer records by its id.
 */
import type { ReactNode } from "react";
import type { Copy, Locale } from "@/lib/copy";
import type { CancellationListRow, CancellationsReport, FunnelGroup } from "@/lib/data";
import { cancellationPivot, fmtDays, FUNNEL_BAR_CLASS, FUNNEL_NEUTRAL_CLASS } from "@/lib/funnel";
import { barShare, fmtCount } from "@/lib/reports";
import { fmtDate, fmtDateTimeShort } from "@/lib/time";
import { BarList } from "./FunnelParts";
import { HeaderHint } from "./HeaderHint";
import { HintLabel } from "./HintLabel";
import { RecordLink } from "./RecordLink";
import { Badge } from "./primitives";

const th = "h-10 px-2 py-1 align-bottom font-semibold";
const td = "h-10 whitespace-nowrap px-2 tabular text-right";
const row = "border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50";

function Scroll({ testId, label, children }: { testId: string; label: string; children: ReactNode }) {
  return (
    <div className="overflow-x-auto" data-testid={`${testId}-scroll`} role="region" aria-label={label} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid={testId}>{children}</table>
    </div>
  );
}

const marketName = (m: string, copy: Copy) => (m === "unknown" ? copy.reports.unknownMarket : m);

/** The requests per market: bars of the requests, then the table with open, closed and the median days to close */
export function CancellationMarkets({ rows, hints, copy, locale }: { rows: CancellationsReport["byMarket"]; hints: Record<string, string>; copy: Copy; locale: Locale }) {
  const t = copy.cancellations;
  const n = (x: number) => fmtCount(x, locale);
  const hint = (label: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
  const largest = Math.max(0, ...rows.map((r) => r.requests));
  const cols: [string, string, (r: CancellationsReport["byMarket"][number]) => string][] = [
    [t.colRequests, hints.cnColRequests!, (r) => n(r.requests)], [t.colOpen, hints.cnColOpen!, (r) => n(r.open)],
    [t.colClosed, hints.cnColClosed!, (r) => n(r.closed)], [t.colDays, hints.cnColDays!, (r) => fmtDays(r.medianDaysToClose, locale, copy.funnel)],
  ];
  return (
    <div className="flex flex-col gap-4">
      <BarList testId="cancellations-market-bars" label={t.marketCard} className={FUNNEL_BAR_CLASS}
        bars={rows.map((r) => ({ key: r.market, label: marketName(r.market, copy), share: barShare(r.requests, largest), value: n(r.requests),
          title: `${marketName(r.market, copy)}: ${n(r.requests)}` }))} />
      <Scroll testId="cancellations-markets" label={t.marketCard}>
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={th}><HintLabel label={t.colMarket}>{hint(t.colMarket, hints.cnColMarket!)}</HintLabel></th>
            {cols.map(([label, text]) => <th key={label} className={`${th} text-right`}><HintLabel label={label}>{hint(label, text)}</HintLabel></th>)}
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.market} className={row}>
              <td className="h-10 whitespace-nowrap px-2 font-semibold">{marketName(r.market, copy)}</td>
              {cols.map(([label, , value]) => <td key={label} className={td}>{value(r)}</td>)}
            </tr>
          ))}
        </tbody>
      </Scroll>
    </div>
  );
}

/** The requests per day or week (a row each, without gaps) and market (a column each), with the total */
export function CancellationPeriods({ byPeriod, keys, group, hints, copy, locale }: {
  byPeriod: CancellationsReport["byPeriod"]; keys: string[]; group: FunnelGroup; hints: Record<string, string>; copy: Copy; locale: Locale;
}) {
  const t = copy.cancellations;
  const n = (x: number) => fmtCount(x, locale);
  const hint = (label: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
  const { markets, rows } = cancellationPivot(byPeriod);
  const byKey = new Map(rows.map((r) => [r.key, r]));
  const first = group === "week" ? copy.funnel.week : copy.funnel.day;
  const labelOf = (k: string) => (group === "week" ? copy.funnel.weekLabel.replace("{week}", fmtDate(k, locale, "short")) : fmtDate(k, locale, "compact"));
  return (
    <Scroll testId="cancellations-periods" label={group === "week" ? t.periodCardWeek : t.periodCardDay}>
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          <th className={th}><HintLabel label={first}>{hint(first, hints.cnColPeriod!)}</HintLabel></th>
          {markets.map((m) => (
            <th key={m} className={`${th} text-right`}>
              <HintLabel label={marketName(m, copy)}>{hint(marketName(m, copy), hints.cnColPeriodMarket!.replace("{market}", marketName(m, copy)))}</HintLabel>
            </th>
          ))}
          <th className={`${th} text-right`}><HintLabel label={copy.reports.total}>{hint(copy.reports.total, hints.cnColPeriodTotal!)}</HintLabel></th>
        </tr>
      </thead>
      <tbody>
        {keys.map((k) => {
          const r = byKey.get(k);
          return (
            <tr key={k} className={row}>
              <td className="h-10 whitespace-nowrap px-2 font-semibold">{labelOf(k)}</td>
              {markets.map((m) => <td key={m} className={td}>{n(r?.cells[m] ?? 0)}</td>)}
              <td className={`${td} font-semibold`}>{n(r?.total ?? 0)}</td>
            </tr>
          );
        })}
      </tbody>
    </Scroll>
  );
}

/** The requests per reason (the catalog's label), the requests without a reason last in the neutral hue */
export function CancellationReasons({ reasons, total, copy, locale }: { reasons: CancellationsReport["reasons"]; total: number; copy: Copy; locale: Locale }) {
  const t = copy.cancellations;
  const n = (x: number) => fmtCount(x, locale);
  const largest = Math.max(0, ...reasons.map((r) => r.requests));
  const named = reasons.filter((r) => r.value !== null);
  const none = reasons.find((r) => r.value === null);
  const value = (x: number) => t.reasonValue.replace("{n}", n(x)).replace("{total}", n(total));
  return (
    <div className="flex flex-col gap-4">
      {named.length > 0 ? (
        <BarList testId="cancellations-reasons" label={t.reasonsCard} className={FUNNEL_BAR_CLASS}
          bars={named.map((r) => ({ key: r.value!, label: r.label ?? r.value!, share: barShare(r.requests, largest), value: value(r.requests), title: `${r.label ?? r.value}: ${value(r.requests)}` }))} />
      ) : null}
      {none ? (
        <BarList testId="cancellations-no-reason" label={t.noReasonRow} className={FUNNEL_NEUTRAL_CLASS}
          bars={[{ key: "none", label: t.noReasonRow, share: barShare(none.requests, largest), value: value(none.requests), title: `${t.noReasonRow}: ${value(none.requests)}` }]} />
      ) : null}
    </div>
  );
}

/** The newest requests: the ticket's id, its pipeline, market, open or closed, creation and close, the reason's label, and its link */
export function CancellationList({ rows, reasonLabels, hints, copy, locale, timeZone }: {
  rows: CancellationListRow[]; reasonLabels: Map<string, string>; hints: Record<string, string>; copy: Copy; locale: Locale; timeZone: string;
}) {
  const t = copy.cancellations;
  const hint = (label: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
  const cols: [string, string][] = [[t.colRequest, hints.cnColRequest!], [t.colPipeline, hints.cnColPipeline!], [t.colMarket, hints.cnColMarket!],
    [t.colState, hints.cnColState!], [t.colCreatedAt, hints.cnColCreatedAt!], [t.colClosedAt, hints.cnColClosedAt!], [t.colReason, hints.cnColReason!]];
  return (
    <Scroll testId="cancellations-list" label={t.listTitle}>
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          {cols.map(([label, text]) => <th key={label} className={th}><HintLabel label={label}>{hint(label, text)}</HintLabel></th>)}
          <th className={th}><span className="sr-only">{t.colLink}</span></th>
        </tr>
      </thead>
      <tbody>
        {rows.map((r) => (
          <tr key={r.recordId} className={row} data-testid="cancellations-row">
            <td className="h-10 whitespace-nowrap px-2 tabular">{r.sourceId}</td>
            <td className="h-10 max-w-[14rem] overflow-hidden text-ellipsis whitespace-nowrap px-2" title={r.pipelineLabel}>{r.pipelineLabel}</td>
            <td className="h-10 whitespace-nowrap px-2">{marketName(r.market, copy)}</td>
            <td className="h-10 whitespace-nowrap px-2">{r.isClosed ? <Badge tone="neutral">{t.closed}</Badge> : <Badge tone="info">{t.open}</Badge>}</td>
            <td className="h-10 whitespace-nowrap px-2 tabular">{fmtDateTimeShort(r.createdAt, timeZone, locale)}</td>
            <td className="h-10 whitespace-nowrap px-2 tabular">{r.closedAt ? fmtDateTimeShort(r.closedAt, timeZone, locale) : "–"}</td>
            <td className="h-10 max-w-[12rem] overflow-hidden text-ellipsis whitespace-nowrap px-2">{r.reason === null ? "–" : reasonLabels.get(r.reason) ?? r.reason}</td>
            <td className="h-10 px-2 text-right"><RecordLink url={r.recordUrl} label={t.openRecord.replace("{id}", r.sourceId)} /></td>
          </tr>
        ))}
      </tbody>
    </Scroll>
  );
}
