/**
 * Assets → Fleet management (addition 0009t; Martin, 16 November 2026, brief B37, D1 to D8): the page's rules apart from
 * React, for the server, the map in the browser and the verifiers. The devices In the field by postcode area, the
 * monitoring-state tiles and the devices that need attention. The devices and their past-due items are the asset
 * register's (Installed base's own rules, D2); each device's postcode area and monitoring state are dummy data until the
 * location and readiness sources are decided (D4, D5), behind the tenant setting fleet_management.dummy_preview (D6).
 * Ids, codes, dates and counts only: never a customer reference, name, email, phone or address.
 */
import type { FleetArea, FleetFilter, FleetRowsQuery, FleetState } from "@/lib/data/types";
import { FLEET_MAP_PROJECTION } from "@/lib/fleet-map-outlines";

export const FLEET_PATH = "/reports/fleet-management";
/** Devices a list page shows (the brief: 50 a page) */
export const FLEET_PAGE_ROWS = 50;

/** The address's keys: the filters as Installed base's (market, f_model), the tile (f_state), the area, the list's page */
export const FLEET_ADDRESS = { market: "market", model: "f_model", state: "f_state", area: "area", page: "page" } as const;

/** The monitoring states in the order of the tiles and the legend (D5) */
export const FLEET_STATES: readonly FleetState[] = ["ready", "needs_attention", "no_connection", "not_monitored"];

/** A tile: the two real figures, then Monitored and the four states (dummy) */
export type FleetTileKey = "in_field" | "past_due" | "monitored" | FleetState;
export const FLEET_TILES: readonly FleetTileKey[] = ["in_field", "past_due", "monitored", "ready", "needs_attention", "no_connection", "not_monitored"];
/** The tiles whose figure is dummy data (their small Dummy badge) */
export const FLEET_DUMMY_TILES: ReadonlySet<FleetTileKey> = new Set(["monitored", "ready", "needs_attention", "no_connection", "not_monitored"]);

/**
 * The states' colours (D8, from Pulse4all-Style 2.3 and 7.5): Ready Deep Blue, Needs attention Warning amber with Inkt
 * text, No connection Muted, Not monitored #C3CAD3 with Inkt text. Leaf Green is not used: on the Live board it reads as
 * Available. Always shown next to the state's label
 */
export const FLEET_STATE_SWATCH: Record<FleetState, string> = {
  ready: "bg-p4a-deepblue",
  needs_attention: "bg-p4a-warning",
  no_connection: "bg-p4a-muted",
  not_monitored: "bg-p4a-unmonitored",
};

export type FleetTiles = Record<FleetTileKey, number>;

/**
 * The tiles summed from the areas and the devices past due not In the field (the server's, D2: In the field and Devices
 * past due as Installed base counts them: the areas' past due, the row without an area's, and those outside the field)
 */
export function fleetTilesOf(areas: readonly FleetArea[], pastDueNotInField: number): FleetTiles {
  const t: FleetTiles = { in_field: 0, past_due: pastDueNotInField, monitored: 0, ready: 0, needs_attention: 0, no_connection: 0, not_monitored: 0 };
  for (const a of areas) {
    t.in_field += a.inField;
    t.past_due += a.pastDue;
    t.ready += a.ready;
    t.needs_attention += a.needsAttention;
    t.no_connection += a.noConnection;
    t.not_monitored += a.notMonitored;
  }
  t.monitored = t.ready + t.needs_attention + t.no_connection;
  return t;
}

/** An area's count under a tile (the map shows the tile's devices alone; In the field when none is chosen) */
export function areaCountOf(a: FleetArea, tile: FleetTileKey | null): number {
  switch (tile) {
    case "past_due": return a.pastDue;
    case "monitored": return a.ready + a.needsAttention + a.noConnection;
    case "ready": return a.ready;
    case "needs_attention": return a.needsAttention;
    case "no_connection": return a.noConnection;
    case "not_monitored": return a.notMonitored;
    default: return a.inField;
  }
}

/** The area's devices that need attention on the map's badge: Needs attention and No connection (the brief's amber badge) */
export function areaAttentionOf(a: FleetArea, tile: FleetTileKey | null): number {
  if (tile === "ready" || tile === "not_monitored") return 0;
  if (tile === "needs_attention") return a.needsAttention;
  if (tile === "no_connection") return a.noConnection;
  return a.needsAttention + a.noConnection;
}

// ---- the address ---------------------------------------------------------------------------------

const MARKET_RE = /^([A-Z]{2}|unknown)$/;
const MODEL_RE = /^[a-z0-9]+(_[a-z0-9]+)*$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export interface FleetAddressState extends FleetFilter {
  tile: FleetTileKey | null;
  areaId: string | null;
  page: number;
  /** A value of the address the page could not use (it is left out, and the page says so) */
  problem: boolean;
}

const one = (v: string | string[] | undefined): string | null => (typeof v === "string" ? v : Array.isArray(v) ? (v[0] ?? null) : null);

