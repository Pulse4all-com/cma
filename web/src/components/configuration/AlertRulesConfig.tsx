"use client";

/**
 * Alert rules (brief B14, addition 0008e): the rules of both triggers, each with its effect in plain
 * words, its alerts of the last 30 days and its sound (which follows the urgency); add and edit through
 * upsert_message_rule (a record is created) or upsert_assignment_rule (a record gets an owner), switch
 * off and on through set_message_rule_enabled. A rule is never deleted, so its earlier alerts stay
 * explained; its name and trigger are fixed once it exists. Pipelines come from the tenant's
 * customer-record connections; nothing here names a pipeline, a permission or a record type.
 *
 * Keyboard: A adds a rule; Ctrl+Enter saves the dialog, Esc closes it.
 */
import { useRef, useState } from "react";
import type { Copy, Locale } from "@/lib/copy";
import type { AlertRule, AlertRuleInput, AlertRulesConfig as Data, AlertTrigger, PermissionInfo } from "@/lib/data";
import { alertRuleProblem, newRule, parseAge, pipelineLabels, pipelinesFor, recordTypes, recordWord, ruleEffect } from "@/lib/alertRules";
import { HeaderHint } from "../HeaderHint";
import { Badge, Button } from "../primitives";
import { fmtWhen } from "./SourcesList";
import { FlagField, FormDialog, SaveNote, field, label, send, th, useSave } from "./shared";

