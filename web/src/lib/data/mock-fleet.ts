/**
 * Assets → Fleet management in mock mode (addition 0009t): the database's rules (188_fleet_management.sql) on the mock's
 * installed base, so the page and the API answer as they will on Postgres. Pulse4all Subscriptions has the preview on
 * (dev's seed, D6), Pulse4all Invest off (no register: the placeholder). The devices and their past-due items are the mock
 * installed base's (In the field and Devices past due equal Installed base's, D2); each device's postcode area and
 * monitoring state are picked by a hash of its id (D4, D5), as the database does with hashtextextended: another hash
 * here, the same rule. Fictional; ids, codes, dates and counts only.
 */
import type { Principal } from "@/lib/auth/identity";
import { CmaDbError } from "@/lib/data/errors";
import type { FleetArea, FleetFilter, FleetPage, FleetReason, FleetRow, FleetRowsPage, FleetRowsQuery, FleetState } from "@/lib/data/types";
import { FLEET_PAGE_ROWS, FLEET_TILES } from "@/lib/fleet-management";
import { addDays, dateKeyInZone } from "@/lib/time";
import { mockInstalledBaseDevices, MOCK_DEVICE_MODELS } from "./mock-flash";

const MOCK_TENANT_2 = "00000000-0000-7000-8000-000000000002";
const REPORT = ["reports.view", "performance.team"];

/** The sample areas of the mock's markets (GB and NL, brief B37's rows), with fixed ids */
const AREAS: readonly { id: string; country: string; code: string; label: string; lat: number; lon: number; weight: number }[] = [
  ["GB", "EC1", "London", 51.52, -0.1, 118], ["GB", "SW1", "London", 51.47, -0.17, 96], ["GB", "M1", "Manchester", 53.48, -2.24, 74],
  ["GB", "B1", "Birmingham", 52.48, -1.9, 68], ["GB", "LS1", "Leeds", 53.8, -1.55, 47], ["GB", "G1", "Glasgow", 55.86, -4.25, 43],
  ["GB", "EH1", "Edinburgh", 55.95, -3.19, 39], ["GB", "BS1", "Bristol", 51.45, -2.59, 41], ["GB", "BN1", "Brighton", 50.82, -0.14, 28],
  ["GB", "CF10", "Cardiff", 51.48, -3.18, 26], ["GB", "NE1", "Newcastle", 54.97, -1.61, 31], ["GB", "L1", "Liverpool", 53.41, -2.98, 35],
  ["NL", "1012", "Amsterdam", 52.37, 4.9, 84], ["NL", "3011", "Rotterdam", 51.92, 4.48, 66], ["NL", "2511", "Den Haag", 52.08, 4.31, 58],
  ["NL", "3511", "Utrecht", 52.09, 5.12, 49], ["NL", "5611", "Eindhoven", 51.44, 5.48, 37], ["NL", "9711", "Groningen", 53.22, 6.57, 26],
].map(([country, code, label, lat, lon, weight], i) => ({
  id: `00000000-0000-7000-8000-0000000fa${String(i + 1).padStart(3, "0")}`, country: String(country), code: String(code), label: String(label),
  lat: Number(lat), lon: Number(lon), weight: Number(weight),
}));

/** FNV-1a, 32 bits: the mock's stand-in for the database's hashtextextended */
function hash(text: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i += 1) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

interface MockFleetDevice {
  id: string;
  serial: string;
  market: string;
  model: string;
  inField: boolean;
  pastDueItems: number;
  areaId: string | null;
  state: FleetState | null;
  reason: FleetReason | null;
  lastSelfTestOn: string | null;
  lastContactAt: string | null;
}

/** D4 and D5 on the mock's devices, as cma.fleet_devices_of */
function devicesOf(me: Principal): MockFleetDevice[] {
  const today = dateKeyInZone(new Date(), me.timeZone);
  const now = Date.now();
  return mockInstalledBaseDevices(me).map((d) => {
    const ha = hash(`${d.id}:fleet-area-v1`);
    const hs = hash(`${d.id}:fleet-state-v1`);
    let areaId: string | null = null;
    if (d.inField) {
      const own = AREAS.filter((a) => a.country === d.market).sort((a, b) => (a.code < b.code ? -1 : a.code > b.code ? 1 : 0));
      const total = own.reduce((n, a) => n + a.weight, 0);
      if (total > 0) {
        let u = ha % total;
        for (const a of own) {
          if (u < a.weight) { areaId = a.id; break; }
          u -= a.weight;
        }
      }
    }
    const k = hs % 1000;
    const r1 = (hs >>> 10) & 1023;
    const r2 = (hs >>> 20) & 1023;
    const state: FleetState | null = !d.inField ? null : k < 370 ? "not_monitored" : k < 392 ? "needs_attention" : k < 424 ? "no_connection" : "ready";
    const reason: FleetReason | null = state === "needs_attention" ? (r1 % 2 === 0 ? "self_test_failed" : "tracker_battery_low")
      : d.pastDueItems > 0 ? "items_past_due" : null;
    // the nightly check-in: today between 00:00 and 01:59 (never after now), or 2 to 11 days back without a connection
    const back = state === "no_connection" ? 2 + (r1 % 10) : 0;
    const contactDay = addDays(today, -back);
    const contact = state === null || state === "not_monitored" ? null
      : new Date(Math.min(now, Date.parse(`${contactDay}T00:00:00Z`) + (r2 % 120) * 60_000)).toISOString();
    const selfTest = state === "ready" || state === "needs_attention" ? addDays(today, -(r2 % 2)) : state === "no_connection" ? contactDay : null;
    return { ...d, areaId, state, reason, lastSelfTestOn: selfTest, lastContactAt: contact };
  });
}

