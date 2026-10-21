"use client";

/**
 * Record kind rules on a CRM connection's page (Configuration → Sources, addition 0008zb): which of this connection's
 * records have a kind, by a pipeline, a category value or both (a record matches when every value the rule holds equals
 * its own). A rule is added with R, archived or put back here; nothing is deleted. The kinds themselves (key, label,
 * record type) are the tenant's catalog on the Sources list. Nothing here names a kind, a pipeline or a category.
 */
import { useRef, useState } from "react";
import type { Copy } from "@/lib/copy";
import type { RecordKindConfig, SourceDetail } from "@/lib/data";
import { HeaderHint } from "../HeaderHint";
import { HintLabel } from "../HintLabel";
import { Badge, Button, Card } from "../primitives";
import { FormDialog, SaveNote, field, label, send, td, th, tr, useSave } from "./shared";

export function SourceKindRules({ detail, kinds, copy }: { detail: SourceDetail; kinds: RecordKindConfig[]; copy: Copy }) {
  const c = copy.configuration;
  const t = copy.configSources;
  const id = detail.connection.id;
  const { state, save } = useSave(c);
  const seq = useRef(0);
  const [open, setOpen] = useState<number | null>(null);
  const active = kinds.filter((k) => k.status === "active");
  const [draft, setDraft] = useState({ kindKey: "", pipelineId: "", category: "" });
  const [problem, setProblem] = useState<string | null>(null);
  const hint = (labelText: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", labelText)} text={text} />;
  const rules = kinds.flatMap((k) => k.rules.filter((r) => r.connectionId === id).map((r) => ({ k, r })));
  const kind = active.find((k) => k.key === draft.kindKey) ?? null;
  const pipelines = detail.pipelines.filter((p) => kind !== null && p.recordType === kind.recordType);

  function add() {
    setDraft({ kindKey: active[0]?.key ?? "", pipelineId: "", category: "" });
    setProblem(null);
    setOpen(++seq.current);
  }

  async function submit() {
    if (!draft.kindKey) return setProblem(t.kindRuleNoKind);
    if (draft.pipelineId === "" && draft.category.trim() === "") return setProblem(t.kindRuleProblem);
    if (draft.category.trim().length > 100) return setProblem(t.kindRuleProblem);
    const body = { kindKey: draft.kindKey, pipelineId: draft.pipelineId || null, category: draft.category.trim() || null, active: true };
    if (await save(() => send("PUT", `/api/v1/configuration/sources/${id}/kind-rules`, body))) setOpen(null);
  }

  return (
    <Card title={t.sectionKindRules}>
      <div className="-mt-2 mb-4 flex items-start justify-between gap-4">
        <p className="max-w-3xl text-small text-p4a-muted">{t.kindRulesIntro}</p>
        <Button variant="outlined" shortcut="R" data-shortcut="r" disabled={active.length === 0} onClick={add}>{t.addKindRule}</Button>
      </div>
      {active.length === 0 ? <p className="mb-4 text-body text-p4a-muted">{t.kindRulesNoKinds}</p> : null}
      {rules.length === 0 ? <p className="text-body text-p4a-muted">{t.kindRulesEmpty}</p> : (
        <div className="overflow-x-auto">
          <table className="w-full border-collapse text-body leading-table" data-testid="source-kind-rules">
            <thead className="bg-p4a-bgblue text-small text-p4a-heading">
              <tr>
                <th className={th}><HintLabel label={t.recordKind}>{hint(t.recordKind, t.hintKind)}</HintLabel></th>
                <th className={th}><HintLabel label={t.pipeline}>{hint(t.pipeline, t.hintKindRulePipeline)}</HintLabel></th>
                <th className={th}><HintLabel label={t.kindRuleCategory}>{hint(t.kindRuleCategory, t.hintKindRuleCategory)}</HintLabel></th>
                <th className={th}>{t.status}</th>
                <th className={th}></th>
              </tr>
            </thead>
            <tbody>
              {rules.map(({ k, r }) => (
                <tr key={`${k.key}:${r.pipelineId ?? ""}:${r.category ?? ""}`} className={`${tr} ${r.isActive && k.status === "active" ? "" : "text-p4a-muted"}`}
                  data-kind={k.key}>
                  <td className={td}><span className="font-semibold">{k.label}</span> <span className="text-caption text-p4a-muted">({k.key})</span></td>
                  <td className={`${td} text-small`}>{r.pipelineId === null ? t.kindRuleAny : `${r.pipelineLabel ?? r.pipelineId} (${r.pipelineId})`}</td>
                  <td className={`${td} text-small`}>{r.category ?? t.kindRuleAny}</td>
                  <td className={td}>{r.isActive ? <Badge tone="success">{t.on}</Badge> : <Badge tone="neutral">{t.off}</Badge>}</td>
                  <td className={`${td} text-right`}>
                    <Button variant="outlined" size="sm"
                      onClick={() => save(() => send("PUT", `/api/v1/configuration/sources/${id}/kind-rules`,
                        { kindKey: k.key, pipelineId: r.pipelineId, category: r.category, active: !r.isActive }))}>
                      {r.isActive ? t.kindRuleArchive : t.kindRuleRestore}
                    </Button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {open === null ? <div className="mt-4"><SaveNote state={state} c={c} /></div> : (
        <FormDialog key={open} title={t.addKindRule} intro={t.kindRuleDialogIntro} onSave={submit} onClose={() => setOpen(null)}
          busy={state.kind === "saving"} saveLabel={c.save} cancelLabel={c.cancel}>
          <label className={label}>
            {t.recordKind}
            <select className={field} value={draft.kindKey} onChange={(e) => setDraft({ ...draft, kindKey: e.target.value, pipelineId: "" })}>
              {active.map((k) => <option key={k.key} value={k.key}>{k.label} ({k.recordType === "deal" ? t.recordTypeDeal : t.recordTypeTicket})</option>)}
            </select>
          </label>
          <label className={label}>
            {t.pipeline}
            <select className={field} value={draft.pipelineId} onChange={(e) => setDraft({ ...draft, pipelineId: e.target.value })}>
              <option value="">{t.kindRuleAny}</option>
              {pipelines.map((p) => <option key={p.pipelineId} value={p.pipelineId}>{p.label}</option>)}
            </select>
          </label>
          <label className={label}>
            {t.kindRuleCategory}
            <input className={field} value={draft.category} maxLength={100} onChange={(e) => setDraft({ ...draft, category: e.target.value })} />
            <span className="font-normal text-caption text-p4a-muted">{t.hintKindRuleCategory}</span>
          </label>
          {problem ? <p className="text-small text-p4a-error">{problem}</p> : null}
          <SaveNote state={state} c={c} />
        </FormDialog>
      )}
    </Card>
  );
}
