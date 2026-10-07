/**
 * Mock data: in memory, fictional, resets on every cold start.
 * It cannot persist, and the UI says so (handover: a mock that cannot persist
 * must say so). Nothing here reaches a database.
 */
import { MOCK_IDENTITY, MOCK_PRINCIPAL, type Principal } from "@/lib/auth/identity";
import { CmaDbError } from "@/lib/db/client";
import { instantsForLocal } from "@/lib/corrections";
import { addDays, dateKeyInZone } from "@/lib/time";
import type {
  CmaData, CorrectionChange, DateKey, ExportHoursRow, HoursSummary, Instant, StatusChangeRow, StatusTimeRow, TeamDay,
  TeamDayDetail, TeamPerson, TenantSetting, TimeEvent, WorkStatus, Workday,
} from "./types";

/** Same answer as the database for a caller without workday.team */
function assertTeam(me: Principal): void {
  if (!me.permissions.includes("workday.team")) throw new CmaDbError("CMA06", "not permitted");
}

/** Same answer as the database for a caller without performance.team (addition 0003c) */
function assertPerformance(me: Principal): void {
  if (!me.permissions.includes("performance.team")) throw new CmaDbError("CMA06", "not permitted");
}

/** Same answer as the database for a caller without workday.export */
function assertExport(me: Principal): void {
  if (!me.permissions.includes("workday.export")) throw new CmaDbError("CMA06", "not permitted");
}

/** Fixture settings shaped like cma.tenant_settings: the fictional tenant uses Dutch spreadsheet conventions */
const MOCK_SETTINGS: TenantSetting[] = [
  { key: "export.csv.date_format", value: "dd-mm-yyyy", isDefault: false },
  { key: "export.csv.decimal_mark", value: "comma", isDefault: false },
  { key: "export.csv.duration_format", value: "decimal_hours", isDefault: true },
  { key: "export.csv.separator", value: "semicolon", isDefault: false },
  { key: "export.csv.utf8_bom", value: "true", isDefault: true },
];

type Key = `${string}:${string}:${DateKey}`;
const owner = (me: Principal) => `${me.tenantId}:${me.userId}:`;
const key = (me: Principal, date: DateKey): Key => `${owner(me)}${date}` as Key;

const store = new Map<Key, Workday>();

/**
 * Fixture data, not app logic: a fictional status list shaped like a tenant's work_status rows
 * (the default ladder of the seed). The screens never branch on these keys or names.
 */
const MOCK_STATUSES: WorkStatus[] = [
  { key: "available", name: "Available", isWorking: true, isProductive: true, isDefault: true },
  { key: "training", name: "Training", isWorking: true, isProductive: false, isDefault: false },
  { key: "meeting", name: "Meeting", isWorking: true, isProductive: false, isDefault: false },
  { key: "break", name: "Break", isWorking: false, isProductive: false, isDefault: false },
  { key: "lunch", name: "Lunch", isWorking: false, isProductive: false, isDefault: false },
];
const DEFAULT_STATUS = MOCK_STATUSES.find((s) => s.isDefault)!;
/** Fixture pay flags (the seed's proposal: paid break, unpaid lunch); never shown to an agent */
const MOCK_PAID = new Set(["available", "training", "meeting", "break"]);

function secondsBetween(a: Instant, b: Instant): number {
  return Math.max(0, Math.floor((Date.parse(b) - Date.parse(a)) / 1000));
}

/** Worked seconds of a day up to `now`: closed stretches plus the running one */
function workedSeconds(w: Workday, now: Instant): number {
  return w.clock.closedSeconds + (w.clock.runningSince ? secondsBetween(w.clock.runningSince, now) : 0);
}

/** Closes the running stretch at `now`; the result has nothing running */
function closeStretch(w: Workday, now: Instant): Workday["clock"] {
  return { closedSeconds: workedSeconds(w, now), runningSince: null };
}