function assertRead(me: Principal, market: string | null, model: string | null): void {
  if (!REPORT.some((p) => me.permissions.includes(p))) throw new CmaDbError("CMA06", "not permitted");
  if (market !== null && !/^([A-Z]{2}|unknown)$/.test(market)) throw new CmaDbError("CMA04", "a market filter is a two-letter code or unknown");
  if (model !== null && !/^[a-z0-9]+(_[a-z0-9]+)*$/.test(model)) throw new CmaDbError("CMA04", "a model filter is a model's key or unknown");
}

const setUp = (me: Principal) => me.tenantId !== MOCK_TENANT_2;

function filtered(me: Principal, f: FleetFilter): MockFleetDevice[] {
  return devicesOf(me).filter((d) => (f.market === null || d.market === f.market) && (f.model === null || d.model === f.model));
}

/** cma.fleet_areas in mock mode */
export function mockFleetAreas(me: Principal, filter: FleetFilter): FleetPage {
  assertRead(me, filter.market, filter.model);
  if (!setUp(me)) return { setUp: false, filter, today: null, timeZone: null, markets: [], models: [], areas: [] };
  const ds = filtered(me, filter);
  const count = (xs: MockFleetDevice[]): Omit<FleetArea, "areaId" | "country" | "areaCode" | "label" | "lat" | "lon"> => ({
    inField: xs.filter((d) => d.inField).length, ready: xs.filter((d) => d.state === "ready").length,
    needsAttention: xs.filter((d) => d.state === "needs_attention").length, noConnection: xs.filter((d) => d.state === "no_connection").length,
    notMonitored: xs.filter((d) => d.state === "not_monitored").length, pastDue: xs.filter((d) => d.pastDueItems > 0).length,
  });
  const areas: FleetArea[] = AREAS
    .map((a) => ({ a, xs: ds.filter((d) => d.areaId === a.id) }))
    .filter((x) => x.xs.length > 0)
    .sort((x, y) => (x.a.country + x.a.code < y.a.country + y.a.code ? -1 : 1))
    .map(({ a, xs }) => ({ areaId: a.id, country: a.country, areaCode: a.code, label: a.label, lat: a.lat, lon: a.lon, ...count(xs) }));
  areas.push({ areaId: null, country: null, areaCode: null, label: null, lat: null, lon: null, ...count(ds.filter((d) => d.areaId === null)) });
  const all = devicesOf(me);
  return {
    setUp: true, filter, today: dateKeyInZone(new Date(), me.timeZone), timeZone: me.timeZone,
    markets: [{ code: "GB", name: "United Kingdom" }, { code: "NL", name: "Netherlands" }].filter((m) => all.some((d) => d.market === m.code)),
    models: MOCK_DEVICE_MODELS.filter((m) => all.some((d) => d.model === m.key)).map((m) => ({ key: m.key, name: m.name })),
    areas,
  };
}

/** cma.fleet_rows in mock mode */
export function mockFleetRows(me: Principal, q: FleetRowsQuery): FleetRowsPage {
  assertRead(me, q.market, q.model);
  if (q.state !== null && !(FLEET_TILES as readonly string[]).includes(q.state)) throw new CmaDbError("CMA04", "not a state of the list");
  if (!Number.isInteger(q.page) || q.page < 1 || q.page > 100000) throw new CmaDbError("CMA04", "a page is a whole number from 1");
  if (!setUp(me)) return { setUp: false, page: q.page, pageSize: FLEET_PAGE_ROWS, total: 0, timeZone: null, rows: [] };
  const rank = (d: MockFleetDevice) => (d.state === "needs_attention" ? 0 : d.state === "no_connection" ? 1 : d.pastDueItems > 0 ? 2 : 3);
  const ds = filtered(me, q)
    .filter((d) => q.areaId === null || d.areaId === q.areaId)
    .filter((d) => {
      switch (q.state) {
        case "in_field": return d.inField;
        case "past_due": return d.pastDueItems > 0;
        case "monitored": return d.state === "ready" || d.state === "needs_attention" || d.state === "no_connection";
        case null: return true;
        default: return d.state === q.state;
      }
    })
    .filter((d) => !q.attentionOnly || d.state === "needs_attention" || d.state === "no_connection" || d.pastDueItems > 0)
    .sort((a, b) => rank(a) - rank(b) || (a.serial < b.serial ? -1 : a.serial > b.serial ? 1 : 0) || (a.id < b.id ? -1 : 1));
  const byId = new Map(AREAS.map((a) => [a.id, a]));
  const rows: FleetRow[] = ds.slice((q.page - 1) * FLEET_PAGE_ROWS, q.page * FLEET_PAGE_ROWS).map((d) => {
    const a = d.areaId ? byId.get(d.areaId) ?? null : null;
    return {
      deviceId: d.id, serial: d.serial, model: d.model, market: d.market, areaId: d.areaId, areaCode: a?.code ?? null, areaLabel: a?.label ?? null,
      state: d.state, reason: d.reason, lastSelfTestOn: d.lastSelfTestOn, lastContactAt: d.lastContactAt, pastDueItems: d.pastDueItems,
      locationSource: d.areaId ? "dummy" : null,
    };
  });
  return { setUp: true, page: q.page, pageSize: FLEET_PAGE_ROWS, total: ds.length, timeZone: me.timeZone, rows };
}
