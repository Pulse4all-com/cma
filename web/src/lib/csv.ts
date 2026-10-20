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
import type {
  CancellationsReport, ExportHoursRow, FirstOrderLevel, FirstOrderListRow, FunnelGroup, FunnelStageRow, LostReasonRow, StatusChangeRow, TenantSetting,
} from "./data/types";

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
  yes: string; no: string; sourceUser: string; sourceSystem: string; sourceCorrection: string; sourceImport: string;
}

/** One row per stretch in a status, from its change to the next; an open stretch has no end */
export function statusChangesCsv(rows: StatusChangeRow[], s: ExportSettings, l: StatusChangeLabels): string {
  const yn = (b: boolean) => (b ? l.yes : l.no);
  const source = { user: l.sourceUser, system: l.sourceSystem, correction: l.sourceCorrection, import: l.sourceImport } as const;
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

// ---- Reports > Forms (addition 0008p; brief B17d) ---------------------------------------------

export interface FormsLabels {
  from: string; to: string; form: string; category: string; market: string; submissions: string; previous: string;
  resolved: string; notFound: string; ambiguous: string; noEmail: string; pending: string; noCategory: string; unknownMarket: string;
}

/** A form in a market over the period, as the report's table shows it: the forms report's lines */
export interface FormsCsvLine {
  formName: string; category: string | null; market: string; submissions: number; previous: number;
  resolved: number; notFound: number; ambiguous: number; noEmail: number; pending: number;
}

/**
 * One row per form and market, as Reports > Forms shows it: the period, the form, its category (the tenant's
 * name, the code when the catalog lacks it), the market, the submissions and the previous period's, then the
 * resolution split. Counts only: no submission, contact or answer to a field that is no choice field.
 */
export function formsCsv(lines: FormsCsvLine[], from: string, to: string, categoryNames: Record<string, string>, s: ExportSettings, l: FormsLabels): string {
  return toCsv(
    [l.from, l.to, l.form, l.category, l.market, l.submissions, l.previous, l.resolved, l.notFound, l.ambiguous, l.noEmail, l.pending],
    lines.map((r) => [
      formatDate(from, s.dateFormat),
      formatDate(to, s.dateFormat),
      safeText(r.formName),
      r.category === null ? l.noCategory : safeText(categoryNames[r.category] ?? r.category),
      r.market === "unknown" ? l.unknownMarket : r.market,
      String(r.submissions),
      String(r.previous),
      String(r.resolved),
      String(r.notFound),
      String(r.ambiguous),
      String(r.noEmail),
      String(r.pending),
    ]),
    s,
  );
}

// ---- Reports > First orders (addition 0008u; brief N19-A part 2) -------------------------------------------

export interface FirstOrdersLabels {
  from: string; to: string; deal: string; orderedAt: string; market: string; level: string; attribution: string; leadDeal: string; conversation: string;
  email: string; phoneMatch: string; attempt: string; knownContact: string; currency: string; amount: string; days: string; yes: string; no: string;
  callCenter: string; selfService: string; unknownMarket: string;
}

/** The date of an instant in a zone as YYYY-MM-DD (Intl, no runtime import) */
function dateInZone(instant: string, timeZone: string): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(instant));
}

/**
 * One row per first order, as Reports > First orders lists it: the period, the deal's id, when it was ordered
 * (date and time in the reader's zone), the market, the level (in the reader's words), the attribution, each piece
 * of evidence as yes or no, the currency and amount (decimal mark from the settings, never summed), the days from the
 * first touch. Ids, codes, amounts and times only: no name, address or phone number exists to export.
 */
export function firstOrdersCsv(rows: FirstOrderListRow[], from: string, to: string, timeZone: string, s: ExportSettings, l: FirstOrdersLabels,
  levelNames: Record<FirstOrderLevel, string>): string {
  const yn = (v: boolean) => (v ? l.yes : l.no);
  const decimal = (v: number | null) => (v === null ? "" : s.decimalMark === "comma" ? v.toFixed(2).replace(".", ",") : v.toFixed(2));
  return toCsv(
    [l.from, l.to, l.deal, l.orderedAt, l.market, l.level, l.attribution, l.leadDeal, l.conversation, l.email, l.phoneMatch, l.attempt, l.knownContact,
      l.currency, l.amount, l.days],
    rows.map((r) => [
      formatDate(from, s.dateFormat),
      formatDate(to, s.dateFormat),
      safeText(r.dealSourceId),
      `${formatDate(dateInZone(r.createdAt, timeZone), s.dateFormat)} ${formatTime(r.createdAt, timeZone)}`,
      r.market === "unknown" ? l.unknownMarket : r.market,
      levelNames[r.level],
      r.attribution === "call_center" ? l.callCenter : l.selfService,
      yn(r.evidence.lead_deal), yn(r.evidence.conversation), yn(r.evidence.email), yn(r.evidence.phone_match), yn(r.evidence.attempt),
      yn(r.evidence.known_contact),
      r.currency ?? "",
      decimal(r.amount),
      decimal(r.daysFromFirstTouch),
    ]),
    s,
  );
}

