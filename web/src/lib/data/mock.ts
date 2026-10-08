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
  AppLink, CmaData, CorrectionChange, DateKey, DirectoryPerson, ExportHoursRow, HoursSummary, Instant, RoleInfo,
  SkillInfo, SkillInput, StatusChangeRow, StatusTimeRow, TeamDay, TeamDayDetail, TeamInfo, TeamMembership, TeamNow,
  TeamNowPerson, TeamPerson, TenantSetting, TimeEvent, WorkStatus, Workday,
} from "./types";

/** Same answer as the database for a caller without workday.team */
function assertTeam(me: Principal): void {
  if (!me.permissions.includes("workday.team")) throw new CmaDbError("CMA06", "not permitted");
}

/** Same answer as the database (0003d) when a day would be created for someone whose time is not kept */
function assertTimeKept(me: Principal): void {
  if (!me.permissions.includes("workday.own")) throw new CmaDbError("CMA06", "time is not kept for this person");
}

/**
 * Fixture links shaped like cma.app_link rows: fictional labels and addresses, one of them for
 * people holding workday.team only. The screens never branch on a key or a label.
 */
const MOCK_LINKS: (AppLink & { permission: string | null })[] = [
  { key: "crm", label: "CRM (test)", address: "https://example.com/crm", permission: null },
  { key: "phone", label: "Phone (test)", address: "https://example.com/phone", permission: null },
  { key: "team-sheet", label: "Team sheet (test)", address: "https://example.com/team-sheet", permission: "workday.team" },
];

/** Same answer as the database for a caller without performance.team (addition 0003c) */
function assertPerformance(me: Principal): void {
  if (!me.permissions.includes("performance.team")) throw new CmaDbError("CMA06", "not permitted");
}

/** Same answer as the database for a caller without monitoring.live (addition 0003e) */
function assertLive(me: Principal): void {
  if (!me.permissions.includes("monitoring.live")) throw new CmaDbError("CMA06", "not permitted");
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

/**
 * The in-memory state lives on globalThis: every page and route handler is its own bundle in the
 * standalone server, so a module-level Map would exist once per bundle and a day opened through
 * the start route would be invisible to the page that renders it (seen 7 October 2026, increment
 * e, when Clock in moved from the page to a route).
 */
type MockState = { store: Map<Key, Workday>; teamStore: Map<string, Map<DateKey, TimeEvent[]>>; teamSeeded: boolean; people: Map<string, DirectoryPerson> | null };
const g = globalThis as unknown as { __cmaMock?: MockState };
const state: MockState = (g.__cmaMock ??= { store: new Map(), teamStore: new Map(), teamSeeded: false, people: null });
const store = state.store;

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
      statusName: null,
      statusSince: null,
      clock: { closedSeconds: (endMin - startMin) * 60, runningSince: null },
    });
  }
}

// ---- the fictional team (fixture data, not app logic) ----------------------------------------

