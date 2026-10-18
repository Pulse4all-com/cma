/**
 * The Sources and Markets screens' logic (addition 0008e), pure and without runtime imports, so
 * web/verify/configuration.mjs can run it under Node's type stripping. Nothing here knows a vendor,
 * a pipeline, a form, a market or an outcome: it shapes what the tenant configured and mirrors the
 * database's rules (cma.connection_settings_ok, cma.record_url, cma.set_business_hours, cma.upsert_market)
 * so a form can explain a refusal before it is sent.
 */
import type { MarketConfig, SourceCallOutcome, SourceForm, SourceKind, SourceSettingValue, SourceSettings } from "@/lib/data/types";

export const SOURCE_KINDS: readonly SourceKind[] = ["crm", "telephony", "commerce", "automation"];

export type SourceSection = "pipelines" | "forms" | "callOutcomes" | "fields" | "taskStatuses" | "taskTypes" | "lines" | "tags" | "missedReasons" | "store";

const SECTIONS: Record<SourceKind, SourceSection[]> = {
  // taskStatuses, taskTypes: the task catalogs of Follow-up and KPI 5 (addition 0008n)
  crm: ["pipelines", "forms", "callOutcomes", "fields", "taskStatuses", "taskTypes"],
  // missedReasons: the missed-call reasons of the inbound report and the Live board (addition 0008i)
  telephony: ["lines", "tags", "missedReasons"],
  commerce: ["store"],
  automation: [],
};

/** The sections of a connection's page: its kind's, or while the kind is unset those of the kinds its rows imply */
export function sourceSections(kind: SourceKind | null, heldKinds: readonly SourceKind[]): SourceSection[] {
  const kinds = kind ? [kind] : heldKinds;
  return [...new Set(kinds.flatMap((k) => SECTIONS[k] ?? []))];
}

/** The kinds a person may choose: any while the connection holds no rows, else only the kinds its rows imply (the database refuses others) */
export function kindChoices(heldKinds: readonly SourceKind[]): SourceKind[] {
  return heldKinds.length > 0 ? SOURCE_KINDS.filter((k) => heldKinds.includes(k)) : [...SOURCE_KINDS];
}

// ---- Settings: cma.connection_settings_ok ------------------------------------------------------

export const RECORD_URL_PREFIX = "record_url_";

/** Why a settings key is refused: its form, a secret-looking word, or a key already there */
export function settingKeyProblem(key: string, existing: readonly string[], isNew: boolean): "key" | "secret" | "duplicate" | null {
  if (!/^[a-z][a-z0-9_]{0,59}$/.test(key)) return "key";
  if (/(secret|token|password|key)/i.test(key)) return "secret";
  if (isNew && existing.includes(key)) return "duplicate";
  return null;
}

/** The settings as the database measures them (jsonb text, at most 4 kB) */
export function settingsSize(settings: SourceSettings): number {
  return `{${Object.entries(settings).map(([k, v]) => `${JSON.stringify(k)}: ${JSON.stringify(v)}`).join(", ")}}`.length;
}

/** Every rule the database applies to the whole object, or null */
export function settingsProblem(settings: SourceSettings): "key" | "secret" | "value" | "size" | null {
  for (const [k, v] of Object.entries(settings)) {
    const p = settingKeyProblem(k, [], false);
    if (p === "key" || p === "secret") return p;
    if (!["string", "number", "boolean"].includes(typeof v) || (typeof v === "number" && !Number.isFinite(v))) return "value";
  }
  return settingsSize(settings) > 4096 ? "size" : null;
}

/**
 * A typed value back in the type it had: a setting that was true or false stays a boolean when the text
 * says true or false, a number stays a number; anything else, and every new setting, is text
 */
export function coerceSettingValue(text: string, original?: SourceSettingValue): SourceSettingValue {
  const t = text.trim();
  if (typeof original === "boolean" && (t === "true" || t === "false")) return t === "true";
  if (typeof original === "number" && /^-?\d+(\.\d+)?$/.test(t)) return Number(t);
  return t;
}

