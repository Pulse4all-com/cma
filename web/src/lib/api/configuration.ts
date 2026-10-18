import "server-only";
import { ApiError } from "@/lib/api/respond";
import type {
  AbsenceTypeInput, AlertRuleInput, ConfigAppLinkInput, ConfigStatusInput, FormCategoryInput, MarketInput, SkillDimension, SkillInputRow, SkillLevel, SourceConnectionInput,
  SourceFormChange, SourceKind, SourceLineInput, SourceMissedReasonInput, SourceOutcomeChange, SourcePipelineInput, SourcePipelineSlaInput, SourceSettings,
  SourceStore, SourceTagInput, SourceTaskStatusInput, SourceTaskTypeInput, TeamInput, SourceInboxChannelInput, SourceInboxInput, SourceMailboxInput,
} from "@/lib/data";
import { normalizeAlias, parseDay, parseOfficeHours, settingsProblem } from "@/lib/sources";

/**
 * Parameter checks of the configuration routes (migration 0005a): shape and bounds only, so a bad
 * body is a 400 before the database is asked; what a value means (a frozen flag, the last working
 * status, an unknown permission) is the database's answer. No key, label or address is assumed.
 */

export function checkKey(value: unknown, pattern: RegExp): string {
  if (typeof value !== "string" || !pattern.test(value) || value.length > 40) throw new ApiError(400, "invalid_key", "key has a wrong form");
  return value;
}

function text(b: Record<string, unknown>, name: string, max: number): string {
  const v = b[name];
  if (typeof v !== "string" || v.trim().length === 0 || v.trim().length > max) throw new ApiError(400, `invalid_${name}`, `${name} must be 1 to ${max} characters`);
  return v.trim();
}

function flag(b: Record<string, unknown>, name: string): boolean {
  if (typeof b[name] !== "boolean") throw new ApiError(400, `invalid_${name}`, `${name} must be true or false`);
  return b[name] as boolean;
}

function order(b: Record<string, unknown>): number {
  const v = b.sortOrder ?? 100;
  if (typeof v !== "number" || !Number.isInteger(v) || v < 0 || v > 9999) throw new ApiError(400, "invalid_sort_order", "sortOrder must be a whole number from 0 to 9999");
  return v;
}

export function checkStatusInput(b: Record<string, unknown>): ConfigStatusInput {
  return {
    key: checkKey(b.key, /^[a-z0-9_]+$/),
    name: text(b, "name", 40),
    isWorking: flag(b, "isWorking"), isProductive: flag(b, "isProductive"), isPaid: flag(b, "isPaid"), isBillable: flag(b, "isBillable"),
    sortOrder: order(b),
  };
}

export function checkLinkInput(b: Record<string, unknown>): ConfigAppLinkInput {
  const address = text(b, "address", 2000);
  if (!/^https:\/\/[^\s]+$/.test(address)) throw new ApiError(400, "invalid_address", "address must start with https:// and hold no spaces");
  const permissionKey = b.permissionKey == null || b.permissionKey === "" ? null : b.permissionKey;
  if (permissionKey !== null && (typeof permissionKey !== "string" || !/^[a-z_]+(\.[a-z_]+)*$/.test(permissionKey))) {
    throw new ApiError(400, "invalid_permission", "permissionKey must be a permission key or empty");
  }
  return { key: checkKey(b.key, /^[a-z0-9]+(-[a-z0-9]+)*$/), label: text(b, "label", 60), address, permissionKey, sortOrder: order(b) };
}

export function checkAbsenceInput(b: Record<string, unknown>): AbsenceTypeInput {
  return { key: checkKey(b.key, /^[a-z0-9_]+$/), name: text(b, "name", 40), isPaid: flag(b, "isPaid"), sortOrder: order(b) };
}

