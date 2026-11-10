/**
 * Assets → Pledge lists (addition 0009j; Martin, 10 November 2026, D1 to D8): the quarter file of the early-stage
 * investors' loans as Pulse4all sends it to the Belastingdienst. The file is exactly the original's (D1): per active loan
 * with devices, by its number, three tabs (main, a, b) with the original's names, headers verbatim (Depriciating
 * included), each layout's column order, formats and column widths; the rows by SN AED as the database orders them.
 * This module turns a file's rows into the book (lib/xlsx writes its bytes) and holds the page's pure helpers. Pure: no
 * runtime import outside the pure libraries, so verify/pledges.mjs runs it without a build.
 *
 * Ids, codes, dates and amounts only; the lender label is the loan catalog's (an investor's name, D8): it is written in
 * the file's tab names and on the page, never in a log.
 */
import type { PledgeFileRow } from "@/lib/data";
import type { XlsxBook, XlsxCell, XlsxSheet } from "./xlsx.ts";

/** The permission of the page, its reads and its files (no default role, D7) */
export const PLEDGE_PERMISSIONS = ["pledges.view"] as const;
export const PLEDGES_PATH = "/reports/pledge-lists";
/** A file holds at most this many rows (the database refuses more, CMA04) */
export const PLEDGE_FILE_MAX_ROWS = 50_000;
/** A check's serials on the page */
export const PLEDGE_CHECK_ROWS = 500;
/** The checks before the next file, in the page's order (cma.pledge_check_keys) */
export const PLEDGE_CHECKS = ["unknown_loan", "no_model_values", "no_first_shipped", "no_language", "customer_ref_invalid", "no_start_date"] as const;
export type PledgeCheck = (typeof PLEDGE_CHECKS)[number];
export const isPledgeCheck = (v: unknown): v is PledgeCheck => typeof v === "string" && (PLEDGE_CHECKS as readonly string[]).includes(v);

/** The original's headers, verbatim */
export const H = {
  serial: "SN AED",
  type: "Type AED",
  country: "Country of location",
  language: "Language",
  loan: "LOAN SPV",
  customer: "Customer ID",
  acquisition: "Acquisition value (in EUR - excl BTW)",
  current: "Current value (in EUR - excl BTW)",
  depreciation: "Depreciation / Month",
  receipts: "Receipts (in EUR - incl BTW)",
  start: "Start date",
  shipped: "First Shipment Date",
  months: "Months Depriciating",
} as const;
type Column = keyof typeof H;

/** Each tab's columns in its own order: the main tab (both layouts), the a- and b-tabs per layout */
export const LAYOUTS: Record<"main" | "a1" | "a2" | "b1" | "b2", readonly Column[]> = {
  main: ["serial", "type", "country", "language", "loan", "customer", "acquisition", "current", "depreciation", "receipts", "start"],
  a1: ["type", "language", "serial", "country", "acquisition", "current", "loan", "shipped", "months", "depreciation"],
  a2: ["serial", "type", "country", "language", "loan", "shipped", "months", "depreciation", "acquisition", "current"],
  b1: ["serial", "customer", "country", "start", "receipts", "type", "language", "loan"],
  b2: ["serial", "customer", "type", "country", "language", "receipts", "loan", "start"],
};

/** The original main tab's column widths, applied by position in every tab */
export const WIDTHS = [9.5, 8.0, 14.8, 8.1, 8.6, 12.6, 27.9, 25.1, 15.9, 21.4, 17.9] as const;

/** A tab name's longest form in a spreadsheet */
export const TAB_NAME_MAX = 31;

const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

/** The file's name: <prefix>_<Month>_<yyyy>.xlsx from the valuation date, the month in English; today's version ends _preview */
export function pledgeFileName(prefix: string, valuationDate: string, preview: boolean): string {
  const [y, m] = ymd(valuationDate);
  const safe = /^[A-Za-z0-9_-]{1,60}$/.test(prefix) ? prefix : "Pledge_Lists";
  return `${safe}_${MONTHS[m - 1] ?? ""}_${String(y).padStart(4, "0")}${preview ? "_preview" : ""}.xlsx`;
}

export interface PledgeLoanTab {
  number: number;
  lenderLabel: string;
  areaLabel: string;
  nameSuffix: string;
  layout: 1 | 2;
}

/**
 * A tab's name: "{n}) {lender} ({count} {area}) {suffix}", "{n}a) {lender} Movable Assets (…) …", "{n}b) {lender}
 * Receivables (…) …", cut at 31 characters (by character, never inside one), an apostrophe the cut leaves at its end
 * dropped (a tab name never ends with one)
 */