/** The settings as text for an edit field */
export function settingText(value: SourceSettingValue): string {
  return typeof value === "string" ? value : String(value);
}

/** record_url_deal → deal; null for any other key */
export function recordTypeOfSetting(key: string): string | null {
  return key.startsWith(RECORD_URL_PREFIX) && key.length > RECORD_URL_PREFIX.length ? key.slice(RECORD_URL_PREFIX.length) : null;
}

/**
 * The link a record link template gives, exactly as cma.record_url builds it: {app_host} from the
 * settings, {account} the connection's account id, {id} the record's id; null when a value is
 * malformed, a placeholder stays unfilled or the result is not a plain https address
 */
export function recordUrlPreview(template: string, settings: SourceSettings, account: string, id: string): string | null {
  if (!/^[A-Za-z0-9_.-]{1,100}$/.test(id) || !/^[A-Za-z0-9_.-]{1,100}$/.test(account)) return null;
  let url = template;
  if (url.includes("{app_host}")) {
    const host = settings.app_host;
    if (typeof host !== "string" || !/^[a-z0-9.-]{1,255}$/.test(host)) return null;
    url = url.split("{app_host}").join(host);
  }
  url = url.split("{account}").join(account).split("{id}").join(id);
  if (!/^https:\/\/[^\s{}]+$/.test(url) || url.length > 500) return null;
  return url;
}

// ---- Reading a source: the polls' cadence and the daily floor (backlog CMA-069) --------------------

/**
 * The connection settings the ingest reads for how often it polls and how much of the source's daily
 * limit a backfill or the nightly reconcile may use, with their defaults and ranges, exactly as the
 * ingest applies them (ingest/src/adapters/hubspot/usage.mjs): a whole number in range, as a number or
 * its digits as text, else the default
 */
export const POLL_SETTINGS = {
  formsIntervalMinutes: { setting: "forms_poll_interval_minutes", fallback: 5, min: 1, max: 1440 },
  openCheckMinutes: { setting: "email_open_check_minutes", fallback: 15, min: 1, max: 1440 },
  floorPct: { setting: "api_daily_floor_pct", fallback: 25, min: 1, max: 90 },
} as const;
export type PollSettingName = keyof typeof POLL_SETTINGS;
/** On: one search a minute decides whether the forms that count in Intake are read; off by default */
export const POLL_PROBE_SETTING = "forms_poll_probe";

/** A typed value as the setting takes it: a whole number within its range, else null */
export function parsePollSetting(name: PollSettingName, text: string): number | null {
  const t = text.trim();
  if (!/^\d{1,5}$/.test(t)) return null;
  const n = Number(t);
  const spec = POLL_SETTINGS[name];
  return n >= spec.min && n <= spec.max ? n : null;
}

export interface PollCadence {
  formsIntervalMinutes: number;
  openCheckMinutes: number;
  floorPct: number;
  probe: boolean;
  /** The settings whose stored value is out of range, so their default applies */
  outOfRange: PollSettingName[];
}

/** The values in force for a connection's settings, each stored value within its range or the default */
export function pollCadenceOf(settings: SourceSettings): PollCadence {
  const outOfRange: PollSettingName[] = [];
  const value = (name: PollSettingName): number => {
    const spec = POLL_SETTINGS[name];
    const v = settings[spec.setting];
    if (v === undefined || v === "") return spec.fallback;
    const n = typeof v === "number" ? v : typeof v === "string" ? parsePollSetting(name, v) : null;
    if (n !== null && Number.isInteger(n) && n >= spec.min && n <= spec.max) return n;
    outOfRange.push(name);
    return spec.fallback;
  };
  const probe = settings[POLL_PROBE_SETTING];
  return {
    formsIntervalMinutes: value("formsIntervalMinutes"),
    openCheckMinutes: value("openCheckMinutes"),
    floorPct: value("floorPct"),
    probe: probe === true || probe === "true",
    outOfRange,
  };
}