export function checkTeamInput(b: Record<string, unknown>): TeamInput {
  const markets = b.markets ?? [];
  if (!Array.isArray(markets) || markets.length > 50 || markets.some((m) => typeof m !== "string" || !/^[a-z]{2}$/.test(m))) {
    throw new ApiError(400, "invalid_markets", "markets must be two-letter lowercase tokens");
  }
  return { key: checkKey(b.key, /^[a-z0-9]+(-[a-z0-9]+)*$/), name: text(b, "name", 60), markets: markets as string[], sortOrder: order(b) };
}

const DIMENSIONS: readonly SkillDimension[] = ["language", "work_type", "channel"];

export function checkDimension(value: unknown): SkillDimension {
  if (typeof value !== "string" || !DIMENSIONS.includes(value as SkillDimension)) throw new ApiError(400, "invalid_dimension", "dimension must be language, work_type or channel");
  return value as SkillDimension;
}

export function checkSkillInput(b: Record<string, unknown>): { input: SkillInputRow; active: boolean } {
  return {
    input: { dimension: checkDimension(b.dimension), key: checkKey(b.key, /^[a-z0-9]+(-[a-z0-9]+)*$/), name: text(b, "name", 40), sortOrder: order(b) },
    active: b.active === undefined ? true : flag(b, "active"),
  };
}

export function checkLevels(b: Record<string, unknown>): SkillLevel[] {
  const levels = b.levels;
  if (!Array.isArray(levels) || levels.length > 10) throw new ApiError(400, "invalid_levels", "levels must be a list of at most ten { level, name }");
  const out: SkillLevel[] = [];
  for (const l of levels as unknown[]) {
    const x = l as Record<string, unknown>;
    if (!x || typeof x !== "object" || typeof x.level !== "number" || !Number.isInteger(x.level) || x.level < 1 || x.level > 10
        || typeof x.name !== "string" || x.name.trim().length === 0 || x.name.length > 40) {
      throw new ApiError(400, "invalid_levels", "each level is a whole number from 1 to 10 with a name");
    }
    out.push({ level: x.level, name: x.name.trim() });
  }
  if (new Set(out.map((l) => l.level)).size !== out.length) throw new ApiError(400, "invalid_levels", "levels must be distinct");
  return out;
}

export function checkTargetInput(b: Record<string, unknown>): { teamKey: string; skillKey: string; weekday: number; minCount: number | null } {
  const weekday = b.weekday;
  if (typeof weekday !== "number" || !Number.isInteger(weekday) || weekday < 1 || weekday > 7) throw new ApiError(400, "invalid_weekday", "weekday is 1 (Monday) to 7 (Sunday)");
  const minCount = b.minCount ?? 0;
  if (typeof minCount !== "number" || !Number.isInteger(minCount) || minCount < 0 || minCount > 99) throw new ApiError(400, "invalid_min_count", "minCount is 0 to 99; 0 clears");
  return { teamKey: checkKey(b.teamKey, /^[a-z0-9]+(-[a-z0-9]+)*$/), skillKey: checkKey(b.skillKey, /^[a-z0-9]+(-[a-z0-9]+)*$/), weekday, minCount: minCount === 0 ? null : minCount };
}

export function checkSettingInput(b: Record<string, unknown>): { key: string; value: string | null } {
  const key = b.key;
  if (typeof key !== "string" || !/^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$/.test(key)) throw new ApiError(400, "invalid_key", "key must be a setting key");
  const value = b.value ?? null;
  if (value !== null && (typeof value !== "string" || value.length === 0 || value.length > 100)) throw new ApiError(400, "invalid_value", "value must be text, or null to reset");
  return { key, value };
}

// ---- Sources, markets, alert rules and linked accounts (addition 0008e) ---------------------------
// Shape and bounds only; whether a market, a pipeline, a form or a person exists, and whether a kind
// fits the connection's rows, is the database's answer.

const KINDS: readonly SourceKind[] = ["crm", "telephony", "commerce", "automation"];
const REF = /^[A-Za-z0-9_.:@\/+=-]{1,100}$/;
const MARKET = /^[A-Z]{2}$/;

