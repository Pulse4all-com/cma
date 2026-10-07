/**
 * Calendar helpers. Instants are UTC on the wire; every calendar decision
 * (which day, which week) is taken in the user's time zone.
 */
import type { DateKey, Instant } from "@/lib/data/types";
import type { Locale } from "@/lib/copy";

const keyFormatters = new Map<string, Intl.DateTimeFormat>();

/** YYYY-MM-DD of an instant in a zone */
export function dateKeyInZone(instant: Instant | Date, timeZone: string): DateKey {
  let f = keyFormatters.get(timeZone);
  if (!f) {
    // en-CA renders ISO order: 2026-10-05
    f = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" });
    keyFormatters.set(timeZone, f);
  }
  return f.format(typeof instant === "string" ? new Date(instant) : instant);
}

/** The hour (0 to 23) of an instant in a zone, for a greeting by time of day */
export function hourInZone(instant: Instant | Date, timeZone: string): number {
  const part = new Intl.DateTimeFormat("en-GB", { timeZone, hour: "numeric", hourCycle: "h23" })
    .formatToParts(typeof instant === "string" ? new Date(instant) : instant)
    .find((p) => p.type === "hour")?.value;
  return Number(part ?? 0) % 24;
}

function toUtcDate(key: DateKey): Date {
  const [y, m, d] = key.split("-").map(Number) as [number, number, number];
  return new Date(Date.UTC(y, m - 1, d));
}

export function addDays(key: DateKey, days: number): DateKey {
  const d = toUtcDate(key);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

/** Whole days from a to b (0 when equal) */
export function daysBetween(a: DateKey, b: DateKey): number {
  return Math.round((toUtcDate(b).getTime() - toUtcDate(a).getTime()) / 86_400_000);
}

/** Monday of the week that holds the date */
export function startOfWeek(key: DateKey): DateKey {
  const dow = toUtcDate(key).getUTCDay(); // 0 = Sunday
  return addDays(key, dow === 0 ? -6 : 1 - dow);
}

export function startOfMonth(key: DateKey): DateKey {
  return `${key.slice(0, 8)}01`;
}

export function endOfMonth(key: DateKey): DateKey {
  const d = toUtcDate(startOfMonth(key));
  d.setUTCMonth(d.getUTCMonth() + 1);
  d.setUTCDate(0);
  return d.toISOString().slice(0, 10);
}

export function isDateKey(value: unknown): value is DateKey {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value) && !Number.isNaN(toUtcDate(value).getTime());
}

const intlLocale: Record<Locale, string> = { en: "en-GB", nl: "nl-NL" };

/** 08:02 */
export function fmtTime(instant: Instant, timeZone: string, locale: Locale): string {
  return new Intl.DateTimeFormat(intlLocale[locale], { timeZone, hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date(instant));
}

/**
 * long:    Thu 12 March 2026 / do 12 maart 2026 (style guide section 4)
 * short:   12 Mar
 * compact: Thu 12 Mar, for table rows
 */
export function fmtDate(key: DateKey, locale: Locale, style: "long" | "short" | "compact" = "long"): string {
  const d = toUtcDate(key);
  return new Intl.DateTimeFormat(intlLocale[locale], {
    timeZone: "UTC",
    weekday: style === "short" ? undefined : "short",
    day: "numeric",
    month: style === "long" ? "long" : "short",
    year: style === "long" ? "numeric" : undefined,
  }).format(d);
}

/** The zone's short name at an instant (CEST, BST), for times shown in someone else's zone */
export function fmtZoneShort(instant: Instant, timeZone: string, locale: Locale): string {
  return new Intl.DateTimeFormat(intlLocale[locale], { timeZone, timeZoneName: "short" })
    .formatToParts(new Date(instant))
    .find((p) => p.type === "timeZoneName")?.value ?? timeZone;
}

/** True when two zones show the same clock time at an instant (Madrid and Amsterdam do, London does not) */
export function sameOffset(instant: Instant, zoneA: string, zoneB: string): boolean {
  const offset = (timeZone: string) =>
    new Intl.DateTimeFormat("en", { timeZone, timeZoneName: "longOffset" })
      .formatToParts(new Date(instant))
      .find((p) => p.type === "timeZoneName")?.value ?? timeZone;
  return offset(zoneA) === offset(zoneB);
}

/** 7h 12m */
export function fmtMinutes(minutes: number): string {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return h === 0 ? `${m}m` : `${h}h ${String(m).padStart(2, "0")}m`;
}

/** 82%, whole percents; "< 1%" for a small share that is not zero; a dash when there is nothing to divide by */
export function fmtPercent(share: number | null, locale: Locale): string {
  if (share === null) return "–";
  const f = new Intl.NumberFormat(intlLocale[locale], { style: "percent", maximumFractionDigits: 0 });
  return share > 0 && share < 0.005 ? `< ${f.format(0.01)}` : f.format(share);
}
