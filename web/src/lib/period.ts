/**
 * The period bar's state from the query string, shared by My hours and Team hours: today, this
 * week, this month or a custom range, all as calendar dates in the viewer's zone.
 */
import type { HoursRange } from "@/lib/data";
import { addDays, daysBetween, endOfMonth, isDateKey, startOfMonth, startOfWeek } from "@/lib/time";

export type Range = "today" | "week" | "month" | "custom";
export const RANGES: Range[] = ["today", "week", "month", "custom"];
export const RANGE_KEYS: Record<Range, string> = { today: "T", week: "W", month: "M", custom: "C" };

type Query = Record<string, string | string[] | undefined>;

export interface Period {
  range: Range;
  period: HoursRange;
  /** Why a custom range was refused; the period then falls back to today */
  invalid: null | "order" | "length";
}

export function resolvePeriod(sp: Query, today: string, maxDays?: number): Period {
  const rangeParam = typeof sp.range === "string" ? sp.range : "today";
  const range: Range = (RANGES as string[]).includes(rangeParam) ? (rangeParam as Range) : "today";
  switch (range) {
    case "today":
      return { range, period: { from: today, to: today }, invalid: null };
    case "week":
      return { range, period: { from: startOfWeek(today), to: addDays(startOfWeek(today), 6) }, invalid: null };
    case "month":
      return { range, period: { from: startOfMonth(today), to: endOfMonth(today) }, invalid: null };
    case "custom": {
      const from = isDateKey(sp.from) ? sp.from : addDays(today, -6);
      const to = isDateKey(sp.to) ? sp.to : today;
      const invalid = from > to ? "order" : maxDays && daysBetween(from, to) + 1 > maxDays ? "length" : null;
      return { range, period: invalid ? { from: today, to: today } : { from, to }, invalid };
    }
  }
}