function ref(v: unknown, name: string): string {
  if (typeof v !== "string" || !REF.test(v)) throw new ApiError(400, `invalid_${name}`, `${name} must be an id of 1 to 100 characters without spaces`);
  return v;
}

function bool(b: Record<string, unknown>, name: string): boolean {
  return flag(b, name);
}

function marketOrNull(v: unknown, name: string): string | null {
  if (v == null || v === "") return null;
  if (typeof v !== "string" || !MARKET.test(v)) throw new ApiError(400, `invalid_${name}`, `${name} must be a two-letter market code or empty`);
  return v;
}

export function checkSourceConnectionInput(b: Record<string, unknown>): SourceConnectionInput {
  const out: SourceConnectionInput = {};
  if (b.name !== undefined) out.name = text(b, "name", 100);
  if (b.isActive !== undefined) out.isActive = flag(b, "isActive");
  if (b.kind !== undefined) {
    if (typeof b.kind !== "string" || !KINDS.includes(b.kind as SourceKind)) throw new ApiError(400, "invalid_kind", "kind must be crm, telephony, commerce or automation");
    out.kind = b.kind as SourceKind;
  }
  if (Object.keys(out).length === 0) throw new ApiError(400, "invalid_body", "name, isActive or kind is required");
  return out;
}

/** The whole settings object; the rules of cma.connection_settings_ok first, so a refusal is a 400 with a code */
export function checkSettingsInput(b: Record<string, unknown>): SourceSettings {
  const s = b.settings;
  if (!s || typeof s !== "object" || Array.isArray(s)) throw new ApiError(400, "invalid_settings", "settings must be a flat object");
  const problem = settingsProblem(s as SourceSettings);
  if (problem === "secret") throw new ApiError(400, "secret_key", "a settings key may not contain secret, token, password or key");
  if (problem) throw new ApiError(400, `invalid_settings_${problem}`, "settings must be a flat object of text, numbers or true and false, lower-case keys, at most 4 kB");
  return s as SourceSettings;
}

export function checkPipelineInput(b: Record<string, unknown>): SourcePipelineInput {
  return { recordType: checkKey(b.recordType, /^[a-z][a-z0-9_]*$/), pipelineId: ref(b.pipelineId, "pipelineId"), isCounted: bool(b, "isCounted"), isLead: bool(b, "isLead") };
}

function list(b: Record<string, unknown>, name: string): Record<string, unknown>[] {
  const v = b[name];
  if (!Array.isArray(v) || v.length === 0 || v.length > 500 || v.some((x) => !x || typeof x !== "object" || Array.isArray(x))) {
    throw new ApiError(400, `invalid_${name}`, `${name} must be a list of 1 to 500 objects`);
  }
  return v as Record<string, unknown>[];
}

export function checkFormChanges(b: Record<string, unknown>): SourceFormChange[] {
  return list(b, "forms").map((x) => {
    const leadSource = x.leadSource == null || x.leadSource === "" ? null : x.leadSource;
    if (leadSource !== null && (typeof leadSource !== "string" || leadSource.trim().length === 0 || leadSource.trim().length > 60)) {
      throw new ApiError(400, "invalid_lead_source", "leadSource must be 1 to 60 characters or empty");
    }
    const change: SourceFormChange = {
      formId: ref(x.formId, "formId"), isCounted: flag(x, "isCounted"), leadSource: leadSource === null ? null : (leadSource as string).trim(), market: marketOrNull(x.market, "market"),
    };
    // polled and the category (addition 0008p), each optional: left out keeps what the form has
    if (x.isPolled !== undefined) change.isPolled = flag(x, "isPolled");
    if (change.isCounted && change.isPolled === false) throw new ApiError(400, "invalid_isPolled", "a counted form is always polled");
    if (x.category !== undefined) change.category = categoryOrNull(x.category);
    return change;
  });
}

const CATEGORY = /^[a-z][a-z0-9_]{0,39}$/;

