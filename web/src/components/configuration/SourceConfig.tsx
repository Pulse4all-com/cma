"use client";

/**
 * One connection's page (Sources, addition 0008e): the connection itself (name, vendor, kind, account,
 * status, secret names as names only), its non-secret settings with a live preview of a record link,
 * and the sections its kind has: pipelines, forms, call outcomes and fields for customer records; lines
 * and tags for telephony, and since addition 0008i its missed-call reasons (label, in the service level,
 * needs a callback); the store for a shop. Every write goes to a route that calls the database
 * function owning the value, and every answer re-reads the page, so a table shows the database's state.
 * Nothing here names a vendor, a pipeline, a form, a market or an outcome.
 *
 * Keyboard: B back to all sources, N renames, S adds a setting, F applies a rule to forms, O to call
 * outcomes, A adds or edits the store; Ctrl+Enter saves a dialog, Esc closes it.
 */
import Link from "next/link";
import { useMemo, useRef, useState } from "react";
import type { Copy, Locale } from "@/lib/copy";
import type { MarketConfig, SourceDetail, SourceForm, SourceKind, SourceLine, SourceMissedReason, SourceSettings, SourceStore } from "@/lib/data";
import {
  coerceSettingValue, kindChoices, recordTypeOfSetting, recordUrlPreview, settingKeyProblem, settingsSize, settingText, sourceSections,
} from "@/lib/sources";
import { dateKeyInZone, fmtDate } from "@/lib/time";
import { ConfirmDialog } from "../ConfirmDialog";
import { HeaderHint } from "../HeaderHint";
import { Badge, Button, Card, Keycap } from "../primitives";
import { FormRuleDialog, OutcomeRuleDialog } from "./SourceRules";
import { kindLabel } from "./SourcesList";
import { FlagField, FormDialog, SaveNote, field, label, send, td, th, useSave } from "./shared";

const EXAMPLE_ID = "123456789";

type Row = { id: number; key: string; text: string; isNew: boolean };