// ---- Rules by name pattern (forms and call outcomes) ---------------------------------------------

/** "Quote, contact; info" → ["quote", "contact", "info"]: lower case, trimmed, each once, in order */
export function parseWords(text: string): string[] {
  return [...new Set(text.split(/[,;\n]+/).map((w) => w.trim().toLowerCase()).filter(Boolean))];
}

/** A name matches when it contains any include word (every name, without include words) and no exclude word; case does not matter */
export function nameMatches(name: string, include: readonly string[], exclude: readonly string[]): boolean {
  const n = name.toLowerCase();
  return (include.length === 0 || include.some((w) => n.includes(w))) && !exclude.some((w) => n.includes(w));
}

/** The word that appears first in the name (an earlier word in the list wins a tie), or null */
export function firstWordIn(name: string, words: readonly string[]): string | null {
  const n = name.toLowerCase();
  let best: { word: string; at: number } | null = null;
  for (const w of words) {
    const at = n.indexOf(w);
    if (at >= 0 && (best === null || at < best.at)) best = { word: w, at };
  }
  return best?.word ?? null;
}

/**
 * The market a name's two-letter prefix names ("UK - Quote" → the market the alias uk names, "NL Contact"
 * → NL): the first two letters followed by a word end, read through the tenant's market aliases first,
 * then as a market code; null when it names no market of the tenant
 */
export function prefixMarket(name: string, markets: readonly Pick<MarketConfig, "code" | "aliases">[]): string | null {
  const m = /^\s*([A-Za-z]{2})(?![A-Za-z0-9_])/.exec(name);
  if (!m) return null;
  const token = m[1]!.toLowerCase();
  const byAlias = markets.find((x) => x.aliases.includes(token));
  if (byAlias) return byAlias.code;
  const byCode = markets.find((x) => x.code === token.toUpperCase());
  return byCode ? byCode.code : null;
}

export type FormRule = {
  include: string[];
  exclude: string[];
  counted: "keep" | "yes" | "no";
  leadSource: { kind: "keep" } | { kind: "clear" } | { kind: "value"; value: string } | { kind: "firstWord" };
  market: { kind: "keep" } | { kind: "clear" } | { kind: "value"; code: string } | { kind: "prefix" };
  /** Forms that do not match: left as they are, or not counted with their lead source cleared */
  others: "keep" | "notCounted";
};

type FormValues = { isCounted: boolean; leadSource: string | null; market: string | null };
export type FormPlanRow = { formId: string; name: string; matched: boolean; before: FormValues; after: FormValues; changes: (keyof FormValues)[] };

/** Why a form rule cannot run yet, or null */
export function formRuleProblem(rule: FormRule): "nothing" | "noInclude" | "leadSource" | "market" | null {
  if (rule.counted === "keep" && rule.leadSource.kind === "keep" && rule.market.kind === "keep" && rule.others === "keep") return "nothing";
  if (rule.leadSource.kind === "firstWord" && rule.include.length === 0) return "noInclude";
  if (rule.leadSource.kind === "value" && (rule.leadSource.value.trim().length === 0 || rule.leadSource.value.trim().length > 60)) return "leadSource";
  if (rule.market.kind === "value" && !/^[A-Z]{2}$/.test(rule.market.code)) return "market";
  return null;
}

/**
 * What a form rule changes, form by form, before anything is saved: only the forms whose values change.
 * A matching form takes the rule's values (a lead source from the first include word in its name, a market
 * from its prefix; a name without a market prefix keeps its market); a form that does not match is left
 * alone, or set to not counted with its lead source cleared when the rule says so.
 */
