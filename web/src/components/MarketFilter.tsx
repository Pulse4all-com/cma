"use client";

/**
 * The Intake report's market filter (F). The list holds the markets with intake in the period, so it
 * needs no catalog read. Choosing a market keeps the period and loads the page for that market.
 */
import type { Route } from "next";
import { useRouter } from "next/navigation";
import type { Copy } from "@/lib/copy";
import { Keycap } from "./primitives";

export function MarketFilter({
  markets,
  market,
  query,
  copy,
}: {
  /** Market codes, "unknown" for intake without a catalog market */
  markets: string[];
  /** The chosen market, or "" for all */
  market: string;
  /** The period part of the query string, kept when the filter changes */
  query: Record<string, string>;
  copy: Copy;
}) {
  const t = copy.intake;
  const router = useRouter();

  function filter(code: string) {
    const qs = new URLSearchParams({ ...query, ...(code ? { market: code } : {}) });
    router.push(`/reports/intake?${qs.toString()}` as Route);
  }

  return (
    <label className="flex flex-col gap-2 text-small font-semibold">
      <span className="flex items-center gap-2">
        {t.marketFilter} <Keycap>F</Keycap>
      </span>
      <select
        value={market}
        data-shortcut="f"
        onChange={(e) => filter(e.target.value)}
        className="h-10 min-w-48 rounded-input border border-p4a-border bg-white px-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue"
      >
        <option value="">{t.allMarkets}</option>
        {markets.map((m) => (
          <option key={m} value={m}>
            {m === "unknown" ? copy.reports.unknownMarket : m}
          </option>
        ))}
      </select>
    </label>
  );
}
