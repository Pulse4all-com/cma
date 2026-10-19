"use client";

/**
 * The filters of Reports → First orders and Orders per person (addition 0008u), next to the period bar: market (K)
 * and level (V, for level: the period bar holds T, W, M and C, the grouping G, the download X, the rail its digits
 * and the top bar L). Choosing keeps the period and the grouping and loads the page with the filter.
 */
import type { Route } from "next";
import { useRouter } from "next/navigation";
import type { Copy } from "@/lib/copy";
import type { FirstOrderFilter, FirstOrderLevel } from "@/lib/data";
import { Keycap } from "./primitives";

const select = "h-10 w-44 rounded-input border border-p4a-border bg-white px-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue";

export function FirstOrderFilters({ pathname, markets, levels, filter, query, copy }: {
  pathname: "/reports/first-orders" | "/reports/orders-per-person";
  /** Market codes, "unknown" for a deal without one */
  markets: string[];
  /** The levels in the tenant's order, self_service last */
  levels: FirstOrderLevel[];
  filter: FirstOrderFilter;
  /** The period and grouping part of the query string, kept when a filter changes */
  query: Record<string, string>;
  copy: Copy;
}) {
  const t = copy.firstOrders;
  const router = useRouter();
  const marketList = filter.market && !markets.includes(filter.market) ? [...markets, filter.market] : markets;

  function go(next: FirstOrderFilter) {
    const qs = new URLSearchParams(Object.entries({ ...query, market: next.market, level: next.level })
      .filter((e): e is [string, string] => e[1] !== null && e[1] !== ""));
    router.push(`${pathname}?${qs.toString()}` as Route);
  }

  return (
    <div className="flex flex-wrap items-end gap-4" data-testid="first-order-filters">
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.marketFilter} <Keycap>K</Keycap></span>
        <select value={filter.market ?? ""} data-shortcut="k" data-testid="first-order-market" className={select}
          onChange={(e) => go({ ...filter, market: e.target.value || null })}>
          <option value="">{t.allMarkets}</option>
          {marketList.map((m) => <option key={m} value={m}>{m === "unknown" ? copy.reports.unknownMarket : m}</option>)}
        </select>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.levelFilter} <Keycap>V</Keycap></span>
        <select value={filter.level ?? ""} data-shortcut="v" data-testid="first-order-level" className={select}
          onChange={(e) => go({ ...filter, level: (e.target.value || null) as FirstOrderLevel | null })}>
          <option value="">{t.allLevels}</option>
          {levels.map((l) => <option key={l} value={l}>{t[`level_${l}`]}</option>)}
        </select>
      </label>
    </div>
  );
}
