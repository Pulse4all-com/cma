/**
 * Callbacks kept (addition 0008w, brief N19-A part 4; KPI 5): the definition of cma.callbacks_kept_of written once more
 * for the mock and its verifier, the figures per ISO week and per person, and the kept share for the screens. A
 * callback is a task of a type marked as a callback and counted; it is kept when a call to its contact (not inbound)
 * starts within tasks.callback_window_minutes before or after its due time, both edges included; not kept once that
 * window has closed without one; pending while it is open. Without a contact or a due time it is counted apart. Pure,
 * with no runtime imports beyond time.ts and reports.ts, so the verifier runs it under Node's type stripping.
 */
import type { CallbackCounts, CallbackOwner, CallbackState, CallbackWeek, DateKey, Instant } from "./data/types.ts";
import { timeInZone } from "./reports.ts";
import { addDays, dateKeyInZone, startOfWeek } from "./time.ts";

/** The team figures: the same permissions as the other reports (cma.callbacks_kept_report) */
export const CALLBACKS_PERMISSIONS = ["reports.view", "performance.team"] as const;
/** Per person: performance.team, as Follow-up's per person (cma.callbacks_kept_per_owner) */
export const CALLBACKS_PER_OWNER_PERMISSION = "performance.team";
/** How many ISO weeks Follow-up shows: the current week and the seven before it (the screen's span, not a business rule) */
export const CALLBACK_WEEKS = 8;

/** Follow-up's span: from the Monday seven weeks before this week's to today (56 days at most, within the 92-day range) */
export function callbackWeeksRange(today: DateKey): { from: DateKey; to: DateKey } {
  return { from: addDays(startOfWeek(today), -7 * (CALLBACK_WEEKS - 1)), to: today };
}

/** Kept as a share of the callbacks decided (kept or not kept); pending ones wait for their window; null without any */
export function keptShare(c: Pick<CallbackCounts, "kept" | "notKept">): number | null {
  const decided = c.kept + c.notKept;
  return decided === 0 ? null : c.kept / decided;
}

export const NO_CALLBACKS: CallbackCounts = { callbacks: 0, kept: 0, notKept: 0, pending: 0, noContact: 0, noDue: 0 };

/** A callback task as the mock holds it: only tasks of a counted callback type, not deleted */
export interface CallbackTaskFixture {
  id: string;
  ownerRef: string | null;
  contactId: string | null;
  dueAt: Instant | null;
  createdAt: Instant;
}

/** A call to a contact as the mock holds it: its start and direction */
export interface CallbackCallFixture {
  contactId: string;
  at: Instant;
  direction: "inbound" | "outbound" | "unknown";
}

/** One callback with its state, as cma.callbacks_kept_of returns it */
export interface CallbackRecord {
  id: string;
  ownerRef: string | null;
  state: CallbackState;
  businessDate: DateKey;
  weekStart: DateKey;
  /** HH:MM:SS of the due time (else the creation) in the tenant's zone, for the previous period like for like */
  localTime: string;
  callAt: Instant | null;
  minutesFromDue: number | null;
}

/** Every callback with its state at `now`: the earliest call not inbound within the window around the due time */
export function callbackRecords(tasks: CallbackTaskFixture[], calls: CallbackCallFixture[], windowMinutes: number, now: Date,
                                timeZone: string): CallbackRecord[] {
  const win = windowMinutes * 60_000;
  return tasks.map((k) => {
    const placed = k.dueAt ?? k.createdAt;
    const businessDate = dateKeyInZone(placed, timeZone);
    let callAt: Instant | null = null;
    if (k.dueAt !== null && k.contactId !== null) {
      const due = Date.parse(k.dueAt);
      const within = calls
        .filter((c) => c.contactId === k.contactId && c.direction !== "inbound" && Math.abs(Date.parse(c.at) - due) <= win)
        .map((c) => c.at)
        .sort((a, b) => Date.parse(a) - Date.parse(b));
      callAt = within[0] ?? null;
    }
    const state: CallbackState = k.dueAt === null ? "no_due"
      : k.contactId === null ? "no_contact"
      : callAt !== null ? "kept"
      : Date.parse(k.dueAt) + win > now.getTime() ? "pending"
      : "not_kept";
    return {
      id: k.id, ownerRef: k.ownerRef, state, businessDate, weekStart: startOfWeek(businessDate), localTime: timeInZone(placed, timeZone), callAt,
      minutesFromDue: callAt !== null && k.dueAt !== null ? Math.round((Date.parse(callAt) - Date.parse(k.dueAt)) / 60_000) : null,
    };
  });
}

function count(records: CallbackRecord[]): CallbackCounts {
  const n = (s: CallbackState) => records.filter((r) => r.state === s).length;
  return {
    callbacks: n("kept") + n("not_kept") + n("pending"), kept: n("kept"), notKept: n("not_kept"), pending: n("pending"),
    noContact: n("no_contact"), noDue: n("no_due"),
  };
}

/** The callbacks of [from, to] by business date; `until` keeps the last day up to that time of day (the previous period while one runs) */
export function callbacksInPeriod(records: CallbackRecord[], from: DateKey, to: DateKey, until: string | null = null): CallbackRecord[] {
  return records.filter((r) => r.businessDate >= from && r.businessDate <= to && (until === null || r.businessDate < to || r.localTime <= until));
}

/** Per ISO week (the weeks with a callback, oldest first) and in total, as cma.callbacks_kept_figures_of */
export function callbackFigures(records: CallbackRecord[]): { weeks: CallbackWeek[]; total: CallbackCounts } {
  const weeks = [...new Set(records.map((r) => r.weekStart))].sort();
  return {
    weeks: weeks.map((w) => ({ weekStart: w, ...count(records.filter((r) => r.weekStart === w)) })),
    total: count(records),
  };
}

/**
 * Per person by name, never ranked (the owner through the linked accounts), the owners without a person as one row
 * with how many owner ids that is, the total; callbacks without a due time left out, as cma.callbacks_kept_per_owner_of
 */
export function callbacksPerOwner(records: CallbackRecord[], personOf: (ownerRef: string) => { userId: string; name: string } | null):
  { rows: CallbackOwner[]; total: CallbackOwner } {
  const rows = records.filter((r) => r.state !== "no_due");
  const people = new Map<string, { name: string; records: CallbackRecord[] }>();
  const unlinked: CallbackRecord[] = [];
  for (const r of rows) {
    const p = r.ownerRef === null ? null : personOf(r.ownerRef);
    if (!p) { unlinked.push(r); continue; }
    const at = people.get(p.userId) ?? { name: p.name, records: [] };
    at.records.push(r);
    people.set(p.userId, at);
  }
  const of = (kind: CallbackOwner["kind"], userId: string | null, name: string | null, list: CallbackRecord[], owners: number | null): CallbackOwner => {
    const c = count(list);
    return { kind, userId, name, unlinkedOwners: owners, callbacks: c.callbacks, kept: c.kept, notKept: c.notKept, pending: c.pending, noContact: c.noContact };
  };
  const out = [...people.entries()].sort((a, b) => a[1].name.localeCompare(b[1].name) || a[0].localeCompare(b[0]))
    .map(([id, p]) => of("person", id, p.name, p.records, null));
  if (unlinked.length > 0) out.push(of("notLinked", null, null, unlinked, new Set(unlinked.flatMap((r) => (r.ownerRef === null ? [] : [r.ownerRef]))).size));
  return { rows: out, total: of("total", null, null, rows, null) };
}
