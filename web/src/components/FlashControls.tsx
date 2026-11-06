"use client";

/**
 * Reports → Flash's controls in the browser (addition 0008zn): As of (A: a business date with a snapshot, or Now), the
 * market (K), the Installed base's model (D, addition 0008zy) and a landing card's live headline. Each control keeps the rest of the address; the figure reads its one
 * overview's headline (GET /api/v1/reports/flash?part=headline) after the page has painted, so the landing answers at
 * once from the stored figures whatever the volume. Ids, codes and counts only.
 */
import type { Route } from "next";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { changeLineOf, definitionChanged, flashHref, splitItemsOf, splitLine, type FlashPath, type FlashSplitItem } from "@/lib/flash";
import { Keycap } from "./primitives";

function go(router: ReturnType<typeof useRouter>, path: FlashPath, query: Record<string, string>, change: Record<string, string | null>) {
  const q: Record<string, string> = { ...query };
  for (const [k, v] of Object.entries(change)) {
    if (v === null || v === "") delete q[k];
    else q[k] = v;
  }
  // a new As of or market starts the list at its first page
  delete q.page;
  router.push(flashHref(path, q) as Route);
}

export function FlashAsOf({ asOf, min, max, query, labels, path = "/reports/flash" }: {
  /** The snapshot date shown, or null for now */
  asOf: string | null;
  /** The first snapshot's date, null before the first */
  min: string | null;
  /** The latest date that can have a snapshot: yesterday */
  max: string;
  query: Record<string, string>;
  labels: { asOf: string; now: string };
  /** The page whose address the control changes (Reports → Flash, or Assets → Installed base, 0008zw) */
  path?: FlashPath;
}) {
  const router = useRouter();
  return (
    <div className="flex flex-col gap-2 text-small font-semibold">
      <label htmlFor="flash-as-of" className="flex items-center gap-2">{labels.asOf} <Keycap>A</Keycap></label>
      <div className="flex items-center gap-2">
        <input id="flash-as-of" type="date" data-shortcut="a" data-testid="flash-as-of" value={asOf ?? ""} min={min ?? undefined} max={max}
          className="h-10 rounded-button border border-p4a-border bg-white px-3 text-body font-normal text-p4a-body focus:border-p4a-deepblue focus:outline-none focus:ring-2 focus:ring-p4a-lightblue"
          onChange={(e) => go(router, path, query, { asOf: e.target.value || null })} />
        <button type="button" data-testid="flash-now" aria-pressed={asOf === null}
          className={`h-10 rounded-button border px-4 font-semibold ${asOf === null ? "border-p4a-deepblue bg-p4a-deepblue text-white" : "border-p4a-deepblue bg-white text-p4a-deepblue"}`}
          onClick={() => go(router, path, query, { asOf: null })}>
          {labels.now}
        </button>
      </div>
    </div>
  );
}

export function FlashMarket({ market, markets, query, labels, path = "/reports/flash" }: {
  market: string | null;
  markets: { code: string; name: string }[];
  query: Record<string, string>;
  labels: { market: string; allMarkets: string; unknownMarket: string };
  /** The page whose address the control changes (0008zw) */
  path?: FlashPath;
}) {
  const router = useRouter();
  return (
    <label className="flex flex-col gap-2 text-small font-semibold">
      <span className="flex items-center gap-2">{labels.market} <Keycap>K</Keycap></span>
      <select value={market ?? ""} data-shortcut="k" data-testid="flash-market" onChange={(e) => go(router, path, query, { market: e.target.value || null })}
        className="h-10 min-w-48 rounded-button border border-p4a-border bg-white px-3 text-body font-normal text-p4a-body focus:border-p4a-deepblue focus:outline-none focus:ring-2 focus:ring-p4a-lightblue">
        <option value="">{labels.allMarkets}</option>
        {markets.map((m) => <option key={m.code} value={m.code}>{m.name === m.code ? m.code : `${m.name} (${m.code})`}</option>)}
        <option value="unknown">{labels.unknownMarket}</option>
      </select>
    </label>
  );
}

/**
 * The Installed base's Model filter (addition 0008zy; D, as on Reports → Maintenance): every tile, per-market bar,
 * breakdown and record of one model, kept in the address as f_model (and in the files); "All models" first, the
 * register's models in its order, unknown last. A model the address names that the document does not is kept as a choice
 */
