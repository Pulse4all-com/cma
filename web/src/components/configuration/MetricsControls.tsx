"use client";

/**
 * The client half of Configuration → Metrics: the filter row (words, page, surface, source owner,
 * status) over the server-rendered cards, the anchor opener (a #key in the address opens that card
 * and scrolls to it, so tile hints can link straight to a figure) and the Copy button of a
 * verification query. Filtering toggles the cards' hidden attribute, so the catalog itself stays
 * server-rendered and costs no data read. The keyboard: / focuses the words filter (the shared
 * data-shortcut hook), Enter on a card's summary toggles it (native details).
 */
import { useCallback, useEffect, useRef, useState } from "react";
import type { Copy } from "@/lib/copy";
import { matchesFilter, type MetricsFilter } from "@/lib/metrics";
import { Keycap } from "../primitives";

const EMPTY: MetricsFilter = { q: "", page: "", surface: "", owner: "", status: "" };

function applyFilter(f: MetricsFilter): number {
  let shown = 0;
  for (const card of document.querySelectorAll<HTMLElement>("[data-metric-card]")) {
    // The card carries its facts as data attributes, written by the server render (MetricsCatalog)
    const show = matchesFilter({
      key: card.id,
      page: card.dataset.page ?? "",
      surface: card.dataset.surface ?? "",
      owners: (card.dataset.owners ?? "").split(" ").filter(Boolean),
      statuses: (card.dataset.statuses ?? "").split(" ").filter(Boolean),
      text: card.dataset.text ?? "",
    }, f);
    card.hidden = !show;
    if (show) shown += 1;
  }
  for (const group of document.querySelectorAll<HTMLElement>("[data-metric-group]")) {
    group.hidden = !group.querySelector("[data-metric-card]:not([hidden])");
  }
  const empty = document.querySelector<HTMLElement>("[data-metrics-empty]");
  if (empty) empty.hidden = shown > 0;
  return shown;
}

export function MetricsFilterBar({ copy, choices, total, statusLabels }: {
  copy: Copy;
  choices: { pages: string[]; surfaces: string[]; owners: string[]; statuses: string[] };
  total: number;
  statusLabels: Record<string, string>;
}) {
  const t = copy.configMetrics;
  const [filter, setFilter] = useState<MetricsFilter>(EMPTY);
  const [shown, setShown] = useState(total);

  const set = useCallback((patch: Partial<MetricsFilter>) => {
    setFilter((f) => {
      const next = { ...f, ...patch };
      setShown(applyFilter(next));
      return next;
    });
  }, []);

  // A #key in the address opens that figure's card and scrolls to it (tile hints link here)
  useEffect(() => {
    const open = () => {
      const key = decodeURIComponent(window.location.hash.slice(1));
      if (!key) return;
      const card = document.getElementById(key);
      if (card instanceof HTMLDetailsElement) {
        card.open = true;
        card.hidden = false;
        card.scrollIntoView({ block: "start" });
      }
    };
    open();
    window.addEventListener("hashchange", open);
    return () => window.removeEventListener("hashchange", open);
  }, []);

  const select = (label: string, value: string, options: [string, string][], onChange: (v: string) => void) => (
    <label className="flex flex-col gap-1 text-caption font-semibold text-p4a-body">
      {label}
      <select
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="h-10 rounded-input border border-p4a-border bg-white px-2 text-small font-normal"
      >
        <option value="">{t.filterAll}</option>
        {options.map(([v, l]) => (
          <option key={v} value={v}>{l}</option>
        ))}
      </select>
    </label>
  );

  return (
    <div className="flex flex-wrap items-end gap-4" data-testid="metrics-filter">
      <label className="flex flex-col gap-1 text-caption font-semibold text-p4a-body">
        <span className="flex items-center gap-2">{t.filterLabel} <Keycap>/</Keycap></span>
        <input
          type="search"
          data-shortcut="/"
          aria-keyshortcuts="/"
          placeholder={t.filterHint}
          value={filter.q}
          onChange={(e) => set({ q: e.target.value })}
          className="h-10 w-72 rounded-input border border-p4a-border bg-white px-3 text-small font-normal placeholder:text-p4a-muted"
        />
      </label>
      {select(t.filterPage, filter.page, choices.pages.map((p) => [p, p]), (v) => set({ page: v }))}
      {select(t.filterSurface, filter.surface, choices.surfaces.map((s) => [s, s]), (v) => set({ surface: v }))}
      {select(t.filterOwner, filter.owner, choices.owners.map((o) => [o, o]), (v) => set({ owner: v }))}
      {select(t.filterStatus, filter.status, choices.statuses.map((s) => [s, statusLabels[s] ?? s]), (v) => set({ status: v }))}
      <p className="pb-2 text-caption text-p4a-grey" data-testid="metrics-count">
        {t.countShown.replace("{n}", String(shown)).replace("{total}", String(total))} · {t.keyboard}
      </p>
    </div>
  );
}

export function CopyQueryButton({ text, label, copied }: { text: string; label: string; copied: string }) {
  const [done, setDone] = useState(false);
  const timer = useRef<number | undefined>(undefined);
  useEffect(() => () => window.clearTimeout(timer.current), []);
  return (
    <button
      type="button"
      className="mt-2 inline-flex h-8 items-center rounded-button border border-p4a-deepblue px-3 text-caption font-semibold text-p4a-deepblue hover:bg-p4a-bgblue"
      onClick={() => {
        void navigator.clipboard?.writeText(text).then(() => {
          setDone(true);
          window.clearTimeout(timer.current);
          timer.current = window.setTimeout(() => setDone(false), 1500);
        });
      }}
    >
      {done ? copied : label}
    </button>
  );
}
