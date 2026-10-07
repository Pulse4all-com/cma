/**
 * The two exports of Team hours as CSV text: hours per person per day, and status changes.
 * Pure and without runtime imports, so verify/csv.mjs tests it without a browser or a database.
 *
 * The format follows the tenant's settings (cma.tenant_settings, migration 0003b): separator,
 * decimal mark, date format, duration format and the UTF-8 byte order mark. Times are 24-hour
 * hh:mm in each day's own zone, the zone named per row. Labels come from the caller (copy.ts),
 * so the file speaks the viewer's language and no column name is in code.
 *
 * Every text cell that a spreadsheet would read as a formula (=, +, -, @, tab, carriage return
 * at the start) gets a leading apostrophe: names are typed by people, and a CSV opened in a
 * spreadsheet program must never run them.
 */
import type { ExportHoursRow, StatusChangeRow, TenantSetting } from "./data/types";

export type Separator = "comma" | "semicolon" | "tab";
export type DecimalMark = "point" | "comma";
export type DateFormat = "yyyy-mm-dd" | "dd-mm-yyyy" | "dd/mm/yyyy" | "mm/dd/yyyy";
export type DurationFormat = "decimal_hours" | "hh:mm" | "minutes";

export interface ExportSettings {
  separator: Separator;
  decimalMark: DecimalMark;
  dateFormat: DateFormat;
  durationFormat: DurationFormat;
  utf8Bom: boolean;
}

/** The catalog defaults of migration 0003b; used only for a value the catalog does not know */
export const DEFAULT_EXPORT_SETTINGS: ExportSettings = {
  separator: "comma",
  decimalMark: "point",
  dateFormat: "yyyy-mm-dd",
  durationFormat: "decimal_hours",
  utf8Bom: true,
};

const SEPARATORS: Record<Separator, string> = { comma: ",", semicolon: ";", tab: "\t" };
const pick = <T extends string>(value: string | undefined, allowed: readonly T[], fallback: T): T =>
  allowed.includes(value as T) ? (value as T) : fallback;

/** The effective settings as the database answers them, typed */
export function exportSettingsFrom(list: TenantSetting[]): ExportSettings {
  const v = (key: string) => list.find((s) => s.key === key)?.value;
  const d = DEFAULT_EXPORT_SETTINGS;
  return {
    separator: pick(v("export.csv.separator"), ["comma", "semicolon", "tab"], d.separator),
    decimalMark: pick(v("export.csv.decimal_mark"), ["point", "comma"], d.decimalMark),
    dateFormat: pick(v("export.csv.date_format"), ["yyyy-mm-dd", "dd-mm-yyyy", "dd/mm/yyyy", "mm/dd/yyyy"], d.dateFormat),
    durationFormat: pick(v("export.csv.duration_format"), ["decimal_hours", "hh:mm", "minutes"], d.durationFormat),
    utf8Bom: v("export.csv.utf8_bom") === undefined ? d.utf8Bom : v("export.csv.utf8_bom") === "true",
  };
}

// ---- cells ----------------------------------------------------------------------------------

/** A cell a spreadsheet would read as a formula gets a leading apostrophe */
export function safeText(value: string): string {
  return /^[=+\-@\t\r]/.test(value) ? `'${value}` : value;
}

