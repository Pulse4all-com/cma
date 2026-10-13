/**
 * The Alert rules screen's logic (brief B14, addition 0008e), pure and without runtime imports, so
 * web/verify/configuration.mjs can run it under Node's type stripping. Rules, pipelines, permissions
 * and record types are the tenant's data; nothing here names one. The effect of a rule is said in
 * plain words from the rule's own values and the copy passed in.
 */
import type { AlertPipelineChoice, AlertRule, AlertRuleInput, AlertTrigger } from "@/lib/data/types";

/** The words the effect sentence is built from (copy.configAlertRules) */
export type EffectWords = {
  effectCreated: string;
  effectAssigned: string;
  effectEveryPipeline: string;
  effectPipelines: string;
  effectAudience: string;
  effectClockedIn: string;
  effectLanguage: string;
  effectFallback: string;
  effectNoFallback: string;
  effectAge: string;
  effectAgeDefault: string;
  soundNormal: string;
  soundUrgent: string;
  effectOff: string;
};

const fill = (text: string, values: Record<string, string>) => text.replace(/\{(\w+)\}/g, (m, k: string) => values[k] ?? m);

/** A record type as a word: deal, ticket, follow_up → follow up */
export function recordWord(recordType: string): string {
  return recordType.replace(/_/g, " ");
}

/** The pipelines' labels a rule names, in the order of the choices, with an unknown id as itself */
export function pipelineLabels(ids: readonly string[], choices: readonly AlertPipelineChoice[], recordType: string): string[] {
  return ids.map((id) => choices.find((c) => c.pipelineId === id && c.recordType === recordType)?.label ?? id);
}

/** The rule's effect in plain words, one sentence per part */
export function ruleEffect(rule: Pick<AlertRule, "trigger" | "recordType" | "pipelineIds" | "audiencePermission" | "matchLanguage" | "onlyClockedIn" | "fallbackPermission" | "urgency" | "maxAgeMinutes" | "enabled">,
                           choices: readonly AlertPipelineChoice[], defaultMaxAge: number, w: EffectWords): string[] {
  const record = recordWord(rule.recordType);
  const where = rule.pipelineIds.length === 0
    ? w.effectEveryPipeline
    : fill(w.effectPipelines, { pipelines: pipelineLabels(rule.pipelineIds, choices, rule.recordType).join(", ") });
  const out: string[] = [];
  if (rule.trigger === "record_assigned") {
    out.push(fill(w.effectAssigned, { record, where }));
  } else {
    const who = [fill(w.effectAudience, { permission: rule.audiencePermission })];
    if (rule.onlyClockedIn) who.push(w.effectClockedIn);
    if (rule.matchLanguage) who.push(w.effectLanguage);
    out.push(fill(w.effectCreated, { record, where, who: who.join(", ") }));
    out.push(rule.fallbackPermission ? fill(w.effectFallback, { permission: rule.fallbackPermission }) : w.effectNoFallback);
  }
  out.push(rule.maxAgeMinutes === null ? fill(w.effectAgeDefault, { minutes: String(defaultMaxAge) }) : fill(w.effectAge, { minutes: String(rule.maxAgeMinutes) }));
  out.push(rule.urgency === "urgent" ? w.soundUrgent : w.soundNormal);
  if (!rule.enabled) out.unshift(w.effectOff);
  return out;
}

/** Why the database would refuse a rule, or null: the name, the record type, the age limit, a permission, a name another rule holds */
export function alertRuleProblem(f: AlertRuleInput, rules: readonly Pick<AlertRule, "name" | "trigger">[], isNew: boolean):
    "name" | "duplicate" | "trigger" | "recordType" | "age" | "audience" | null {
  const name = f.name.trim();
  if (name.length === 0 || name.length > 80) return "name";
  const same = rules.find((r) => r.name === name);
  if (isNew && same) return "duplicate";
  if (!isNew && same && same.trigger !== f.trigger) return "trigger";
  if (!/^[a-z][a-z0-9_]*$/.test(f.recordType) || f.recordType === "contact") return "recordType";
  if (f.maxAgeMinutes !== null && (!Number.isInteger(f.maxAgeMinutes) || f.maxAgeMinutes < 1 || f.maxAgeMinutes > 10080)) return "age";
  if (f.trigger === "record_created" && !/^[a-z_]+(\.[a-z_]+)+$/.test(f.audiencePermission)) return "audience";
  return null;
}

/** The record types a rule can name: those of the tenant's pipelines, plus the rule's own */
export function recordTypes(choices: readonly AlertPipelineChoice[], extra: readonly string[] = []): string[] {
  return [...new Set([...choices.map((c) => c.recordType), ...extra])].sort();
}

/** The pipelines a rule of this record type can name, counted first, by label */
export function pipelinesFor(choices: readonly AlertPipelineChoice[], recordType: string): AlertPipelineChoice[] {
  return choices.filter((c) => c.recordType === recordType)
    .sort((a, b) => Number(!a.isCounted) - Number(!b.isCounted) || a.label.localeCompare(b.label) || a.pipelineId.localeCompare(b.pipelineId));
}

/** A typed age limit: empty is the setting's default (null), else whole minutes from 1 to 10080 */
export function parseAge(text: string): number | null | "invalid" {
  const t = text.trim();
  if (t === "") return null;
  if (!/^\d+$/.test(t)) return "invalid";
  const n = Number(t);
  return n >= 1 && n <= 10080 ? n : "invalid";
}

/** A new rule's starting values: everything the database's defaults say, for the trigger chosen */
export function newRule(trigger: AlertTrigger, recordType: string): AlertRuleInput {
  return {
    name: "", trigger, recordType, pipelineIds: [], urgency: trigger === "record_assigned" ? "urgent" : "normal", maxAgeMinutes: null,
    audiencePermission: "leads.accept", matchLanguage: true, onlyClockedIn: true, fallbackPermission: "leads.manage",
  };
}
