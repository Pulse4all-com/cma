/**
 * Mock data: in memory, fictional, resets on every cold start.
 * It cannot persist, and the UI says so (handover: a mock that cannot persist
 * must say so). Nothing here reaches a database.
 */
import type { Principal } from "@/lib/auth/identity";
import type { CmaData, DateKey, HoursSummary, Instant, Workday } from "./types";

type Key = `${string}:${string}:${DateKey}`;
const key = (me: Principal, date: DateKey): Key => `${me.tenantId}:${me.userId}:${date}`;

const store = new Map<Key, Workday>();

function dateKeyOf(instant: Instant): DateKey {
  return instant.slice(0, 10);
}

function minutesBetween(a: Instant, b: Instant): number {
  return Math.max(0, Math.round((Date.parse(b) - Date.parse(a)) / 60000));
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
    const startMin = 8 * 60 + ((i * 7) % 20);
    const endMin = 17 * 60 + ((i * 11) % 35) - (i % 3 === 0 ? 30 : 0);
    const at = (m: number) =>
      new Date(d.getTime() + m * 60000).toISOString();
    store.set(k, { date, status: "ended", startedAt: at(startMin), endedAt: at(endMin) });
  }
}

export const mockData: CmaData = {
  async openWorkday(me, now) {
    const date = dateKeyOf(now);
    seedHistory(me, date);
    const k = key(me, date);
    const existing = store.get(k);
    if (existing) return existing;
    const fresh: Workday = { date, status: "working", startedAt: now, endedAt: null };
    store.set(k, fresh);
    return fresh;
  },

  async getWorkday(me, date) {
    return store.get(key(me, date)) ?? null;
  },

  async endWorkday(me, now) {
    const date = dateKeyOf(now);
    const current = store.get(key(me, date));
    if (!current) throw new Error("No open workday");
    if (current.status === "ended") return current;
    const ended: Workday = { ...current, status: "ended", endedAt: now };
    store.set(key(me, date), ended);
    return ended;
  },

  async getHours(me, range) {
    const days = [...store.values()]
      .filter((w) => w.date >= range.from && w.date <= range.to)
      .sort((a, b) => a.date.localeCompare(b.date))
      .map((w) => ({
        date: w.date,
        startedAt: w.startedAt,
        endedAt: w.endedAt,
        minutes: minutesBetween(w.startedAt, w.endedAt ?? new Date().toISOString()),
      }));
    const summary: HoursSummary = {
      ...range,
      days,
      totalMinutes: days.reduce((sum, d) => sum + d.minutes, 0),
    };
    return summary;
  },
};