/** Quotes a cell when it holds the separator, a quote or a line break (RFC 4180) */
export function quote(cell: string, separator: string): string {
  return cell.includes(separator) || /["\r\n]/.test(cell) ? `"${cell.replaceAll('"', '""')}"` : cell;
}

/** YYYY-MM-DD in the tenant's date format */
export function formatDate(key: string, format: DateFormat): string {
  const [y, m, d] = key.split("-");
  switch (format) {
    case "dd-mm-yyyy": return `${d}-${m}-${y}`;
    case "dd/mm/yyyy": return `${d}/${m}/${y}`;
    case "mm/dd/yyyy": return `${m}/${d}/${y}`;
    default: return key;
  }
}

/**
 * Seconds as a duration. Whole minutes first (rounded down), the same figure the screens show,
 * so a file and the screen never differ by a minute.
 */
export function formatDuration(seconds: number, s: Pick<ExportSettings, "durationFormat" | "decimalMark">): string {
  const minutes = Math.floor(Math.max(0, seconds) / 60);
  if (s.durationFormat === "minutes") return String(minutes);
  if (s.durationFormat === "hh:mm") return `${Math.floor(minutes / 60)}:${String(minutes % 60).padStart(2, "0")}`;
  const hours = (Math.round((minutes / 60) * 100) / 100).toFixed(2);
  return s.decimalMark === "comma" ? hours.replace(".", ",") : hours;
}

/** 24-hour hh:mm of an instant in a zone */
export function formatTime(instant: string, timeZone: string): string {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone, hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  }).formatToParts(new Date(instant));
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "00";
  return `${get("hour")}:${get("minute")}`;
}

/** Rows to CSV text: optional byte order mark, CRLF line ends, every cell quoted where needed */
export function toCsv(header: string[], rows: string[][], s: Pick<ExportSettings, "separator" | "utf8Bom">): string {
  const sep = SEPARATORS[s.separator];
  const line = (cells: string[]) => cells.map((c) => quote(c, sep)).join(sep);
  return (s.utf8Bom ? "\uFEFF" : "") + [header, ...rows].map(line).join("\r\n") + "\r\n";
}

// ---- the two files --------------------------------------------------------------------------

export interface HoursLabels {
  date: string; person: string; employer: string; timeZone: string; clockedIn: string; clockedOut: string;
  worked: string; paid: string; billable: string; notClockedOut: string; corrected: string; yes: string; no: string;
}

/** Hours per person per day: one row per day, as Team hours shows it, plus billable time */
export function hoursCsv(rows: ExportHoursRow[], s: ExportSettings, l: HoursLabels): string {
  const yn = (b: boolean) => (b ? l.yes : l.no);
  return toCsv(
    [l.date, l.person, l.employer, l.timeZone, l.clockedIn, l.clockedOut, l.worked, l.paid, l.billable, l.notClockedOut, l.corrected],
    rows.map((r) => [
      formatDate(r.date, s.dateFormat),
      safeText(r.displayName),
      safeText(r.organisationName),
      r.timeZone,
      formatTime(r.startedAt, r.timeZone),
      r.endedAt ? formatTime(r.endedAt, r.timeZone) : "",
      formatDuration(r.workedSeconds, s),
      formatDuration(r.paidSeconds, s),
      formatDuration(r.billableSeconds, s),
      yn(r.isCapped),
      yn(r.hasCorrection),
    ]),
    s,
  );
}

export interface StatusChangeLabels {
  date: string; person: string; employer: string; timeZone: string; status: string; from: string; to: string;
  duration: string; working: string; paid: string; billable: string; enteredBy: string; notClockedOut: string;
  yes: string; no: string; sourceUser: string; sourceSystem: string; sourceCorrection: string;
}

/** One row per stretch in a status, from its change to the next; an open stretch has no end */
export function statusChangesCsv(rows: StatusChangeRow[], s: ExportSettings, l: StatusChangeLabels): string {
  const yn = (b: boolean) => (b ? l.yes : l.no);
  const source = { user: l.sourceUser, system: l.sourceSystem, correction: l.sourceCorrection } as const;
  return toCsv(
    [l.date, l.person, l.employer, l.timeZone, l.status, l.from, l.to, l.duration, l.working, l.paid, l.billable, l.enteredBy, l.notClockedOut],
    rows.map((r) => [
      formatDate(r.date, s.dateFormat),
      safeText(r.displayName),
      safeText(r.organisationName),
      r.timeZone,
      safeText(r.statusName),
      formatTime(r.from, r.timeZone),
      r.to ? formatTime(r.to, r.timeZone) : "",
      formatDuration(r.seconds, s),
      yn(r.isWorking),
      yn(r.isPaid),
      yn(r.isBillable),
      source[r.source],
      yn(r.isCapped),
    ]),
    s,
  );
}