export function AlertRulesConfig({ data, permissions, copy, locale, timeZone }: { data: Data; permissions: PermissionInfo[]; copy: Copy; locale: Locale; timeZone: string }) {
  const c = copy.configuration;
  const t = copy.configAlertRules;
  const { state, save } = useSave(c);
  // a fresh key per opening, so every dialog starts from the values as they stand
  const seq = useRef(0);
  const tick = () => ++seq.current;
  const hint = (labelText: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", labelText)} text={text} />;
  const types = recordTypes(data.pipelines, data.rules.map((r) => r.recordType));
  const [target, setTarget] = useState<{ rule: AlertRule | null; opened: number } | null>(null);
  const [form, setForm] = useState<AlertRuleInput>(newRule("record_created", types[0] ?? "deal"));
  const [ageText, setAgeText] = useState("");
  const [problem, setProblem] = useState<string | null>(null);

  function open(rule: AlertRule | null, trigger: AlertTrigger = "record_created") {
    setForm(rule ? {
      name: rule.name, trigger: rule.trigger, recordType: rule.recordType, pipelineIds: [...rule.pipelineIds], urgency: rule.urgency, maxAgeMinutes: rule.maxAgeMinutes,
      audiencePermission: rule.audiencePermission, matchLanguage: rule.matchLanguage, onlyClockedIn: rule.onlyClockedIn, fallbackPermission: rule.fallbackPermission,
    } : newRule(trigger, types[0] ?? "deal"));
    setAgeText(rule?.maxAgeMinutes ? String(rule.maxAgeMinutes) : "");
    setProblem(null);
    setTarget({ rule, opened: tick() });
  }

  async function submit() {
    const age = parseAge(ageText);
    if (age === "invalid") return setProblem(t.problemAge);
    const input = { ...form, name: form.name.trim(), maxAgeMinutes: age };
    const p = alertRuleProblem(input, data.rules, target?.rule === null);
    if (p) {
      setProblem({ name: t.problemName, duplicate: t.problemDuplicate, trigger: t.problemTrigger, recordType: t.problemRecordType, age: t.problemAge, audience: t.problemAudience }[p]);
      return;
    }
    if (await save(() => send("PUT", "/api/v1/configuration/alert-rules", input), t.problemTrigger)) setTarget(null);
  }

  const choices = pipelinesFor(data.pipelines, form.recordType);
  const togglePipeline = (id: string, on: boolean) => setForm({ ...form, pipelineIds: on ? [...form.pipelineIds, id] : form.pipelineIds.filter((x) => x !== id) });

  return (
    <>
      <div className="mb-4 flex items-end justify-between gap-4">
        <SaveNote state={state} c={c} />
        <Button variant="primary" shortcut="A" data-shortcut="a" onClick={() => open(null)}>{t.add}</Button>
      </div>
      {data.rules.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
        <table className="w-full border-collapse text-body" data-testid="alert-rules">
          <thead className="bg-p4a-bgblue text-small text-p4a-heading">
            <tr>
              <th className={th}>{t.rule}</th>
              <th className={th}>{t.trigger}{hint(t.trigger, t.hintTrigger)}</th>
              <th className={th}>{t.pipelines}{hint(t.pipelines, t.hintPipelines)}</th>
              <th className={th}>{t.urgency}{hint(t.urgency, `${t.hintUrgency} ${t.hintSound}`)}</th>
              <th className={`${th} text-right`}>{t.alerts}{hint(t.alerts, t.hintAlerts)}</th>
              <th className={th}></th>
            </tr>
          </thead>
          {data.rules.map((r) => (
            <tbody key={r.id} className={`border-t border-p4a-border ${r.enabled ? "" : "text-p4a-muted"}`} data-rule={r.name}>
              <tr>
                <td className="px-3 pt-3 align-top">
                  <span className="font-semibold">{r.name}</span>
                  <span className="ml-2">{r.enabled ? <Badge tone="success">{t.enabled}</Badge> : <Badge tone="neutral">{t.disabled}</Badge>}</span>
                </td>
                <td className="px-3 pt-3 align-top text-small">{(t as Record<string, string>)[`trigger_${r.trigger}`] ?? r.trigger}<span className="block text-caption text-p4a-muted">{recordWord(r.recordType)}</span></td>
                <td className="px-3 pt-3 align-top text-small">{r.pipelineIds.length === 0 ? t.everyPipeline : pipelineLabels(r.pipelineIds, data.pipelines, r.recordType).join(", ")}</td>
                <td className="px-3 pt-3 align-top">
                  {r.urgency === "urgent" ? <Badge tone="warning">{t.urgency_urgent}</Badge> : <Badge tone="info">{t.urgency_normal}</Badge>}
                  <span className="block text-caption text-p4a-muted">{r.urgency === "urgent" ? t.soundChime : t.soundOne}</span>
                </td>
                <td className="px-3 pt-3 align-top text-right tabular-nums">
                  {r.alerts30d}
                  {r.lastAlertAt ? <span className="block text-caption text-p4a-muted">{t.lastAlert.replace("{when}", fmtWhen(r.lastAlertAt, locale, timeZone))}</span> : null}
                </td>
                <td className="px-3 pt-3 align-top text-right" rowSpan={2}>
                  <div className="flex flex-col items-end gap-2">
                    <Button variant="outlined" size="sm" onClick={() => open(r)}>{c.edit}</Button>
                    {r.enabled
                      ? <Button variant="destructive" size="sm" onClick={() => save(() => send("PUT", `/api/v1/configuration/alert-rules/${r.id}/enabled`, { enabled: false }))}>{t.switchOff}</Button>
                      : <Button variant="outlined" size="sm" onClick={() => save(() => send("PUT", `/api/v1/configuration/alert-rules/${r.id}/enabled`, { enabled: true }))}>{t.switchOn}</Button>}
                  </div>
                </td>
              </tr>
              <tr>
                <td colSpan={5} className="px-3 pb-3 pt-2 text-small" data-testid="rule-effect" data-hint-anchor="">
                  <span className="font-semibold">{t.effect}</span>{hint(t.effect, t.hintEffect)} <span>{ruleEffect(r, data.pipelines, data.defaultMaxAgeMinutes, t).join(" ")}</span>
                </td>
              </tr>
            </tbody>
          ))}
        </table>
      )}

      {target ? (
        <FormDialog key={target.opened} title={target.rule ? `${t.edit}: ${target.rule.name}` : t.add} onSave={submit} onClose={() => setTarget(null)}
          busy={state.kind === "saving"} saveLabel={c.save} cancelLabel={c.cancel} wide>
          <div className="grid grid-cols-2 gap-4">
            <label className={label}>
              {t.name}
              <input className={field} value={form.name} maxLength={80} disabled={target.rule !== null} onChange={(e) => setForm({ ...form, name: e.target.value })} />
              <span className="font-normal text-caption text-p4a-muted">{t.nameHint}</span>
            </label>
            <label className={label}>
              {t.trigger}
              <select className={field} value={form.trigger} disabled={target.rule !== null}
                onChange={(e) => setForm({ ...newRule(e.target.value as AlertTrigger, form.recordType), name: form.name })}>
                <option value="record_created">{t.trigger_record_created}</option>
                <option value="record_assigned">{t.trigger_record_assigned}</option>
              </select>
            </label>
            <label className={label}>
              {t.recordType}
              <select className={field} value={form.recordType} onChange={(e) => setForm({ ...form, recordType: e.target.value, pipelineIds: [] })}>
                {types.map((x) => <option key={x} value={x}>{recordWord(x)}</option>)}
              </select>
            </label>
            <label className={label}>
              {t.urgency}
              <select className={field} value={form.urgency} onChange={(e) => setForm({ ...form, urgency: e.target.value as AlertRuleInput["urgency"] })}>
                <option value="normal">{t.urgency_normal} · {t.soundOne}</option>
                <option value="urgent">{t.urgency_urgent} · {t.soundChime}</option>
              </select>
            </label>
          </div>
          <fieldset className="flex flex-col gap-2">
            <legend className="mb-1 text-small font-semibold">{t.choosePipelines}</legend>
            <span className="text-caption text-p4a-muted">{t.pipelinesHint}</span>
            {choices.length === 0 ? <span className="text-small text-p4a-muted">{t.noPipelines}</span> : (
              <div className="grid grid-cols-2 gap-2">
                {choices.map((p) => (
                  <label key={`${p.connectionName}:${p.pipelineId}`} className="flex items-center gap-2 text-body">
                    <input type="checkbox" className="h-4 w-4" checked={form.pipelineIds.includes(p.pipelineId)} onChange={(e) => togglePipeline(p.pipelineId, e.target.checked)} />
                    <span>{p.label}{p.isCounted ? "" : <span className="text-caption text-p4a-muted"> · {t.notCounted}</span>}</span>
                  </label>
                ))}
              </div>
            )}
          </fieldset>
          {form.trigger === "record_created" ? (
            <div className="grid grid-cols-2 gap-4">
              <label className={label}>
                {t.audience}
                <select className={field} value={form.audiencePermission} onChange={(e) => setForm({ ...form, audiencePermission: e.target.value })}>
                  {permissions.map((p) => <option key={p.key} value={p.key}>{p.key}</option>)}
                </select>
                <span className="font-normal text-caption text-p4a-muted">{t.audienceHint}</span>
              </label>
              <label className={label}>
                {t.fallback}
                <select className={field} value={form.fallbackPermission ?? ""} onChange={(e) => setForm({ ...form, fallbackPermission: e.target.value || null })}>
                  <option value="">{t.noFallback}</option>
                  {permissions.map((p) => <option key={p.key} value={p.key}>{p.key}</option>)}
                </select>
              </label>
              <FlagField name={t.onlyClockedIn} checked={form.onlyClockedIn} onChange={(v) => setForm({ ...form, onlyClockedIn: v })} />
              <FlagField name={t.matchLanguage} hint={t.matchLanguageHint} checked={form.matchLanguage} onChange={(v) => setForm({ ...form, matchLanguage: v })} />
            </div>
          ) : null}
          <label className={label}>
            {t.age}
            <input className={`${field} w-40`} inputMode="numeric" value={ageText} onChange={(e) => setAgeText(e.target.value)} />
            <span className="font-normal text-caption text-p4a-muted">{t.ageHint.replace("{minutes}", String(data.defaultMaxAgeMinutes))}</span>
          </label>
          <p className="rounded-input bg-p4a-bgblue px-4 py-3 text-small text-p4a-body" data-testid="rule-effect-preview">
            <span className="font-semibold">{t.effect}: </span>
            {ruleEffect({ ...form, enabled: target.rule?.enabled ?? true, maxAgeMinutes: (() => { const a = parseAge(ageText); return a === "invalid" ? null : a; })() },
              data.pipelines, data.defaultMaxAgeMinutes, t).join(" ")}
          </p>
          {problem ? <p className="text-small text-p4a-error">{problem}</p> : null}
          <SaveNote state={state} c={c} />
        </FormDialog>
      ) : null}
    </>
  );
}
