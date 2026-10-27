"use client";

/**
 * The filters of Reports → Maintenance (addition 0008zi): the horizon's first month, the market (K) and the model (D).
 * Choosing keeps the horizon's length, the scope and the view and loads the page with the filter; an open device list
 * closes. The address keys are from, market and model.
 */
import type { Route } from "next";
import { useRouter } from "next/navigation";
import { Keycap } from "./primitives";

const select = "h-10 w-44 rounded-input border border-p4a-border bg-white px-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue";

export interface MaintenanceFilterCopy {
  from: string; marketFilter: string; allMarkets: string; modelFilter: string; allModels: string; unknownMarket: string; unknownModel: string;
}

export function MaintenanceFilters({ months, markets, models, fromMonth, currentMonth, market, model, query, copy }: {
  /** The months the horizon may start in, with their labels */
  months: { key: string; label: string }[];
  /** Market codes, "unknown" for a device without one */
  markets: string[];
  models: { key: string; name: string | null }[];
  fromMonth: string;
  currentMonth: string;
  market: string | null;
  model: string | null;
  /** The rest of the query string (months, scope, view), kept when a filter changes */
  query: Record<string, string>;
  copy: MaintenanceFilterCopy;
}) {
  const router = useRouter();
  const marketList = market && !markets.includes(market) ? [...markets, market] : markets;
  const modelList = model && !models.some((m) => m.key === model) ? [...models, { key: model, name: null }] : models;

  function go(next: { from: string; market: string | null; model: string | null }) {
    const qs = new URLSearchParams(query);
    if (next.from !== currentMonth) qs.set("from", next.from);
    if (next.market) qs.set("market", next.market);
    if (next.model) qs.set("model", next.model);
    router.push(`/reports/maintenance?${qs.toString()}` as Route);
  }

  return (
    <div className="flex flex-wrap items-end gap-4" data-testid="maintenance-filters">
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span>{copy.from}</span>
        <select value={fromMonth} data-testid="maintenance-from" className={select} onChange={(e) => go({ from: e.target.value, market, model })}>
          {months.map((m) => <option key={m.key} value={m.key}>{m.label}</option>)}
        </select>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{copy.marketFilter} <Keycap>K</Keycap></span>
        <select value={market ?? ""} data-shortcut="k" data-testid="maintenance-market" className={select}
          onChange={(e) => go({ from: fromMonth, market: e.target.value || null, model })}>
          <option value="">{copy.allMarkets}</option>
          {marketList.map((m) => <option key={m} value={m}>{m === "unknown" ? copy.unknownMarket : m}</option>)}
        </select>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{copy.modelFilter} <Keycap>D</Keycap></span>
        <select value={model ?? ""} data-shortcut="d" data-testid="maintenance-model" className={select}
          onChange={(e) => go({ from: fromMonth, market, model: e.target.value || null })}>
          <option value="">{copy.allModels}</option>
          {modelList.map((m) => <option key={m.key} value={m.key}>{m.key === "unknown" ? copy.unknownModel : m.name ?? m.key}</option>)}
        </select>
      </label>
    </div>
  );
}
