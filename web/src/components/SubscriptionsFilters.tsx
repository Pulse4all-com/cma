"use client";

/**
 * The filters of Customers → Subscriptions (addition 0009zh, D.1): Market (K), Store (S, the stores of the chosen market),
 * Proposition (P, from the tenant's subscriptions.propositions and none), Billing interval (I) and the month range (from,
 * to). The choices come with the page's one read, so the bar reads no catalog of its own; choosing loads the page with
 * the filter in its address (market, store, proposition, interval, from, to), kept with the movements' view, so a
 * filtered view can be bookmarked. A change of filter starts the list on its first page. It takes only its own words,
 * not the page's whole copy. A choice is a transition: the boxes read busy from the click until the new page is there
 * (CLAUDE.md, Performance: a click shows something within 100 ms).
 */
import type { Route } from "next";
import { useTransition } from "react";
import { useRouter } from "next/navigation";
import type { SubscriptionsCopy } from "@/lib/copy";
import type { SubscriptionsFilter, SubscriptionsInterval } from "@/lib/data";
import { monthAddress, SUBSCRIPTIONS_PATH, subscriptionsQuery } from "@/lib/subscriptions";
import { Keycap } from "./primitives";

export type SubscriptionsFilterWords = Pick<SubscriptionsCopy, "filtersLabel" | "marketFilter" | "allMarkets" | "unknownMarket" | "storeFilter" | "allStores"
  | "propositionFilter" | "allPropositions" | "noProposition" | "intervalFilter" | "allIntervals" | "interval_monthly" | "interval_quarterly" | "interval_yearly"
  | "interval_other" | "interval_unknown" | "fromLabel" | "toLabel">;

export function SubscriptionsFilters({ filter, from, to, markets, stores, propositions, intervals, months, keep, t, path = SUBSCRIPTIONS_PATH }: {
  filter: SubscriptionsFilter; from: string; to: string; markets: string[]; stores: { connectionId: string; handle: string; market: string }[];
  propositions: string[]; intervals: SubscriptionsInterval[];
  /** The months a range may take, newest first, as { value: YYYY-MM, label } */
  months: { value: string; label: string }[];
  /** What the filters keep in the address (the movements' view, the list's measure and sort) */
  keep: Record<string, string>;
  t: SubscriptionsFilterWords;
  /** The page the filters lead to: Customers → Subscriptions, or Customers → Payments, which shares its filters (addition 0009zy) */
  path?: string;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const select = `h-10 w-44 rounded-input border border-p4a-border bg-white px-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue ${pending ? "cursor-progress opacity-60" : ""}`;
  const storeList = stores.filter((s) => filter.market === null || s.market === filter.market);

  function go(next: SubscriptionsFilter, range: { from: string; to: string }) {
    const qs = new URLSearchParams({ ...keep, ...subscriptionsQuery(next), from: monthAddress(range.from), to: monthAddress(range.to) }).toString();
    startTransition(() => router.push(`${path}?${qs}` as Route));
  }
  const range = { from, to };

  return (
    <div role="group" aria-label={t.filtersLabel} className="flex flex-wrap items-end gap-4" data-testid="subscriptions-filters" aria-busy={pending || undefined}>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.marketFilter} <Keycap>K</Keycap></span>
        <select value={filter.market ?? ""} data-shortcut="k" data-testid="subscriptions-market" className={select}
          onChange={(e) => go({ ...filter, market: e.target.value || null, store: null }, range)}>
          <option value="">{t.allMarkets}</option>
          {markets.map((m) => <option key={m} value={m}>{m === "unknown" ? t.unknownMarket : m}</option>)}
        </select>
      </label>
      {storeList.length > 1 || filter.store ? (
        <label className="flex flex-col gap-2 text-small font-semibold">
          <span className="flex items-center gap-2">{t.storeFilter} <Keycap>S</Keycap></span>
          <select value={filter.store ?? ""} data-shortcut="s" data-testid="subscriptions-store" className={select}
            onChange={(e) => go({ ...filter, store: e.target.value || null }, range)}>
            <option value="">{t.allStores}</option>
            {storeList.map((s) => <option key={s.connectionId} value={s.connectionId}>{`${s.handle} (${s.market})`}</option>)}
          </select>
        </label>
      ) : null}
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.propositionFilter} <Keycap>P</Keycap></span>
        <select value={filter.proposition ?? ""} data-shortcut="p" data-testid="subscriptions-proposition" className={select}
          onChange={(e) => go({ ...filter, proposition: e.target.value || null }, range)}>
          <option value="">{t.allPropositions}</option>
          {propositions.map((p) => <option key={p} value={p}>{p === "none" ? t.noProposition : p}</option>)}
        </select>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.intervalFilter} <Keycap>I</Keycap></span>
        <select value={filter.interval ?? ""} data-shortcut="i" data-testid="subscriptions-interval" className={select}
          onChange={(e) => go({ ...filter, interval: (e.target.value || null) as SubscriptionsInterval | null }, range)}>
          <option value="">{t.allIntervals}</option>
          {intervals.map((i) => <option key={i} value={i}>{t[`interval_${i}`]}</option>)}
        </select>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span>{t.fromLabel}</span>
        <select value={monthAddress(from)} data-testid="subscriptions-from" className={select}
          onChange={(e) => go(filter, { from: `${e.target.value}-01`, to })}>
          {months.filter((m) => m.value <= monthAddress(to)).map((m) => <option key={m.value} value={m.value}>{m.label}</option>)}
        </select>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span>{t.toLabel}</span>
        <select value={monthAddress(to)} data-testid="subscriptions-to" className={select}
          onChange={(e) => go(filter, { from, to: `${e.target.value}-01` })}>
          {months.filter((m) => m.value >= monthAddress(from)).map((m) => <option key={m.value} value={m.value}>{m.label}</option>)}
        </select>
      </label>
    </div>
  );
}