// ---- Reports > Funnel and Cancellations (addition 0008zb) --------------------------------------------------

export interface FunnelFileLabels {
  from: string; to: string; pipeline: string; stage: string; readsTimes: string; entered: string; stillThere: string; movedOn: string; medianDays: string;
  p80Days: string; reachedWon: string; enteredPrevious: string; yes: string; no: string;
}

/** A number with the tenant's decimal mark and fixed decimals; empty for none */
function decimalOf(v: number | null, digits: number, s: Pick<ExportSettings, "decimalMark">): string {
  if (v === null) return "";
  const text = v.toFixed(digits);
  return s.decimalMark === "comma" ? text.replace(".", ",") : text;
}

/**
 * One row per stage, as Reports > Funnel shows it: the period, the pipeline, the stage, whether its times are read, then
 * entered, still there, moved on, the median and 80th percentile of days in the stage, reached won and entered in the
 * previous period; empty figures for a stage whose times are not read. Counts and days only
 */
export function funnelStagesCsv(rows: FunnelStageRow[], from: string, to: string, s: ExportSettings, l: FunnelFileLabels): string {
  const n = (v: number | null) => (v === null ? "" : String(v));
  return toCsv(
    [l.from, l.to, l.pipeline, l.stage, l.readsTimes, l.entered, l.stillThere, l.movedOn, l.medianDays, l.p80Days, l.reachedWon, l.enteredPrevious],
    rows.map((r) => [
      formatDate(from, s.dateFormat), formatDate(to, s.dateFormat), safeText(r.pipelineLabel), safeText(r.label), r.readsTimes ? l.yes : l.no,
      n(r.entered), n(r.stillThere), n(r.movedOn), decimalOf(r.medianDays, 1, s), decimalOf(r.p80Days, 1, s), n(r.reachedWon), n(r.enteredPrevious),
    ]),
    s,
  );
}

export interface LostReasonsFileLabels {
  from: string; to: string; reason: string; value: string; kind: string; deals: string; share: string; real: string; dataQuality: string; none: string;
  noReason: string;
}

/**
 * One row per lost reason, as Reports > Funnel shows them: the real reasons with their share of the real lost deals, the
 * data-quality reasons with their share of every lost deal, then no reason; the share as a fraction with four decimals.
 * The option's label and value only, never free text
 */
export function lostReasonsCsv(reasons: LostReasonRow[], dataQuality: LostReasonRow[], noReason: { deals: number; share: number | null }, from: string, to: string,
  s: ExportSettings, l: LostReasonsFileLabels): string {
  const row = (r: LostReasonRow, kind: string) => [formatDate(from, s.dateFormat), formatDate(to, s.dateFormat), safeText(r.label), safeText(r.value), kind,
    String(r.deals), decimalOf(r.share, 4, s)];
  return toCsv(
    [l.from, l.to, l.reason, l.value, l.kind, l.deals, l.share],
    [...reasons.map((r) => row(r, l.real)), ...dataQuality.map((r) => row(r, l.dataQuality)),
      [formatDate(from, s.dateFormat), formatDate(to, s.dateFormat), l.noReason, "", l.none, String(noReason.deals), decimalOf(noReason.share, 4, s)]],
    s,
  );
}

export interface CancellationsFileLabels {
  period: string; day: string; week: string; market: string; requests: string; open: string; closed: string; medianDays: string; unknownMarket: string;
}

/**
 * One row per day or week (its Monday) and market, as Reports > Cancellations counts them: the requests created, open and
 * closed now, the median days to close. It counts requests, never contracts. Counts and days only
 */
export function cancellationsCsv(rows: CancellationsReport["byPeriod"], group: FunnelGroup, s: ExportSettings, l: CancellationsFileLabels): string {
  return toCsv(
    [l.period, l.market, l.requests, l.open, l.closed, l.medianDays],
    rows.map((r) => [
      `${group === "week" ? l.week : l.day} ${formatDate(r.key, s.dateFormat)}`, r.market === "unknown" ? l.unknownMarket : r.market,
      String(r.requests), String(r.open), String(r.closed), decimalOf(r.medianDaysToClose, 1, s),
    ]),
    s,
  );
}