export function SourceConfig({ detail, markets, copy, locale, timeZone }: {
  detail: SourceDetail; markets: MarketConfig[]; copy: Copy; locale: Locale; timeZone: string;
}) {
  const c = copy.configuration;
  const t = copy.configSources;
  const conn = detail.connection;
  const base = `/api/v1/configuration/sources/${conn.id}`;
  const { state, save } = useSave(c);
  // a fresh key per opening, so every dialog starts from the values as they stand
  const seq = useRef(0);
  const tick = () => ++seq.current;
  const hint = (labelText: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", labelText)} text={text} />;
  const sections = sourceSections(conn.kind, conn.heldKinds);
  const marketCodes = markets.map((m) => m.code);

  // ---- connection
  const [renaming, setRenaming] = useState<number | null>(null);
  const [name, setName] = useState(conn.name);
  const [nameProblem, setNameProblem] = useState<string | null>(null);
  const [confirmOff, setConfirmOff] = useState(false);
  const choices = kindChoices(conn.heldKinds);
  const [kind, setKind] = useState<SourceKind | "">(conn.kind ?? "");

  // ---- settings
  const original = conn.settings;
  const [rows, setRows] = useState<Row[]>(() => Object.entries(original).map(([key, v], i) => ({ id: -(i + 1), key, text: settingText(v), isNew: false })));
  const [settingsProblemText, setSettingsProblemText] = useState<string | null>(null);
  const edited: SourceSettings = useMemo(() => {
    const out: SourceSettings = {};
    for (const r of rows) if (r.key.trim()) out[r.key.trim()] = coerceSettingValue(r.text, original[r.key.trim()]);
    return out;
  }, [rows, original]);

  // ---- dialogs
  const [formEdit, setFormEdit] = useState<{ form: SourceForm; opened: number } | null>(null);
  const [formDraft, setFormDraft] = useState<{ isCounted: boolean; leadSource: string; market: string }>({ isCounted: true, leadSource: "", market: "" });
  const [formProblem, setFormProblem] = useState<string | null>(null);
  const [ruleOpen, setRuleOpen] = useState<{ kind: "forms" | "outcomes"; opened: number } | null>(null);
  const [storeEdit, setStoreEdit] = useState<number | null>(null);
  const [store, setStore] = useState<SourceStore>(detail.store ?? { handle: "", name: "", market: marketCodes[0] ?? "", currency: "", timeZone: "" });
  const [storeProblem, setStoreProblem] = useState<string | null>(null);
  // switching a line off removes its stored calls (addition 0008f), so it asks first, on Cancel (an irreversible
  // confirmation); the box stays ticked until the save is confirmed; switching on does not ask
  const [lineOff, setLineOff] = useState<SourceLine | null>(null);
  // a missed-call reason's label (addition 0008i); its two switches save at once from the table
  const [reasonEdit, setReasonEdit] = useState<{ reason: SourceMissedReason; opened: number } | null>(null);
  const [reasonLabel, setReasonLabel] = useState("");
  const [reasonProblem, setReasonProblem] = useState<string | null>(null);

  async function rename() {
    const v = name.trim();
    if (v.length === 0 || v.length > 100) {
      setNameProblem(t.nameProblem);
      return;
    }
    if (await save(() => send("PUT", base, { name: v }))) setRenaming(null);
  }

  async function saveSettings() {
    setSettingsProblemText(null);
    const keys = rows.map((r) => r.key.trim()).filter(Boolean);
    for (const k of keys) {
      const p = settingKeyProblem(k, [], false);
      if (p === "key") return setSettingsProblemText(`${k}: ${t.settingKeyProblem}`);
      if (p === "secret") return setSettingsProblemText(`${k}: ${t.settingSecretProblem}`);
      if (keys.filter((x) => x === k).length > 1) return setSettingsProblemText(`${k}: ${t.settingDuplicate}`);
    }
    if (settingsSize(edited) > 4096) return setSettingsProblemText(t.settingsTooLarge);
    if (JSON.stringify(edited) === JSON.stringify(original)) return setSettingsProblemText(t.settingsNoChange);
    await save(() => send("PUT", `${base}/settings`, { settings: edited }), t.settingSecretProblem);
  }

  function openForm(f: SourceForm) {
    setFormDraft({ isCounted: f.isCounted, leadSource: f.leadSource ?? "", market: f.market ?? "" });
    setFormProblem(null);
    setFormEdit({ form: f, opened: tick() });
  }

  async function saveForm() {
    if (!formEdit) return;
    const lead = formDraft.leadSource.trim();
    if (lead.length > 60) return setFormProblem(t.ruleLeadSourceProblem);
    const body = { forms: [{ formId: formEdit.form.formId, isCounted: formDraft.isCounted, leadSource: lead || null, market: formDraft.market || null }] };
    if (await save(() => send("PUT", `${base}/forms`, body))) setFormEdit(null);
  }

  /** One reason as it would be saved: the current label and switches, with the change given */
  function sendReason(r: SourceMissedReason, change: Partial<Pick<SourceMissedReason, "label" | "countsInServiceLevel" | "needsCallback">>) {
    const body = { code: r.code, label: r.label, countsInServiceLevel: r.countsInServiceLevel, needsCallback: r.needsCallback, ...change };
    return save(() => send("PUT", `${base}/missed-reasons`, body));
  }

  async function saveReasonLabel() {
    if (!reasonEdit) return;
    const v = reasonLabel.trim();
    if (v.length === 0 || v.length > 100) return setReasonProblem(t.reasonLabelProblem);
    if (await sendReason(reasonEdit.reason, { label: v })) setReasonEdit(null);
  }

  async function saveStore() {
    const s = { ...store, handle: store.handle.trim(), name: store.name.trim(), currency: store.currency.trim().toUpperCase(), timeZone: store.timeZone.trim() };
    if (!/^[a-z0-9-]{1,60}$/.test(s.handle) || !s.name || s.name.length > 80 || !s.market || !/^[A-Z]{3}$/.test(s.currency) || !s.timeZone) {
      setStoreProblem(t.storeProblem);
      return;
    }
    if (await save(() => send("PUT", `${base}/store`, s), t.handleTaken)) setStoreEdit(null);
  }

  const settingPreview = (key: string, text: string) => {
    const type = recordTypeOfSetting(key);
    if (type === null) return null;
    const sample = detail.sampleIds[type];
    const url = recordUrlPreview(text.trim(), edited, conn.accountId, sample ?? EXAMPLE_ID);
    return (
      <p className="mt-1 text-caption text-p4a-muted" data-testid={`preview-${key}`}>
        {t.preview} {sample ? t.previewFor.replace("{id}", sample) : t.previewExample}:{" "}
        {url === null ? <span className="text-p4a-error">{t.previewNone}</span>
          : sample ? <a href={url} target="_blank" rel="noopener noreferrer" className="break-all text-p4a-deepblue underline">{url}</a>
          : <span className="break-all">{url}</span>}
      </p>
    );
  };

  return (
    <>
      <div className="flex items-center justify-between gap-4">
        <Link href="/configuration/sources" data-shortcut="b" className="inline-flex items-center gap-3 text-small font-semibold text-p4a-deepblue hover:underline">
          ← {t.back} <Keycap>B</Keycap>
        </Link>
        <SaveNote state={state} c={c} />
      </div>

      {/* ---- the connection ---- */}
      <Card title={t.sectionConnection}>
        <dl className="grid grid-cols-[14rem_1fr] gap-x-6 gap-y-3 text-body" data-testid="source-connection">
          <dt className="font-semibold">{t.name}</dt>
          <dd className="flex items-center gap-3">
            <span>{conn.name}</span>
            <Button variant="outlined" size="sm" shortcut="N" data-shortcut="n" onClick={() => { setName(conn.name); setNameProblem(null); setRenaming(tick()); }}>{c.edit}</Button>
          </dd>
          <dt className="font-semibold">{t.vendor}</dt>
          <dd>{conn.adapter}</dd>
          <dt className="font-semibold">{t.kind}</dt>
          <dd className="flex flex-wrap items-center gap-3">
            <span>{kindLabel(conn.kind, t)}</span>
            <select aria-label={t.kindChoose} className={field} value={kind} onChange={(e) => setKind(e.target.value as SourceKind | "")}>
              {conn.kind === null ? <option value="">{t.kindChoose}</option> : null}
              {choices.map((k) => <option key={k} value={k}>{kindLabel(k, t)}</option>)}
            </select>
            <Button variant="outlined" size="sm" disabled={kind === "" || kind === conn.kind}
              onClick={() => save(() => send("PUT", base, { kind }), t.kindConflict)}>{t.kindSave}</Button>
            <span className="w-full text-caption text-p4a-muted">{t.kindHint}{conn.heldKinds.length > 0 ? ` ${t.kindLocked}` : ""}</span>
          </dd>
          <dt className="font-semibold">{t.account}</dt>
          <dd className="tabular-nums">{conn.accountId}</dd>
          <dt className="font-semibold">{t.status}</dt>
          <dd className="flex items-center gap-3">
            {conn.isActive ? <Badge tone="success">{t.active}</Badge> : <Badge tone="neutral">{t.inactive}</Badge>}
            {conn.isActive
              ? <Button variant="destructive" size="sm" onClick={() => setConfirmOff(true)}>{t.switchOff}</Button>
              : <Button variant="outlined" size="sm" onClick={() => save(() => send("PUT", base, { isActive: true }))}>{t.switchOn}</Button>}
          </dd>
          <dt className="font-semibold">{t.addressKey}{hint(t.addressKey, t.addressKeyHint)}</dt>
          <dd className="break-all text-small">{conn.key}</dd>
          <dt className="font-semibold">{t.signingSecret}{hint(t.signingSecret, t.secretHint)}</dt>
          <dd className="text-small">{conn.signingSecretName ?? t.noSecret}</dd>
          <dt className="font-semibold">{t.tokenSecret}{hint(t.tokenSecret, t.secretHint)}</dt>
          <dd className="text-small">{conn.tokenSecretName ?? t.noSecret}</dd>
        </dl>
      </Card>

      {/* ---- settings ---- */}
      <Card title={t.sectionSettings}>
        <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{t.settingsIntro} {t.settingsNever}</p>
        {sections.includes("missedReasons") ? <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted" data-testid="call-link-hint">{t.callLinkHint}</p> : null}
        <table className="w-full border-collapse text-body" data-testid="source-settings">
          <thead className="bg-p4a-bgblue text-small text-p4a-heading">
            <tr><th className={`${th} w-72`}>{t.settingKey}</th><th className={th}>{t.settingValue}</th><th className={th}></th></tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id}>
                <td className={td}>
                  {r.isNew
                    ? <input aria-label={t.settingKey} className={`${field} w-full`} value={r.key} maxLength={60} onChange={(e) => setRows(rows.map((x) => (x.id === r.id ? { ...x, key: e.target.value } : x)))} />
                    : <span className="text-small">{r.key}</span>}
                </td>
                <td className={td}>
                  <input aria-label={`${t.settingValue} ${r.key}`} className={`${field} w-full`} value={r.text} maxLength={2000}
                    onChange={(e) => setRows(rows.map((x) => (x.id === r.id ? { ...x, text: e.target.value } : x)))} />
                  {settingPreview(r.key.trim(), r.text)}
                </td>
                <td className={`${td} text-right`}>
                  <Button variant="text" size="sm" onClick={() => setRows(rows.filter((x) => x.id !== r.id))}>{t.removeSetting}</Button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        <div className="mt-4 flex flex-wrap items-center gap-3">
          <Button variant="outlined" shortcut="S" data-shortcut="s" onClick={() => setRows([...rows, { id: tick(), key: "", text: "", isNew: true }])}>{t.addSetting}</Button>
          <Button variant="primary" onClick={saveSettings} disabled={state.kind === "saving"}>{t.saveSettings}</Button>
          {settingsProblemText ? <p className="text-small text-p4a-error" role="alert">{settingsProblemText}</p> : null}
        </div>
      </Card>

      {conn.kind === "automation" ? <Card><p className="text-body">{t.automationNote}</p></Card> : null}
      {sections.length === 0 && conn.kind !== "automation" ? <Card><p className="text-body text-p4a-muted">{t.noSections}</p></Card> : null}

      {/* ---- pipelines ---- */}
      {sections.includes("pipelines") ? (
        <Card title={t.sectionPipelines}>
          <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{t.pipelinesIntro}</p>
          {detail.pipelines.length === 0 ? <p className="text-body text-p4a-muted">{t.pipelinesEmpty}</p> : (
            <table className="w-full border-collapse text-body" data-testid="source-pipelines">
              <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                <tr>
                  <th className={th}>{t.recordType}</th>
                  <th className={th}>{t.pipeline}</th>
                  <th className={th}>{t.counted}{hint(t.counted, t.hintCounted)}</th>
                  <th className={th}>{t.lead}{hint(t.lead, t.hintLead)}</th>
                </tr>
              </thead>
              <tbody>
                {detail.pipelines.map((p) => (
                  <tr key={`${p.recordType}:${p.pipelineId}`} className={p.isActive ? "" : "text-p4a-muted"}>
                    <td className={`${td} text-small`}>{p.recordType}</td>
                    <td className={td}><span className="font-semibold">{p.label}</span> <span className="text-caption text-p4a-muted">({p.pipelineId})</span></td>
                    <td className={td}>
                      <input type="checkbox" className="h-4 w-4" aria-label={`${t.counted}: ${p.label}`} checked={p.isCounted}
                        onChange={(e) => save(() => send("PUT", `${base}/pipelines`, { recordType: p.recordType, pipelineId: p.pipelineId, isCounted: e.target.checked, isLead: p.isLead }))} />
                    </td>
                    <td className={td}>
                      {p.recordType === "deal" ? (
                        <input type="checkbox" className="h-4 w-4" aria-label={`${t.lead}: ${p.label}`} checked={p.isLead}
                          onChange={(e) => save(() => send("PUT", `${base}/pipelines`, { recordType: p.recordType, pipelineId: p.pipelineId, isCounted: p.isCounted, isLead: e.target.checked }))} />
                      ) : <span className="text-caption text-p4a-muted">{t.leadDealsOnly}</span>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </Card>
      ) : null}

      {/* ---- forms ---- */}
      {sections.includes("forms") ? (
        <Card title={t.sectionForms}>
          <div className="-mt-2 mb-4 flex items-start justify-between gap-4">
            <p className="max-w-3xl text-small text-p4a-muted">{t.formsIntro}</p>
            <Button variant="outlined" shortcut="F" data-shortcut="f" disabled={detail.forms.length === 0} onClick={() => setRuleOpen({ kind: "forms", opened: tick() })}>{t.applyRule}</Button>
          </div>
          {detail.forms.length === 0 ? <p className="text-body text-p4a-muted">{t.formsEmpty}</p> : (
            <table className="w-full border-collapse text-body" data-testid="source-forms">
              <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                <tr>
                  <th className={th}>{t.form}</th>
                  <th className={th}>{t.counted}{hint(t.counted, t.hintFormCounted)}</th>
                  <th className={th}>{t.leadSource}{hint(t.leadSource, t.hintLeadSource)}</th>
                  <th className={th}>{t.market}{hint(t.market, t.hintFormMarket)}</th>
                  <th className={th}></th>
                </tr>
              </thead>
              <tbody>
                {detail.forms.map((f) => (
                  <tr key={f.formId} className={f.isActive ? "" : "text-p4a-muted"} data-form={f.formId}>
                    <td className={td}><span className="font-semibold">{f.name}</span> <span className="text-caption text-p4a-muted">({f.formId})</span></td>
                    <td className={td}>{f.isCounted ? <Badge tone="success">{copy.configSources.on}</Badge> : <Badge tone="neutral">{copy.configSources.off}</Badge>}</td>
                    <td className={`${td} text-small`}>{f.leadSource ?? "–"}</td>
                    <td className={`${td} text-small`}>{f.market ?? t.noMarket}</td>
                    <td className={`${td} text-right`}><Button variant="outlined" size="sm" onClick={() => openForm(f)}>{c.edit}</Button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </Card>
      ) : null}

      {/* ---- call outcomes ---- */}
      {sections.includes("callOutcomes") ? (
        <Card title={t.sectionOutcomes}>
          <div className="-mt-2 mb-4 flex items-start justify-between gap-4">
            <p className="max-w-3xl text-small text-p4a-muted">{t.outcomesIntro}</p>
            <Button variant="outlined" shortcut="O" data-shortcut="o" disabled={detail.callOutcomes.length === 0} onClick={() => setRuleOpen({ kind: "outcomes", opened: tick() })}>{t.applyRuleOutcomes}</Button>
          </div>
          {detail.callOutcomes.length === 0 ? <p className="text-body text-p4a-muted">{t.outcomesEmpty}</p> : (
            <table className="w-full border-collapse text-body" data-testid="source-outcomes">
              <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                <tr><th className={th}>{t.outcome}</th><th className={th}>{t.connected}{hint(t.connected, t.hintConnected)}</th></tr>
              </thead>
              <tbody>
                {detail.callOutcomes.map((o) => (
                  <tr key={o.outcomeRef} className={o.isActive ? "" : "text-p4a-muted"}>
                    <td className={td}><span className="font-semibold">{o.label}</span> <span className="text-caption text-p4a-muted">({o.outcomeRef})</span></td>
                    <td className={td}>
                      <input type="checkbox" className="h-4 w-4" aria-label={`${t.connected}: ${o.label}`} checked={o.isConnected}
                        onChange={(e) => save(() => send("PUT", `${base}/call-outcomes`, { outcomes: [{ outcomeRef: o.outcomeRef, isConnected: e.target.checked }] }))} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </Card>
      ) : null}

      {/* ---- fields (read only in this increment) ---- */}
      {sections.includes("fields") ? (
        <Card title={t.sectionFields}>
          <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{t.fieldsIntro}</p>
          {detail.fields.length === 0 ? <p className="text-body text-p4a-muted">{t.fieldsEmpty}</p> : (
            <table className="w-full border-collapse text-body" data-testid="source-fields">
              <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                <tr><th className={th}>{t.entity}</th><th className={th}>{t.field}</th><th className={`${th} text-right`}>{t.slot}</th><th className={th}>{t.property}{hint(t.property, t.hintProperty)}</th></tr>
              </thead>
              <tbody>
                {detail.fields.map((f) => (
                  <tr key={`${f.entity}:${f.field}:${f.refSystem ?? ""}:${f.slot}`}>
                    <td className={`${td} text-small`}>{f.entity}</td>
                    <td className={`${td} text-small`}>{f.field}{f.refSystem ? ` · ${f.refSystem}` : ""}</td>
                    <td className={`${td} text-right tabular-nums text-small`}>{f.slot}</td>
                    <td className={`${td} text-small`}>{f.property}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          {detail.writeback.length > 0 ? (
            <>
              <h3 className="mb-2 mt-6 text-body font-semibold text-p4a-heading">{t.writeback}</h3>
              <p className="mb-4 max-w-3xl text-small text-p4a-muted">{t.writebackIntro}</p>
              <table className="w-full border-collapse text-body" data-testid="source-writeback">
                <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                  <tr><th className={th}>{t.field}</th><th className={`${th} text-right`}>{t.slot}</th><th className={th}>{t.property}</th><th className={th}>{t.mode}</th><th className={th}>{t.status}</th></tr>
                </thead>
                <tbody>
                  {detail.writeback.map((w) => (
                    <tr key={`${w.field}:${w.slot}`} className={w.enabled ? "" : "text-p4a-muted"}>
                      <td className={`${td} text-small`}>{w.field}</td>
                      <td className={`${td} text-right tabular-nums text-small`}>{w.slot}</td>
                      <td className={`${td} text-small`}>{w.property}</td>
                      <td className={`${td} text-small`}>{(t as Record<string, string>)[`mode_${w.mode}`] ?? w.mode}</td>
                      <td className={td}>{w.enabled ? <Badge tone="success">{t.on}</Badge> : <Badge tone="neutral">{t.off}</Badge>}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </>
          ) : null}
        </Card>
      ) : null}

      {/* ---- lines ---- */}
      {sections.includes("lines") ? (
        <Card title={t.sectionLines}>
          <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{t.linesIntro}</p>
          {detail.lines.length === 0 ? <p className="text-body text-p4a-muted">{t.linesEmpty}</p> : (
            <table className="w-full border-collapse text-body" data-testid="source-lines">
              <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                <tr>
                  <th className={th}>{t.line}</th>
                  <th className={th}>{t.number}{hint(t.number, t.hintNumber)}</th>
                  <th className={th}>{t.market}{hint(t.market, t.hintLineMarket)}</th>
                  <th className={th}>{t.counted}{hint(t.counted, t.hintLineCounted)}</th>
                </tr>
              </thead>
              <tbody>
                {detail.lines.map((l) => (
                  <tr key={l.lineRef} className={l.isActive ? "" : "text-p4a-muted"}>
                    <td className={td}><span className="font-semibold">{l.name}</span> <span className="text-caption text-p4a-muted">({l.lineRef})</span></td>
                    <td className={`${td} tabular-nums text-small`}>{l.digits ?? "–"}</td>
                    <td className={td}>
                      <select aria-label={`${t.market}: ${l.name}`} className={field} value={l.market ?? ""}
                        onChange={(e) => save(() => send("PUT", `${base}/lines`, { lineRef: l.lineRef, market: e.target.value || null, isCounted: l.isCounted }))}>
                        <option value="">{t.noMarket}</option>
                        {marketCodes.map((m) => <option key={m} value={m}>{m}</option>)}
                      </select>
                    </td>
                    <td className={td}>
                      <input type="checkbox" className="h-4 w-4" aria-label={`${t.counted}: ${l.name}`} checked={l.isCounted}
                        onChange={(e) => e.target.checked
                          ? save(() => send("PUT", `${base}/lines`, { lineRef: l.lineRef, market: l.market, isCounted: true }))
                          : setLineOff(l)} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </Card>
      ) : null}

      {/* ---- tags ---- */}
      {sections.includes("tags") ? (
        <Card title={t.sectionTags}>
          <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{t.tagsIntro}</p>
          {detail.tags.length === 0 ? <p className="text-body text-p4a-muted">{t.tagsEmpty}</p> : (
            <table className="w-full border-collapse text-body" data-testid="source-tags">
              <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                <tr><th className={th}>{t.tag}</th><th className={th}>{t.counted}{hint(t.counted, t.hintTagCounted)}</th></tr>
              </thead>
              <tbody>
                {detail.tags.map((x) => (
                  <tr key={x.tagRef} className={x.isActive ? "" : "text-p4a-muted"}>
                    <td className={td}><span className="font-semibold">{x.name}</span> <span className="text-caption text-p4a-muted">({x.tagRef})</span></td>
                    <td className={td}>
                      <input type="checkbox" className="h-4 w-4" aria-label={`${t.counted}: ${x.name}`} checked={x.isCounted}
                        onChange={(e) => save(() => send("PUT", `${base}/tags`, { tagRef: x.tagRef, isCounted: e.target.checked }))} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </Card>
      ) : null}

      {/* ---- missed-call reasons (addition 0008i) ---- */}
      {sections.includes("missedReasons") ? (
        <Card title={t.sectionMissedReasons}>
          <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{t.missedReasonsIntro}</p>
          {detail.missedReasons.length === 0 ? <p className="text-body text-p4a-muted">{t.missedReasonsEmpty}</p> : (
            <table className="w-full border-collapse text-body" data-testid="source-missed-reasons">
              <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                <tr>
                  <th className={th}>{t.reasonCode}{hint(t.reasonCode, t.hintReasonCode)}</th>
                  <th className={th}>{t.reasonLabel}{hint(t.reasonLabel, t.hintReasonLabel)}</th>
                  <th className={th}>{t.reasonInServiceLevel}{hint(t.reasonInServiceLevel, t.hintReasonInServiceLevel)}</th>
                  <th className={th}>{t.reasonNeedsCallback}{hint(t.reasonNeedsCallback, t.hintReasonNeedsCallback)}</th>
                  <th className={`${th} text-right`}>{t.reasonSeen}{hint(t.reasonSeen, t.hintReasonSeen)}</th>
                  <th className={th}>{t.reasonLastSeen}</th>
                  <th className={th}><span className="sr-only">{t.editReason}</span></th>
                </tr>
              </thead>
              <tbody>
                {detail.missedReasons.map((r) => (
                  <tr key={r.code}>
                    <td className={td}>
                      <span className="text-small">{r.code}</span>
                      {r.inCatalog ? null : <span className="ml-2"><Badge tone="neutral">{t.reasonDefaults}</Badge></span>}
                    </td>
                    <td className={`${td} font-semibold`}>{r.label}</td>
                    <td className={td}>
                      <input type="checkbox" className="h-4 w-4" aria-label={`${t.reasonInServiceLevel}: ${r.label}`} checked={r.countsInServiceLevel}
                        onChange={(e) => sendReason(r, { countsInServiceLevel: e.target.checked })} />
                    </td>
                    <td className={td}>
                      <input type="checkbox" className="h-4 w-4" aria-label={`${t.reasonNeedsCallback}: ${r.label}`} checked={r.needsCallback}
                        onChange={(e) => sendReason(r, { needsCallback: e.target.checked })} />
                    </td>
                    <td className={`${td} tabular-nums text-right`}>{r.seenCalls}</td>
                    <td className={`${td} whitespace-nowrap tabular-nums text-small`}>{r.lastSeenAt ? fmtDate(dateKeyInZone(r.lastSeenAt, timeZone), locale, "compact") : "–"}</td>
                    <td className={`${td} text-right`}>
                      <Button variant="text" size="sm" onClick={() => { setReasonLabel(r.label); setReasonProblem(null); setReasonEdit({ reason: r, opened: tick() }); }}>{c.edit}</Button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </Card>
      ) : null}

      {/* ---- store ---- */}
      {sections.includes("store") ? (
        <Card title={t.sectionStore}>
          <div className="-mt-2 mb-4 flex items-start justify-between gap-4">
            <p className="max-w-3xl text-small text-p4a-muted">{t.storeIntro}</p>
            <Button variant="outlined" shortcut="A" data-shortcut="a" onClick={() => { setStore(detail.store ?? { handle: "", name: "", market: marketCodes[0] ?? "", currency: "", timeZone: "" }); setStoreProblem(null); setStoreEdit(tick()); }}>
              {detail.store ? t.editStore : t.addStore}
            </Button>
          </div>
          {detail.store ? (
            <dl className="grid grid-cols-[14rem_1fr] gap-x-6 gap-y-3 text-body" data-testid="source-store">
              <dt className="font-semibold">{t.handle}</dt><dd className="text-small">{detail.store.handle}</dd>
              <dt className="font-semibold">{t.storeName}</dt><dd>{detail.store.name}</dd>
              <dt className="font-semibold">{t.market}</dt><dd>{detail.store.market}</dd>
              <dt className="font-semibold">{t.currency}</dt><dd>{detail.store.currency}</dd>
              <dt className="font-semibold">{t.timeZone}</dt><dd>{detail.store.timeZone}</dd>
            </dl>
          ) : <p className="text-body text-p4a-muted">{t.storeEmpty}</p>}
        </Card>
      ) : null}

      {/* ---- dialogs ---- */}
      {renaming !== null ? (
        <FormDialog key={renaming} title={`${c.edit}: ${conn.name}`} onSave={rename} onClose={() => setRenaming(null)} busy={state.kind === "saving"} saveLabel={c.save} cancelLabel={c.cancel}>
          <label className={label}>
            {t.name}
            <input className={field} value={name} maxLength={100} onChange={(e) => setName(e.target.value)} />
          </label>
          {nameProblem ? <p className="text-small text-p4a-error">{nameProblem}</p> : null}
          <SaveNote state={state} c={c} />
        </FormDialog>
      ) : null}

      {formEdit ? (
        <FormDialog key={formEdit.opened} title={`${t.editForm}: ${formEdit.form.name}`} onSave={saveForm} onClose={() => setFormEdit(null)} busy={state.kind === "saving"} saveLabel={c.save} cancelLabel={c.cancel}>
          <FlagField name={t.counted} hint={t.hintFormCounted} checked={formDraft.isCounted} onChange={(v) => setFormDraft({ ...formDraft, isCounted: v })} />
          <div className="grid grid-cols-2 gap-4">
            <label className={label}>
              {t.leadSource}
              <input className={field} value={formDraft.leadSource} maxLength={60} onChange={(e) => setFormDraft({ ...formDraft, leadSource: e.target.value })} />
              <span className="font-normal text-caption text-p4a-muted">{t.hintLeadSource}</span>
            </label>
            <label className={label}>
              {t.market}
              <select className={field} value={formDraft.market} onChange={(e) => setFormDraft({ ...formDraft, market: e.target.value })}>
                <option value="">{t.noMarket}</option>
                {marketCodes.map((m) => <option key={m} value={m}>{m}</option>)}
              </select>
              <span className="font-normal text-caption text-p4a-muted">{t.hintFormMarket}</span>
            </label>
          </div>
          {formProblem ? <p className="text-small text-p4a-error">{formProblem}</p> : null}
          <SaveNote state={state} c={c} />
        </FormDialog>
      ) : null}

      {ruleOpen?.kind === "forms" ? (
        <FormRuleDialog key={ruleOpen.opened} forms={detail.forms} markets={markets} copy={copy} busy={state.kind === "saving"}
          onClose={() => setRuleOpen(null)}
          onSave={async (changes) => { if (await save(() => send("PUT", `${base}/forms`, { forms: changes }))) setRuleOpen(null); }} />
      ) : null}

      {ruleOpen?.kind === "outcomes" ? (
        <OutcomeRuleDialog key={ruleOpen.opened} outcomes={detail.callOutcomes} copy={copy} busy={state.kind === "saving"}
          onClose={() => setRuleOpen(null)}
          onSave={async (changes) => { if (await save(() => send("PUT", `${base}/call-outcomes`, { outcomes: changes }))) setRuleOpen(null); }} />
      ) : null}

      {reasonEdit ? (
        <FormDialog key={reasonEdit.opened} title={`${t.editReason}: ${reasonEdit.reason.code}`} onSave={saveReasonLabel} onClose={() => setReasonEdit(null)} busy={state.kind === "saving"} saveLabel={c.save} cancelLabel={c.cancel}>
          <label className={label}>
            {t.reasonLabel}
            <input className={field} value={reasonLabel} maxLength={100} onChange={(e) => setReasonLabel(e.target.value)} />
            <span className="font-normal text-caption text-p4a-muted">{t.hintReasonLabel}</span>
          </label>
          {reasonProblem ? <p className="text-small text-p4a-error">{reasonProblem}</p> : null}
          <SaveNote state={state} c={c} />
        </FormDialog>
      ) : null}

      {storeEdit !== null ? (
        <FormDialog key={storeEdit} title={detail.store ? t.editStore : t.addStore} onSave={saveStore} onClose={() => setStoreEdit(null)} busy={state.kind === "saving"} saveLabel={c.save} cancelLabel={c.cancel} wide>
          <div className="grid grid-cols-2 gap-4">
            <label className={label}>
              {t.handle}
              <input className={`${field}`} value={store.handle} maxLength={60} onChange={(e) => setStore({ ...store, handle: e.target.value })} />
              <span className="font-normal text-caption text-p4a-muted">{t.handleHint}</span>
            </label>
            <label className={label}>
              {t.storeName}
              <input className={field} value={store.name} maxLength={80} onChange={(e) => setStore({ ...store, name: e.target.value })} />
            </label>
            <label className={label}>
              {t.market}
              <select className={field} value={store.market} onChange={(e) => setStore({ ...store, market: e.target.value })}>
                {marketCodes.map((m) => <option key={m} value={m}>{m}</option>)}
              </select>
            </label>
            <label className={label}>
              {t.currency}
              <input className={field} value={store.currency} maxLength={3} onChange={(e) => setStore({ ...store, currency: e.target.value })} />
              <span className="font-normal text-caption text-p4a-muted">{t.currencyHint}</span>
            </label>
            <label className={`${label} col-span-2`}>
              {t.timeZone}
              <input className={field} value={store.timeZone} maxLength={64} onChange={(e) => setStore({ ...store, timeZone: e.target.value })} />
              <span className="font-normal text-caption text-p4a-muted">{t.timeZoneHint}</span>
            </label>
          </div>
          {storeProblem ? <p className="text-small text-p4a-error">{storeProblem}</p> : null}
          <SaveNote state={state} c={c} />
        </FormDialog>
      ) : null}

      <ConfirmDialog open={confirmOff} title={t.switchOff} confirmLabel={t.switchOff} cancelLabel={c.cancel} busy={state.kind === "saving"}
        onCancel={() => setConfirmOff(false)}
        onConfirm={async () => { if (await save(() => send("PUT", base, { isActive: false }))) setConfirmOff(false); }}>
        {t.switchOffConfirm.replace("{name}", conn.name)}
      </ConfirmDialog>

      <ConfirmDialog open={lineOff !== null} title={t.lineOff} confirmLabel={t.lineOff} cancelLabel={c.cancel} busy={state.kind === "saving"} irreversible
        onCancel={() => setLineOff(null)}
        onConfirm={async () => {
          if (lineOff && await save(() => send("PUT", `${base}/lines`, { lineRef: lineOff.lineRef, market: lineOff.market, isCounted: false }))) setLineOff(null);
        }}>
        {t.lineOffConfirm.replace("{name}", lineOff?.name ?? "")}
      </ConfirmDialog>
    </>
  );
}
