/**
 * The period bar's state from the query string, shared by every page with the period bar (My hours,
 * Team hours and the reports): yesterday, today, this week, this month or a custom range, all as
 * calendar dates in the viewer's zone. Without a range, or with one it does not know, the period is
 * today. Yesterday is a period that has ended, so the reports compare it with the whole day before
 * (previousPeriod in lib/reports, README Decision log, 14 October 2026).
 */
import type { HoursRange } from "@/lib/data";
import { addDays, daysBetween, endOfMonth, isDateKey, startOfMonth, startOfWeek } from "./time.ts";

export type Range = "yesterday" | "today" | "week" | "month" | "custom";
export const RANGES: Range[] = ["yesterday", "today", "week", "month", "custom"];
export const RANGE_KEYS: Record<Range, string> = { yesterday: "Y", today: "T", week: "W", month: "M", custom: "C" };

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
    case "yesterday":
      return { range, period: { from: addDays(today, -1), to: addDays(today, -1) }, invalid: null };
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
