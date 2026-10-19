"use client";

/**
 * One connection's page (Sources, addition 0008e): the connection itself (name, vendor, kind, account,
 * status, secret names as names only), its non-secret settings with a live preview of a record link,
 * and the sections its kind has: pipelines, forms, call outcomes and fields for customer records; lines
 * and tags for telephony, and since addition 0008i its missed-call reasons (label, in the service level,
 * needs a callback); the store for a shop. Every write goes to a route that calls the database
 * function owning the value, and every answer re-reads the page, so a table shows the database's state.
 * Nothing here names a vendor, a pipeline, a form, a market or an outcome. Tables follow
 * docs/style/Pulse4all-Style.md 7.6 (rows of at least 40px, zebra rows, a hover row; the row's name Semi
 * Bold as its header, its id Muted).
 *
 * Keyboard: B back to all sources, N renames, S adds a setting, F applies a rule to forms, O to call
 * outcomes, A adds or edits the store; Ctrl+Enter saves a dialog, Esc closes it.
 */
import Link from "next/link";
import { Fragment, useMemo, useRef, useState } from "react";
import type { Copy, Locale } from "@/lib/copy";
import type {
  FormCategory, MarketConfig, SourceDetail, SourceForm, SourceKind, SourceLine, SourceMailbox, SourceMissedReason, SourceSettings, SourceStore, SourceTaskStatus, SourceTaskType,
} from "@/lib/data";
import { DQ_UNLINKED_SKIP_DEFAULT, DQ_UNLINKED_SKIP_KEY, DQ_UNLINKED_SKIP_NONE, parsePipelineSla, unlinkedSkipOf } from "@/lib/follow-up";
import {
  POLL_PROBE_SETTING, POLL_SETTINGS, coerceSettingValue, emailMarketSteps, formCategoryChoices, formEditProblem, kindChoices, mailboxLabelProblem, parsePollSetting, pollCadenceOf,
  recordTypeOfSetting, recordUrlPreview, settingCodes, settingKeyProblem, settingsSize, settingText, sourceSections, type PollSettingName,
} from "@/lib/sources";
import { settingAnchor } from "@/lib/configuration";
import { dateKeyInZone, fmtDate } from "@/lib/time";
import { ConfirmDialog } from "../ConfirmDialog";
import { HeaderHint } from "../HeaderHint";
import { Badge, Button, Card, Keycap } from "../primitives";
import { FormRuleDialog, OutcomeRuleDialog } from "./SourceRules";
import { kindLabel } from "./SourcesList";
import { FlagField, FormDialog, SaveNote, field, label, send, td, th, tr, useSave } from "./shared";

const EXAMPLE_ID = "123456789";

type Row = { id: number; key: string; text: string; isNew: boolean };

/** The tenant's email settings (additions 0008m and 0008t), shown in words on a CRM connection */
export interface EmailSettingsInWords {
  startDate: string | null;
  replyTargetMinutes: number | null;
  noResponseDays: number | null;
  marketOrder: string | null;
}

const EMAIL_NUMBER_KEYS = { reply: "email.reply_target_minutes", days: "email.no_response_days" } as const;
const EMAIL_NUMBER_MAX = { reply: 10080, days: 90 } as const;