function categoryOrNull(v: unknown): string | null {
  if (v === null || v === "") return null;
  if (typeof v !== "string" || !CATEGORY.test(v) || v === "none") throw new ApiError(400, "invalid_category", "category must be a category code or empty");
  return v;
}

/** A form category of the Sources page (addition 0008p): code, name, order and whether it is switched on */
export function checkFormCategoryInput(b: Record<string, unknown>): FormCategoryInput {
  const code = b.code;
  if (typeof code !== "string" || !CATEGORY.test(code) || code === "none") {
    throw new ApiError(400, "invalid_code", "code must be lower-case letters, digits and _, starting with a letter, at most 40");
  }
  return { code, name: text(b, "name", 60), sortOrder: order(b), isActive: b.isActive === undefined ? true : flag(b, "isActive") };
}

export function checkOutcomeChanges(b: Record<string, unknown>): SourceOutcomeChange[] {
  return list(b, "outcomes").map((x) => ({ outcomeRef: ref(x.outcomeRef, "outcomeRef"), isConnected: flag(x, "isConnected") }));
}

export function checkLineInput(b: Record<string, unknown>): SourceLineInput {
  return { lineRef: ref(b.lineRef, "lineRef"), market: marketOrNull(b.market, "market"), isCounted: flag(b, "isCounted") };
}

export function checkTagInput(b: Record<string, unknown>): SourceTagInput {
  return { tagRef: ref(b.tagRef, "tagRef"), isCounted: flag(b, "isCounted") };
}

/** { code, label, countsInServiceLevel, needsCallback }: one missed-call reason of a telephony connection (addition 0008i) */
export function checkMissedReasonInput(b: Record<string, unknown>): SourceMissedReasonInput {
  return { code: text(b, "code", 60), label: text(b, "label", 100), countsInServiceLevel: flag(b, "countsInServiceLevel"), needsCallback: flag(b, "needsCallback") };
}

/** { recordType: "ticket", pipelineId, slaMinutes }: a ticket pipeline's own response time (0008o); 1 to 100000, or null for the tenant default */
export function checkPipelineSlaInput(b: Record<string, unknown>): SourcePipelineSlaInput {
  if (b.recordType !== "ticket") throw new ApiError(400, "invalid_record_type", "a response time is set on ticket pipelines only");
  const v = b.slaMinutes;
  if (v !== null && (typeof v !== "number" || !Number.isInteger(v) || v < 1 || v > 100000)) {
    throw new ApiError(400, "invalid_sla_minutes", "slaMinutes must be a whole number from 1 to 100000, or null for the default");
  }
  return { recordType: "ticket", pipelineId: ref(b.pipelineId, "pipelineId"), slaMinutes: v as number | null };
}

/** { statusRef, label, isDone }: one task status of a CRM connection (0008n) */
export function checkTaskStatusInput(b: Record<string, unknown>): SourceTaskStatusInput {
  return { statusRef: ref(b.statusRef, "statusRef"), label: text(b, "label", 100), isDone: flag(b, "isDone") };
}

/** { typeRef, label, isCallback, isCounted }: one task type of a CRM connection (0008n) */
export function checkTaskTypeInput(b: Record<string, unknown>): SourceTaskTypeInput {
  return { typeRef: ref(b.typeRef, "typeRef"), label: text(b, "label", 100), isCallback: flag(b, "isCallback"), isCounted: flag(b, "isCounted") };
}

/** { inboxId, isCounted, market }: one inbox of a CRM connection's conversations (0008m) */
export function checkInboxInput(b: Record<string, unknown>): SourceInboxInput {
  return { inboxId: ref(b.inboxId, "inboxId"), isCounted: flag(b, "isCounted"), market: marketOrNull(b.market, "market") };
}