/** A fortnight of fictional history so the hours screen has something to show */
function seedHistory(me: Principal, today: DateKey) {
  const base = new Date(`${today}T00:00:00Z`);
  for (let i = 1; i <= 14; i++) {
    const d = new Date(base);
    d.setUTCDate(base.getUTCDate() - i);
    const dow = d.getUTCDay();
    if (dow === 0 || dow === 6) continue;
    const date = d.toISOString().slice(0, 10);
    const k = key(me, date);
    if (store.has(k)) continue;
    // UTC minutes; roughly 08:00 to 17:00 in Central European summer time
    const startMin = 6 * 60 + ((i * 7) % 20);
    const endMin = 15 * 60 + ((i * 11) % 35) - (i % 3 === 0 ? 30 : 0);
    const at = (m: number) =>
      new Date(d.getTime() + m * 60000).toISOString();
    store.set(k, {
      date,
      status: "ended",
      startedAt: at(startMin),
      endedAt: at(endMin),
      statusKey: null,
      statusSince: null,
      clock: { closedSeconds: (endMin - startMin) * 60, runningSince: null },
    });
  }
}

// ---- the fictional team (fixture data, not app logic) ----------------------------------------

const MOCK_SUPERVISOR_ID = "00000000-0000-7000-8000-000000000102";
const MOCK_MANAGER_ID = "00000000-0000-7000-8000-000000000103";
const MOCK_ANALYST_ID = "00000000-0000-7000-8000-000000000104";

/** Two employers and three zones, so the screen shows employer and zone handling */
const TEAM: TeamPerson[] = [
  { userId: "00000000-0000-7000-8000-000000000201", displayName: "Ana Ferrer", organisationName: "Newco", timeZone: "Europe/Madrid" },
  { userId: "00000000-0000-7000-8000-000000000202", displayName: "Jordi Puig", organisationName: "Newco", timeZone: "Europe/Madrid" },
  { userId: "00000000-0000-7000-8000-000000000203", displayName: "Sanne Visser", organisationName: "Pulse4all", timeZone: "Europe/Amsterdam" },
  { userId: "00000000-0000-7000-8000-000000000204", displayName: "Lucas Moreau", organisationName: "Newco", timeZone: "Europe/Madrid" },
  { userId: "00000000-0000-7000-8000-000000000205", displayName: "Emma Clarke", organisationName: "Newco", timeZone: "Europe/London" },
];

type MockEvent = TimeEvent;
/** userId -> business date -> every event of that day, effective or not */
const teamStore = new Map<string, Map<DateKey, MockEvent[]>>();
let teamSeeded = false;

function localMs(date: DateKey, time: string, timeZone: string): number {
  // The earlier instant when a time occurs twice; fixture times avoid the skipped hour
  return instantsForLocal(date, time, timeZone)[0]?.ms ?? Date.parse(`${date}T${time}:00Z`);
}

function mockEvent(
  kind: TimeEvent["kind"], at: Instant, statusKey: string | null, source: TimeEvent["source"],
  extra: Partial<Pick<TimeEvent, "supersedes" | "reason" | "approvedByName">> = {},
): MockEvent {
  return {
    id: crypto.randomUUID(),
    kind,
    statusKey,
    statusName: MOCK_STATUSES.find((s) => s.key === statusKey)?.name ?? null,
    at,
    recordedAt: source === "correction" ? new Date().toISOString() : at,
    source,
    supersedes: extra.supersedes ?? null,
    reason: extra.reason ?? null,
    approvedByName: extra.approvedByName ?? null,
    isEffective: true,
  };
}

/** Effective events in time order: not a void, not replaced by a later correction */
function effective(events: MockEvent[]): MockEvent[] {
  return events
    .filter((e) => e.kind !== "void" && !events.some((x) => x.supersedes === e.id))
    .sort((a, b) => Date.parse(a.at) - Date.parse(b.at));
}

function withEffective(events: MockEvent[]): MockEvent[] {
  const live = new Set(effective(events).map((e) => e.id));
  return [...events]
    .map((e) => ({ ...e, isEffective: live.has(e.id) }))
    .sort((a, b) => Date.parse(a.at) - Date.parse(b.at) || Date.parse(a.recordedAt) - Date.parse(b.recordedAt));
}