export function FlashModel({ model, models, query, labels, path = "/reports/flash" }: {
  model: string | null;
  models: { key: string; name: string | null }[];
  query: Record<string, string>;
  labels: { model: string; allModels: string; unknownModel: string };
  path?: FlashPath;
}) {
  const router = useRouter();
  const list = model && !models.some((m) => m.key === model) ? [...models, { key: model, name: null }] : models;
  return (
    <label className="flex flex-col gap-2 text-small font-semibold">
      <span className="flex items-center gap-2">{labels.model} <Keycap>D</Keycap></span>
      <select value={model ?? ""} data-shortcut="d" data-testid="flash-model" onChange={(e) => go(router, path, query, { f_model: e.target.value || null })}
        className="h-10 min-w-48 rounded-button border border-p4a-border bg-white px-3 text-body font-normal text-p4a-body focus:border-p4a-deepblue focus:outline-none focus:ring-2 focus:ring-p4a-lightblue">
        <option value="">{labels.allModels}</option>
        {list.map((m) => <option key={m.key} value={m.key}>{m.key === "unknown" ? labels.unknownModel : m.name ?? m.key}</option>)}
      </select>
    </label>
  );
}

/**
 * A landing card's live figure: its overview's headline read once after the page painted. While it reads, a calm line;
 * a failed read shows the dash, never an error code. The change against the figure to compare with is written here too,
 * since it needs the live value; a flow whose period is open (open: lib/flash periodComplete) says "so far" instead
 */
export function FlashLiveFigure({ overview, market, from, to, previous, previousDefinitionVersion, open, locale, labels }: {
  overview: string;
  market: string | null;
  from: string | null;
  to: string | null;
  previous: number | null;
  /** The definition the figure compared with followed (addition 0008zu): a different one is marked under the change */
  previousDefinitionVersion?: string | null;
  /** The period is open (a flow's Today, a running week or month, or a source not read since its end): no change shown */
  open: boolean;
  locale: string;
  labels: { loading: string; changeSince: string; changeFlat: string; noCompare: string; openPeriod: string; previousOnText: string | null;
    /** "The figure of <date> was counted by an earlier definition", its date filled in; none without a date */
    definitionEarlier?: string | null;
    /** The words of the split's keys (the order kinds, addition 0008zw: lib/flash splitLabelsOf); a key without one shows itself */
    splitLabels?: Record<string, string> };
}) {
  const [read, setRead] = useState<{ value: number | null; split: FlashSplitItem[] | null; version: string | null } | "loading" | "failed">("loading");
  useEffect(() => {
    const q = new URLSearchParams({ overview, part: "headline", ...(market ? { market } : {}), ...(from ? { from } : {}), ...(to ? { to } : {}) });
    let gone = false;
    fetch(`/api/v1/reports/flash?${q.toString()}`, { headers: { accept: "application/json" } })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))
      .then((j: { data?: { value?: number | null; split?: unknown; definitionVersion?: string | null } }) => {
        if (!gone) {
          setRead({ value: typeof j.data?.value === "number" ? j.data.value : null, split: splitItemsOf(j.data?.split),
            version: typeof j.data?.definitionVersion === "string" ? j.data.definitionVersion : null });
        }
      })
      .catch(() => { if (!gone) setRead("failed"); });
    return () => { gone = true; };
  }, [overview, market, from, to]);
  const n = (x: number) => new Intl.NumberFormat(locale === "nl" ? "nl-NL" : "en-GB", { maximumFractionDigits: 1 }).format(x);
  if (read === "loading") return <p className="text-small text-p4a-muted" data-testid={`flash-live-${overview}`}>{labels.loading}</p>;
  const shown = read === "failed" ? null : read.value;
  // the change as the stored cards write it (lib/flash's changeLineOf, which verify:flash tests)
  const change = changeLineOf(shown, previous, labels.previousOnText, open, labels, n);
  // the headline's split: per device-holding status, each in the subscription app's word (addition 0008zu); the orders per
  // order kind in the reader's language (addition 0008zw)
  // the installed base per model, each by the register's name the database gives with it (addition 0008zy)
  const split = read === "failed" ? null : splitLine(read.split, n, (k, x) => x.label ?? labels.splitLabels?.[k] ?? k);
  // a figure compared with one counted by an earlier definition is marked, never read as a change in the business
  const earlier = !open && read !== "failed" && labels.definitionEarlier && definitionChanged(read.version, previousDefinitionVersion, previous)
    ? labels.definitionEarlier : null;
  return (
    <>
      <p className="tabular text-title font-bold text-p4a-heading" data-testid={`flash-live-${overview}`}>{shown === null ? "–" : n(shown)}</p>
      {split ? <p className="tabular text-small text-p4a-body" data-testid={`flash-split-${overview}`}>{split}</p> : null}
      <p className="text-small text-p4a-muted">{change}</p>
      {earlier ? <p className="text-small text-p4a-muted" data-testid={`flash-definition-${overview}`}>{earlier}</p> : null}
    </>
  );
}
