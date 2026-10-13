"use client";

/**
 * Rules by name pattern (Sources, addition 0008e): one dialog for forms, one for call outcomes. The
 * person types the words a name contains (and does not), chooses what the rule sets, and sees every
 * change form by form before anything is saved; Save sends exactly the rows of the preview in one
 * request, which the database writes in one transaction (set_form, set_call_outcome). The plans come
 * from lib/sources (planFormRule, planOutcomeRule), so the preview and the verifier share one rule.
 */
import { useMemo, useState } from "react";
import type { Copy } from "@/lib/copy";
import type { MarketConfig, SourceCallOutcome, SourceForm, SourceFormChange, SourceOutcomeChange } from "@/lib/data";
import { formRuleProblem, parseWords, planFormRule, planOutcomeRule, type FormRule, type OutcomeRule } from "@/lib/sources";
import { Badge } from "../primitives";
import { FormDialog, field, label, td, th } from "./shared";

function Radio({ name, value, checked, onChange, children }: { name: string; value: string; checked: boolean; onChange: (v: string) => void; children: React.ReactNode }) {
  return (
    <label className="flex items-center gap-2 text-body font-normal">
      <input type="radio" name={name} value={value} checked={checked} onChange={() => onChange(value)} />
      <span>{children}</span>
    </label>
  );
}

const yesNo = (v: boolean, t: Copy["configSources"]) => (v ? t.ruleYes : t.ruleNo);