const MOCK_SUPERVISOR_ID = "00000000-0000-7000-8000-000000000102";
const MOCK_MANAGER_ID = "00000000-0000-7000-8000-000000000103";
const MOCK_ANALYST_ID = "00000000-0000-7000-8000-000000000104";
const MOCK_ADMIN_ID = "00000000-0000-7000-8000-000000000105";

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
const teamStore = state.teamStore;

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
  if (state.teamSeeded) return;
  state.teamSeeded = true;
  const now = Date.now();
  TEAM.forEach((p, n) => {
    const days = new Map<DateKey, MockEvent[]>();
    teamStore.set(p.userId, days);
    const today = dateKeyInZone(new Date(), p.timeZone);
    let weekday = 0;
    for (let i = 0; i <= 14; i++) {
      const date = addDays(today, -i);
      if (i === 0) {
        // Today, relative to now, so the Live board shows every state at any hour: Ana at work after
        // a break, Jordi on a break, Sanne in a meeting, Lucas clocked out, Emma not clocked in.
        // Minutes before now, scaled down when the day is young so nothing lands on yesterday.
        const elapsed = Math.max(60_000, now - localMs(date, "00:00", p.timeZone));
        const scale = Math.min(1, elapsed / (310 * 60_000));
        const ago = (minutes: number) => new Date(now - minutes * 60_000 * scale).toISOString();
        const todayPlan: [TimeEvent["kind"], string, string | null][][] = [
          [["start", ago(130), "available"], ["status", ago(70), "break"], ["status", ago(55), "available"]],
          [["start", ago(200), "available"], ["status", ago(12), "break"]],
          [["start", ago(95), "available"], ["status", ago(25), "meeting"]],
          [["start", ago(300), "available"], ["status", ago(120), "lunch"], ["status", ago(90), "available"], ["end", ago(30), null]],
          [],
        ];
        const events = (todayPlan[n] ?? []).map(([k, t, s]) => mockEvent(k, t, s, "user"));
        if (events.length) days.set(date, events);
        continue;
      }
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


// ---- the Team screen's fixture (migration 0004): catalog and people shaped like the directory ---

/** Same answer as the database for a caller without users.manage_agents or users.manage_all */
function assertManage(me: Principal): void {
  if (!me.permissions.includes("users.manage_agents") && !me.permissions.includes("users.manage_all")) {
    throw new CmaDbError("CMA06", "not permitted");
  }
}

const MOCK_LEVELS = [
  { level: 1, name: "Basic" }, { level: 2, name: "Good" }, { level: 3, name: "Fluent" }, { level: 4, name: "Native" },
];

/** Fictional catalog: keys and names are tenant data; nothing branches on them */
/** Fixture employers shaped like cma.organisation rows, the two of the fictional tenant */
const MOCK_ORGANISATIONS = [
  { key: "pulse4all", name: "Pulse4all", timeZone: "Europe/Amsterdam" },
  { key: "newco", name: "Newco", timeZone: "Europe/Madrid" },
];

const MOCK_TEAMS: TeamInfo[] = [
  { key: "en", name: "Team EN", markets: ["gb", "ie"], sortOrder: 10, memberCount: 0 },
  { key: "nl", name: "Team NL", markets: ["nl", "be"], sortOrder: 20, memberCount: 0 },
  { key: "de", name: "Team DE", markets: ["de", "at", "ch"], sortOrder: 30, memberCount: 0 },
  { key: "fr", name: "Team FR", markets: ["fr"], sortOrder: 40, memberCount: 0 },
  { key: "nordics", name: "Team Nordics", markets: ["dk", "se", "no", "fi"], sortOrder: 50, memberCount: 0 },
];
const MOCK_SKILLS: SkillInfo[] = [
  ...["en:English", "nl:Dutch", "de:German", "fr:French", "da:Danish", "sv:Swedish"].map((x, i) => {
    const [key, name] = x.split(":") as [string, string];
    return { dimension: "language" as const, key, name, sortOrder: (i + 1) * 10, isActive: true, levels: MOCK_LEVELS };
  }),
  ...["sales:Sales", "operations:Operations", "debt:Debt"].map((x, i) => {
    const [key, name] = x.split(":") as [string, string];
    return { dimension: "work_type" as const, key, name, sortOrder: (i + 1) * 10, isActive: true, levels: [] };
  }),
];
/** The default ladder as rows, with the managing flag the database derives from the permissions */
const MOCK_ROLES: Omit<RoleInfo, "assignable">[] = [
  { key: "agent", name: "Agent", isSystem: true, isManaging: false, permissions: ["workday.own", "roster.view", "leads.accept", "performance.own"] },
  { key: "analytics", name: "Analytics", isSystem: true, isManaging: false, permissions: ["reports.view", "performance.team", "monitoring.live", "quality.manage"] },
  { key: "supervisor", name: "Supervisor", isSystem: true, isManaging: false, permissions: ["workday.own", "roster.view", "workday.team", "performance.team", "monitoring.live", "messages.send"] },
  { key: "manager", name: "Call center manager", isSystem: true, isManaging: true, permissions: ["workday.own", "workday.team", "roster.manage", "skills.manage", "users.manage_agents", "workday.export"] },
  { key: "admin", name: "Administrator", isSystem: true, isManaging: true, permissions: ["workday.own", "workday.team", "roster.manage", "skills.manage", "users.manage_agents", "users.manage_all", "tenant.configure", "workday.export"] },
];

function mockSkill(key: string, level: number | null): DirectoryPerson["skills"][number] {
  const s = MOCK_SKILLS.find((x) => x.key === key)!;
  return { dimension: s.dimension, key: s.key, name: s.name, level, levelName: level ? MOCK_LEVELS.find((l) => l.level === level)?.name ?? null : null };
}

function mockTeam(key: string) {
  const t = MOCK_TEAMS.find((x) => x.key === key)!;
  return { key: t.key, name: t.name };
}

/** The fictional team of five plus the test identities, as the directory would list them */
function seedPeople(): Map<string, DirectoryPerson> {
  if (state.people) return state.people;
  const person = (
    p: Pick<DirectoryPerson, "userId" | "displayName" | "organisationName" | "timeZone"> & { email: string; roleKey: string; teams?: string[]; skills?: [string, number | null][] },
  ): DirectoryPerson => {
    const role = MOCK_ROLES.find((r) => r.key === p.roleKey)!;
    return {
      userId: p.userId, email: p.email, displayName: p.displayName, isActive: true,
      organisationKey: p.organisationName.toLowerCase(), organisationName: p.organisationName, timeZone: p.timeZone,
      roleKey: role.key, roleName: role.name, isManaging: role.isManaging,
      timeKept: role.permissions.includes("workday.own"),
      teams: (p.teams ?? []).map(mockTeam),
      skills: (p.skills ?? []).map(([k, l]) => mockSkill(k, l)),
      mayEdit: false,
    };
  };
  const list: DirectoryPerson[] = [
    person({ ...TEAM[0]!, email: "ana.ferrer@example.com", roleKey: "agent", teams: ["nl", "en"], skills: [["nl", 4], ["en", 2], ["sales", null], ["operations", null]] }),
    person({ ...TEAM[1]!, email: "jordi.puig@example.com", roleKey: "agent", teams: ["de"], skills: [["de", 3], ["en", 3], ["sales", null]] }),
    person({ ...TEAM[2]!, email: "sanne.visser@example.com", roleKey: "supervisor", teams: ["nl"], skills: [["nl", 4], ["en", 3], ["operations", null], ["debt", null]] }),
    person({ ...TEAM[3]!, email: "lucas.moreau@example.com", roleKey: "agent", teams: ["fr"], skills: [["fr", 4], ["en", 2], ["sales", null]] }),
    person({ ...TEAM[4]!, email: "emma.clarke@example.com", roleKey: "agent", teams: ["en", "nordics"], skills: [["en", 4], ["da", 1], ["sales", null], ["debt", null]] }),
    person({ userId: MOCK_PRINCIPAL.userId, displayName: "Agent One", organisationName: "Newco", timeZone: "Europe/Madrid", email: "agent-one@example.com", roleKey: "agent", teams: ["nl"], skills: [["nl", 4], ["sales", null]] }),
    person({ userId: MOCK_SUPERVISOR_ID, displayName: "Test supervisor", organisationName: "Newco", timeZone: "Europe/Madrid", email: "supervisor@example.com", roleKey: "supervisor", teams: ["nl"] }),
    person({ userId: MOCK_MANAGER_ID, displayName: "Test manager", organisationName: "Pulse4all", timeZone: "Europe/Amsterdam", email: "manager@example.com", roleKey: "manager" }),
    person({ userId: MOCK_ANALYST_ID, displayName: "Test analyst", organisationName: "Pulse4all", timeZone: "Europe/Amsterdam", email: "analyst@example.com", roleKey: "analytics" }),
    person({ userId: MOCK_ADMIN_ID, displayName: "Test admin", organisationName: "Pulse4all", timeZone: "Europe/Amsterdam", email: "admin@example.com", roleKey: "admin" }),
  ];
  state.people = new Map(list.map((p) => [p.userId, p]));
  return state.people;
}

/** The directory as the database shapes it for this caller: who is listed, who may be edited */
function directoryFor(me: Principal): DirectoryPerson[] {
  const all = me.permissions.includes("users.manage_all");
  return [...seedPeople().values()]
    .filter((p) => all || p.userId === me.userId || !p.isManaging)
    .map((p) => ({ ...p, mayEdit: p.userId !== me.userId && (all || !p.isManaging) }))
    .sort((a, b) => Number(!a.isActive) - Number(!b.isActive) || a.displayName.localeCompare(b.displayName));
}

/** The database's answer when the caller may not change this person */
function editable(me: Principal, userId: string): DirectoryPerson {
  assertManage(me);
  const p = seedPeople().get(userId);
  if (!p) throw new CmaDbError("CMA02", "person not found");
  if (!(me.permissions.includes("users.manage_all") || !p.isManaging)) throw new CmaDbError("CMA06", "may not manage this person");
  return p;
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
        // As the default ladder after 0004: the manager also exports, manages agents and skills and plans the
        // roster; the supervisor does not; both watch the Live board
        permissions: identity.subject === "manager"
          ? ["workday.own", "workday.team", "workday.export", "performance.team", "monitoring.live", "reports.view",
             "users.manage_agents", "skills.manage", "roster.manage", "roster.view"]
          : ["workday.own", "workday.team", "performance.team", "monitoring.live", "roster.view"],
      };
    }
    // The admin (0004): everything the manager has plus configuration and user management for everyone
    if (identity.provider === MOCK_IDENTITY.provider && identity.subject === "admin") {
      return {
        ...MOCK_PRINCIPAL,
        userId: MOCK_ADMIN_ID,
        displayName: "Test admin",
        organisationName: "Pulse4all",
        roleKey: "admin",
        permissions: ["workday.own", "workday.team", "workday.export", "performance.team", "monitoring.live", "reports.view",
                      "users.manage_agents", "users.manage_all", "tenant.configure", "skills.manage", "roster.manage", "roster.view"],
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

  async startWorkday(me, now) {
    const date = dateKeyInZone(now, me.timeZone);
    const k = key(me, date);
    const existing = store.get(k);
    if (existing) return existing;
    // Same contract as cma.open_workday after 0003d: nothing exists yet, so only a person whose
    // time is kept gets a day
    assertTimeKept(me);
    seedHistory(me, date);
    const fresh: Workday = {
      date,
      status: "working",
      startedAt: now,
      endedAt: null,
      statusKey: DEFAULT_STATUS.key,
      statusName: DEFAULT_STATUS.name,
      statusSince: now,
      clock: { closedSeconds: 0, runningSince: DEFAULT_STATUS.isWorking ? now : null },
    };
    store.set(k, fresh);
    return fresh;
  },

  async getWorkday(me, date) {
    // The fictional history exists for anyone whose time is kept, whether or not they clocked in yet
    if (me.permissions.includes("workday.own")) seedHistory(me, dateKeyInZone(new Date(), me.timeZone));
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
      statusName: null,
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
      statusName: next.name,
      statusSince: now,
      clock: { closedSeconds: closed.closedSeconds, runningSince: next.isWorking ? now : null },
    };
    store.set(key(me, date), updated);
    return updated;
  },

  async getHours(me, range) {
    // Own hours only: hours are pay data, never a colleague's
    if (me.permissions.includes("workday.own")) seedHistory(me, dateKeyInZone(new Date(), me.timeZone));
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

  /** Today per person, the way cma.team_now derives it from the day's effective events */
  async getTeamNow(me): Promise<TeamNow> {
    assertLive(me);
    seedTeam();
    const people: TeamNowPerson[] = TEAM.map((p) => {
      const date = dateKeyInZone(new Date(), p.timeZone);
      const events = teamStore.get(p.userId)?.get(date) ?? [];
      const live = effective(events);
      const start = live.find((e) => e.kind === "start");
      if (!start) {
        return { userId: p.userId, displayName: p.displayName, organisationKey: p.organisationName.toLowerCase(),
          organisationName: p.organisationName, timeZone: p.timeZone, date, day: null, status: null };
      }
      const end = live.find((e) => e.kind === "end") ?? null;
      const marks = live.filter((e) => e.kind !== "end");
      const last = marks[marks.length - 1]!;
      const current = MOCK_STATUSES.find((x) => x.key === last.statusKey) ?? null;
      // Closed stretches in working statuses; the last stretch is open while the day is
      let closed = 0;
      marks.forEach((e, i) => {
        const s = MOCK_STATUSES.find((x) => x.key === e.statusKey);
        const until = i + 1 < marks.length ? Date.parse(marks[i + 1]!.at) : end ? Date.parse(end.at) : null;
        if (s?.isWorking && until !== null) closed += Math.max(0, Math.floor((until - Date.parse(e.at)) / 1000));
      });
      const day: Workday = {
        date,
        status: end ? "ended" : "working",
        startedAt: start.at,
        endedAt: end?.at ?? null,
        statusKey: end ? null : last.statusKey,
        statusName: end ? null : current?.name ?? last.statusKey,
        statusSince: end ? null : last.at,
        clock: { closedSeconds: closed, runningSince: !end && current?.isWorking ? last.at : null },
      };
      const status = !end && current
        ? { key: current.key, name: current.name, isActive: true, isWorking: current.isWorking,
            isProductive: current.isProductive, isPaid: MOCK_PAID.has(current.key), isBillable: MOCK_PAID.has(current.key) }
        : null;
      return { userId: p.userId, displayName: p.displayName, organisationKey: p.organisationName.toLowerCase(),
        organisationName: p.organisationName, timeZone: p.timeZone, date, day, status };
    });
    return {
      people,
      statusFlags: MOCK_STATUSES.map((x) => ({ isWorking: x.isWorking, isProductive: x.isProductive, isPaid: MOCK_PAID.has(x.key) })),
    };
  },

  /** The fixture links this person may see, as cma.app_links filters them */
  async listAppLinks(me) {
    return MOCK_LINKS
      .filter((l) => l.permission === null || me.permissions.includes(l.permission))
      .map(({ key, label, address }) => ({ key, label, address }));
  },

  async listTeamMembersNow(me): Promise<TeamMembership[]> {
    if (!["monitoring.live", "workday.team", "roster.manage", "users.manage_agents", "users.manage_all"].some((p) => me.permissions.includes(p))) {
      throw new CmaDbError("CMA06", "not permitted");
    }
    return [...seedPeople().values()].flatMap((p) => p.teams.map((t) => ({ userId: p.userId, teamKey: t.key, teamName: t.name })));
  },

  // Team screen (0004): the cheap rules of the functions hold here too; the database proves the real ones
  async listDirectory(me) {
    assertManage(me);
    return directoryFor(me);
  },

  async listRoles(me): Promise<RoleInfo[]> {
    assertManage(me);
    const all = me.permissions.includes("users.manage_all");
    return MOCK_ROLES.map((r) => ({ ...r, assignable: all || !r.isManaging }));
  },

  async listTeams(): Promise<TeamInfo[]> {
    const people = [...seedPeople().values()];
    return MOCK_TEAMS.map((t) => ({ ...t, memberCount: people.filter((p) => p.isActive && p.teams.some((x) => x.key === t.key)).length }));
  },

  async listOrganisations() {
    return MOCK_ORGANISATIONS;
  },

  async listSkills() {
    return MOCK_SKILLS;
  },

  async addPerson(me, input) {
    assertManage(me);
    const role = MOCK_ROLES.find((r) => r.key === input.roleKey);
    if (!role) throw new CmaDbError("CMA02", "unknown role");
    if (role.isManaging && !me.permissions.includes("users.manage_all")) throw new CmaDbError("CMA06", "a managing role needs users.manage_all");
    const email = input.email.trim().toLowerCase();
    const existing = [...seedPeople().values()].find((p) => p.email === email);
    if (existing) {
      if (!existing.isActive) throw new CmaDbError("CMA03", "exists but is inactive");
      return existing.userId;   // rerun-safe, as cma.add_person
    }
    const org = MOCK_ORGANISATIONS.find((o) => o.key === input.organisationKey);
    if (!org) throw new CmaDbError("CMA02", "unknown employer");
    const userId = crypto.randomUUID();
    seedPeople().set(userId, {
      userId, email, displayName: input.displayName.trim(), isActive: true,
      organisationKey: org.key, organisationName: org.name, timeZone: input.timeZone ?? org.timeZone,
      roleKey: role.key, roleName: role.name, isManaging: role.isManaging, timeKept: role.permissions.includes("workday.own"),
      teams: [], skills: [], mayEdit: false,
    });
    return userId;
  },

  async setPersonRole(me, userId, roleKey) {
    const p = editable(me, userId);
    const role = MOCK_ROLES.find((r) => r.key === roleKey);
    if (!role) throw new CmaDbError("CMA02", "unknown role");
    if (role.isManaging && !me.permissions.includes("users.manage_all")) throw new CmaDbError("CMA06", "a managing role needs users.manage_all");
    seedPeople().set(userId, { ...p, roleKey: role.key, roleName: role.name, isManaging: role.isManaging, timeKept: p.isActive && role.permissions.includes("workday.own") });
  },

  async setPersonActive(me, userId, active) {
    const p = editable(me, userId);
    const role = MOCK_ROLES.find((r) => r.key === p.roleKey);
    seedPeople().set(userId, { ...p, isActive: active, timeKept: active && (role?.permissions.includes("workday.own") ?? false) });
  },

  async setPersonTeams(me, userId, teamKeys) {
    const p = editable(me, userId);
    for (const k of teamKeys) if (!MOCK_TEAMS.some((t) => t.key === k)) throw new CmaDbError("CMA02", "unknown team");
    seedPeople().set(userId, { ...p, teams: MOCK_TEAMS.filter((t) => teamKeys.includes(t.key)).map((t) => mockTeam(t.key)) });
  },

  async setPersonSkills(me, userId, skills: SkillInput[]) {
    const p = editable(me, userId);
    if (!me.permissions.includes("skills.manage")) throw new CmaDbError("CMA06", "not permitted");
    const next = skills.map((x) => {
      const s = MOCK_SKILLS.find((k) => k.key === x.key);
      if (!s) throw new CmaDbError("CMA02", "unknown skill");
      const scaled = s.levels.length > 0;
      if (scaled && (x.level === undefined || !s.levels.some((l) => l.level === x.level))) throw new CmaDbError("CMA04", "level outside the scale");
      if (!scaled && x.level !== undefined) throw new CmaDbError("CMA04", "a binary skill takes no level");
      return mockSkill(s.key, scaled ? x.level! : null);
    });
    const order = (k: DirectoryPerson["skills"][number]) => MOCK_SKILLS.findIndex((s) => s.key === k.key);
    seedPeople().set(userId, { ...p, skills: next.sort((a, b) => order(a) - order(b)) });
  },
};
