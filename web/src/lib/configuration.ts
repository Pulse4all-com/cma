/**
 * The configuration screens' logic (migration 0005a), pure and without runtime imports beyond
 * the csv module (itself pure), so web/verify/configuration.mjs can run it under Node's type
 * stripping. Nothing here knows a status key, a team key or a setting value: it shapes what the
 * tenant configured and explains the database's refusals.
 */
import type { ConfigStatus, CoverageTargetRow, SkillLevel, TenantSetting } from "@/lib/data/types";
import { exportSettingsFrom, formatDate, formatDuration, toCsv } from "./csv.ts";

/** Flag changes on a status with time behind it are refused by the database; the form says so first */
export function flagsFrozen(status: Pick<ConfigStatus, "usageCount">): boolean {
  return status.usageCount > 0;
}

/** Whether a status may be retired now, and why not: the rule the database applies, so the button can say it */
export function retireProblem(status: Pick<ConfigStatus, "key" | "isDefault" | "isWorking" | "isActive">, all: Pick<ConfigStatus, "key" | "isWorking" | "isActive">[]): "default" | "lastWorking" | null {
  if (!status.isActive) return null;
  if (status.isDefault) return "default";
  if (status.isWorking && !all.some((s) => s.key !== status.key && s.isActive && s.isWorking)) return "lastWorking";
  return null;
}

/** Statuses as the screen lists them: active ones in order, then retired ones when shown */
export function visibleStatuses<T extends Pick<ConfigStatus, "isActive" | "sortOrder" | "key">>(statuses: T[], showRetired: boolean): T[] {
  return statuses
    .filter((s) => showRetired || s.isActive)
    .sort((a, b) => Number(!a.isActive) - Number(!b.isActive) || a.sortOrder - b.sortOrder || a.key.localeCompare(b.key));
}

/** A new or edited status: the shape the route checks, so the form explains before sending */
export function statusFormProblem(f: { key: string; name: string }, isNew: boolean, existingKeys: string[]): "key" | "name" | "duplicate" | null {
  if (!/^[a-z0-9_]+$/.test(f.key) || f.key.length > 40) return "key";
  if (isNew && existingKeys.includes(f.key)) return "duplicate";
  if (f.name.trim().length === 0 || f.name.trim().length > 40) return "name";
  return null;
}

/** "nl, be  DE" → ["be", "de", "nl"]: lowercase two-letter tokens, deduplicated, in order */
export function parseMarkets(text: string): string[] | null {
  const tokens = text.split(/[\s,;]+/).map((t) => t.trim().toLowerCase()).filter(Boolean);
  if (tokens.some((t) => !/^[a-z]{2}$/.test(t))) return null;
  return [...new Set(tokens)].sort();
}

/** "Basic, Good, Fluent, Native" → a scale from 1 upwards; an empty text is a binary dimension */
export function parseLevels(text: string): SkillLevel[] | null {
  const names = text.split(/[,;\n]+/).map((t) => t.trim()).filter(Boolean);
  if (names.length > 10 || names.some((n) => n.length > 40)) return null;
  if (new Set(names.map((n) => n.toLowerCase())).size !== names.length) return null;
  return names.map((name, i) => ({ level: i + 1, name }));
}

export function levelsText(levels: SkillLevel[]): string {
  return [...levels].sort((a, b) => a.level - b.level).map((l) => l.name).join(", ");
}

/** The target for a team, work type and ISO weekday, 0 when none */
export function targetAt(targets: CoverageTargetRow[], teamKey: string, skillKey: string, weekday: number): number {
  return targets.find((t) => t.teamKey === teamKey && t.skillKey === skillKey && t.weekday === weekday)?.minCount ?? 0;
}

/** A typed target: a whole number from 0 to 99, or null when the text is not one */
export function parseTarget(text: string): number | null {
  const t = text.trim();
  if (t === "") return 0;
  if (!/^\d{1,2}$/.test(t)) return null;
  return Number(t);
}

/** The export settings as rows: catalog key, current value, whether it is the default, the allowed values */
export const EXPORT_SETTING_KEYS = [
  "export.csv.separator", "export.csv.decimal_mark", "export.csv.date_format", "export.csv.duration_format", "export.csv.utf8_bom",
] as const;
export type ExportSettingKey = (typeof EXPORT_SETTING_KEYS)[number];

export const EXPORT_SETTING_VALUES: Record<ExportSettingKey, readonly string[]> = {
  "export.csv.separator": ["comma", "semicolon", "tab"],
  "export.csv.decimal_mark": ["point", "comma"],
  "export.csv.date_format": ["yyyy-mm-dd", "dd-mm-yyyy", "dd/mm/yyyy", "mm/dd/yyyy"],
  "export.csv.duration_format": ["decimal_hours", "hh:mm", "minutes"],
  "export.csv.utf8_bom": ["true", "false"],
};

/** The minute settings the Exports page also shows (integers, no fixed list) */
export const MINUTE_SETTING_KEYS = ["roster.adherence_tolerance_minutes", "workday.auto_close_grace_minutes"] as const;
export type MinuteSettingKey = (typeof MINUTE_SETTING_KEYS)[number];

export function parseMinutes(text: string): number | null {
  if (!/^\d{1,4}$/.test(text.trim())) return null;
  return Number(text.trim());
}

/**
 * One header and one sample row of the hours file in the tenant's format, as a spreadsheet reads
 * it: the separator, the decimal mark, the date, a 7.5-hour duration and the byte order mark shown
 * as a word. Labels come from copy; the sample values are fixed and fictional.
 */
export function exportPreview(settings: TenantSetting[], labels: { date: string; person: string; worked: string; bom: string; noBom: string }): string[] {
  const s = exportSettingsFrom(settings);
  const csv = toCsv([labels.date, labels.person, labels.worked], [[formatDate("2026-10-08", s.dateFormat), "A. Example", formatDuration(27_000, s)]], s);
  const lines = csv.replace(/\r\n$/, "").split("\r\n");
  const bom = lines[0]?.startsWith("\uFEFF");
  return [(bom ? labels.bom : labels.noBom), ...lines.map((l) => l.replace(/^\uFEFF/, "").replace(/\t/g, " ⇥ "))];
}
