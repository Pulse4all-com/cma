/**
 * Mock data: in memory, fictional, resets on every cold start.
 * It cannot persist, and the UI says so (handover: a mock that cannot persist
 * must say so). Nothing here reaches a database.
 */
import { MOCK_IDENTITY, MOCK_PRINCIPAL, type Principal } from "@/lib/auth/identity";
import { CmaDbError } from "@/lib/db/client";
import { dateKeyInZone } from "@/lib/time";
import type { CmaData, DateKey, HoursSummary, Instant, WorkStatus, Workday } from "./types";

type Key = `${string}:${string}:${DateKey}`;
const owner = (me: Principal) => `${me.tenantId}:${me.userId}:`;
const key = (me: Principal, date: DateKey): Key => `${owner(me)}${date}` as Key;

const store = new Map<Key, Workday>();

/**
 * Fixture data, not app logic: a fictional status list shaped like a tenant's work_status rows
 * (the default ladder of the seed). The screens never branch on these keys or names.
 */
const MOCK_STATUSES: WorkStatus[] = [
  { key: "available", name: "Available", isWorking: true, isDefault: true },
  { key: "training", name: "Training", isWorking: true, isDefault: false },
  { key: "meeting", name: "Meeting", isWorking: true, isDefault: false },
  { key: "break", name: "Break", isWorking: false, isDefault: false },
  { key: "lunch", name: "Lunch", isWorking: false, isDefault: false },
];
const DEFAULT_STATUS = MOCK_STATUSES.find((s) => s.isDefault)!;

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
};