/** One day's header and figures, the way cma.workday_summary derives them */
function teamDay(p: TeamPerson, date: DateKey, events: MockEvent[]): TeamDay {
  const live = effective(events);
  const start = live.find((e) => e.kind === "start")!;
  const end = live.find((e) => e.kind === "end") ?? null;
  const today = dateKeyInZone(new Date(), p.timeZone);
  const isCapped = !end && date < today;
  const stop = end ? Date.parse(end.at) : isCapped ? localMs(addDays(date, 1), "00:00", p.timeZone) : Date.now();
  let working = 0;
  let paid = 0;
  const marks = live.filter((e) => e.kind !== "end");
  marks.forEach((e, i) => {
    const until = Math.min(stop, i + 1 < marks.length ? Date.parse(marks[i + 1]!.at) : stop);
    const seconds = Math.max(0, Math.floor((until - Date.parse(e.at)) / 1000));
    const s = MOCK_STATUSES.find((x) => x.key === e.statusKey);
    if (s?.isWorking) working += seconds;
    if (e.statusKey && MOCK_PAID.has(e.statusKey)) paid += seconds;
  });
  return {
    userId: p.userId,
    displayName: p.displayName,
    organisationName: p.organisationName,
    date,
    timeZone: p.timeZone,
    status: end ? "ended" : "open",
    startedAt: start.at,
    endedAt: end?.at ?? null,
    minutes: Math.floor(working / 60),
    paidMinutes: Math.floor(paid / 60),
    isCapped,
    needsCorrection: isCapped,
    hasCorrection: events.some((e) => e.source === "correction"),
  };
}

function readTeamDay(userId: string, date: DateKey): TeamDayDetail {
  const p = TEAM.find((x) => x.userId === userId);
  const events = p ? teamStore.get(userId)?.get(date) ?? [] : [];
  return { day: p && events.length ? teamDay(p, date, events) : null, events: withEffective(events) };
}

/** One day's status stretches, the way cma.time_interval derives them (billable = paid in the fixture) */
function statusRows(p: TeamPerson, date: DateKey, events: MockEvent[]): StatusChangeRow[] {
  const live = effective(events);
  const end = live.find((e) => e.kind === "end") ?? null;
  const today = dateKeyInZone(new Date(), p.timeZone);
  const capped = !end && date < today;
  const stop = end ? Date.parse(end.at) : capped ? localMs(addDays(date, 1), "00:00", p.timeZone) : Date.now();
  const marks = live.filter((e) => e.kind !== "end");
  return marks.map((e, i) => {
    const next = marks[i + 1] ? Date.parse(marks[i + 1]!.at) : end ? Date.parse(end.at) : null;
    const until = Math.min(stop, next ?? stop);
    const status = MOCK_STATUSES.find((x) => x.key === e.statusKey);
    const paid = !!e.statusKey && MOCK_PAID.has(e.statusKey);
    return {
      userId: p.userId,
      displayName: p.displayName,
      organisationName: p.organisationName,
      date,
      timeZone: p.timeZone,
      statusKey: e.statusKey ?? "",
      statusName: status?.name ?? e.statusKey ?? "",
      isWorking: !!status?.isWorking,
      isProductive: !!status?.isProductive,
      isPaid: paid,
      isBillable: paid,
      from: e.at,
      to: next === null ? null : new Date(next).toISOString(),
      isOpen: next === null,
      isCapped: next === null && capped,
      seconds: Math.max(0, Math.floor((until - Date.parse(e.at)) / 1000)),
      source: e.source,
    };
  });
}

/**
 * A fortnight of weekdays per person, with the cases the Hours screen must show: today still
 * clocked in, a forgotten clock-out, a missing day, and a day corrected afterwards.
 */
function seedTeam() {
  if (teamSeeded) return;
  teamSeeded = true;
  const now = Date.now();
  TEAM.forEach((p, n) => {
    const days = new Map<DateKey, MockEvent[]>();
    teamStore.set(p.userId, days);
    const today = dateKeyInZone(new Date(), p.timeZone);
    let weekday = 0;
    for (let i = 0; i <= 14; i++) {
      const date = addDays(today, -i);
      const dow = new Date(`${date}T00:00:00Z`).getUTCDay();
      if (dow === 0 || dow === 6) continue;
      weekday++;
      if (n === 4 && weekday === 3) continue;   // Emma: a day without any clock-in
      const j = (i * 7 + n * 3) % 20;
      const at = (time: string, plus = 0) => new Date(localMs(date, time, p.timeZone) + plus * 60_000).toISOString();
      const plan: [TimeEvent["kind"], string, string | null][] = [
        ["start", at("08:50", j), "available"],
        ["status", at("11:00", j % 7), "break"],
        ["status", at("11:15", j % 7), "available"],
        ["status", at("13:30"), "lunch"],
        ["status", at("14:00"), "available"],
      ];
      // Working time that is not productive, so every group of the Dashboard has something to show
      if ((weekday + n) % 3 === 0) plan.push(["status", at("15:30"), "meeting"], ["status", at("16:15"), "available"]);
      if (n === 2 && weekday % 4 === 1) plan.push(["status", at("09:30"), "training"], ["status", at("10:30"), "available"]);
      const forgot = n === 3 && weekday === 2;  // Lucas: forgot to clock out
      if (!forgot) plan.push(["end", at("17:30", j), null]);
      plan.sort((a, b) => Date.parse(a[1]) - Date.parse(b[1]));
      const events = plan.filter(([, t]) => Date.parse(t) <= now).map(([k, t, s]) => mockEvent(k, t, s, "user"));
      if (events.length === 0) continue;
      if (n === 1 && weekday === 4) {         // Jordi: an end time confirmed afterwards
        const old = events.find((e) => e.kind === "end");
        if (old) {
          events.push(mockEvent("end", at("18:10"), null, "correction", {
            supersedes: old.id, reason: "Stayed for a customer call, confirmed by phone", approvedByName: "Test supervisor",
          }));
        }
      }
      days.set(date, events);
    }
  });
}

