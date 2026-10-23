"use client";

/**
 * Configuration → Metrics: the metric catalog, bundled from the build's copy of
 * docs/metrics/catalog.json (src/lib/metrics-catalog.json, a generated verbatim copy) with the
 * tenant's current setting values next to the defaults. A client module on purpose: the catalog is
 * large (489 figures), so the JSON ships once as a cacheable build chunk, the server renders only
 * the collapsed summaries, and a card's full body renders when it opens (Enter on its summary, a
 * click, or a #key in the address — the anchor the tile hints link to). The page passes only the
 * chrome strings, the settings and the data map's address; the only data read stays the settings.
 * Catalog texts are English on purpose; the chrome follows the viewer's language. Status chips in
 * the neutral and warning tones, never a red surface. / focuses the words filter (the shared
 * data-shortcut hook reads the attribute).
 */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { Copy } from "@/lib/copy";
import {
  cardFacts, entriesByPage, filterChoices, matchesFilter, type MetricEntry, type MetricCatalog, type MetricsFilter,
} from "@/lib/metrics";
import rawCatalog from "@/lib/metrics-catalog.json";
import { Badge, Keycap } from "../primitives";

const CATALOG = rawCatalog as unknown as MetricCatalog;
const EMPTY: MetricsFilter = { q: "", page: "", surface: "", owner: "", status: "" };

type Chrome = Copy["configMetrics"];
type Current = Map<string, { value: string; isDefault: boolean }>;

const STATUS_LABEL: Record<MetricEntry["status"][number], keyof Chrome> = {
  verified: "statusVerified",
  discrepancy: "statusDiscrepancy",
  ambiguous: "statusAmbiguous",
  prerequisite_missing: "statusPrerequisiteMissing",
  cadence_unconfirmed: "statusCadenceUnconfirmed",
};

function StatusChips({ entry, t }: { entry: MetricEntry; t: Chrome }) {
  return (
    <span className="flex flex-wrap gap-1">
      {entry.status.map((s) => (
        <Badge key={s} tone={s === "verified" ? "neutral" : "warning"}>{t[STATUS_LABEL[s]]}</Badge>
      ))}
    </span>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <h4 className="text-caption font-semibold text-p4a-grey">{label}</h4>
      <div className="mt-1 text-small text-p4a-body">{children}</div>
    </div>
  );
}

