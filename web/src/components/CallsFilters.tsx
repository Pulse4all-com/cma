"use client";

/**
 * The market (K) and line (N) filters of Reports → Calls and Calls per agent (addition 0008j), next to
 * the period bar. The lists hold the markets and lines with calls in the period (the lines within the
 * chosen market), so they need no catalog read; a chosen value that has no calls stays in its list.
 * Choosing keeps the period and the grouping and loads the page with the filter; a new market clears the
 * line. K and N are free on both pages: the period bar holds Y, T, W, M and C, the grouping G, the rail
 * its digits and the top bar L.
 */
import type { Route } from "next";
import { useRouter } from "next/navigation";
import type { Copy } from "@/lib/copy";
import type { CallsFilter, CallsLine } from "@/lib/data";
import { Keycap } from "./primitives";

export function CallsFilters({ pathname, markets, lines, filter, query, copy }: {
  pathname: "/reports/calls" | "/reports/calls-per-agent";
  /** Market codes, "unknown" for calls on a line without a market */
  markets: string[];
  lines: CallsLine[];
  filter: CallsFilter;
  /** The period and grouping part of the query string, kept when a filter changes */
  query: Record<string, string>;
  copy: Copy;
}) {
  const t = copy.calls;
  const router = useRouter();
  const marketList = filter.market && !markets.includes(filter.market) ? [...markets, filter.market] : markets;
  const lineList = filter.line && !lines.some((l) => l.key === filter.line) ? [...lines, { key: filter.line, name: null }] : lines;
  const select = "h-10 w-40 rounded-input border border-p4a-border bg-white px-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue";

  function go(next: CallsFilter) {
    const qs = new URLSearchParams({ ...query, ...(next.market ? { market: next.market } : {}), ...(next.line ? { line: next.line } : {}) });
    router.push(`${pathname}?${qs.toString()}` as Route);
  }

  return (
    <div className="flex flex-wrap items-end gap-4" data-testid="calls-filters">
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.marketFilter} <Keycap>K</Keycap></span>
        <select value={filter.market ?? ""} data-shortcut="k" data-testid="calls-market" className={select}
          onChange={(e) => go({ market: e.target.value || null, line: null })}>
          <option value="">{t.allMarkets}</option>
          {marketList.map((m) => <option key={m} value={m}>{m === "unknown" ? copy.reports.unknownMarket : m}</option>)}
        </select>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.lineFilter} <Keycap>N</Keycap></span>
        <select value={filter.line ?? ""} data-shortcut="n" data-testid="calls-line" className={select}
          onChange={(e) => go({ market: filter.market, line: e.target.value || null })}>
          <option value="">{t.allLines}</option>
          {lineList.map((l) => <option key={l.key} value={l.key}>{l.name && l.name !== "unknown" ? l.name : t.unknownLine}</option>)}
        </select>
      </label>
    </div>
  );
}
