"use client";

/**
 * The filters of Reports → Attempts per deal and Attempts per agent (addition 0008y), next to the period bar: market
 * (K), pipeline (P) and which deals (S: the lead pipelines or every counted pipeline). The period bar holds T, W, M and
 * C, the grouping G, the rail its digits and the top bar L. Choosing keeps the period and the grouping and loads the
 * page with the filter.
 */
import type { Route } from "next";
import { useRouter } from "next/navigation";
import type { Copy } from "@/lib/copy";
import type { AttemptFilter, AttemptScope } from "@/lib/data";
import { ATTEMPT_SCOPES } from "@/lib/attempts";
import { Keycap } from "./primitives";

const select = "h-10 w-44 rounded-input border border-p4a-border bg-white px-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue";

export function AttemptFilters({ pathname, markets, pipelines, filter, query, copy }: {
  pathname: "/reports/attempts" | "/reports/attempts-per-agent";
  /** Market codes, "unknown" for a deal without one */
  markets: string[];
  pipelines: { key: string; label: string }[];
  filter: AttemptFilter;
  /** The period and grouping part of the query string, kept when a filter changes */
  query: Record<string, string>;
  copy: Copy;
}) {
  const t = copy.attempts;
  const router = useRouter();
  const marketList = filter.market && !markets.includes(filter.market) ? [...markets, filter.market] : markets;
  const pipelineList = filter.pipeline && !pipelines.some((p) => p.key === filter.pipeline) ? [...pipelines, { key: filter.pipeline, label: filter.pipeline }] : pipelines;

  function go(next: AttemptFilter) {
    const qs = new URLSearchParams(Object.entries({ ...query, market: next.market, pipeline: next.pipeline, scope: next.scope === "lead" ? null : next.scope })
      .filter((e): e is [string, string] => e[1] !== null && e[1] !== ""));
    router.push(`${pathname}?${qs.toString()}` as Route);
  }

  return (
    <div className="flex flex-wrap items-end gap-4" data-testid="attempts-filters">
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.marketFilter} <Keycap>K</Keycap></span>
        <select value={filter.market ?? ""} data-shortcut="k" data-testid="attempts-market" className={select}
          onChange={(e) => go({ ...filter, market: e.target.value || null })}>
          <option value="">{t.allMarkets}</option>
          {marketList.map((m) => <option key={m} value={m}>{m === "unknown" ? copy.reports.unknownMarket : m}</option>)}
        </select>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.pipelineFilter} <Keycap>P</Keycap></span>
        <select value={filter.pipeline ?? ""} data-shortcut="p" data-testid="attempts-pipeline" className={select}
          onChange={(e) => go({ ...filter, pipeline: e.target.value || null })}>
          <option value="">{t.allPipelines}</option>
          {pipelineList.map((p) => <option key={p.key} value={p.key}>{p.label}</option>)}
        </select>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.scopeFilter} <Keycap>S</Keycap></span>
        <select value={filter.scope} data-shortcut="s" data-testid="attempts-scope" className={select}
          onChange={(e) => go({ ...filter, scope: e.target.value as AttemptScope, pipeline: null })}>
          {ATTEMPT_SCOPES.map((s) => <option key={s} value={s}>{t[`scope_${s}`]}</option>)}
        </select>
      </label>
    </div>
  );
}