export function planFormRule(forms: readonly SourceForm[], rule: FormRule, markets: readonly Pick<MarketConfig, "code" | "aliases">[]): FormPlanRow[] {
  const out: FormPlanRow[] = [];
  for (const f of forms) {
    const before: FormValues = { isCounted: f.isCounted, leadSource: f.leadSource, market: f.market };
    const after: FormValues = { ...before };
    const matched = nameMatches(f.name, rule.include, rule.exclude);
    if (matched) {
      if (rule.counted !== "keep") after.isCounted = rule.counted === "yes";
      if (rule.leadSource.kind === "clear") after.leadSource = null;
      else if (rule.leadSource.kind === "value") after.leadSource = rule.leadSource.value.trim();
      else if (rule.leadSource.kind === "firstWord") after.leadSource = firstWordIn(f.name, rule.include) ?? before.leadSource;
      if (rule.market.kind === "clear") after.market = null;
      else if (rule.market.kind === "value") after.market = rule.market.code;
      else if (rule.market.kind === "prefix") after.market = prefixMarket(f.name, markets) ?? before.market;
    } else if (rule.others === "notCounted") {
      after.isCounted = false;
      after.leadSource = null;
    }
    const changes = (Object.keys(before) as (keyof FormValues)[]).filter((k) => before[k] !== after[k]);
    if (changes.length > 0) out.push({ formId: f.formId, name: f.name, matched, before, after, changes });
  }
  return out;
}

export type OutcomeRule = {
  include: string[];
  exclude: string[];
  connected: boolean;
  /** Outcomes that do not match: left as they are, or set to the opposite */
  others: "keep" | "opposite";
};
export type OutcomePlanRow = { outcomeRef: string; label: string; matched: boolean; before: boolean; after: boolean };

/** What an outcome rule changes before anything is saved: only the outcomes whose value changes */
export function planOutcomeRule(outcomes: readonly SourceCallOutcome[], rule: OutcomeRule): OutcomePlanRow[] {
  const out: OutcomePlanRow[] = [];
  for (const o of outcomes) {
    const matched = nameMatches(o.label, rule.include, rule.exclude);
    const after = matched ? rule.connected : rule.others === "opposite" ? !rule.connected : o.isConnected;
    if (after !== o.isConnected) out.push({ outcomeRef: o.outcomeRef, label: o.label, matched, before: o.isConnected, after });
  }
  return out;
}

// ---- Markets: cma.upsert_market, cma.set_market_alias, cma.set_business_hours ----------------------

export type MarketForm = {
  code: string; name: string; timeZone: string; languageCode: string; currency: string;
  languageSkillKey: string | null; minLanguageLevel: number | null;
};

/** Why the database would refuse a market, or null; the time zone itself is the database's answer */
export function marketFormProblem(f: MarketForm): "uk" | "code" | "name" | "zone" | "language" | "currency" | "level" | null {
  if (f.code === "UK") return "uk";
  if (!/^[A-Z]{2}$/.test(f.code)) return "code";
  if (f.name.trim().length === 0 || f.name.trim().length > 80) return "name";
  if (f.timeZone.trim().length === 0 || f.timeZone.length > 64) return "zone";
  if (!/^[a-z]{2}$/.test(f.languageCode)) return "language";
  if (!/^[A-Z]{3}$/.test(f.currency)) return "currency";
  if (f.minLanguageLevel !== null && f.languageSkillKey === null) return "level";
  return null;
}

/** An alias as the database stores it (trimmed, lower case), or null when it is empty or too long */
export function normalizeAlias(text: string): string | null {
  const a = text.trim().toLowerCase();
  return a.length >= 1 && a.length <= 100 ? a : null;
}