export function SourceConfig({ detail, markets, categories = [], copy, locale, timeZone, connectedMinSeconds = null, email = null }: {
  detail: SourceDetail; markets: MarketConfig[]; copy: Copy; locale: Locale; timeZone: string;
  /** The tenant's email settings (addition 0008t), shown in words on a CRM connection */
  email?: EmailSettingsInWords | null;
  /** The tenant's form categories (addition 0008p), for a form's category */
  categories?: FormCategory[];
  /** telephony.connected_min_seconds (addition 0008j), shown in words on a telephony connection */
  connectedMinSeconds?: number | null;
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
  // a header over a narrow column (a checkbox) may wrap, so the missed-reason table fits its card at 1280 px
  const thWrap = th.replace("whitespace-nowrap", "whitespace-normal");
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

  // ---- how often the connection is read (backlog CMA-069): three numbers and the probe, settings of the connection
  const cadence = pollCadenceOf(original);
  const [pollText, setPollText] = useState<Partial<Record<PollSettingName, string>>>({});
  const [pollProblem, setPollProblem] = useState<string | null>(null);

  // ---- dialogs
  const [formEdit, setFormEdit] = useState<{ form: SourceForm; opened: number } | null>(null);
  const [formDraft, setFormDraft] = useState<{ isCounted: boolean; isPolled: boolean; category: string; leadSource: string; market: string }>(
    { isCounted: true, isPolled: true, category: "", leadSource: "", market: "" });
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
  // a mailbox's label (0008t); its switch and market save at once from the table
  const [mailboxEdit, setMailboxEdit] = useState<{ mailbox: SourceMailbox; opened: number } | null>(null);
  const [mailboxLabel, setMailboxLabel] = useState("");
  const [mailboxProblem, setMailboxProblem] = useState<string | null>(null);
  // the two email numbers (0008t), each saved on blur once it parses, as a pipeline's response time
  const [emailText, setEmailText] = useState<Partial<Record<keyof typeof EMAIL_NUMBER_KEYS, string>>>({});

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

  /** One number of the cadence block: saved on blur or Enter once it is a whole number in range and differs from the stored value */
  async function savePoll(name: PollSettingName) {
    const text = pollText[name];
    if (text === undefined) return;
    const spec = POLL_SETTINGS[name];
    const v = parsePollSetting(name, text);
    if (v === null) return setPollProblem(t.pollProblem.replace("{min}", String(spec.min)).replace("{max}", String(spec.max)));
    setPollProblem(null);
    if (original[spec.setting] !== v) await save(() => send("PUT", `${base}/settings`, { settings: { ...original, [spec.setting]: v } }));
    setPollText((prev) => { const next = { ...prev }; delete next[name]; return next; });
  }

  /** A sentence of the cadence block with its number field where the copy has {n} */
  const pollLine = (name: PollSettingName, template: string) => {
    const [before = "", after = ""] = template.split("{n}");
    const spec = POLL_SETTINGS[name];
    const stored = original[spec.setting];
    return (
      <li className="flex flex-wrap items-center gap-x-2 gap-y-1" data-testid={`poll-${spec.setting}`}>
        <span>{before.trim()}</span>
        <input type="text" inputMode="numeric" className={`${field} w-20 text-right tabular-nums`} aria-label={t.pollValue.replace("{label}", template.replace("{n}", "…"))}
          value={pollText[name] ?? String(cadence[name])} maxLength={5}
          onChange={(e) => setPollText((prev) => ({ ...prev, [name]: e.target.value }))}
          onBlur={() => savePoll(name)} onKeyDown={(e) => { if (e.key === "Enter") void savePoll(name); }} />
        <span>{after.trim()}</span>
        {cadence.outOfRange.includes(name) ? (
          <span className="w-full text-caption text-p4a-muted">
            {t.pollOutOfRange.replace("{value}", String(stored)).replace("{min}", String(spec.min)).replace("{max}", String(spec.max)).replace("{fallback}", String(spec.fallback))}
          </span>
        ) : null}
      </li>
    );
  };

  function openForm(f: SourceForm) {
    setFormDraft({ isCounted: f.isCounted, isPolled: f.isPolled || f.isCounted, category: f.category ?? "", leadSource: f.leadSource ?? "", market: f.market ?? "" });
    setFormProblem(null);
    setFormEdit({ form: f, opened: tick() });
  }

  async function saveForm() {
    if (!formEdit) return;
    const lead = formDraft.leadSource.trim();
    const problem = formEditProblem(formDraft);
    if (problem) return setFormProblem(problem === "leadSource" ? t.ruleLeadSourceProblem : t.polledProblem);
    // polled and the category (addition 0008p) travel with the rest; a counted form is polled
    const body = { forms: [{
      formId: formEdit.form.formId, isCounted: formDraft.isCounted, leadSource: lead || null, market: formDraft.market || null,
      isPolled: formDraft.isPolled || formDraft.isCounted, category: formDraft.category || null,
    }] };
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

  // a ticket pipeline's own response time (0008o): saved on blur once the text parses and differs
  const [slaText, setSlaText] = useState<Record<string, string>>({});
  async function savePipelineSla(pipelineId: string, current: number | null) {
    const text = slaText[pipelineId];
    if (text === undefined) return;
    const v = parsePipelineSla(text);
    if (v === undefined) return;
    if (v !== current) await save(() => send("PUT", `${base}/pipeline-sla`, { recordType: "ticket", pipelineId, slaMinutes: v }));
    setSlaText((prev) => { const next = { ...prev }; delete next[pipelineId]; return next; });
  }

  // a task status's or type's label (0008n); the switches save at once from the table
  const [taskEdit, setTaskEdit] = useState<{ kind: "status"; ref: string; row: SourceTaskStatus; opened: number } | { kind: "type"; ref: string; row: SourceTaskType; opened: number } | null>(null);
  const [taskLabel, setTaskLabel] = useState("");
  const [taskProblem, setTaskProblem] = useState<string | null>(null);
  async function saveTaskLabel() {
    if (!taskEdit) return;
    const v = taskLabel.trim();
    if (v.length === 0 || v.length > 100) return setTaskProblem(t.taskLabelProblem);
    const ok = taskEdit.kind === "status"
      ? await save(() => send("PUT", `${base}/task-statuses`, { statusRef: taskEdit.ref, label: v, isDone: taskEdit.row.isDone }))
      : await save(() => send("PUT", `${base}/task-types`, { typeRef: taskEdit.ref, label: v, isCallback: taskEdit.row.isCallback, isCounted: taskEdit.row.isCounted }));
    if (ok) setTaskEdit(null);
  }

  const emailNumber = (k: keyof typeof EMAIL_NUMBER_KEYS, text: string) => {
    const v = text.trim();
    return /^\d{1,5}$/.test(v) && Number(v) >= 1 && Number(v) <= EMAIL_NUMBER_MAX[k] ? Number(v) : null;
  };
  async function saveEmailNumber(k: keyof typeof EMAIL_NUMBER_KEYS) {
    const text = emailText[k];
    if (text === undefined || !email) return;
    const v = emailNumber(k, text);
    if (v === null) return;
    const current = k === "reply" ? email.replyTargetMinutes : email.noResponseDays;
    if (v !== current) await save(() => send("PUT", "/api/v1/configuration/settings", { key: EMAIL_NUMBER_KEYS[k], value: String(v) }));
    setEmailText((prev) => { const next = { ...prev }; delete next[k]; return next; });
  }

  /** One mailbox as it would be saved: its current label, switch and market, with the change given */
  function sendMailbox(m: SourceMailbox, change: Partial<Pick<SourceMailbox, "label" | "isCounted" | "market">>) {
    const body = { accountId: m.accountId, label: m.label, isCounted: m.isCounted, market: m.market, ...change };
    return save(() => send("PUT", `${base}/mailboxes`, body));
  }
  async function saveMailboxLabel() {
    if (!mailboxEdit) return;
    if (mailboxLabelProblem(mailboxLabel)) return setMailboxProblem(t.mailboxLabelProblem);
    if (await sendMailbox(mailboxEdit.mailbox, { label: mailboxLabel.trim() || null })) setMailboxEdit(null);
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
          {sections.includes("missedReasons") ? (
            <>
              <dt className="font-semibold">{t.connectedCall}</dt>
              <dd className="flex flex-wrap items-baseline gap-x-3" data-testid="source-connected-threshold">
                <span>{t.connectedThreshold.replace("{seconds}", connectedMinSeconds === null ? "–" : new Intl.NumberFormat(locale === "nl" ? "nl-NL" : "en-GB").format(connectedMinSeconds))}</span>
                <Link href={`/configuration/exports#${settingAnchor("telephony.connected_min_seconds")}`} className="text-small font-semibold text-p4a-deepblue hover:underline">
                  {t.connectedThresholdLink}
                </Link>
              </dd>
            </>
          ) : null}
        </dl>
      </Card>

      {/* ---- settings ---- */}
      <Card title={t.sectionSettings}>
        <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{t.settingsIntro} {t.settingsNever}</p>
        {sections.includes("missedReasons") ? <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted" data-testid="call-link-hint">{t.callLinkHint}</p> : null}
        {sections.includes("taskStatuses") ? <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted" data-testid="task-link-hint">{t.taskLinkHint}</p> : null}
        {sections.includes("missedReasons") ? (
          // the unlinked-calls check (data quality, 0008o): one setting of this connection, written with the others
          <label className={`${label} mb-4 max-w-3xl`}>
            <span className="flex items-center">{t.unlinkedCheck}{hint(t.unlinkedCheck, t.unlinkedHint)}</span>
            <select className={field} data-testid="source-unlinked-check" value={unlinkedSkipOf(original, conn.kind)}
              onChange={(e) => save(() => send("PUT", `${base}/settings`, { settings: { ...original, [DQ_UNLINKED_SKIP_KEY]: e.target.value } }))}>
              <option value={DQ_UNLINKED_SKIP_DEFAULT}>{t.unlinkedSkip}</option>
              <option value={DQ_UNLINKED_SKIP_NONE}>{t.unlinkedAll}</option>
            </select>
          </label>
        ) : null}
        {sections.includes("forms") ? (
          // how often the connection is read and the daily floor (backlog CMA-069): settings of this connection, written with the others
          <div className="mb-6 max-w-3xl" data-testid="source-cadence">
            <h3 className="text-body font-semibold text-p4a-heading">{t.pollTitle}</h3>
            <p className="mb-3 text-small text-p4a-muted">{t.pollIntro}</p>
            <ul className="space-y-3 text-body">
              <li data-testid="poll-counted">{cadence.probe ? t.pollCountedProbe.replace("{n}", String(cadence.formsIntervalMinutes)) : t.pollCounted}</li>
              {pollLine("formsIntervalMinutes", t.pollForms)}
              {pollLine("openCheckMinutes", t.pollOpenCheck)}
              {pollLine("floorPct", t.pollFloor)}
              <li className="flex items-center gap-3">
                <label className="flex items-center gap-3">
                  <input type="checkbox" className="h-4 w-4 accent-p4a-deepblue" data-testid="poll-probe" checked={cadence.probe}
                    onChange={(e) => save(() => send("PUT", `${base}/settings`, { settings: { ...original, [POLL_PROBE_SETTING]: e.target.checked } }))} />
                  <span>{t.pollProbe}</span>
                </label>
                {hint(t.pollProbe, t.pollProbeHint.replace("{n}", String(cadence.formsIntervalMinutes)))}
              </li>
            </ul>
            {pollProblem ? <p className="mt-2 text-caption text-p4a-error" role="alert">{pollProblem}</p> : null}
          </div>
        ) : null}
        <table className="w-full border-collapse text-body leading-table" data-testid="source-settings">
          <thead className="bg-p4a-bgblue text-small text-p4a-heading">
            <tr><th className={`${th} w-72`}>{t.settingKey}</th><th className={th}>{t.settingValue}</th><th className={th}></th></tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id} className={tr}>
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
            <table className="w-full border-collapse text-body leading-table" data-testid="source-pipelines">
              <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                <tr>
                  <th className={th}>{t.recordType}</th>
                  <th className={th}>{t.pipeline}</th>
                  <th className={th}>{t.counted}{hint(t.counted, t.hintCounted)}</th>
                  <th className={th}>{t.lead}{hint(t.lead, t.hintLead)}</th>
                  <th className={th}>{t.orderPipeline}{hint(t.orderPipeline, t.hintOrderPipeline)}</th>
                  <th className={th}>{t.responseTime}{hint(t.responseTime, t.hintResponseTime)}</th>
                </tr>
              </thead>
              <tbody>
                {detail.pipelines.map((p) => (
                  <tr key={`${p.recordType}:${p.pipelineId}`} className={`${tr} ${p.isActive ? "" : "text-p4a-muted"}`}>
                    <td className={`${td} text-small`}>{p.recordType}</td>
                    <td className={td}><span className="font-semibold">{p.label}</span> <span className="text-caption text-p4a-muted">({p.pipelineId})</span></td>
                    <td className={td}>
                      <input type="checkbox" className="h-4 w-4 accent-p4a-deepblue" aria-label={`${t.counted}: ${p.label}`} checked={p.isCounted}
                        onChange={(e) => save(() => send("PUT", `${base}/pipelines`, { recordType: p.recordType, pipelineId: p.pipelineId, isCounted: e.target.checked, isLead: p.isLead }))} />
                    </td>
                    <td className={td}>
                      {p.recordType === "deal" ? (
                        <input type="checkbox" className="h-4 w-4 accent-p4a-deepblue" aria-label={`${t.lead}: ${p.label}`} checked={p.isLead}
                          onChange={(e) => save(() => send("PUT", `${base}/pipelines`, { recordType: p.recordType, pipelineId: p.pipelineId, isCounted: p.isCounted, isLead: e.target.checked }))} />
                      ) : <span className="text-caption text-p4a-muted">{t.leadDealsOnly}</span>}
                    </td>
                    <td className={td}>
                      {p.recordType === "deal" ? (
                        // the order pipeline (addition 0008u): its won deals are orders for Reports, First orders
                        <input type="checkbox" className="h-4 w-4 accent-p4a-deepblue" aria-label={`${t.orderPipeline}: ${p.label}`} checked={p.isOrder}
                          data-testid={`pipeline-order-${p.pipelineId}`}
                          onChange={(e) => save(() => send("PUT", `${base}/pipelines`, { recordType: p.recordType, pipelineId: p.pipelineId, isCounted: p.isCounted, isLead: p.isLead, isOrder: e.target.checked }))} />
                      ) : <span className="text-caption text-p4a-muted">{t.orderDealsOnly}</span>}
                    </td>
                    <td className={td}>
                      {p.recordType === "ticket" ? (
                        // the pipeline's own response time (0008o): saved on blur once it parses; empty is the tenant default
                        <span className="flex items-center gap-2">
                          <input className={`${field} w-24 tabular-nums ${parsePipelineSla(slaText[p.pipelineId] ?? String(p.slaMinutes ?? "")) === undefined ? "border-p4a-error" : ""}`}
                            inputMode="numeric" maxLength={6} aria-label={`${t.responseTime}: ${p.label}`} data-testid={`pipeline-sla-${p.pipelineId}`}
                            value={slaText[p.pipelineId] ?? String(p.slaMinutes ?? "")}
                            onChange={(e) => setSlaText({ ...slaText, [p.pipelineId]: e.target.value })}
                            onBlur={() => savePipelineSla(p.pipelineId, p.slaMinutes)}
                            onKeyDown={(e) => { if (e.key === "Enter") (e.target as HTMLInputElement).blur(); }} />
                          {p.slaMinutes === null ? <span className="text-caption text-p4a-muted">{t.responseTimeDefault}</span> : null}
                        </span>
                      ) : <span className="text-caption text-p4a-muted">{t.responseTimeTicketsOnly}</span>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          {/* the deal stages' outcomes (addition 0008u): from the source, a person's choice kept over every later read */}
          <h3 className="mb-2 mt-6 text-body font-semibold text-p4a-heading">{t.stagesTitle}</h3>
          <p className="mb-4 max-w-3xl text-small text-p4a-muted">{t.stagesIntro}</p>
          {detail.pipelines.filter((p) => p.recordType === "deal").every((p) => p.stages.length === 0) ? <p className="text-body text-p4a-muted">{t.stagesEmpty}</p> : (
            <div className="overflow-x-auto">
              <table className="w-full border-collapse text-body leading-table" data-testid="source-stages">
                <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                  <tr>
                    <th className={th}>{t.pipeline}</th>
                    <th className={th}>{t.stage}</th>
                    <th className={th}>{t.stageOutcome}{hint(t.stageOutcome, t.hintStageOutcome)}</th>
                    <th className={th}><span className="sr-only">{t.outcomeFromSource}</span></th>
                  </tr>
                </thead>
                <tbody>
                  {detail.pipelines.filter((p) => p.recordType === "deal").flatMap((p) => p.stages.map((st) => (
                    <tr key={`${p.pipelineId}:${st.stageId}`} className={`${tr} ${st.isActive && p.isActive ? "" : "text-p4a-muted"}`}>
                      <td className={`${td} text-small`}>{p.label}</td>
                      <td className={td}><span className="font-semibold">{st.label}</span> <span className="text-caption text-p4a-muted">({st.stageId})</span></td>
                      <td className={td}>
                        <select className={`${field} w-36`} aria-label={`${t.stageOutcome}: ${p.label}, ${st.label}`} value={st.outcome ?? "none"}
                          data-testid={`stage-outcome-${p.pipelineId}-${st.stageId}`}
                          onChange={(e) => save(() => send("PUT", `${base}/stages`, { pipelineId: p.pipelineId, stageId: st.stageId, outcome: e.target.value }))}>
                          <option value="won">{t.outcomeWon}</option>
                          <option value="lost">{t.outcomeLost}</option>
                          <option value="none">{t.outcomeNone}</option>
                        </select>
                      </td>
                      <td className={`${td} text-caption text-p4a-muted`}>{st.outcomeSource === "person" ? t.outcomeByPerson : st.outcomeSource === "source" ? t.outcomeFromSource : ""}</td>
                    </tr>
                  )))}
                </tbody>
              </table>
            </div>
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
            <table className="w-full border-collapse text-body leading-table" data-testid="source-forms">
              <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                <tr>
                  <th className={th}>{t.form}</th>
                  <th className={th}>{t.polled}{hint(t.polled, t.hintFormPolled)}</th>
                  <th className={th}>{t.counted}{hint(t.counted, t.hintFormCounted)}</th>
                  <th className={th}>{t.category}{hint(t.category, t.hintFormCategory)}</th>
                  <th className={th}>{t.leadSource}{hint(t.leadSource, t.hintLeadSource)}</th>
                  <th className={th}>{t.market}{hint(t.market, t.hintFormMarket)}</th>
                  <th className={th}></th>
                </tr>
              </thead>
              <tbody>
                {detail.forms.map((f) => (
                  <tr key={f.formId} className={`${tr} ${f.isActive ? "" : "text-p4a-muted"}`} data-form={f.formId}>
                    <td className={td}><span className="font-semibold">{f.name}</span> <span className="text-caption text-p4a-muted">({f.formId})</span></td>
                    <td className={td}>{f.isPolled ? <Badge tone="success">{copy.configSources.on}</Badge> : <Badge tone="neutral">{copy.configSources.off}</Badge>}</td>
                    <td className={td}>{f.isCounted ? <Badge tone="success">{copy.configSources.on}</Badge> : <Badge tone="neutral">{copy.configSources.off}</Badge>}</td>
                    <td className={`${td} text-small`}>{f.category === null ? t.noCategory : categories.find((k) => k.code === f.category)?.name ?? f.category}</td>
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
            <table className="w-full border-collapse text-body leading-table" data-testid="source-outcomes">
              <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                <tr><th className={th}>{t.outcome}</th><th className={th}>{t.connected}{hint(t.connected, t.hintConnected)}</th></tr>
              </thead>
              <tbody>
                {detail.callOutcomes.map((o) => (
                  <tr key={o.outcomeRef} className={`${tr} ${o.isActive ? "" : "text-p4a-muted"}`}>
                    <td className={td}><span className="font-semibold">{o.label}</span> <span className="text-caption text-p4a-muted">({o.outcomeRef})</span></td>
                    <td className={td}>
                      <input type="checkbox" className="h-4 w-4 accent-p4a-deepblue" aria-label={`${t.connected}: ${o.label}`} checked={o.isConnected}
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
            <table className="w-full border-collapse text-body leading-table" data-testid="source-fields">
              <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                <tr><th className={th}>{t.entity}</th><th className={th}>{t.field}</th><th className={`${th} text-right`}>{t.slot}</th><th className={th}>{t.property}{hint(t.property, t.hintProperty)}</th></tr>
              </thead>
              <tbody>
                {detail.fields.map((f) => (
                  <tr key={`${f.entity}:${f.field}:${f.refSystem ?? ""}:${f.slot}`} className={tr}>
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
              <table className="w-full border-collapse text-body leading-table" data-testid="source-writeback">
                <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                  <tr><th className={th}>{t.field}</th><th className={`${th} text-right`}>{t.slot}</th><th className={th}>{t.property}</th><th className={th}>{t.mode}</th><th className={th}>{t.status}</th></tr>
                </thead>
                <tbody>
                  {detail.writeback.map((w) => (
                    <tr key={`${w.field}:${w.slot}`} className={`${tr} ${w.enabled ? "" : "text-p4a-muted"}`}>
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

      {/* ---- task statuses (addition 0008n) ---- */}
      {sections.includes("taskStatuses") ? (
        <Card title={t.sectionTaskStatuses}>
          <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{t.taskStatusesIntro}</p>
          {detail.taskStatuses.length === 0 ? <p className="text-body text-p4a-muted">{t.taskStatusesEmpty}</p> : (
            <table className="w-full border-collapse text-body leading-table" data-testid="source-task-statuses">
              <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                <tr>
                  <th className={th}>{t.taskStatus}{hint(t.taskStatus, t.hintTaskStatus)}</th>
                  <th className={th}>{t.taskLabel}{hint(t.taskLabel, t.hintTaskLabel)}</th>
                  <th className={th}>{t.taskDone}{hint(t.taskDone, t.hintTaskDone)}</th>
                  <th className={`${th} text-right`}>{t.taskSeen}{hint(t.taskSeen, t.hintTaskSeen)}</th>
                  <th className={th}>{t.taskLastSeen}</th>
                  <th className={th}><span className="sr-only">{t.editTaskStatus}</span></th>
                </tr>
              </thead>
              <tbody>
                {detail.taskStatuses.map((s) => (
                  <tr key={s.statusRef} className={tr}>
                    <td className={`${td} text-small`}>{s.statusRef}</td>
                    <td className={`${td} font-semibold`}>{s.label}</td>
                    <td className={td}>
                      <input type="checkbox" className="h-4 w-4 accent-p4a-deepblue" aria-label={`${t.taskDone}: ${s.label}`} checked={s.isDone}
                        onChange={(e) => save(() => send("PUT", `${base}/task-statuses`, { statusRef: s.statusRef, label: s.label, isDone: e.target.checked }))} />
                    </td>
                    <td className={`${td} tabular-nums text-right`}>{s.seenTasks}</td>
                    <td className={`${td} whitespace-nowrap tabular-nums text-small`}>{s.lastSeenAt ? fmtDate(dateKeyInZone(s.lastSeenAt, timeZone), locale, "compact") : "–"}</td>
                    <td className={`${td} text-right`}>
                      <Button variant="text" size="sm" onClick={() => { setTaskLabel(s.label); setTaskProblem(null); setTaskEdit({ kind: "status", ref: s.statusRef, row: s, opened: tick() }); }}>{c.edit}</Button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </Card>
      ) : null}

      {/* ---- task types (addition 0008n) ---- */}
      {sections.includes("taskTypes") ? (
        <Card title={t.sectionTaskTypes}>
          <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{t.taskTypesIntro}</p>
          {detail.taskTypes.length === 0 ? <p className="text-body text-p4a-muted">{t.taskStatusesEmpty}</p> : (
            <table className="w-full border-collapse text-body leading-table" data-testid="source-task-types">
              <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                <tr>
                  <th className={th}>{t.taskType}{hint(t.taskType, t.hintTaskType)}</th>
                  <th className={th}>{t.taskLabel}{hint(t.taskLabel, t.hintTaskTypeLabel)}</th>
                  <th className={th}>{t.taskCallback}{hint(t.taskCallback, t.hintTaskCallback)}</th>
                  <th className={th}>{t.taskCounted}{hint(t.taskCounted, t.hintTaskCounted)}</th>
                  <th className={`${th} text-right`}>{t.taskSeen}{hint(t.taskSeen, t.hintTaskOpen)}</th>
                  <th className={`${th} text-right`}>{t.taskOpenCount}</th>
                  <th className={th}>{t.taskLastSeen}</th>
                  <th className={th}><span className="sr-only">{t.editTaskType}</span></th>
                </tr>
              </thead>
              <tbody>
                {detail.taskTypes.map((y) => (
                  <tr key={y.typeRef} className={tr}>
                    <td className={`${td} text-small`}>{y.typeRef}</td>
                    <td className={`${td} font-semibold`}>{y.label}</td>
                    <td className={td}>
                      <input type="checkbox" className="h-4 w-4 accent-p4a-deepblue" aria-label={`${t.taskCallback}: ${y.label}`} checked={y.isCallback}
                        onChange={(e) => save(() => send("PUT", `${base}/task-types`, { typeRef: y.typeRef, label: y.label, isCallback: e.target.checked, isCounted: y.isCounted }))} />
                    </td>
                    <td className={td}>
                      <input type="checkbox" className="h-4 w-4 accent-p4a-deepblue" aria-label={`${t.taskCounted}: ${y.label}`} checked={y.isCounted}
                        onChange={(e) => save(() => send("PUT", `${base}/task-types`, { typeRef: y.typeRef, label: y.label, isCallback: y.isCallback, isCounted: e.target.checked }))} />
                    </td>
                    <td className={`${td} tabular-nums text-right`}>{y.seenTasks}</td>
                    <td className={`${td} tabular-nums text-right`}>{y.openTasks}</td>
                    <td className={`${td} whitespace-nowrap tabular-nums text-small`}>{y.lastSeenAt ? fmtDate(dateKeyInZone(y.lastSeenAt, timeZone), locale, "compact") : "–"}</td>
                    <td className={`${td} text-right`}>
                      <Button variant="text" size="sm" onClick={() => { setTaskLabel(y.label); setTaskProblem(null); setTaskEdit({ kind: "type", ref: y.typeRef, row: y, opened: tick() }); }}>{c.edit}</Button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </Card>
      ) : null}

      {/* ---- email (addition 0008t) ---- */}
      {sections.includes("email") ? (
        <Card title={t.sectionEmail}>
          <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{t.emailIntro}</p>
          <div className="mb-6 grid grid-cols-2 gap-x-8 gap-y-6">
            <section>
              <h3 className="mb-3 text-body font-semibold text-p4a-heading">{t.emailSettingsTitle}</h3>
              <dl className="grid grid-cols-[10rem_1fr] gap-x-4 gap-y-3 text-small" data-testid="source-email-settings">
                <dt className="font-semibold">{t.emailPoll}</dt>
                <dd>{original.email_poll === true ? t.emailPollOn : t.emailPollOff}</dd>
                <dt className="font-semibold">{t.emailStart}</dt>
                <dd>{email?.startDate ? fmtDate(email.startDate, locale, "compact") : t.emailStartNone}</dd>
                {(["reply", "days"] as const).map((k) => {
                  const current = email ? (k === "reply" ? email.replyTargetMinutes : email.noResponseDays) : null;
                  const text = emailText[k] ?? (current === null ? "" : String(current));
                  const title = k === "reply" ? t.emailReplyTarget : t.emailNoResponse;
                  return (
                    <Fragment key={k}>
                      <dt className="font-semibold">{title}</dt>
                      <dd className="flex flex-col gap-2">
                        <span>{current === null ? "–" : (k === "reply" ? t.emailReplyTargetValue.replace("{minutes}", String(current)) : t.emailNoResponseValue.replace("{days}", String(current)))}</span>
                        <input className={`${field} w-24 tabular-nums ${emailNumber(k, text) === null ? "border-p4a-error" : ""}`} inputMode="numeric" maxLength={5}
                          aria-label={title} data-testid={`source-email-${k}`} value={text} disabled={!email}
                          onChange={(e) => setEmailText({ ...emailText, [k]: e.target.value })}
                          onBlur={() => saveEmailNumber(k)}
                          onKeyDown={(e) => { if (e.key === "Enter") (e.target as HTMLInputElement).blur(); }} />
                        {emailNumber(k, text) === null ? <span className="text-caption text-p4a-error" role="alert">{t.emailNumberProblem}</span> : null}
                      </dd>
                    </Fragment>
                  );
                })}
                <dt className="font-semibold">{t.emailMarketOrder}</dt>
                <dd>{t.emailMarketOrderValue.replace("{steps}", emailMarketSteps(email?.marketOrder).map((x) => t[`emailStep_${x}`]).join(", "))}</dd>
              </dl>
            </section>
            <section>
              <h3 className="mb-3 text-body font-semibold text-p4a-heading">{t.emailOriginTitle}</h3>
              <p className="mb-3 text-small text-p4a-muted">{t.emailOriginIntro}</p>
              <dl className="grid grid-cols-[10rem_1fr] gap-x-4 gap-y-3 text-small" data-testid="source-email-origins">
                <dt className="font-semibold">{t.emailOriginProperty}</dt>
                <dd className="break-all">{typeof original.email_origin_property === "string" && original.email_origin_property.trim() ? original.email_origin_property : t.emailOriginNone}</dd>
                <dt className="font-semibold">{t.emailInboxCopies}</dt>
                <dd className="break-words">{settingCodes(original, "email_inbox_copy_origins").length > 0
                  ? t.emailInboxCopiesValue.replace("{codes}", settingCodes(original, "email_inbox_copy_origins").join(", ")) : t.emailInboxCopiesNone}</dd>
                <dt className="font-semibold">{t.emailAutomated}</dt>
                <dd className="break-words">{settingCodes(original, "email_automated_origins").length > 0
                  ? t.emailAutomatedValue.replace("{codes}", settingCodes(original, "email_automated_origins").join(", ")) : t.emailAutomatedNone}</dd>
              </dl>
            </section>
          </div>

          <h3 className="mb-2 text-body font-semibold text-p4a-heading">{t.emailInboxes}</h3>
          {detail.inboxes.length === 0 ? <p className="mb-6 text-body text-p4a-muted">{t.emailInboxesEmpty}</p> : (
            <div className="mb-6 overflow-x-auto">
              <table className="w-full border-collapse text-body leading-table" data-testid="source-inboxes">
                <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                  <tr>
                    <th className={th}>{t.emailInbox}</th>
                    <th className={th}>{t.counted}{hint(t.counted, t.hintEmailInboxCounted)}</th>
                    <th className={th}>{t.market}{hint(t.market, t.hintEmailInboxMarket)}</th>
                  </tr>
                </thead>
                <tbody>
                  {detail.inboxes.map((b) => (
                    <tr key={b.inboxId} className={`${tr} ${b.isActive ? "" : "text-p4a-muted"}`}>
                      <td className={td}><span className="font-semibold">{b.name}</span> <span className="text-caption text-p4a-muted">({b.inboxId})</span></td>
                      <td className={td}>
                        <input type="checkbox" className="h-4 w-4 accent-p4a-deepblue" aria-label={`${t.counted}: ${b.name}`} checked={b.isCounted}
                          onChange={(e) => save(() => send("PUT", `${base}/inboxes`, { inboxId: b.inboxId, isCounted: e.target.checked, market: b.market }))} />
                      </td>
                      <td className={td}>
                        <select className={`${field} w-36`} aria-label={`${t.market}: ${b.name}`} value={b.market ?? ""}
                          onChange={(e) => save(() => send("PUT", `${base}/inboxes`, { inboxId: b.inboxId, isCounted: b.isCounted, market: e.target.value || null }))}>
                          <option value="">{t.noMarket}</option>
                          {[...new Set([...marketCodes, ...(b.market ? [b.market] : [])])].map((m) => <option key={m} value={m}>{m}</option>)}
                        </select>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}

          <h3 className="mb-2 text-body font-semibold text-p4a-heading">{t.emailMailboxes}</h3>
          {detail.mailboxes.length === 0 ? <p className="mb-6 text-body text-p4a-muted">{t.emailMailboxesEmpty}</p> : (
            <div className="mb-6 overflow-x-auto">
              <table className="w-full border-collapse text-body leading-table" data-testid="source-mailboxes">
                <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                  <tr>
                    <th className={th}>{t.emailMailbox}{hint(t.emailMailbox, t.hintEmailMailbox)}</th>
                    <th className={th}>{t.emailInbox}</th>
                    <th className={th}>{t.counted}{hint(t.counted, t.hintEmailMailboxCounted)}</th>
                    <th className={th}>{t.market}{hint(t.market, t.hintEmailMailboxMarket)}</th>
                    <th className={th}><span className="sr-only">{t.editMailbox}</span></th>
                  </tr>
                </thead>
                <tbody>
                  {detail.mailboxes.map((m) => {
                    const shown = m.label ?? m.name;
                    return (
                      <tr key={m.accountId} className={`${tr} ${m.isActive ? "" : "text-p4a-muted"}`} data-mailbox={m.accountId}>
                        <td className={td}>
                          <span className="font-semibold">{shown}</span>{" "}
                          <span className="text-caption text-p4a-muted">({m.label && m.name !== m.accountId ? `${m.name} · ` : ""}{m.accountId})</span>
                        </td>
                        <td className={`${td} text-small`}>{detail.inboxes.find((b) => b.inboxId === m.inboxId)?.name ?? m.inboxId ?? "–"}</td>
                        <td className={td}>
                          <input type="checkbox" className="h-4 w-4 accent-p4a-deepblue" aria-label={`${t.counted}: ${shown}`} checked={m.isCounted}
                            onChange={(e) => sendMailbox(m, { isCounted: e.target.checked })} />
                        </td>
                        <td className={td}>
                          <select className={`${field} w-36`} aria-label={`${t.market}: ${shown}`} value={m.market ?? ""}
                            onChange={(e) => sendMailbox(m, { market: e.target.value || null })}>
                            <option value="">{t.noMarket}</option>
                            {[...new Set([...marketCodes, ...(m.market ? [m.market] : [])])].map((x) => <option key={x} value={x}>{x}</option>)}
                          </select>
                        </td>
                        <td className={`${td} text-right`}>
                          <Button variant="text" size="sm" onClick={() => { setMailboxLabel(m.label ?? ""); setMailboxProblem(null); setMailboxEdit({ mailbox: m, opened: tick() }); }}>{c.edit}</Button>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}

          <h3 className="mb-2 text-body font-semibold text-p4a-heading">{t.emailChannels}</h3>
          {detail.inboxChannels.length === 0 ? <p className="text-body text-p4a-muted">{t.emailChannelsEmpty}</p> : (
            <div className="overflow-x-auto">
              <table className="w-full border-collapse text-body leading-table" data-testid="source-inbox-channels">
                <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                  <tr>
                    <th className={th}>{t.emailChannel}</th>
                    <th className={th}>{t.emailChannelKind}</th>
                    <th className={th}>{t.counted}{hint(t.counted, t.hintEmailChannelCounted)}</th>
                  </tr>
                </thead>
                <tbody>
                  {detail.inboxChannels.map((k) => (
                    <tr key={k.channelId} className={`${tr} ${k.isActive ? "" : "text-p4a-muted"}`}>
                      <td className={td}><span className="font-semibold">{k.name}</span> <span className="text-caption text-p4a-muted">({k.channelId})</span></td>
                      <td className={`${td} text-small`}>{k.kind}</td>
                      <td className={td}>
                        <input type="checkbox" className="h-4 w-4 accent-p4a-deepblue" aria-label={`${t.counted}: ${k.name}`} checked={k.isCounted}
                          onChange={(e) => save(() => send("PUT", `${base}/inbox-channels`, { channelId: k.channelId, isCounted: e.target.checked }))} />
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </Card>
      ) : null}

      {/* ---- lines ---- */}
      {sections.includes("lines") ? (
        <Card title={t.sectionLines}>
          <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{t.linesIntro}</p>
          {detail.lines.length === 0 ? <p className="text-body text-p4a-muted">{t.linesEmpty}</p> : (
            <table className="w-full border-collapse text-body leading-table" data-testid="source-lines">
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
                  <tr key={l.lineRef} className={`${tr} ${l.isActive ? "" : "text-p4a-muted"}`}>
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
                      <input type="checkbox" className="h-4 w-4 accent-p4a-deepblue" aria-label={`${t.counted}: ${l.name}`} checked={l.isCounted}
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
            <table className="w-full border-collapse text-body leading-table" data-testid="source-tags">
              <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                <tr><th className={th}>{t.tag}</th><th className={th}>{t.counted}{hint(t.counted, t.hintTagCounted)}</th></tr>
              </thead>
              <tbody>
                {detail.tags.map((x) => (
                  <tr key={x.tagRef} className={`${tr} ${x.isActive ? "" : "text-p4a-muted"}`}>
                    <td className={td}><span className="font-semibold">{x.name}</span> <span className="text-caption text-p4a-muted">({x.tagRef})</span></td>
                    <td className={td}>
                      <input type="checkbox" className="h-4 w-4 accent-p4a-deepblue" aria-label={`${t.counted}: ${x.name}`} checked={x.isCounted}
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
            // a code can be 60 characters without a break: the table scrolls inside its card, never past it
            <div className="overflow-x-auto" data-testid="source-missed-reasons-scroll">
            <table className="w-full border-collapse text-body leading-table" data-testid="source-missed-reasons">
              <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                <tr>
                  <th className={th}>{t.reasonCode}{hint(t.reasonCode, t.hintReasonCode)}</th>
                  <th className={th}>{t.reasonLabel}{hint(t.reasonLabel, t.hintReasonLabel)}</th>
                  <th className={thWrap}>{t.reasonInServiceLevel}{hint(t.reasonInServiceLevel, t.hintReasonInServiceLevel)}</th>
                  <th className={thWrap}>{t.reasonNeedsCallback}{hint(t.reasonNeedsCallback, t.hintReasonNeedsCallback)}</th>
                  <th className={`${th} text-right`}>{t.reasonSeen}{hint(t.reasonSeen, t.hintReasonSeen)}</th>
                  <th className={th}>{t.reasonLastSeen}</th>
                  <th className={th}><span className="sr-only">{t.editReason}</span></th>
                </tr>
              </thead>
              <tbody>
                {detail.missedReasons.map((r) => (
                  <tr key={r.code} className={tr}>
                    <td className={td}>
                      <span className="text-small">{r.code}</span>
                      {r.inCatalog ? null : <span className="ml-2"><Badge tone="neutral">{t.reasonDefaults}</Badge></span>}
                    </td>
                    <td className={`${td} font-semibold`}>{r.label}</td>
                    <td className={td}>
                      <input type="checkbox" className="h-4 w-4 accent-p4a-deepblue" aria-label={`${t.reasonInServiceLevel}: ${r.label}`} checked={r.countsInServiceLevel}
                        onChange={(e) => sendReason(r, { countsInServiceLevel: e.target.checked })} />
                    </td>
                    <td className={td}>
                      <input type="checkbox" className="h-4 w-4 accent-p4a-deepblue" aria-label={`${t.reasonNeedsCallback}: ${r.label}`} checked={r.needsCallback}
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
            </div>
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
          <FlagField name={t.polled} hint={t.hintFormPolled} checked={formDraft.isPolled || formDraft.isCounted} disabled={formDraft.isCounted}
            onChange={(v) => setFormDraft({ ...formDraft, isPolled: v })} />
          <FlagField name={t.counted} hint={t.hintFormCounted} checked={formDraft.isCounted}
            onChange={(v) => setFormDraft({ ...formDraft, isCounted: v, isPolled: formDraft.isPolled || v })} />
          <div className="grid grid-cols-2 gap-4">
            <label className={`${label} col-span-2`}>
              {t.category}
              <select className={field} value={formDraft.category} onChange={(e) => setFormDraft({ ...formDraft, category: e.target.value })}>
                <option value="">{t.noCategory}</option>
                {formCategoryChoices(categories, formEdit.form.category).map((k) => (
                  <option key={k.code} value={k.code}>{k.isActive ? k.name : t.categorySwitchedOff.replace("{name}", k.name)}</option>
                ))}
              </select>
              <span className="font-normal text-caption text-p4a-muted">{t.hintFormCategory}</span>
            </label>
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

      {mailboxEdit ? (
        <FormDialog key={mailboxEdit.opened} title={`${t.editMailbox}: ${mailboxEdit.mailbox.accountId}`} onSave={saveMailboxLabel}
          onClose={() => setMailboxEdit(null)} busy={state.kind === "saving"} saveLabel={c.save} cancelLabel={c.cancel}>
          <label className={label}>
            {t.mailboxLabel}
            <input className={field} value={mailboxLabel} maxLength={80} onChange={(e) => setMailboxLabel(e.target.value)} data-testid="mailbox-label" />
            <span className="font-normal text-caption text-p4a-muted">{t.mailboxLabelHint}</span>
          </label>
          {mailboxProblem ? <p className="text-small text-p4a-error" role="alert">{mailboxProblem}</p> : null}
        </FormDialog>
      ) : null}

      {taskEdit ? (
        <FormDialog key={taskEdit.opened} title={`${taskEdit.kind === "status" ? t.editTaskStatus : t.editTaskType}: ${taskEdit.ref}`} onSave={saveTaskLabel}
          onClose={() => setTaskEdit(null)} busy={state.kind === "saving"} saveLabel={c.save} cancelLabel={c.cancel}>
          <label className={label}>
            {t.taskLabel}
            <input className={field} value={taskLabel} maxLength={100} autoFocus onChange={(e) => setTaskLabel(e.target.value)} />
          </label>
          {taskProblem ? <p className="text-small text-p4a-error" role="alert">{taskProblem}</p> : null}
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
