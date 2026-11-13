"use client";

/**
 * The filters of Reports → Funnel (addition 0008zb): market (K), pipeline (P, the lead pipelines only) and source (S, the
 * deal's source channel as the customer records hold it); Reports → Cancellations takes the market alone; Reports → Lead
 * cohorts (addition 0008zm) all three. The period bar
 * holds Y, T, W, M and C, the grouping G, the rail its digits and the top bar L. Choosing keeps the period and the grouping
 * and loads the page with the filter; the address keys are market, pipeline and source.
 */
import type { Route } from "next";
import type { FunnelFilter } from "@/lib/data";
import { funnelFilterQuery, type FunnelClientCopy } from "@/lib/funnel";
import { Keycap } from "./primitives";
import { PENDING_ROW, usePendingChoice } from "./usePendingPush";

const select = "h-10 w-44 rounded-input border border-p4a-border bg-white px-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue";

export function FunnelFilters({ pathname, markets, pipelines, sourceChannels, filter, query, copy, marketOnly = false }: {
  pathname: "/reports/funnel" | "/reports/cancellations" | "/reports/reviews" | "/reports/lead-cohorts";
  /** Market codes, "unknown" for a record without one */
  markets: string[];
  pipelines: { key: string; label: string }[];
  sourceChannels: string[];
  filter: FunnelFilter;
  /** The period and grouping part of the query string, kept when a filter changes */
  query: Record<string, string>;
  copy: FunnelClientCopy;
  /** Cancellations: the market only */
  marketOnly?: boolean;
}) {
  const t = copy.funnel;
  const [pending, shown, choose] = usePendingChoice(filter);
  const marketList = shown.market && !markets.includes(shown.market) ? [...markets, shown.market] : markets;
  const pipelineList = shown.pipeline && !pipelines.some((p) => p.key === shown.pipeline) ? [...pipelines, { key: shown.pipeline, label: shown.pipeline }] : pipelines;
  const sourceList = shown.sourceChannel && !sourceChannels.includes(shown.sourceChannel) ? [...sourceChannels, shown.sourceChannel] : sourceChannels;

  function go(next: FunnelFilter) {
    const qs = new URLSearchParams({ ...query, ...funnelFilterQuery(next) });
    choose(next, `${pathname}?${qs.toString()}` as Route);
  }

  return (
    <div className={`flex flex-wrap items-end gap-4 ${PENDING_ROW}`} data-testid="funnel-filters" aria-busy={pending || undefined}>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.marketFilter} <Keycap>K</Keycap></span>
        <select value={shown.market ?? ""} data-shortcut="k" data-testid="funnel-market" className={select}
          onChange={(e) => go({ ...shown, market: e.target.value || null })}>
          <option value="">{t.allMarkets}</option>
          {marketList.map((m) => <option key={m} value={m}>{m === "unknown" ? copy.reports.unknownMarket : m}</option>)}
        </select>
      </label>
      {marketOnly ? null : (
        <>
          <label className="flex flex-col gap-2 text-small font-semibold">
            <span className="flex items-center gap-2">{t.pipelineFilter} <Keycap>P</Keycap></span>
            <select value={shown.pipeline ?? ""} data-shortcut="p" data-testid="funnel-pipeline" className={select}
              onChange={(e) => go({ ...shown, pipeline: e.target.value || null })}>
              <option value="">{t.allPipelines}</option>
              {pipelineList.map((p) => <option key={p.key} value={p.key}>{p.label}</option>)}
            </select>
          </label>
          <label className="flex flex-col gap-2 text-small font-semibold">
            <span className="flex items-center gap-2">{t.sourceFilter} <Keycap>S</Keycap></span>
            <select value={shown.sourceChannel ?? ""} data-shortcut="s" data-testid="funnel-source" className={select}
              onChange={(e) => go({ ...shown, sourceChannel: e.target.value || null })}>
              <option value="">{t.allSources}</option>
              {sourceList.map((s) => <option key={s} value={s}>{s}</option>)}
            </select>
          </label>
        </>
      )}
    </div>
  );
}
