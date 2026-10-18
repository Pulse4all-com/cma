"use client";

/**
 * The filters of Reports → Email and Email per agent (addition 0008t), next to the period bar: market (K), inbox
 * (I) and mailbox (B). The lists hold what the period's emails have, so a chosen value without email stays in its
 * list. Choosing keeps the period and the grouping and loads the page with the filter. B, not M, for the mailbox:
 * the period bar holds T, W, M (this month) and C, the grouping G, the rail its digits and the top bar L.
 */
import type { Route } from "next";
import { useRouter } from "next/navigation";
import type { Copy } from "@/lib/copy";
import type { EmailFilter } from "@/lib/data";
import { Keycap } from "./primitives";

const select = "h-10 w-44 rounded-input border border-p4a-border bg-white px-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue";

export function EmailFilters({ pathname, markets, inboxes, accounts, filter, query, copy }: {
  pathname: "/reports/email" | "/reports/email-per-agent";
  /** Market codes, "unknown" for email without a market */
  markets: string[];
  inboxes: { key: string; name: string }[];
  accounts: { key: string; name: string }[];
  filter: EmailFilter;
  /** The period and grouping part of the query string, kept when a filter changes */
  query: Record<string, string>;
  copy: Copy;
}) {
  const t = copy.email;
  const router = useRouter();
  const withChosen = (list: { key: string; name: string }[], chosen: string | null) =>
    chosen && !list.some((x) => x.key === chosen) ? [...list, { key: chosen, name: chosen.split(":").slice(1).join(":") }] : list;
  const marketList = filter.market && !markets.includes(filter.market) ? [...markets, filter.market] : markets;
  const inboxList = withChosen(inboxes, filter.inbox);
  const accountList = withChosen(accounts, filter.account);

  function go(next: EmailFilter) {
    const qs = new URLSearchParams(Object.entries({ ...query, market: next.market, inbox: next.inbox, account: next.account })
      .filter((e): e is [string, string] => e[1] !== null && e[1] !== ""));
    router.push(`${pathname}?${qs.toString()}` as Route);
  }

  return (
    <div className="flex flex-wrap items-end gap-4" data-testid="email-filters">
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.marketFilter} <Keycap>K</Keycap></span>
        <select value={filter.market ?? ""} data-shortcut="k" data-testid="email-market" className={select}
          onChange={(e) => go({ ...filter, market: e.target.value || null })}>
          <option value="">{t.allMarkets}</option>
          {marketList.map((m) => <option key={m} value={m}>{m === "unknown" ? copy.reports.unknownMarket : m}</option>)}
        </select>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.inboxFilter} <Keycap>I</Keycap></span>
        <select value={filter.inbox ?? ""} data-shortcut="i" data-testid="email-inbox" className={select}
          onChange={(e) => go({ ...filter, inbox: e.target.value || null })}>
          <option value="">{t.allInboxes}</option>
          {inboxList.map((x) => <option key={x.key} value={x.key}>{x.name}</option>)}
        </select>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.accountFilter} <Keycap>B</Keycap></span>
        <select value={filter.account ?? ""} data-shortcut="b" data-testid="email-account" className={select}
          onChange={(e) => go({ ...filter, account: e.target.value || null })}>
          <option value="">{t.allAccounts}</option>
          {accountList.map((x) => <option key={x.key} value={x.key}>{x.name}</option>)}
        </select>
      </label>
    </div>
  );
}