export function FormRuleDialog({ forms, markets, copy, busy, onSave, onClose }: {
  forms: SourceForm[]; markets: MarketConfig[]; copy: Copy; busy: boolean;
  onSave: (changes: SourceFormChange[]) => void; onClose: () => void;
}) {
  const c = copy.configuration;
  const t = copy.configSources;
  const [include, setInclude] = useState("");
  const [exclude, setExclude] = useState("");
  const [counted, setCounted] = useState<FormRule["counted"]>("keep");
  const [leadKind, setLeadKind] = useState<FormRule["leadSource"]["kind"]>("keep");
  const [leadValue, setLeadValue] = useState("");
  const [marketKind, setMarketKind] = useState<FormRule["market"]["kind"]>("keep");
  const [marketCode, setMarketCode] = useState(markets[0]?.code ?? "");
  const [others, setOthers] = useState<FormRule["others"]>("keep");

  const rule: FormRule = useMemo(() => ({
    include: parseWords(include), exclude: parseWords(exclude), counted,
    leadSource: leadKind === "value" ? { kind: "value", value: leadValue } : { kind: leadKind } as FormRule["leadSource"],
    market: marketKind === "value" ? { kind: "value", code: marketCode } : { kind: marketKind } as FormRule["market"],
    others,
  }), [include, exclude, counted, leadKind, leadValue, marketKind, marketCode, others]);
  const problem = formRuleProblem(rule);
  const plan = useMemo(() => (problem ? [] : planFormRule(forms, rule, markets)), [forms, rule, markets, problem]);
  const problemText = problem === "nothing" ? t.ruleNothing : problem === "noInclude" ? t.ruleNoInclude
    : problem === "leadSource" ? t.ruleLeadSourceProblem : problem === "market" ? t.ruleMarketProblem : null;

  function submit() {
    if (problem || plan.length === 0) return;
    onSave(plan.map((p) => ({ formId: p.formId, isCounted: p.after.isCounted, leadSource: p.after.leadSource, market: p.after.market })));
  }

  const show = (v: string | null) => v ?? "–";
  return (
    <FormDialog title={t.ruleTitleForms} intro={t.ruleIntro} onSave={submit} onClose={onClose} busy={busy}
      saveLabel={t.ruleSave.replace("{n}", String(plan.length))} cancelLabel={c.cancel} wide>
      <div className="grid grid-cols-2 gap-4">
        <label className={label}>
          {t.ruleInclude}
          <input className={field} value={include} onChange={(e) => setInclude(e.target.value)} />
          <span className="font-normal text-caption text-p4a-muted">{t.ruleIncludeHint}</span>
        </label>
        <label className={label}>
          {t.ruleExclude}
          <input className={field} value={exclude} onChange={(e) => setExclude(e.target.value)} />
        </label>
      </div>
      <div className="grid grid-cols-3 gap-4">
        <fieldset className="flex flex-col gap-2">
          <legend className="mb-1 text-small font-semibold">{t.ruleCounted}</legend>
          <Radio name="counted" value="keep" checked={counted === "keep"} onChange={(v) => setCounted(v as FormRule["counted"])}>{t.ruleKeep}</Radio>
          <Radio name="counted" value="yes" checked={counted === "yes"} onChange={(v) => setCounted(v as FormRule["counted"])}>{t.ruleYes}</Radio>
          <Radio name="counted" value="no" checked={counted === "no"} onChange={(v) => setCounted(v as FormRule["counted"])}>{t.ruleNo}</Radio>
        </fieldset>
        <fieldset className="flex flex-col gap-2">
          <legend className="mb-1 text-small font-semibold">{t.ruleLeadSource}</legend>
          <Radio name="lead" value="keep" checked={leadKind === "keep"} onChange={(v) => setLeadKind(v as typeof leadKind)}>{t.ruleKeep}</Radio>
          <Radio name="lead" value="firstWord" checked={leadKind === "firstWord"} onChange={(v) => setLeadKind(v as typeof leadKind)}>{t.ruleFirstWord}</Radio>
          <Radio name="lead" value="value" checked={leadKind === "value"} onChange={(v) => setLeadKind(v as typeof leadKind)}>{t.ruleSetTo}</Radio>
          {leadKind === "value" ? <input aria-label={t.ruleLeadSource} className={field} value={leadValue} maxLength={60} onChange={(e) => setLeadValue(e.target.value)} /> : null}
          <Radio name="lead" value="clear" checked={leadKind === "clear"} onChange={(v) => setLeadKind(v as typeof leadKind)}>{t.ruleClear}</Radio>
        </fieldset>
        <fieldset className="flex flex-col gap-2">
          <legend className="mb-1 text-small font-semibold">{t.ruleMarket}</legend>
          <Radio name="market" value="keep" checked={marketKind === "keep"} onChange={(v) => setMarketKind(v as typeof marketKind)}>{t.ruleKeep}</Radio>
          <Radio name="market" value="prefix" checked={marketKind === "prefix"} onChange={(v) => setMarketKind(v as typeof marketKind)}>{t.rulePrefix}</Radio>
          <Radio name="market" value="value" checked={marketKind === "value"} onChange={(v) => setMarketKind(v as typeof marketKind)}>{t.ruleSetTo}</Radio>
          {marketKind === "value" ? (
            <select aria-label={t.ruleMarket} className={field} value={marketCode} onChange={(e) => setMarketCode(e.target.value)}>
              {markets.map((m) => <option key={m.code} value={m.code}>{m.code} · {m.name}</option>)}
            </select>
          ) : null}
          <Radio name="market" value="clear" checked={marketKind === "clear"} onChange={(v) => setMarketKind(v as typeof marketKind)}>{t.ruleClear}</Radio>
        </fieldset>
      </div>
      <fieldset className="flex flex-col gap-2">
        <legend className="mb-1 text-small font-semibold">{t.ruleOthers}</legend>
        <Radio name="others" value="keep" checked={others === "keep"} onChange={(v) => setOthers(v as FormRule["others"])}>{t.ruleOthersKeep}</Radio>
        <Radio name="others" value="notCounted" checked={others === "notCounted"} onChange={(v) => setOthers(v as FormRule["others"])}>{t.ruleOthersNotCounted}</Radio>
      </fieldset>

      <section aria-live="polite">
        <h3 className="mb-2 text-body font-semibold text-p4a-heading">
          {t.rulePreviewTitle} · {plan.length === 0 ? t.rulePreviewNone : t.rulePreviewCount.replace("{n}", String(plan.length)).replace("{total}", String(forms.length))}
        </h3>
        {problemText ? <p className="text-small text-p4a-error">{problemText}</p> : null}
        {plan.length > 0 ? (
          <div className="max-h-72 overflow-y-auto rounded-input border border-p4a-border">
            <table className="w-full border-collapse text-small" data-testid="rule-preview">
              <thead className="sticky top-0 bg-p4a-bgblue text-p4a-heading">
                <tr><th className={th}>{t.form}</th><th className={th}>{t.counted}</th><th className={th}>{t.leadSource}</th><th className={th}>{t.market}</th></tr>
              </thead>
              <tbody>
                {plan.map((p) => (
                  <tr key={p.formId}>
                    <td className={td}>
                      <span className="font-semibold">{p.name}</span>{" "}
                      <Badge tone={p.matched ? "info" : "neutral"}>{p.matched ? t.ruleMatched : t.ruleNotMatched}</Badge>
                    </td>
                    <td className={td}>{p.changes.includes("isCounted") ? <>{yesNo(p.before.isCounted, t)} → <strong>{yesNo(p.after.isCounted, t)}</strong></> : yesNo(p.after.isCounted, t)}</td>
                    <td className={td}>{p.changes.includes("leadSource") ? <>{show(p.before.leadSource)} → <strong>{show(p.after.leadSource)}</strong></> : show(p.after.leadSource)}</td>
                    <td className={td}>{p.changes.includes("market") ? <>{show(p.before.market)} → <strong>{show(p.after.market)}</strong></> : show(p.after.market)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : null}
      </section>
    </FormDialog>
  );
}

export function OutcomeRuleDialog({ outcomes, copy, busy, onSave, onClose }: {
  outcomes: SourceCallOutcome[]; copy: Copy; busy: boolean;
  onSave: (changes: SourceOutcomeChange[]) => void; onClose: () => void;
}) {
  const c = copy.configuration;
  const t = copy.configSources;
  const [include, setInclude] = useState("");
  const [exclude, setExclude] = useState("");
  const [connected, setConnected] = useState(false);
  const [others, setOthers] = useState<OutcomeRule["others"]>("keep");
  const rule: OutcomeRule = useMemo(() => ({ include: parseWords(include), exclude: parseWords(exclude), connected, others }), [include, exclude, connected, others]);
  const plan = useMemo(() => planOutcomeRule(outcomes, rule), [outcomes, rule]);

  function submit() {
    if (plan.length === 0) return;
    onSave(plan.map((p) => ({ outcomeRef: p.outcomeRef, isConnected: p.after })));
  }

  return (
    <FormDialog title={t.ruleTitleOutcomes} intro={t.ruleIntro} onSave={submit} onClose={onClose} busy={busy}
      saveLabel={t.ruleSave.replace("{n}", String(plan.length))} cancelLabel={c.cancel} wide>
      <div className="grid grid-cols-2 gap-4">
        <label className={label}>
          {t.ruleIncludeOutcomes}
          <input className={field} value={include} onChange={(e) => setInclude(e.target.value)} />
          <span className="font-normal text-caption text-p4a-muted">{t.ruleIncludeHint}</span>
        </label>
        <label className={label}>
          {t.ruleExclude}
          <input className={field} value={exclude} onChange={(e) => setExclude(e.target.value)} />
        </label>
      </div>
      <div className="grid grid-cols-2 gap-4">
        <fieldset className="flex flex-col gap-2">
          <legend className="mb-1 text-small font-semibold">{t.ruleConnected}</legend>
          <Radio name="connected" value="yes" checked={connected} onChange={() => setConnected(true)}>{t.ruleYes}</Radio>
          <Radio name="connected" value="no" checked={!connected} onChange={() => setConnected(false)}>{t.ruleNo}</Radio>
        </fieldset>
        <fieldset className="flex flex-col gap-2">
          <legend className="mb-1 text-small font-semibold">{t.ruleOutcomeOthers}</legend>
          <Radio name="others" value="keep" checked={others === "keep"} onChange={(v) => setOthers(v as OutcomeRule["others"])}>{t.ruleOthersKeep}</Radio>
          <Radio name="others" value="opposite" checked={others === "opposite"} onChange={(v) => setOthers(v as OutcomeRule["others"])}>{t.ruleOthersOpposite}</Radio>
        </fieldset>
      </div>
      <section aria-live="polite">
        <h3 className="mb-2 text-body font-semibold text-p4a-heading">
          {t.rulePreviewTitle} · {plan.length === 0 ? t.rulePreviewNone : t.rulePreviewCount.replace("{n}", String(plan.length)).replace("{total}", String(outcomes.length))}
        </h3>
        {plan.length > 0 ? (
          <div className="max-h-72 overflow-y-auto rounded-input border border-p4a-border">
            <table className="w-full border-collapse text-small" data-testid="rule-preview">
              <thead className="sticky top-0 bg-p4a-bgblue text-p4a-heading">
                <tr><th className={th}>{t.outcome}</th><th className={th}>{t.connected}</th></tr>
              </thead>
              <tbody>
                {plan.map((p) => (
                  <tr key={p.outcomeRef}>
                    <td className={td}><span className="font-semibold">{p.label}</span> <Badge tone={p.matched ? "info" : "neutral"}>{p.matched ? t.ruleMatched : t.ruleNotMatched}</Badge></td>
                    <td className={td}>{yesNo(p.before, t)} → <strong>{yesNo(p.after, t)}</strong></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : null}
      </section>
    </FormDialog>
  );
}
