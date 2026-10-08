import "server-only";
import { ApiError, dateParam } from "./respond";
import type { RosterCellInput } from "@/lib/data";

/** A Monday in YYYY-MM-DD, or a 400: a roster week starts on a Monday (cma.assert_week_start checks again) */
export function weekStartParam(value: string | null | undefined): string {
  const d = dateParam(value ?? null, "weekStart");
  if (new Date(`${d}T00:00:00Z`).getUTCDay() !== 1) throw new ApiError(400, "invalid_week", "weekStart must be a Monday");
  return d;
}

const KEY_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;

/** The team of a roster: a team key, or null for the whole tenant; whether it exists is the database's answer */
export function teamParam(value: unknown): string | null {
  if (value === undefined || value === null || value === "") return null;
  if (typeof value !== "string" || !KEY_RE.test(value)) throw new ApiError(400, "invalid_team", "team must be a team key");
  return value;
}

const TIME_RE = /^([01]\d|2[0-4]):[0-5]\d$/;

/** A cell as the planner sends it: { kind: "shift", start, end, note? } | { kind: "absence", absenceKey, note? } | { kind: "clear" } */
export function cellParam(raw: unknown): RosterCellInput {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new ApiError(400, "invalid_cell", "cell must be an object");
  const c = raw as Record<string, unknown>;
  const note = c.note === undefined || c.note === null ? null : typeof c.note === "string" && c.note.trim().length <= 200 ? c.note.trim() || null : undefined;
  if (note === undefined) throw new ApiError(400, "invalid_cell", "note must be at most 200 characters");
  if (c.kind === "clear") return { kind: "clear" };
  if (c.kind === "shift") {
    if (typeof c.start !== "string" || typeof c.end !== "string" || !TIME_RE.test(c.start) || !TIME_RE.test(c.end)) {
      throw new ApiError(400, "invalid_cell", "start and end must be hh:mm");
    }
    if (c.start === "24:00" || c.end <= c.start) throw new ApiError(400, "invalid_cell", "a shift ends after it starts, within the day");
    return { kind: "shift", start: c.start, end: c.end, note };
  }
  if (c.kind === "absence") {
    if (typeof c.absenceKey !== "string" || !KEY_RE.test(c.absenceKey.replace(/_/g, "-"))) throw new ApiError(400, "invalid_cell", "absenceKey must be a key");
    return { kind: "absence", absenceKey: c.absenceKey, note };
  }
  throw new ApiError(400, "invalid_cell", "kind must be shift, absence or clear");
}
