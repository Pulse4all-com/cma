"use client";

/**
 * The market (K), segment and state (S) filters of Customers → Courtesy (addition 0009a). The lists come with the page's read
 * (the markets of every courtesy order, the tenant's segments and unknown), so they need no catalog read; choosing loads the
 * page with the filter in its address, kept with the period, the grouping and the cohorts, so a filtered view can be
 * bookmarked and Welcome's Needs attention can open the Not reached orders. The database runs every filter. It takes only its
 * own strings (copy.courtesy and the unknown market's name), not the whole copy.
 */
import type { Route } from "next";
import { useRouter } from "next/navigation";
import type { Copy } from "@/lib/copy";
import { COURTESY_STATE_FILTERS, courtesyQuery } from "@/lib/courtesy";
import type { CourtesyFilter, CourtesyStateFilter } from "@/lib/data";
import { Keycap } from "./primitives";

export function CourtesyFilters({ markets, segments, filter, keep, t, unknownMarket }: {
  markets: string[]; segments: string[]; filter: CourtesyFilter; keep: Record<string, string>; t: Copy["courtesy"]; unknownMarket: string;
}) {
  const router = useRouter();
  const select = "h-10 w-48 rounded-input border border-p4a-border bg-white px-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue";
  const marketList = filter.market && !markets.includes(filter.market) ? [...markets, filter.market] : markets;
  const segmentList = filter.segment && !segments.includes(filter.segment) ? [...segments, filter.segment] : segments;

  function go(next: CourtesyFilter) {
    const qs = new URLSearchParams({ ...keep, ...courtesyQuery(next) }).toString();
    router.push((qs ? `/reports/courtesy?${qs}` : "/reports/courtesy") as Route);
  }

  return (
    <div className="flex flex-wrap items-end gap-4" data-testid="courtesy-filters">
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.marketFilter} <Keycap>K</Keycap></span>
        <select value={filter.market ?? ""} data-shortcut="k" data-testid="courtesy-market" className={select}
          onChange={(e) => go({ ...filter, market: e.target.value || null })}>
          <option value="">{t.allMarkets}</option>
          {marketList.map((m) => <option key={m} value={m}>{m === "unknown" ? unknownMarket : m}</option>)}
        </select>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span>{t.segmentFilter}</span>
        <select value={filter.segment ?? ""} data-testid="courtesy-segment" className={select}
          onChange={(e) => go({ ...filter, segment: e.target.value || null })}>
          <option value="">{t.allSegments}</option>
          {segmentList.map((s) => <option key={s} value={s}>{s === "unknown" ? t.unknownSegment : s}</option>)}
        </select>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.stateFilter} <Keycap>S</Keycap></span>
        <select value={filter.state ?? ""} data-shortcut="s" data-testid="courtesy-state" className={select}
          onChange={(e) => go({ ...filter, state: (e.target.value || null) as CourtesyStateFilter | null })}>
          <option value="">{t.stateAll}</option>
          {COURTESY_STATE_FILTERS.map((s) => <option key={s} value={s}>{t[`state_${s}`]}</option>)}
        </select>
      </label>
    </div>
  );
}
