"use client";

/**
 * The filters of Customers → Active (addition 0009l): market (K), segment and Direct / Indirect. The lists come with the
 * page's above-the-fold read of the stored answer (the markets of the base, the tenant's segments and unknown, the three
 * channels), so the frame reads no catalog and shows the filters' outline until they are there; choosing loads the page with the filter in its address, kept with the range, the cohort grouping and the
 * panels' own choices, so a filtered view can be bookmarked and a market's row can link to it. The database runs every
 * filter, on every panel, the list and the file alike. It takes only its own ten strings and the unknown market's name,
 * not the page's copy. A choice is a transition: the three boxes read busy from the click until the page's outline
 * takes their place (CLAUDE.md, Performance: a click shows something within 100 ms).
 */
import type { Route } from "next";
import { useTransition } from "react";
import { useRouter } from "next/navigation";
import type { ActiveCopy } from "@/lib/copy";
import { ACTIVE_CHANNELS, activeQuery } from "@/lib/active";
import type { ActiveChannel, ActiveFilter } from "@/lib/data";
import { Keycap } from "./primitives";

/** The filters' own words: the labels, the three "all" choices and the channels' names (not the page's whole copy: it rides to the browser) */
export type ActiveFilterWords = Pick<ActiveCopy, "marketFilter" | "allMarkets" | "segmentFilter" | "allSegments" | "unknownSegment" | "channel" | "allChannels"
  | "channel_indirect" | "channel_direct" | "channel_unknown">;

export function ActiveFilters({ markets, segments, filter, keep, t, unknownMarket }: {
  markets: string[]; segments: string[]; filter: ActiveFilter; keep: Record<string, string>; t: ActiveFilterWords; unknownMarket: string;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const select = `h-10 w-44 rounded-input border border-p4a-border bg-white px-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue ${pending ? "cursor-progress opacity-60" : ""}`;
  const marketList = filter.market && !markets.includes(filter.market) ? [...markets, filter.market] : markets;
  const segmentList = filter.segment && !segments.includes(filter.segment) ? [...segments, filter.segment] : segments;

  function go(next: ActiveFilter) {
    const qs = new URLSearchParams({ ...keep, ...activeQuery(next) }).toString();
    startTransition(() => router.push((qs ? `/reports/active?${qs}` : "/reports/active") as Route));
  }

  return (
    <div className="flex flex-wrap items-end gap-4" data-testid="active-filters" aria-busy={pending || undefined}>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.marketFilter} <Keycap>K</Keycap></span>
        <select value={filter.market ?? ""} data-shortcut="k" data-testid="active-market" className={select}
          onChange={(e) => go({ ...filter, market: e.target.value || null })}>
          <option value="">{t.allMarkets}</option>
          {marketList.map((m) => <option key={m} value={m}>{m === "unknown" ? unknownMarket : m}</option>)}
        </select>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span>{t.segmentFilter}</span>
        <select value={filter.segment ?? ""} data-testid="active-segment" className={select}
          onChange={(e) => go({ ...filter, segment: e.target.value || null })}>
          <option value="">{t.allSegments}</option>
          {segmentList.map((s) => <option key={s} value={s}>{s === "unknown" ? t.unknownSegment : s}</option>)}
        </select>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span>{t.channel}</span>
        <select value={filter.channel ?? ""} data-testid="active-channel" className={select}
          onChange={(e) => go({ ...filter, channel: (e.target.value || null) as ActiveChannel | null })}>
          <option value="">{t.allChannels}</option>
          {ACTIVE_CHANNELS.map((c) => <option key={c} value={c}>{t[`channel_${c}`]}</option>)}
        </select>
      </label>
    </div>
  );
}