/** The page's state from its address: what does not fit is left out (problem) */
export function fleetStateOf(sp: Record<string, string | string[] | undefined>): FleetAddressState {
  let problem = false;
  const take = <T>(raw: string | null, ok: (v: string) => boolean, as: (v: string) => T): T | null => {
    if (raw === null || raw === "") return null;
    if (ok(raw)) return as(raw);
    problem = true;
    return null;
  };
  const market = take(one(sp[FLEET_ADDRESS.market]), (v) => MARKET_RE.test(v), (v) => v);
  const model = take(one(sp[FLEET_ADDRESS.model]), (v) => v.length <= 40 && MODEL_RE.test(v), (v) => v);
  const tile = take(one(sp[FLEET_ADDRESS.state]), (v) => (FLEET_TILES as readonly string[]).includes(v), (v) => v as FleetTileKey);
  const areaId = take(one(sp[FLEET_ADDRESS.area]), (v) => UUID_RE.test(v), (v) => v);
  const page = take(one(sp[FLEET_ADDRESS.page]), (v) => /^[1-9][0-9]{0,4}$/.test(v), (v) => Number(v)) ?? 1;
  return { market, model, tile, areaId, page, problem };
}

/** The address's keys of a state (the defaults left out) */
export function fleetQueryOf(st: Pick<FleetAddressState, "market" | "model" | "tile" | "areaId" | "page">): Record<string, string> {
  const q: Record<string, string> = {};
  if (st.market) q[FLEET_ADDRESS.market] = st.market;
  if (st.model) q[FLEET_ADDRESS.model] = st.model;
  if (st.tile) q[FLEET_ADDRESS.state] = st.tile;
  if (st.areaId) q[FLEET_ADDRESS.area] = st.areaId;
  if (st.page > 1) q[FLEET_ADDRESS.page] = String(st.page);
  return q;
}

export function fleetHref(query: Record<string, string>): string {
  const qs = new URLSearchParams(query).toString();
  return `${FLEET_PATH}${qs ? `?${qs}` : ""}`;
}

/**
 * The list the side panel reads (the brief: "Devices that need attention" by default; the selected area's devices
 * otherwise): a tile's state narrows either; the default list is the devices that need attention, unless a tile is chosen
 */
export function fleetRowsQueryOf(st: FleetAddressState): FleetRowsQuery {
  return {
    market: st.market, model: st.model, state: st.tile, areaId: st.areaId,
    attentionOnly: st.areaId === null && st.tile === null, page: st.page,
  };
}

// ---- the map ---------------------------------------------------------------------------------------

const RAD = Math.PI / 180;

/** A point in the outlines' projection (D7: Lambert azimuthal equal-area, 10°E 52°N), in km, y growing south (SVG) */
export function projectKm(lon: number, lat: number): [number, number] {
  const l0 = FLEET_MAP_PROJECTION.lon0 * RAD;
  const p0 = FLEET_MAP_PROJECTION.lat0 * RAD;
  const l = lon * RAD;
  const p = lat * RAD;
  const k = Math.sqrt(2 / (1 + Math.sin(p0) * Math.sin(p) + Math.cos(p0) * Math.cos(p) * Math.cos(l - l0)));
  const x = FLEET_MAP_PROJECTION.radiusKm * k * Math.cos(p) * Math.sin(l - l0);
  const y = FLEET_MAP_PROJECTION.radiusKm * k * (Math.cos(p0) * Math.sin(p) - Math.sin(p0) * Math.cos(p) * Math.cos(l - l0));
  return [x, -y];
}

/** An area placed on the map: its projected centre and its counts under the tile */
export interface FleetPoint {
  areaId: string;
  label: string;
  areaCode: string;
  country: string;
  x: number;
  y: number;
  count: number;
  attention: number;
}

/** A marker: one area, or a group of areas close together at the view's scale */
export interface FleetCluster {
  key: string;
  x: number;
  y: number;
  count: number;
  attention: number;
  members: FleetPoint[];
}

/** The areas the map shows under a tile: those with a device counted, projected */
export function fleetPointsOf(areas: readonly FleetArea[], tile: FleetTileKey | null): FleetPoint[] {
  const out: FleetPoint[] = [];
  for (const a of areas) {
    if (a.areaId === null || a.lat === null || a.lon === null) continue;
    const count = areaCountOf(a, tile);
    if (count <= 0) continue;
    const [x, y] = projectKm(a.lon, a.lat);
    out.push({ areaId: a.areaId, label: a.label ?? a.areaCode ?? "", areaCode: a.areaCode ?? "", country: a.country ?? "", x, y, count,
      attention: areaAttentionOf(a, tile) });
  }
  return out;
}

/** The share of the view's side within which areas form one group (the brief: 7.5 %) */
export const FLEET_CLUSTER_SHARE = 0.075;

/**
 * Greedy clustering (the brief): the areas by count, largest first (then by id, so the result never depends on the
 * input's order); each area not yet taken starts a group and takes every area not yet taken within the radius of it.
 * A group sits at its members' centre weighted by their counts
 */