function hhmm(text: string): string | null {
  const t = text.trim();
  let m = /^(\d{1,2})(?:[:.](\d{2}))?$/.exec(t);
  if (!m) m = /^(\d{2})(\d{2})$/.exec(t);
  if (!m) return null;
  const h = Number(m[1]);
  const min = m[2] === undefined ? 0 : Number(m[2]);
  if (min > 59 || h > 24 || (h === 24 && min !== 0)) return null;
  return `${String(h).padStart(2, "0")}:${String(min).padStart(2, "0")}`;
}

/**
 * Office hours as typed ("9-12:30, 13-17", "0900-1700", empty for closed) in the form set_business_hours
 * takes ("09:00-12:30,13:00-17:00", "" closed); null when a range is malformed, closes before it opens,
 * opens at 24:00 or overlaps another range of the day
 */
export function parseOfficeHours(text: string): string | null {
  const parts = text.split(",").map((p) => p.trim()).filter(Boolean);
  const ranges: [string, string][] = [];
  for (const p of parts) {
    const m = /^(.+?)\s*(?:-|–|to)\s*(.+)$/.exec(p);
    if (!m) return null;
    const open = hhmm(m[1]!);
    const close = hhmm(m[2]!);
    if (!open || !close || open === "24:00" || close <= open) return null;
    ranges.push([open, close]);
  }
  ranges.sort((a, b) => a[0].localeCompare(b[0]));
  for (let i = 1; i < ranges.length; i++) if (ranges[i]![0] < ranges[i - 1]![1]) return null;
  return ranges.map(([o, c]) => `${o}-${c}`).join(",");
}

/**
 * A market's hours for one weekday as the business-time functions read them: its own hours when it has
 * any (a day without its own ranges is then closed), else the default row's
 */
export function effectiveHours(hours: readonly { market: string; weekday: number; hours: string }[], market: string, weekday: number): { hours: string; fromDefault: boolean } {
  const own = hours.filter((h) => h.market === market);
  if (market !== "*" && own.length > 0) return { hours: own.find((h) => h.weekday === weekday)?.hours ?? "", fromDefault: false };
  return { hours: hours.find((h) => h.market === "*" && h.weekday === weekday)?.hours ?? "", fromDefault: market !== "*" };
}

/** A holiday's date as YYYY-MM-DD, or null */
export function parseDay(text: string): string | null {
  const t = text.trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(t)) return null;
  const d = new Date(`${t}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === t ? t : null;
}

// ---- Forms reporting (addition 0008p; brief B17d) ------------------------------------------------

/** A form category code as cma.set_form_category takes it: lower-case letters, digits and _, starting with a letter, at most 40, not "none" */
export const FORM_CATEGORY_CODE = /^[a-z][a-z0-9_]{0,39}$/;

/**
 * What stops a form's edit on the Sources page before it is sent, as cma.set_form and cma.set_form_reporting
 * refuse it: a lead source over 60 characters, or a counted form that is not polled
 */
export function formEditProblem(d: { isCounted: boolean; isPolled: boolean; leadSource: string }): "leadSource" | "polled" | null {
  if (d.leadSource.trim().length > 60) return "leadSource";
  if (d.isCounted && !d.isPolled) return "polled";
  return null;
}

/** The categories a form's category is chosen from: the active ones, and the form's own when it is switched off (it keeps it) */
export function formCategoryChoices<C extends { code: string; isActive: boolean }>(categories: readonly C[], current: string | null): C[] {
  return categories.filter((k) => k.isActive || k.code === current);
}

/** What stops a form category before it is sent, as cma.set_form_category refuses it: the code, the name (1 to 60) or the order (0 to 9999) */
export function formCategoryProblem(d: { code: string; name: string; sortOrder: string }): "code" | "name" | "order" | null {
  if (!FORM_CATEGORY_CODE.test(d.code) || d.code === "none") return "code";
  const name = d.name.trim();
  if (name.length < 1 || name.length > 60) return "name";
  const order = Number(d.sortOrder);
  if (d.sortOrder.trim() === "" || !Number.isInteger(order) || order < 0 || order > 9999) return "order";
  return null;
}