export function tabName(kind: "main" | "a" | "b", loan: PledgeLoanTab, count: number): string {
  const middle = kind === "main" ? "" : kind === "a" ? " Movable Assets" : " Receivables";
  const full = `${loan.number}${kind === "main" ? "" : kind}) ${loan.lenderLabel}${middle} (${count} ${loan.areaLabel}) ${loan.nameSuffix}`;
  return [...full].slice(0, TAB_NAME_MAX).join("").replace(/'+$/, "");
}

/** Customer ID: a number with format 0 when it is digits only, at most 15, without a leading zero; else text; In Storage text */
export function customerCell(v: string | null): XlsxCell {
  if (v === null || v === "") return null;
  return /^(0|[1-9]\d{0,14})$/.test(v) ? { t: "n", v, s: "int" } : { t: "s", v };
}

/** A date's year, month and day (YYYY-MM-DD) */
function ymd(date: string): [number, number, number] {
  const [y = "0", m = "1", d = "1"] = date.split("-");
  return [Number(y), Number(m), Number(d)];
}

/** A date (YYYY-MM-DD) as Excel's serial (days since 1899-12-30, counted in UTC) */
export function dateSerial(date: string): number {
  const [y, m, d] = ymd(date);
  return Math.round((Date.UTC(y, m - 1, d) - Date.UTC(1899, 11, 30)) / 86_400_000);
}

const money = (v: string | null): XlsxCell => (v === null ? null : { t: "n", v, s: "money" });
const text = (v: string | null): XlsxCell => (v === null || v === "" ? null : { t: "s", v });
const date = (v: string | null): XlsxCell => (v === null ? null : { t: "n", v: String(dateSerial(v)), s: "date" });

/** One cell of a row */
export function cellOf(column: Column, r: PledgeFileRow): XlsxCell {
  switch (column) {
    case "serial": return text(r.serial);
    case "type": return text(r.typeLabel);
    case "country": return text(r.market);
    case "language": return text(r.language);
    case "loan": return { t: "n", v: String(r.loanNumber), s: "general" };
    case "customer": return customerCell(r.customerId);
    case "acquisition": return money(r.acquisitionValue);
    case "current": return money(r.currentValue);
    case "depreciation": return money(r.depreciationPerMonth);
    case "receipts": return money(r.receipts);
    case "start": return date(r.startDate);
    case "shipped": return date(r.firstShippedOn);
    case "months": return { t: "n", v: String(r.monthsDepreciating), s: "int" };
  }
}

function sheetOf(name: string, columns: readonly Column[], rows: readonly PledgeFileRow[]): XlsxSheet {
  return { name, widths: WIDTHS.slice(0, columns.length), header: columns.map((c) => H[c]), rows: rows.map((r) => columns.map((c) => cellOf(c, r))) };
}

/**
 * The book of a file's rows: per loan by number (the loan's labels and layout as the rows carry them, so a stored file
 * keeps the labels it was taken with), its main, a- and b-tabs, the rows in the given order (by SN AED, the database's).
 * A loan without rows has no tab; a file without rows has no book (null)
 */
export function pledgeBook(rows: readonly PledgeFileRow[], valuationDate: string): XlsxBook | null {
  const loans = new Map<number, PledgeFileRow[]>();
  for (const r of rows) {
    const list = loans.get(r.loanNumber);
    if (list) list.push(r);
    else loans.set(r.loanNumber, [r]);
  }
  const sheets: XlsxSheet[] = [];
  for (const number of [...loans.keys()].sort((a, b) => a - b)) {
    const list = loans.get(number) ?? [];
    const first = list[0];
    if (!first) continue;
    const loan: PledgeLoanTab = { number, lenderLabel: first.lenderLabel, areaLabel: first.areaLabel, nameSuffix: first.nameSuffix, layout: first.layout };
    const n = list.length;
    sheets.push(sheetOf(tabName("main", loan, n), LAYOUTS.main, list));
    sheets.push(sheetOf(tabName("a", loan, n), loan.layout === 2 ? LAYOUTS.a2 : LAYOUTS.a1, list));
    sheets.push(sheetOf(tabName("b", loan, n), loan.layout === 2 ? LAYOUTS.b2 : LAYOUTS.b1, list));
  }
  return sheets.length ? { sheets, date: valuationDate } : null;
}

/** A valuation date in a file's path: the first day of a quarter as YYYY-MM-DD, years 2000 to 2999; "today" for today's version */
export function fileDateParam(value: string): string | "today" | null {
  if (value === "today") return "today";
  const m = /^(2\d{3})-(01|04|07|10)-01$/.exec(value);
  return m ? value : null;
}

/** A sum in EUR for the page (decimal text from the database), in the locale's currency format (€1,250.00; € 1.250,00) */
export function fmtAmount(v: string, locale: "en" | "nl"): string {
  return new Intl.NumberFormat(locale === "nl" ? "nl-NL" : "en-GB", { style: "currency", currency: "EUR", minimumFractionDigits: 2, maximumFractionDigits: 2 })
    .format(Number(v));
}
