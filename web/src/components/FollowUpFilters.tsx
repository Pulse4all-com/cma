"use client";

/**
 * The market (K), person (O) and state (S) filters of Reports → Follow-up (addition 0008o). The lists hold
 * what is waiting right now (lib/follow-up filterOptions), so they need no catalog read; choosing loads the
 * page with the filter in its query, so a filtered view can be bookmarked and the 10-second refresh keeps it.
 * K, O and S are free on this page: it has no period bar and no grouping; the rail holds its digits and W,
 * the top bar L and ?. It takes only its own strings (copy.followUp and the unknown market's name), not the whole
 * copy: a client component's props travel in every refresh of the page (addition 0008s).
 */
import type { Route } from "next";
import { useRouter } from "next/navigation";
import type { Copy } from "@/lib/copy";
import { filterQuery, OWNER_NONE, type FilterOptions, type FollowUpFilter } from "@/lib/follow-up";
import { Keycap } from "./primitives";

export function FollowUpFilters({ options, filter, t, unknownMarket }: { options: FilterOptions; filter: FollowUpFilter; t: Copy["followUp"]; unknownMarket: string }) {
  const router = useRouter();
  const select = "h-10 w-48 rounded-input border border-p4a-border bg-white px-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue";
  const markets = filter.market && !options.markets.includes(filter.market) ? [...options.markets, filter.market] : options.markets;
  const owners = filter.owner && filter.owner !== OWNER_NONE && !options.owners.some((o) => o.id === filter.owner)
    ? [...options.owners, { id: filter.owner, name: null }] : options.owners;

  function go(next: FollowUpFilter) {
    const qs = new URLSearchParams(filterQuery(next)).toString();
    router.push((qs ? `/reports/follow-up?${qs}` : "/reports/follow-up") as Route);
  }

  return (
    <div className="flex flex-wrap items-end gap-4" data-testid="follow-up-filters">
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.marketFilter} <Keycap>K</Keycap></span>
        <select value={filter.market ?? ""} data-shortcut="k" data-testid="follow-up-market" className={select}
          onChange={(e) => go({ ...filter, market: e.target.value || null })}>
          <option value="">{t.allMarkets}</option>
          {markets.map((m) => <option key={m} value={m}>{m === "unknown" ? unknownMarket : m}</option>)}
        </select>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.ownerFilter} <Keycap>O</Keycap></span>
        <select value={filter.owner ?? ""} data-shortcut="o" data-testid="follow-up-owner" className={select}
          onChange={(e) => go({ ...filter, owner: e.target.value || null })}>
          <option value="">{t.allOwners}</option>
          {owners.map((o) => <option key={o.id} value={o.id}>{o.name ?? t.notMapped}</option>)}
          {options.hasUnowned || filter.owner === OWNER_NONE ? <option value={OWNER_NONE}>{t.ownerNone}</option> : null}
        </select>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.stateFilter} <Keycap>S</Keycap></span>
        <select value={filter.state ?? ""} data-shortcut="s" data-testid="follow-up-state" className={select}
          onChange={(e) => go({ ...filter, state: e.target.value === "attention" ? "attention" : null })}>
          <option value="">{t.stateAll}</option>
          <option value="attention">{t.stateAttention}</option>
        </select>
      </label>
    </div>
  );
}