export function clusterPoints(points: readonly FleetPoint[], radiusKm: number): FleetCluster[] {
  const order = [...points].sort((a, b) => b.count - a.count || (a.areaId < b.areaId ? -1 : a.areaId > b.areaId ? 1 : 0));
  const taken = new Set<string>();
  const out: FleetCluster[] = [];
  for (const seed of order) {
    if (taken.has(seed.areaId)) continue;
    const members: FleetPoint[] = [];
    for (const p of order) {
      if (taken.has(p.areaId)) continue;
      if (Math.hypot(p.x - seed.x, p.y - seed.y) <= radiusKm) {
        members.push(p);
        taken.add(p.areaId);
      }
    }
    const count = members.reduce((n, m) => n + m.count, 0);
    out.push({
      key: members.map((m) => m.areaId).sort().join("+"),
      x: members.reduce((n, m) => n + m.x * m.count, 0) / count,
      y: members.reduce((n, m) => n + m.y * m.count, 0) / count,
      count, attention: members.reduce((n, m) => n + m.attention, 0), members,
    });
  }
  return out;
}

/**
 * At the closest zoom a group cannot be split by zooming further (two areas of one city a few km apart): its areas are
 * shown each as a marker of its own, around the group's centre, apart by the given distance (the largest marker's
 * diameter in km), so every marker can be seen and clicked
 */
export function spreadClusters(groups: readonly FleetCluster[], apartKm: number): FleetCluster[] {
  return groups.flatMap((g) => {
    if (g.members.length <= 1) return [g];
    const n = g.members.length;
    const r = apartKm / (2 * Math.sin(Math.PI / n));
    return [...g.members].sort((a, b) => (a.areaId < b.areaId ? -1 : 1)).map((m, i) => ({
      key: m.areaId, x: g.x + r * Math.cos((2 * Math.PI * i) / n - Math.PI / 2), y: g.y + r * Math.sin((2 * Math.PI * i) / n - Math.PI / 2),
      count: m.count, attention: m.attention, members: [m],
    }));
  });
}

/** A view of the map: its centre and its width and height, in km */
export interface FleetView {
  cx: number;
  cy: number;
  w: number;
  h: number;
}

/** The smallest view's width: zooming in stops here (a city and its surroundings) */
export const FLEET_MIN_VIEW_KM = 120;
/** The largest: zooming out stops here (Europe and its seas) */
export const FLEET_MAX_VIEW_KM = 6000;

/** A box [minX, minY, maxX, maxY] as a view of the given aspect (height / width), with a margin */
export function viewOfBox(box: readonly [number, number, number, number], aspect: number, margin = 0.08): FleetView {
  const bw = Math.max(box[2] - box[0], FLEET_MIN_VIEW_KM);
  const bh = Math.max(box[3] - box[1], FLEET_MIN_VIEW_KM * aspect);
  let w = bw * (1 + 2 * margin);
  let h = bh * (1 + 2 * margin);
  if (h / w > aspect) w = h / aspect;
  else h = w * aspect;
  w = Math.min(Math.max(w, FLEET_MIN_VIEW_KM), FLEET_MAX_VIEW_KM);
  return { cx: (box[0] + box[2]) / 2, cy: (box[1] + box[3]) / 2, w, h: w * aspect };
}

/** The view zoomed by a factor (2 in, 0.5 out) around its centre, within the bounds */
export function zoomView(v: FleetView, factor: number): FleetView {
  const aspect = v.h / v.w;
  const w = Math.min(Math.max(v.w / factor, FLEET_MIN_VIEW_KM), FLEET_MAX_VIEW_KM);
  return { cx: v.cx, cy: v.cy, w, h: w * aspect };
}

/** The union of boxes, or null for none */
export function unionBox(boxes: readonly (readonly [number, number, number, number])[]): [number, number, number, number] | null {
  if (boxes.length === 0) return null;
  return [Math.min(...boxes.map((b) => b[0])), Math.min(...boxes.map((b) => b[1])), Math.max(...boxes.map((b) => b[2])), Math.max(...boxes.map((b) => b[3]))];
}

/** The box of some points, or null for none */
export function boxOfPoints(points: readonly { x: number; y: number }[]): [number, number, number, number] | null {
  if (points.length === 0) return null;
  return [Math.min(...points.map((p) => p.x)), Math.min(...points.map((p) => p.y)), Math.max(...points.map((p) => p.x)), Math.max(...points.map((p) => p.y))];
}

/** A view between two views at t (0 to 1), eased: the zoom's animation */
export function viewBetween(a: FleetView, b: FleetView, t: number): FleetView {
  const e = t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) ** 2 / 2;
  return { cx: a.cx + (b.cx - a.cx) * e, cy: a.cy + (b.cy - a.cy) * e, w: a.w + (b.w - a.w) * e, h: a.h + (b.h - a.h) * e };
}

/** A marker's diameter in px by its count, against the largest on the map: 28 to 56 px */
export function markerSizePx(count: number, largest: number): number {
  return Math.round(28 + 28 * Math.sqrt(Math.max(0, count) / Math.max(1, largest)));
}