/** { accountId, label, isCounted, market }: one mailbox (0008t); a label is 1 to 80 characters without an @ (the CMA keeps no address), or null */
export function checkMailboxInput(b: Record<string, unknown>): SourceMailboxInput {
  const label = b.label == null || (typeof b.label === "string" && b.label.trim() === "") ? null : b.label;
  if (label !== null && (typeof label !== "string" || label.trim().length > 80 || label.includes("@"))) {
    throw new ApiError(400, "invalid_label", "label must be 1 to 80 characters without an @, or empty");
  }
  return { accountId: ref(b.accountId, "accountId"), label: label === null ? null : (label as string).trim(), isCounted: flag(b, "isCounted"), market: marketOrNull(b.market, "market") };
}

/** { channelId, isCounted }: one channel of a CRM connection's conversations (0008m) */
export function checkInboxChannelInput(b: Record<string, unknown>): SourceInboxChannelInput {
  return { channelId: ref(b.channelId, "channelId"), isCounted: flag(b, "isCounted") };
}

export function checkStoreInput(b: Record<string, unknown>): SourceStore {
  const handle = b.handle;
  if (typeof handle !== "string" || !/^[a-z0-9-]{1,60}$/.test(handle)) throw new ApiError(400, "invalid_handle", "handle is 1 to 60 lower-case letters, digits or hyphens");
  const currency = b.currency;
  if (typeof currency !== "string" || !/^[A-Z]{3}$/.test(currency)) throw new ApiError(400, "invalid_currency", "currency is three upper-case letters");
  const market = marketOrNull(b.market, "market");
  if (market === null) throw new ApiError(400, "invalid_market", "market is required");
  return { handle, name: text(b, "name", 80), market, currency, timeZone: text(b, "timeZone", 64) };
}

export function checkMarketInput(b: Record<string, unknown>): { input: MarketInput; active: boolean } {
  const code = b.code;
  if (typeof code !== "string" || !MARKET.test(code)) throw new ApiError(400, "invalid_code", "code is two upper-case letters (ISO 3166-1), GB not UK");
  const languageCode = b.languageCode;
  if (typeof languageCode !== "string" || !/^[a-z]{2}$/.test(languageCode)) throw new ApiError(400, "invalid_language", "languageCode is two lower-case letters");
  const currency = b.currency;
  if (typeof currency !== "string" || !/^[A-Z]{3}$/.test(currency)) throw new ApiError(400, "invalid_currency", "currency is three upper-case letters");
  const skill = b.languageSkillKey == null || b.languageSkillKey === "" ? null : b.languageSkillKey;
  if (skill !== null && (typeof skill !== "string" || !/^[a-z0-9]+(-[a-z0-9]+)*$/.test(skill))) throw new ApiError(400, "invalid_skill", "languageSkillKey must be a skill key or empty");
  const level = b.minLanguageLevel ?? null;
  if (level !== null && (typeof level !== "number" || !Number.isInteger(level) || level < 1 || level > 9)) throw new ApiError(400, "invalid_level", "minLanguageLevel is 1 to 9 or empty");
  return {
    input: { code, name: text(b, "name", 80), timeZone: text(b, "timeZone", 64), languageCode, currency, languageSkillKey: skill as string | null, minLanguageLevel: level as number | null, sortOrder: order(b) },
    active: b.active === undefined ? true : flag(b, "active"),
  };
}

export function checkAliasInput(b: Record<string, unknown>): { alias: string; code: string | null } {
  const alias = typeof b.alias === "string" ? normalizeAlias(b.alias) : null;
  if (alias === null) throw new ApiError(400, "invalid_alias", "alias is 1 to 100 characters");
  return { alias, code: marketOrNull(b.code, "code") };
}

