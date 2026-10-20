"use client";

/**
 * Record kinds (Configuration → Sources, addition 0008zb): the tenant's catalog of the kinds of CRM records it reports on,
 * such as a cancellation request, as configuration: a key, a label, the record type (set once) and the order; switched
 * off, a kind gives no record its kind, and nothing is deleted. Which records have a kind is set per connection by its
 * rules (a pipeline, a category value or both), on the connection's page. The setting reports.cancellation_kind picks the
 * kind Reports → Cancellations counts; empty counts none. Nothing is assumed: no kind exists until someone adds it.
 */
import { useRef, useState } from "react";
import type { Copy } from "@/lib/copy";
import type { RecordKindConfig } from "@/lib/data";
import { HeaderHint } from "../HeaderHint";
import { HintLabel } from "../HintLabel";
import { Badge, Button, Card } from "../primitives";
import { FlagField, FormDialog, SaveNote, field, label, send, td, th, tr, useSave } from "./shared";

const KEY_RE = /^[a-z][a-z0-9_-]{1,40}$/;

export function RecordKinds({ kinds, copy }: { kinds: RecordKindConfig[]; copy: Copy }) {
  const c = copy.configuration;
  const t = copy.configSources;
  const { state, save } = useSave(c);
  const seq = useRef(0);
  const [edit, setEdit] = useState<{ isNew: boolean; opened: number } | null>(null);
  const [draft, setDraft] = useState({ key: "", label: "", recordType: "ticket" as "deal" | "ticket", sortOrder: "100", isActive: true });
  const [problem, setProblem] = useState<string | null>(null);
  const hint = (labelText: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", labelText)} text={text} />;
  const current = kinds.find((k) => k.isCancellationKind)?.key ?? "";
  // the active kinds, and the kind the setting names even while switched off, so the choice shows as it stands
  const choices = kinds.filter((k) => k.status === "active" || k.isCancellationKind);

  function open(k: RecordKindConfig | null) {
    setDraft(k ? { key: k.key, label: k.label, recordType: k.recordType, sortOrder: String(k.sortOrder), isActive: k.status === "active" }
      : { key: "", label: "", recordType: "ticket", sortOrder: String(Math.max(0, ...kinds.map((x) => x.sortOrder)) + 10), isActive: true });
    setProblem(null);
    setEdit({ isNew: k === null, opened: ++seq.current });
  }

  async function submit() {
    const order = Number(draft.sortOrder);
    if (!KEY_RE.test(draft.key) || draft.label.trim().length < 1 || draft.label.trim().length > 80 || !/^\d{1,5}$/.test(draft.sortOrder) || order > 10000) {
      return setProblem(t.kindProblem);
    }
    const body = { key: draft.key, label: draft.label.trim(), recordType: draft.recordType, sortOrder: order, isActive: draft.isActive };
    if (await save(() => send("PUT", "/api/v1/configuration/record-kinds", body), t.recordKindConflict)) setEdit(null);
  }

  return (
    <Card title={t.kindsTitle}>
      <div className="-mt-2 mb-4 flex items-start justify-between gap-4">
        <p className="max-w-3xl text-small text-p4a-muted">{t.kindsIntro}</p>
        <Button variant="outlined" shortcut="K" data-shortcut="k" onClick={() => open(null)}>{t.addKind}</Button>
      </div>
      <div className="mb-6 flex flex-wrap items-end gap-4" data-testid="cancellation-kind">
        <label className={label}>
          <span className="flex items-center" data-hint-anchor="">{t.cancellationKind}{hint(t.cancellationKind, t.hintCancellationKind)}</span>
          <select className={`${field} w-72`} value={current} data-testid="cancellation-kind-select"
            onChange={(e) => save(() => send("PUT", "/api/v1/configuration/settings", { key: "reports.cancellation_kind", value: e.target.value || null }))}>
            <option value="">{t.cancellationKindNone}</option>
            {choices.map((k) => <option key={k.key} value={k.key}>{k.label}</option>)}
          </select>
        </label>
      </div>
      {kinds.length === 0 ? <p className="text-body text-p4a-muted">{t.kindsEmpty}</p> : (
        <table className="w-full border-collapse text-body leading-table" data-testid="record-kinds">
          <thead className="bg-p4a-bgblue text-small text-p4a-heading">
            <tr>
              <th className={th}><HintLabel label={t.recordKind}>{hint(t.recordKind, t.hintKind)}</HintLabel></th>
              <th className={th}><HintLabel label={t.kindKey}>{hint(t.kindKey, t.hintKindKey)}</HintLabel></th>
              <th className={th}>{t.kindRecordType}</th>
              <th className={`${th} text-right`}>{t.categoryOrder}</th>
              <th className={`${th} text-right`}><HintLabel label={t.kindRules}>{hint(t.kindRules, t.hintKindRules)}</HintLabel></th>
              <th className={th}>{t.status}</th>
              <th className={th}></th>
            </tr>
          </thead>
          <tbody>
            {kinds.map((k) => (
              <tr key={k.key} className={`${tr} ${k.status === "active" ? "" : "text-p4a-muted"}`} data-kind={k.key}>
                <td className={`${td} font-semibold`}>{k.label}{k.isCancellationKind ? <span className="ml-2"><Badge tone="info">{t.kindCountsCancellations}</Badge></span> : null}</td>
                <td className={`${td} text-small`}>{k.key}</td>
                <td className={`${td} text-small`}>{k.recordType === "deal" ? t.recordTypeDeal : t.recordTypeTicket}</td>
                <td className={`${td} tabular text-right`}>{k.sortOrder}</td>
                <td className={`${td} tabular text-right`}>{k.rules.filter((r) => r.isActive).length}</td>
                <td className={td}>{k.status === "active" ? <Badge tone="success">{t.on}</Badge> : <Badge tone="neutral">{t.off}</Badge>}</td>
                <td className={`${td} text-right`}><Button variant="outlined" size="sm" onClick={() => open(k)}>{c.edit}</Button></td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {edit === null ? <div className="mt-4"><SaveNote state={state} c={c} /></div> : (
        <FormDialog key={edit.opened} title={edit.isNew ? t.addKind : `${t.editKind}: ${draft.key}`} onSave={submit} onClose={() => setEdit(null)}
          busy={state.kind === "saving"} saveLabel={c.save} cancelLabel={c.cancel}>
          <div className="grid grid-cols-2 gap-4">
            <label className={label}>
              {t.kindKey}
              <input className={field} value={draft.key} maxLength={41} readOnly={!edit.isNew} onChange={(e) => setDraft({ ...draft, key: e.target.value.trim() })} />
              <span className="font-normal text-caption text-p4a-muted">{t.hintKindKey}</span>
            </label>
            <label className={label}>
              {t.recordKind}
              <input className={field} value={draft.label} maxLength={80} onChange={(e) => setDraft({ ...draft, label: e.target.value })} />
            </label>
            <label className={label}>
              {t.kindRecordType}
              <select className={field} value={draft.recordType} disabled={!edit.isNew} onChange={(e) => setDraft({ ...draft, recordType: e.target.value as "deal" | "ticket" })}>
                <option value="ticket">{t.recordTypeTicket}</option>
                <option value="deal">{t.recordTypeDeal}</option>
              </select>
            </label>
            <label className={label}>
              {t.categoryOrder}
              <input className={field} inputMode="numeric" value={draft.sortOrder} maxLength={5} onChange={(e) => setDraft({ ...draft, sortOrder: e.target.value.trim() })} />
            </label>
          </div>
          <FlagField name={t.kindActive} hint={t.hintKindActive} checked={draft.isActive} onChange={(v) => setDraft({ ...draft, isActive: v })} />
          {problem ? <p className="text-small text-p4a-error">{problem}</p> : null}
          <SaveNote state={state} c={c} />
        </FormDialog>
      )}
    </Card>
  );
}