export const mockData: CmaData = {
  /**
   * Any verified identity may work as the test agent. A real person behind IAP
   * sees their own email, so nobody mistakes the mock for their record; roles,
   * employer and tenant are the test agent's.
   */
  async findPrincipal(identity) {
    if (identity.provider === MOCK_IDENTITY.provider && identity.subject === MOCK_IDENTITY.subject) {
      return MOCK_PRINCIPAL;
    }
    // The dev seed's test supervisor and manager: they may see and correct the fictional team
    if (identity.provider === MOCK_IDENTITY.provider && (identity.subject === "supervisor" || identity.subject === "manager")) {
      return {
        ...MOCK_PRINCIPAL,
        userId: identity.subject === "supervisor" ? MOCK_SUPERVISOR_ID : MOCK_MANAGER_ID,
        displayName: identity.subject === "supervisor" ? "Test supervisor" : "Test manager",
        roleKey: identity.subject,
        // As the default ladder: the manager also exports, the supervisor does not
        permissions: identity.subject === "manager"
          ? ["workday.own", "workday.team", "workday.export", "performance.team", "reports.view"]
          : ["workday.own", "workday.team", "performance.team"],
      };
    }
    // An analytics user as in the default ladder: reports and the Dashboard, no clock, no corrections
    if (identity.provider === MOCK_IDENTITY.provider && identity.subject === "analyst") {
      return {
        ...MOCK_PRINCIPAL,
        userId: MOCK_ANALYST_ID,
        displayName: "Test analyst",
        organisationName: "Pulse4all",
        roleKey: "analytics",
        permissions: ["reports.view", "performance.team", "monitoring.live", "quality.manage"],
      };
    }
    return {
      ...MOCK_PRINCIPAL,
      // one mock user per real person, so two testers do not share a clock
      userId: `mock:${identity.provider}:${identity.subject}`,
      displayName: identity.email,
    };
  },

  async openWorkday(me, now) {
    const date = dateKeyInZone(now, me.timeZone);
    seedHistory(me, date);
    const k = key(me, date);
    const existing = store.get(k);
    if (existing) return existing;
    const fresh: Workday = {
      date,
      status: "working",
      startedAt: now,
      endedAt: null,
      statusKey: DEFAULT_STATUS.key,
      statusSince: now,
      clock: { closedSeconds: 0, runningSince: DEFAULT_STATUS.isWorking ? now : null },
    };
    store.set(k, fresh);
    return fresh;
  },

  async getWorkday(me, date) {
    return store.get(key(me, date)) ?? null;
  },

  async endWorkday(me, now) {
    const date = dateKeyInZone(now, me.timeZone);
    const current = store.get(key(me, date));
    // Same contract as the Postgres implementation: no day today is CMA02 (not found)
    if (!current) throw new CmaDbError("CMA02", "no workday today");
    if (current.status === "ended") return current;
    const ended: Workday = {
      ...current,
      status: "ended",
      endedAt: now,
      statusKey: null,
      statusSince: null,
      clock: closeStretch(current, now),
    };
    store.set(key(me, date), ended);
    return ended;
  },

  async listStatuses() {
    return MOCK_STATUSES;
  },

  async setStatus(me, statusKey, now) {
    const date = dateKeyInZone(now, me.timeZone);
    const current = store.get(key(me, date));
    // Same contract as cma.set_status: CMA02 no day or unknown key, CMA03 ended day
    if (!current) throw new CmaDbError("CMA02", "no workday today");
    if (current.status === "ended") throw new CmaDbError("CMA03", "workday already ended");
    const next = MOCK_STATUSES.find((s) => s.key === statusKey);
    if (!next) throw new CmaDbError("CMA02", "unknown work status");
    const closed = closeStretch(current, now);
    const updated: Workday = {
      ...current,
      statusKey: next.key,
      statusSince: now,
      clock: { closedSeconds: closed.closedSeconds, runningSince: next.isWorking ? now : null },
    };
    store.set(key(me, date), updated);
    return updated;
  },

  async getHours(me, range) {
    // Own hours only: hours are pay data, never a colleague's
    const mine = owner(me);
    const now = new Date().toISOString();
    const days = [...store.entries()]
      .filter(([k]) => k.startsWith(mine))
      .map(([, w]) => w)
      .filter((w) => w.date >= range.from && w.date <= range.to)
      .sort((a, b) => a.date.localeCompare(b.date))
      .map((w) => ({
        date: w.date,
        startedAt: w.startedAt,
        endedAt: w.endedAt,
        minutes: Math.floor(workedSeconds(w, now) / 60),
      }));
    const summary: HoursSummary = {
      ...range,
      days,
      totalMinutes: days.reduce((sum, d) => sum + d.minutes, 0),
    };
    return summary;
  },

  // Team data: a fictional team of five with a fortnight of days, held in memory like the rest.
  // The cheap rules of cma.correct_workday hold here too; the database proves the real ones.
  async listTeamPeople(me) {
    assertTeam(me);
    return TEAM;
  },

  async getTeamHours(me, range, userId) {
    assertTeam(me);
    seedTeam();
    const days: TeamDay[] = [];
    for (const p of TEAM) {
      if (userId && p.userId !== userId) continue;
      for (const [date, events] of teamStore.get(p.userId) ?? []) {
        if (date >= range.from && date <= range.to && events.length) days.push(teamDay(p, date, events));
      }
    }
    days.sort((a, b) => a.date.localeCompare(b.date) || a.displayName.localeCompare(b.displayName));
    return { ...range, days };
  },

  async getTeamDay(me, userId, date) {
    assertTeam(me);
    seedTeam();
    return readTeamDay(userId, date);
  },

  async correctWorkday(me, userId, date, correction) {
    assertTeam(me);
    seedTeam();
    if (userId === me.userId) throw new CmaDbError("CMA06", "nobody corrects their own day");
    const person = TEAM.find((p) => p.userId === userId);
    if (!person) throw new CmaDbError("CMA02", "no such person");
    const reason = correction.reason.trim();
    if (reason.length < 3 || reason.length > 500) throw new CmaDbError("CMA04", "a reason of 3 to 500 characters");
    if (date > dateKeyInZone(new Date(), person.timeZone)) throw new CmaDbError("CMA04", "date in the future");

    const days = teamStore.get(userId)!;
    const events = [...(days.get(date) ?? [])];
    const isNew = events.length === 0;
    const from = localMs(date, "00:00", person.timeZone);
    const to = localMs(addDays(date, 1), "00:00", person.timeZone);
    correction.changes.forEach((c: CorrectionChange, i) => {
      if (isNew && i === 0 && (c.kind !== "start" || c.supersedes)) throw new CmaDbError("CMA04", "the first change must be the start");
      if (c.supersedes) {
        if (!events.some((e) => e.id === c.supersedes)) throw new CmaDbError("CMA04", "event not in this day");
        if (events.some((e) => e.supersedes === c.supersedes)) throw new CmaDbError("CMA04", "event already superseded");
      } else if (c.kind === "void") {
        throw new CmaDbError("CMA04", "void needs the event it cancels");
      }
      const ms = c.at ? Date.parse(c.at) : Date.now();
      if (c.kind !== "void" && (ms < from || ms > to || ms > Date.now() + 300_000)) {
        throw new CmaDbError("CMA04", "time outside the day or in the future");
      }
      const status = c.statusKey ? MOCK_STATUSES.find((s) => s.key === c.statusKey) : undefined;
      if ((c.kind === "start" || c.kind === "status") && !status) throw new CmaDbError("CMA02", "unknown work status");
      events.push(mockEvent(c.kind, new Date(ms).toISOString(), status?.key ?? null, "correction", {
        supersedes: c.supersedes ?? null, reason, approvedByName: me.displayName,
      }));
    });

    const live = effective(events);
    const starts = live.filter((e) => e.kind === "start");
    const ends = live.filter((e) => e.kind === "end");
    const startMs = starts[0] ? Date.parse(starts[0].at) : 0;
    const lastLive = Math.max(...live.filter((e) => e.kind !== "end").map((e) => Date.parse(e.at)));
    if (starts.length !== 1 || ends.length > 1 || live.some((e) => Date.parse(e.at) < startMs)
        || (ends[0] && Date.parse(ends[0].at) < lastLive)) {
      throw new CmaDbError("CMA04", "the day must have one start, at most one end, nothing before the start or after the end");
    }
    days.set(date, events);
    return readTeamDay(userId, date);
  },

  async listSettings() {
    return MOCK_SETTINGS;
  },

  async exportHours(me, range, userId) {
    assertExport(me);
    seedTeam();
    const rows: ExportHoursRow[] = [];
    for (const p of TEAM) {
      if (userId && p.userId !== userId) continue;
      for (const [date, events] of teamStore.get(p.userId) ?? []) {
        if (date < range.from || date > range.to || !events.length) continue;
        const d = teamDay(p, date, events);
        rows.push({
          userId: d.userId, displayName: d.displayName, organisationName: d.organisationName, date: d.date,
          timeZone: d.timeZone, status: d.status, startedAt: d.startedAt, endedAt: d.endedAt,
          workedSeconds: d.minutes * 60,
          productiveSeconds: statusRows(p, date, events).filter((r) => r.isProductive).reduce((n, r) => n + r.seconds, 0),
          paidSeconds: d.paidMinutes * 60, billableSeconds: d.paidMinutes * 60,
          isCapped: d.isCapped, needsCorrection: d.needsCorrection, hasCorrection: d.hasCorrection,
        });
      }
    }
    rows.sort((a, b) => a.date.localeCompare(b.date) || a.displayName.localeCompare(b.displayName));
    return { settings: MOCK_SETTINGS, rows };
  },

  async exportStatusChanges(me, range, userId) {
    assertExport(me);
    seedTeam();
    const rows: StatusChangeRow[] = [];
    for (const p of TEAM) {
      if (userId && p.userId !== userId) continue;
      for (const [date, events] of teamStore.get(p.userId) ?? []) {
        if (date >= range.from && date <= range.to && events.length) rows.push(...statusRows(p, date, events));
      }
    }
    rows.sort((a, b) => a.date.localeCompare(b.date) || a.displayName.localeCompare(b.displayName) || a.from.localeCompare(b.from));
    return { settings: MOCK_SETTINGS, rows };
  },

  /** The stretches of statusRows summed per person, day and status, as cma.team_status_time does */
  async getTeamStatusTime(me, range, userId) {
    assertPerformance(me);
    seedTeam();
    const sums = new Map<string, StatusTimeRow>();
    for (const p of TEAM) {
      if (userId && p.userId !== userId) continue;
      for (const [date, events] of teamStore.get(p.userId) ?? []) {
        if (date < range.from || date > range.to || !events.length) continue;
        for (const s of statusRows(p, date, events)) {
          const k = `${s.userId}:${s.date}:${s.statusKey}`;
          const row = sums.get(k);
          if (row) {
            row.seconds += s.seconds;
            row.stretches += 1;
            row.isCapped ||= s.isCapped;
            continue;
          }
          const order = MOCK_STATUSES.findIndex((x) => x.key === s.statusKey);
          sums.set(k, {
            userId: s.userId, displayName: s.displayName, organisationName: s.organisationName, date: s.date,
            timeZone: s.timeZone, statusKey: s.statusKey, statusName: s.statusName,
            sortOrder: (order < 0 ? MOCK_STATUSES.length : order) * 10 + 10, statusActive: true,
            isWorking: s.isWorking, isProductive: s.isProductive, isPaid: s.isPaid, isBillable: s.isBillable,
            seconds: s.seconds, stretches: 1, isCapped: s.isCapped,
          });
        }
      }
    }
    const rows = [...sums.values()].sort((a, b) =>
      a.date.localeCompare(b.date) || a.displayName.localeCompare(b.displayName) || a.userId.localeCompare(b.userId) ||
      a.sortOrder - b.sortOrder || a.statusKey.localeCompare(b.statusKey));
    return { ...range, rows };
  },
};