export function checkHoursInput(b: Record<string, unknown>): { market: string; days: { weekday: number; hours: string }[] } {
  const market = b.market;
  if (typeof market !== "string" || !(market === "*" || MARKET.test(market))) throw new ApiError(400, "invalid_market", "market is a market code or *");
  const days = b.days;
  if (!Array.isArray(days) || days.length === 0 || days.length > 7) throw new ApiError(400, "invalid_days", "days is a list of 1 to 7 { weekday, hours }");
  const out = days.map((d: unknown) => {
    const x = (d ?? {}) as Record<string, unknown>;
    const weekday = x.weekday;
    if (typeof weekday !== "number" || !Number.isInteger(weekday) || weekday < 1 || weekday > 7) throw new ApiError(400, "invalid_weekday", "weekday is 1 (Monday) to 7 (Sunday)");
    const hours = typeof x.hours === "string" ? parseOfficeHours(x.hours) : null;
    if (hours === null) throw new ApiError(400, "invalid_hours", "hours are ranges like 09:00-17:00, or empty for closed");
    return { weekday, hours };
  });
  if (new Set(out.map((d) => d.weekday)).size !== out.length) throw new ApiError(400, "invalid_days", "each weekday once");
  return { market, days: out };
}

export function checkHolidayInput(b: Record<string, unknown>): { market: string; day: string; name: string | null } {
  const market = b.market;
  if (typeof market !== "string" || !(market === "*" || MARKET.test(market))) throw new ApiError(400, "invalid_market", "market is a market code or *");
  const day = typeof b.day === "string" ? parseDay(b.day) : null;
  if (day === null) throw new ApiError(400, "invalid_day", "day must be a date in YYYY-MM-DD");
  return { market, day, name: b.name == null ? null : text(b, "name", 100) };
}

export function checkAlertRuleInput(b: Record<string, unknown>): AlertRuleInput {
  const trigger = b.trigger;
  if (trigger !== "record_created" && trigger !== "record_assigned") throw new ApiError(400, "invalid_trigger", "trigger is record_created or record_assigned");
  const urgency = b.urgency;
  if (urgency !== "normal" && urgency !== "urgent") throw new ApiError(400, "invalid_urgency", "urgency is normal or urgent");
  const pipelineIds = b.pipelineIds ?? [];
  if (!Array.isArray(pipelineIds) || pipelineIds.length > 50) throw new ApiError(400, "invalid_pipelines", "pipelineIds is a list of at most 50 ids");
  const age = b.maxAgeMinutes ?? null;
  if (age !== null && (typeof age !== "number" || !Number.isInteger(age) || age < 1 || age > 10080)) throw new ApiError(400, "invalid_age", "maxAgeMinutes is 1 to 10080 or empty");
  const permission = (v: unknown, name: string, nullable: boolean): string | null => {
    if (nullable && (v == null || v === "")) return null;
    if (typeof v !== "string" || !/^[a-z_]+(\.[a-z_]+)+$/.test(v)) throw new ApiError(400, `invalid_${name}`, `${name} must be a permission key${nullable ? " or empty" : ""}`);
    return v;
  };
  const created = trigger === "record_created";
  return {
    name: text(b, "name", 80), trigger, recordType: checkKey(b.recordType, /^[a-z][a-z0-9_]*$/), pipelineIds: pipelineIds.map((p) => ref(p, "pipelineId")),
    urgency, maxAgeMinutes: age as number | null,
    audiencePermission: created ? permission(b.audiencePermission, "audiencePermission", false)! : "leads.accept",
    matchLanguage: created ? flag(b, "matchLanguage") : false,
    onlyClockedIn: created ? flag(b, "onlyClockedIn") : false,
    fallbackPermission: created ? permission(b.fallbackPermission, "fallbackPermission", true) : null,
  };
}

export function checkLinkedAccountInput(b: Record<string, unknown>): { system: string; externalId: string | null } {
  const system = b.system;
  if (typeof system !== "string" || !/^[a-z0-9]+_(owner|user)$/.test(system)) throw new ApiError(400, "invalid_system", "system must read <system>_owner or <system>_user");
  const v = b.externalId;
  if (v == null || v === "") return { system, externalId: null };
  if (typeof v !== "string" || v.trim().length === 0 || v.trim().length > 100 || /\s/.test(v.trim())) throw new ApiError(400, "invalid_external_id", "the id is 1 to 100 characters without spaces");
  return { system, externalId: v.trim() };
}
