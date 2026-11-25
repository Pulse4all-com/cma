import "server-only";
import { ApiError, dateParam } from "./respond";
import type { AssignmentBlockInput, RosterCellInput } from "@/lib/data";

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

const BLOCK_START_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
const BLOCK_END_RE = /^(([01]\d|2[0-3]):[0-5]\d|24:00)$/;

/**
 * A person-date's blocks as the planner sends them (addition 0009zw): [{ code, start, end, hoursMarket?, note? }], at most 96;
 * times hh:mm in the person's zone (an end of 24:00 allowed), the hours market's code or null (own market). The
 * grid, the shift, overlap and the market's kind are the database's answers (400 or 404)
 */
export function blocksParam(raw: unknown): AssignmentBlockInput[] {
  if (!Array.isArray(raw) || raw.length > 96) throw new ApiError(400, "invalid_blocks", "blocks must be an array of at most 96 blocks");
  return raw.map((x) => {
    if (!x || typeof x !== "object" || Array.isArray(x)) throw new ApiError(400, "invalid_blocks", "each block is an object");
    const b = x as Record<string, unknown>;
    if (typeof b.code !== "string" || !/^[A-Z0-9]{1,6}$/.test(b.code)) throw new ApiError(400, "invalid_blocks", "code must be 1 to 6 of A-Z and 0-9");
    if (typeof b.start !== "string" || typeof b.end !== "string" || !BLOCK_START_RE.test(b.start) || !BLOCK_END_RE.test(b.end) || b.end <= b.start) {
      throw new ApiError(400, "invalid_blocks", "start and end must be hh:mm, the end after the start");
    }
    const market = b.hoursMarket === undefined || b.hoursMarket === null || b.hoursMarket === "" ? null : b.hoursMarket;
    if (market !== null && (typeof market !== "string" || !/^[A-Z]{2}$/.test(market))) throw new ApiError(400, "invalid_blocks", "hoursMarket must be a market code");
    const note = b.note === undefined || b.note === null || b.note === "" ? null : b.note;
    if (note !== null && (typeof note !== "string" || note.trim().length > 120)) throw new ApiError(400, "invalid_blocks", "note must be at most 120 characters");
    return { code: b.code, start: b.start, end: b.end, hoursMarket: market as string | null, note: note === null ? null : (note as string).trim() || null };
  });
}
