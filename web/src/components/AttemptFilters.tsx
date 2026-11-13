"use client";

/**
 * The filters of Reports → Attempts per deal and Attempts per agent (addition 0008y; 0008z): market (K), pipeline (P, the
 * lead pipelines only), attempts (A: every deal, the deals with no attempt yet, those with at least one) and outcome (O:
 * open, won, lost or ordered another way). The period bar holds Y, T, W, M and C, the grouping G, the rail its digits and the
 * top bar L. Choosing keeps the period and the grouping and loads the page with the filter; the address keys are market,
 * pipeline, attempted and outcome.
 */
import type { Route } from "next";
import type { AttemptAttempted, AttemptFilter, AttemptOutcomeFilter } from "@/lib/data";
import { ATTEMPT_ATTEMPTED, ATTEMPT_OUTCOMES, attemptFilterQuery, type AttemptClientCopy } from "@/lib/attempts";
import { Keycap } from "./primitives";
import { PENDING_ROW, usePendingChoice } from "./usePendingPush";

const select = "h-10 w-44 rounded-input border border-p4a-border bg-white px-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue";

export function AttemptFilters({ pathname, markets, pipelines, filter, query, copy }: {
  pathname: "/reports/attempts" | "/reports/attempts-per-agent";
  /** Market codes, "unknown" for a deal without one */
  markets: string[];
  pipelines: { key: string; label: string }[];
  filter: AttemptFilter;
  /** The period and grouping part of the query string, kept when a filter changes */
  query: Record<string, string>;
  copy: AttemptClientCopy;
}) {
  const t = copy.attempts;
  const [pending, shown, choose] = usePendingChoice(filter);
  const marketList = shown.market && !markets.includes(shown.market) ? [...markets, shown.market] : markets;
  const pipelineList = shown.pipeline && !pipelines.some((p) => p.key === shown.pipeline) ? [...pipelines, { key: shown.pipeline, label: shown.pipeline }] : pipelines;
  const outcomeLabel = (o: AttemptOutcomeFilter) => (o === "all" ? t.outcomeAll : t[`outcome_${o}`]);

  function go(next: AttemptFilter) {
    const qs = new URLSearchParams({ ...query, ...attemptFilterQuery(next) });
    choose(next, `${pathname}?${qs.toString()}` as Route);
  }

  return (
    <div className={`flex flex-wrap items-end gap-4 ${PENDING_ROW}`} data-testid="attempts-filters" aria-busy={pending || undefined}>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.marketFilter} <Keycap>K</Keycap></span>
        <select value={shown.market ?? ""} data-shortcut="k" data-testid="attempts-market" className={select}
          onChange={(e) => go({ ...shown, market: e.target.value || null })}>
          <option value="">{t.allMarkets}</option>
          {marketList.map((m) => <option key={m} value={m}>{m === "unknown" ? copy.reports.unknownMarket : m}</option>)}
        </select>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.pipelineFilter} <Keycap>P</Keycap></span>
        <select value={shown.pipeline ?? ""} data-shortcut="p" data-testid="attempts-pipeline" className={select}
          onChange={(e) => go({ ...shown, pipeline: e.target.value || null })}>
          <option value="">{t.allPipelines}</option>
          {pipelineList.map((p) => <option key={p.key} value={p.key}>{p.label}</option>)}
        </select>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.attemptedFilter} <Keycap>A</Keycap></span>
        <select value={shown.attempted} data-shortcut="a" data-testid="attempts-attempted" className={select}
          onChange={(e) => go({ ...shown, attempted: e.target.value as AttemptAttempted })}>
          {ATTEMPT_ATTEMPTED.map((a) => <option key={a} value={a}>{t[`attempted_${a}`]}</option>)}
        </select>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.outcomeFilter} <Keycap>O</Keycap></span>
        <select value={shown.outcome} data-shortcut="o" data-testid="attempts-outcome" className={select}
          onChange={(e) => go({ ...shown, outcome: e.target.value as AttemptOutcomeFilter })}>
          {ATTEMPT_OUTCOMES.map((o) => <option key={o} value={o}>{outcomeLabel(o)}</option>)}
        </select>
      </label>
    </div>
  );
}
