"use client";

/**
 * Reports → Flash's controls in the browser (addition 0008zm): As of (A: a business date with a snapshot, or Now), the
 * market (K) and a landing card's live headline. Each control keeps the rest of the address; the figure reads its one
 * overview's headline (GET /api/v1/reports/flash?part=headline) after the page has painted, so the landing answers at
 * once from the stored figures whatever the volume. Ids, codes and counts only.
 */
import type { Route } from "next";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { changeArrow, changeOf } from "@/lib/flash";
import { Keycap } from "./primitives";

function go(router: ReturnType<typeof useRouter>, query: Record<string, string>, change: Record<string, string | null>) {
  const q: Record<string, string> = { ...query };
  for (const [k, v] of Object.entries(change)) {
    if (v === null || v === "") delete q[k];
    else q[k] = v;
  }
  // a new As of or market starts the list at its first page
  delete q.page;
  const qs = new URLSearchParams(q).toString();
  router.push(`/reports/flash${qs ? `?${qs}` : ""}` as Route);
}

export function FlashAsOf({ asOf, min, max, query, labels }: {
  /** The snapshot date shown, or null for now */
  asOf: string | null;
  /** The first snapshot's date, null before the first */
  min: string | null;
  /** The latest date that can have a snapshot: yesterday */
  max: string;
  query: Record<string, string>;
  labels: { asOf: string; now: string };
}) {
  const router = useRouter();
  return (
    <div className="flex flex-col gap-2 text-small font-semibold">
      <label htmlFor="flash-as-of" className="flex items-center gap-2">{labels.asOf} <Keycap>A</Keycap></label>
      <div className="flex items-center gap-2">
        <input id="flash-as-of" type="date" data-shortcut="a" data-testid="flash-as-of" value={asOf ?? ""} min={min ?? undefined} max={max}
          className="h-10 rounded-button border border-p4a-border bg-white px-3 text-body font-normal text-p4a-body focus:border-p4a-deepblue focus:outline-none focus:ring-2 focus:ring-p4a-lightblue"
          onChange={(e) => go(router, query, { asOf: e.target.value || null })} />
        <button type="button" data-testid="flash-now" aria-pressed={asOf === null}
          className={`h-10 rounded-button border px-4 font-semibold ${asOf === null ? "border-p4a-deepblue bg-p4a-deepblue text-white" : "border-p4a-deepblue bg-white text-p4a-deepblue"}`}
          onClick={() => go(router, query, { asOf: null })}>
          {labels.now}
        </button>
      </div>
    </div>
  );
}

export function FlashMarket({ market, markets, query, labels }: {
  market: string | null;
  markets: { code: string; name: string }[];
  query: Record<string, string>;
  labels: { market: string; allMarkets: string; unknownMarket: string };
}) {
  const router = useRouter();
  return (
    <label className="flex flex-col gap-2 text-small font-semibold">
      <span className="flex items-center gap-2">{labels.market} <Keycap>K</Keycap></span>
      <select value={market ?? ""} data-shortcut="k" data-testid="flash-market" onChange={(e) => go(router, query, { market: e.target.value || null })}
        className="h-10 min-w-48 rounded-button border border-p4a-border bg-white px-3 text-body font-normal text-p4a-body focus:border-p4a-deepblue focus:outline-none focus:ring-2 focus:ring-p4a-lightblue">
        <option value="">{labels.allMarkets}</option>
        {markets.map((m) => <option key={m.code} value={m.code}>{m.name === m.code ? m.code : `${m.name} (${m.code})`}</option>)}
        <option value="unknown">{labels.unknownMarket}</option>
      </select>
    </label>
  );
}

/**
 * A landing card's live figure: its overview's headline read once after the page painted. While it reads, a calm line;
 * a failed read shows the dash, never an error code. The change against the figure to compare with is written here too,
 * since it needs the live value
 */
export function FlashLiveFigure({ overview, market, from, to, previous, locale, labels }: {
  overview: string;
  market: string | null;
  from: string | null;
  to: string | null;
  previous: number | null;
  locale: string;
  labels: { loading: string; changeSince: string; changeFlat: string; noCompare: string; previousOnText: string | null };
}) {
  const [value, setValue] = useState<number | null | "loading" | "failed">("loading");
  useEffect(() => {
    const q = new URLSearchParams({ overview, part: "headline", ...(market ? { market } : {}), ...(from ? { from } : {}), ...(to ? { to } : {}) });
    let gone = false;
    fetch(`/api/v1/reports/flash?${q.toString()}`, { headers: { accept: "application/json" } })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))
      .then((j: { data?: { value?: number | null } }) => { if (!gone) setValue(typeof j.data?.value === "number" ? j.data.value : null); })
      .catch(() => { if (!gone) setValue("failed"); });
    return () => { gone = true; };
  }, [overview, market, from, to]);
  const n = (x: number) => new Intl.NumberFormat(locale === "nl" ? "nl-NL" : "en-GB", { maximumFractionDigits: 1 }).format(x);
  if (value === "loading") return <p className="text-small text-p4a-muted" data-testid={`flash-live-${overview}`}>{labels.loading}</p>;
  const shown = typeof value === "number" ? value : null;
  // the change as the stored cards write it (lib/flash's changeOf and changeArrow, which verify:flash tests)
  let change = labels.noCompare;
  const c = changeOf(shown, previous);
  if (c.direction !== "none" && labels.previousOnText) {
    change = c.direction === "flat" ? labels.changeFlat.replace("{date}", labels.previousOnText)
      : labels.changeSince.replace("{arrow}", changeArrow(c.direction)).replace("{delta}", n(Math.abs(c.delta ?? 0))).replace("{date}", labels.previousOnText);
  }
  return (
    <>
      <p className="tabular text-title font-bold text-p4a-heading" data-testid={`flash-live-${overview}`}>{shown === null ? "–" : n(shown)}</p>
      <p className="text-small text-p4a-muted">{change}</p>
    </>
  );
}
