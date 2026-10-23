/**
 * Configuration → Metrics: the metric catalog, rendered from the build's copy of
 * docs/metrics/catalog.json (src/lib/metrics-catalog.json) with the tenant's current setting values
 * next to the defaults. Server components; the only data read is the settings list the page passes
 * in. One section per page in the catalog's order, one card per figure, collapsed by default
 * (native details, so Enter on the summary toggles it); every card carries its key as the anchor.
 * Catalog texts are English on purpose (the catalog is written in English); the chrome follows the
 * viewer's language. Status chips in the neutral and warning tones, never a red surface.
 */
import type { Copy } from "@/lib/copy";
import { cardFacts, entriesByPage, filterChoices, type MetricEntry } from "@/lib/metrics";
import { Badge } from "../primitives";
import { CopyQueryButton, MetricsFilterBar } from "./MetricsControls";

const STATUS_LABEL: Record<MetricEntry["status"][number], keyof Copy["configMetrics"]> = {
  verified: "statusVerified",
  discrepancy: "statusDiscrepancy",
  ambiguous: "statusAmbiguous",
  prerequisite_missing: "statusPrerequisiteMissing",
  cadence_unconfirmed: "statusCadenceUnconfirmed",
};

function StatusChips({ entry, copy }: { entry: MetricEntry; copy: Copy }) {
  return (
    <span className="flex flex-wrap gap-1">
      {entry.status.map((s) => (
        <Badge key={s} tone={s === "verified" ? "neutral" : "warning"}>{copy.configMetrics[STATUS_LABEL[s]]}</Badge>
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

function SourcesTable({ entry, copy, datamap }: { entry: MetricEntry; copy: Copy; datamap: string | null }) {
  const t = copy.configMetrics;
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
                  <a
                    href={`${datamap}#${s.table}`}
                    target="_blank"
                    rel="noreferrer noopener"
                    title={t.datamapHint}
                    className="text-p4a-deepblue hover:underline"
                  >
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

function SettingsTable({ entry, copy, current }: { entry: MetricEntry; copy: Copy; current: Map<string, { value: string; isDefault: boolean }> }) {
  const t = copy.configMetrics;
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

function MetricCard({ entry, copy, current, datamap }: {
  entry: MetricEntry; copy: Copy; current: Map<string, { value: string; isDefault: boolean }>; datamap: string | null;
}) {
  const t = copy.configMetrics;
  const facts = cardFacts(entry);
  return (
    <details
      id={entry.key}
      className="group rounded-card border border-p4a-border bg-white"
      data-metric-card=""
      data-page={facts.page}
      data-surface={facts.surface}
      data-owners={facts.owners.join(" ")}
      data-statuses={facts.statuses.join(" ")}
      data-text={facts.text}
    >
      <summary className="grid cursor-pointer list-none grid-cols-[1fr_auto] items-start gap-x-4 gap-y-1 rounded-card px-4 py-3 hover:bg-p4a-bgblue/50 [&::-webkit-details-marker]:hidden">
        <span className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
          <code className="text-small font-semibold text-p4a-deepblue">{entry.key}</code>
          {entry.tile ? <span className="text-small font-semibold text-p4a-body">{entry.tile}</span> : <span className="text-caption text-p4a-muted">{entry.surface === "export" ? t.exportColumn : t.apiOnly}</span>}
          <a href={entry.page} className="text-caption text-p4a-deepblue hover:underline" title={t.openPage}>{entry.page}</a>
        </span>
        <StatusChips entry={entry} copy={copy} />
        <span className="col-span-2 text-small text-p4a-muted">{entry.definition}</span>
      </summary>
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
        <Field label={t.sourcesTitle}><SourcesTable entry={entry} copy={copy} datamap={datamap} /></Field>
        <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
          <Field label={t.filtersTitle}>
            <ul className="list-disc pl-5">{entry.filters.map((f, i) => <li key={i}>{f}</li>)}</ul>
          </Field>
          <div className="flex flex-col gap-4">
            <Field label={t.timeTitle}>{entry.time}</Field>
            {entry.comparison ? <Field label={t.comparisonTitle}>{entry.comparison}</Field> : null}
          </div>
        </div>
        {entry.settings.length > 0 ? <Field label={t.settingsTitle}><SettingsTable entry={entry} copy={copy} current={current} /></Field> : null}
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
                  <span className="ml-1 text-caption text-p4a-grey">
                    {p.check ? t.prereqCheck.replace("{check}", p.check) : t.prereqNoCheck}
                  </span>
                </li>
              ))}
            </ul>
          </Field>
        ) : null}
        <Field label={t.docsTitle}>{entry.docs.join("; ")}</Field>
        {entry.notes ? <Field label={t.notesTitle}><p className="whitespace-pre-wrap">{entry.notes}</p></Field> : null}
      </div>
    </details>
  );
}

export function MetricsCatalogView({ entries, copy, current, datamap }: {
  entries: readonly MetricEntry[];
  copy: Copy;
  current: Map<string, { value: string; isDefault: boolean }>;
  datamap: string | null;
}) {
  const t = copy.configMetrics;
  const choices = filterChoices(entries);
  const statusLabels = Object.fromEntries(
    (Object.keys(STATUS_LABEL) as (keyof typeof STATUS_LABEL)[]).map((s) => [s, copy.configMetrics[STATUS_LABEL[s]]]),
  );
  return (
    <div className="flex flex-col gap-6" data-testid="metrics-catalog">
      <MetricsFilterBar copy={copy} choices={choices} total={entries.length} statusLabels={statusLabels} />
      {entriesByPage(entries).map((group) => (
        <section key={group.page} aria-label={group.page} data-metric-group="">
          <h2 className="mb-2 text-panel font-semibold text-p4a-heading">
            {group.page}
            <span className="ml-2 text-caption font-normal text-p4a-grey">{group.entries.length}</span>
          </h2>
          <div className="flex flex-col gap-2">
            {group.entries.map((e) => (
              <MetricCard key={e.key} entry={e} copy={copy} current={current} datamap={datamap} />
            ))}
          </div>
        </section>
      ))}
      <p hidden data-metrics-empty="" className="text-body text-p4a-muted">{t.noMatches}</p>
    </div>
  );
}