function CopyQueryButton({ text, label, copied }: { text: string; label: string; copied: string }) {
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

function SourcesTable({ entry, t, datamap }: { entry: MetricEntry; t: Chrome; datamap: string | null }) {
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-small">
        <thead>
          <tr className="bg-p4a-bgblue text-left text-caption font-semibold text-p4a-heading">
            <th className="rounded-l-button px-2 py-1">{t.sourceTable}</th>
            <th className="px-2 py-1">{t.sourceColumns}</th>
            <th className="px-2 py-1">{t.sourceOwner}</th>
            <th className="px-2 py-1">{t.sourceFedBy}</th>
            <th className="rounded-r-button px-2 py-1">{t.sourceCadence}</th>
          </tr>
        </thead>
        <tbody>
          {entry.sources.map((s, i) => (
            <tr key={`${s.table}-${i}`} className="border-b border-p4a-border align-top last:border-0">
              <td className="whitespace-nowrap px-2 py-1 font-semibold">
                {datamap ? (
                  <a href={`${datamap}#${s.table}`} target="_blank" rel="noreferrer noopener" title={t.datamapHint} className="text-p4a-deepblue hover:underline">
                    {s.table}
                  </a>
                ) : (
                  s.table
                )}
              </td>
              <td className="px-2 py-1">{s.columns.join(", ")}</td>
              <td className="whitespace-nowrap px-2 py-1">{s.owner}</td>
              <td className="px-2 py-1">{s.fed_by}</td>
              <td className="px-2 py-1">{s.cadence}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function SettingsTable({ entry, t, current }: { entry: MetricEntry; t: Chrome; current: Current }) {
  return (
    <table className="w-full text-small">
      <thead>
        <tr className="bg-p4a-bgblue text-left text-caption font-semibold text-p4a-heading">
          <th className="rounded-l-button px-2 py-1">{t.settingKey}</th>
          <th className="px-2 py-1">{t.settingCurrent}</th>
          <th className="rounded-r-button px-2 py-1">{t.settingDefault}</th>
        </tr>
      </thead>
      <tbody>
        {entry.settings.map((s) => {
          const live = current.get(s.key);
          return (
            <tr key={s.key} className="border-b border-p4a-border align-top last:border-0">
              <td className="whitespace-nowrap px-2 py-1 font-semibold">{s.key}</td>
              <td className="px-2 py-1">
                {live ? live.value : <span className="text-p4a-muted">{t.settingUnset}</span>}
                {live?.isDefault ? <span className="ml-1 text-caption text-p4a-grey">({t.settingUnset})</span> : null}
              </td>
              <td className="px-2 py-1 text-p4a-muted">{s.default}</td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}

/** A card's full body; rendered only while the card is open, so the page stays light */
function CardBody({ entry, t, current, datamap }: { entry: MetricEntry; t: Chrome; current: Current; datamap: string | null }) {
  return (
    <div className="flex flex-col gap-4 border-t border-p4a-border px-4 py-4">
      <Field label={t.formula}><pre className="whitespace-pre-wrap rounded-button bg-p4a-bgblue/40 p-2 font-mono text-caption text-p4a-body">{entry.formula}</pre></Field>
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <Field label={t.unit}>{entry.unit}</Field>
        <Field label={t.grain}>{entry.grain.join(", ")}</Field>
        <Field label={t.permissionsTitle}>
          {entry.permissions.anyOf.join(" or ")}
          {entry.permissions.perPerson ? <span className="block text-caption text-p4a-grey">{t.perPersonNote.replace("{key}", entry.permissions.perPerson)}</span> : null}
        </Field>
        <Field label={t.refreshTitle}>{entry.refresh}</Field>
      </div>
      <Field label={t.sourcesTitle}><SourcesTable entry={entry} t={t} datamap={datamap} /></Field>
      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <Field label={t.filtersTitle}>
          <ul className="list-disc pl-5">{entry.filters.map((f, i) => <li key={i}>{f}</li>)}</ul>
        </Field>
        <div className="flex flex-col gap-4">
          <Field label={t.timeTitle}>{entry.time}</Field>
          {entry.comparison ? <Field label={t.comparisonTitle}>{entry.comparison}</Field> : null}
        </div>
      </div>
      {entry.settings.length > 0 ? <Field label={t.settingsTitle}><SettingsTable entry={entry} t={t} current={current} /></Field> : null}
      <Field label={t.computedTitle}>
        <ul className="list-disc pl-5">
          {entry.computed_in.sql.map((s) => <li key={s.object}><code>{s.object}</code> ({s.migration})</li>)}
          {entry.computed_in.ts.map((x) => <li key={`${x.file}:${x.export}`}><code>{x.export}</code> in {x.file}</li>)}
        </ul>
      </Field>
      <Field label={t.verifyTitle}>
        {entry.verify_sql ? (
          <div data-verify-sql="">
            <p className="mb-1 text-caption text-p4a-grey">{t.verifyHint}</p>
            <pre className="overflow-x-auto rounded-button bg-p4a-inkt p-3 font-mono text-caption text-p4a-bgblue-dark"><code>{entry.verify_sql}</code></pre>
            <CopyQueryButton text={entry.verify_sql} label={t.copyQuery} copied={t.copied} />
          </div>
        ) : (
          <p className="text-p4a-muted">{t.verifyNone}</p>
        )}
      </Field>
      <Field label={t.fixtureTitle}>{entry.fixture_check}</Field>
      {entry.prerequisites.length > 0 ? (
        <Field label={t.prerequisitesTitle}>
          <ul className="list-disc pl-5">
            {entry.prerequisites.map((p, i) => (
              <li key={i}>
                {p.item}
                <span className="ml-1 text-caption text-p4a-grey">{p.check ? t.prereqCheck.replace("{check}", p.check) : t.prereqNoCheck}</span>
              </li>
            ))}
          </ul>
        </Field>
      ) : null}
      <Field label={t.docsTitle}>{entry.docs.join("; ")}</Field>
      {entry.notes ? <Field label={t.notesTitle}><p className="whitespace-pre-wrap">{entry.notes}</p></Field> : null}
    </div>
  );
}

function MetricCard({ entry, t, current, datamap, open, onToggle }: {
  entry: MetricEntry; t: Chrome; current: Current; datamap: string | null; open: boolean; onToggle: (key: string, open: boolean) => void;
}) {
  return (
    <details
      id={entry.key}
      open={open}
      onToggle={(e) => onToggle(entry.key, (e.target as HTMLDetailsElement).open)}
      className="rounded-card border border-p4a-border bg-white"
      data-metric-card=""
    >
      <summary className="grid cursor-pointer list-none grid-cols-[1fr_auto] items-start gap-x-4 gap-y-1 rounded-card px-4 py-3 hover:bg-p4a-bgblue/50 [&::-webkit-details-marker]:hidden">
        <span className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
          <code className="text-small font-semibold text-p4a-deepblue">{entry.key}</code>
          {entry.tile
            ? <span className="text-small font-semibold text-p4a-body">{entry.tile}</span>
            : <span className="text-caption text-p4a-muted">{entry.surface === "export" ? t.exportColumn : t.apiOnly}</span>}
          <a href={entry.page} className="text-caption text-p4a-deepblue hover:underline" title={t.openPage}>{entry.page}</a>
        </span>
        <StatusChips entry={entry} t={t} />
        <span className="col-span-2 text-small text-p4a-muted">{entry.definition}</span>
      </summary>
      {open ? <CardBody entry={entry} t={t} current={current} datamap={datamap} /> : null}
    </details>
  );
}

export function MetricsCatalogView({ t, settings, datamap }: {
  /** The page's chrome strings (copy.configMetrics) */
  t: Chrome;
  /** The tenant's effective settings, the page's one data read */
  settings: readonly { key: string; value: string; isDefault: boolean }[];
  datamap: string | null;
}) {
  const entries = CATALOG.entries;
  const current: Current = useMemo(() => new Map(settings.map((s) => [s.key, { value: s.value, isDefault: s.isDefault }])), [settings]);
  const choices = useMemo(() => filterChoices(entries), [entries]);
  const facts = useMemo(() => new Map(entries.map((e) => [e.key, cardFacts(e)])), [entries]);
  const [filter, setFilter] = useState<MetricsFilter>(EMPTY);
  const [open, setOpen] = useState<ReadonlySet<string>>(new Set());

  const onToggle = useCallback((key: string, isOpen: boolean) => {
    setOpen((prev) => {
      if (prev.has(key) === isOpen) return prev;
      const next = new Set(prev);
      if (isOpen) next.add(key);
      else next.delete(key);
      return next;
    });
  }, []);

  // A #key in the address opens that figure's card and scrolls to it (the tile hints link here)
  useEffect(() => {
    const openHash = () => {
      const key = decodeURIComponent(window.location.hash.slice(1));
      if (!key || !facts.has(key)) return;
      setOpen((prev) => (prev.has(key) ? prev : new Set([...prev, key])));
      requestAnimationFrame(() => document.getElementById(key)?.scrollIntoView({ block: "start" }));
    };
    openHash();
    window.addEventListener("hashchange", openHash);
    return () => window.removeEventListener("hashchange", openHash);
  }, [facts]);

  const shown = entries.filter((e) => {
    const f = facts.get(e.key);
    return f !== undefined && matchesFilter(f, filter);
  });
  const groups = entriesByPage(shown);

  const select = (label: string, value: string, options: [string, string][], onChange: (v: string) => void) => (
    <label className="flex flex-col gap-1 text-caption font-semibold text-p4a-body">
      {label}
      <select value={value} onChange={(e) => onChange(e.target.value)} className="h-10 rounded-input border border-p4a-border bg-white px-2 text-small font-normal">
        <option value="">{t.filterAll}</option>
        {options.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
      </select>
    </label>
  );
  const statusLabel = (s: string) => t[STATUS_LABEL[s as MetricEntry["status"][number]]] ?? s;

  return (
    <div className="flex flex-col gap-6" data-testid="metrics-catalog">
      <div className="flex flex-wrap items-end gap-4" data-testid="metrics-filter">
        <label className="flex flex-col gap-1 text-caption font-semibold text-p4a-body">
          <span className="flex items-center gap-2">{t.filterLabel} <Keycap>/</Keycap></span>
          <input
            type="search"
            data-shortcut="/"
            aria-keyshortcuts="/"
            placeholder={t.filterHint}
            value={filter.q}
            onChange={(e) => setFilter((f) => ({ ...f, q: e.target.value }))}
            className="h-10 w-72 rounded-input border border-p4a-border bg-white px-3 text-small font-normal placeholder:text-p4a-muted"
          />
        </label>
        {select(t.filterPage, filter.page, choices.pages.map((p) => [p, p]), (v) => setFilter((f) => ({ ...f, page: v })))}
        {select(t.filterSurface, filter.surface, choices.surfaces.map((s) => [s, s]), (v) => setFilter((f) => ({ ...f, surface: v })))}
        {select(t.filterOwner, filter.owner, choices.owners.map((o) => [o, o]), (v) => setFilter((f) => ({ ...f, owner: v })))}
        {select(t.filterStatus, filter.status, choices.statuses.map((s) => [s, statusLabel(s)]), (v) => setFilter((f) => ({ ...f, status: v })))}
        <p className="pb-2 text-caption text-p4a-grey" data-testid="metrics-count">
          {t.countShown.replace("{n}", String(shown.length)).replace("{total}", String(entries.length))} · {t.keyboard}
        </p>
      </div>
      {groups.map((group) => (
        <section key={group.page} aria-label={group.page} data-metric-group="">
          <h2 className="mb-2 text-panel font-semibold text-p4a-heading">
            {group.page}
            <span className="ml-2 text-caption font-normal text-p4a-grey">{group.entries.length}</span>
          </h2>
          <div className="flex flex-col gap-2">
            {group.entries.map((e) => (
              <MetricCard key={e.key} entry={e} t={t} current={current} datamap={datamap} open={open.has(e.key)} onToggle={onToggle} />
            ))}
          </div>
        </section>
      ))}
      {shown.length === 0 ? <p data-metrics-empty="" className="text-body text-p4a-muted">{t.noMatches}</p> : null}
    </div>
  );
}
