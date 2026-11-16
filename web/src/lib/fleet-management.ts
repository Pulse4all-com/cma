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

/** The gap in px two markers keep (E1: grouped when closer than the sum of their radii plus 4 px) */
export const FLEET_MARKER_GAP_PX = 4;
/** A marker's diameter in px: the smallest (its count and its badge apart, E1) and the largest */
export const FLEET_MARKER_MIN_PX = 44;
export const FLEET_MARKER_MAX_PX = 64;
/** The attention badge's height in px (h-4) and the width it takes per character (12 px digits, px-1), at least 20 px */
export const FLEET_BADGE_HEIGHT_PX = 16;
const BADGE_CHAR_PX = 8;
const BADGE_MIN_WIDTH_PX = 20;

/** A marker's diameter in px by its count, against the largest on the map: 44 to 64 px */
export function markerSizePx(count: number, largest: number): number {
  return Math.round(FLEET_MARKER_MIN_PX + (FLEET_MARKER_MAX_PX - FLEET_MARKER_MIN_PX) * Math.sqrt(Math.min(1, Math.max(0, count) / Math.max(1, largest))));
}

/** The badge's offset from the marker's centre, right and up (E1: its centre on the circle's edge at 45°) */
export function badgeOffsetPx(sizePx: number): number {
  return (sizePx / 2) * Math.SQRT1_2;
}

/** The badge's width in px for its count (an estimate kept on the safe side: 8 px a character, a group separator each 3 digits) */
export function badgeWidthPx(attention: number): number {
  const digits = String(Math.max(0, Math.round(attention))).length;
  const chars = digits + Math.floor((digits - 1) / 3);
  return Math.max(BADGE_MIN_WIDTH_PX, 8 + BADGE_CHAR_PX * chars);
}

/**
 * What a marker covers on screen around its centre, in px: its circle's box, and its badge (outside the circle, top right)
 * where it has one. left, up, right, down: how far it reaches each way
 */
export function markerExtentPx(count: number, attention: number, largest: number): { left: number; up: number; right: number; down: number } {
  const r = markerSizePx(count, largest) / 2;
  if (attention <= 0) return { left: r, up: r, right: r, down: r };
  const o = badgeOffsetPx(2 * r);
  return { left: r, up: Math.max(r, o + FLEET_BADGE_HEIGHT_PX / 2), right: Math.max(r, o + badgeWidthPx(attention) / 2), down: r };
}

/** Whether two markers (centres in px) would cover each other, their gap included */
function overlapPx(a: { x: number; y: number; e: ReturnType<typeof markerExtentPx> }, b: { x: number; y: number; e: ReturnType<typeof markerExtentPx> }): boolean {
  const apartX = a.x <= b.x ? b.x - a.x >= a.e.right + b.e.left + FLEET_MARKER_GAP_PX : a.x - b.x >= b.e.right + a.e.left + FLEET_MARKER_GAP_PX;
  if (apartX) return false;
  return a.y <= b.y ? b.y - a.y < a.e.down + b.e.up + FLEET_MARKER_GAP_PX : a.y - b.y < b.e.down + a.e.up + FLEET_MARKER_GAP_PX;
}

function clusterOf(members: FleetPoint[]): FleetCluster {
  const count = members.reduce((n, m) => n + m.count, 0);
  const sorted = [...members].sort((a, b) => (a.areaId < b.areaId ? -1 : a.areaId > b.areaId ? 1 : 0));
  return {
    key: sorted.map((m) => m.areaId).join("+"),
    x: members.reduce((n, m) => n + m.x * m.count, 0) / count,
    y: members.reduce((n, m) => n + m.y * m.count, 0) / count,
    count, attention: members.reduce((n, m) => n + m.attention, 0), members: sorted,
  };
}

/**
 * Groups the areas whose markers would cover each other on screen at the view's scale (E1, decided 16 November 2026):
 * every area starts as a marker of its own; while two markers would overlap (their boxes, the badge included, closer than
 * 4 px: so always when the distance between their centres is below the sum of their radii plus 4 px), the closest such
 * pair becomes one marker at its members' centre weighted by their counts, and the sizes are taken again against the
 * largest. A marker only shrinks as the largest grows, so the markers that stay apart stay apart. The result depends on
 * the scale alone (px per km), never on the view's centre or the input's order: recomputed on every zoom
 */
export function groupOnScreen(points: readonly FleetPoint[], pxPerKm: number): FleetCluster[] {
  let cs = [...points].sort((a, b) => (a.areaId < b.areaId ? -1 : a.areaId > b.areaId ? 1 : 0)).map((p) => clusterOf([p]));
  for (;;) {
    const largest = Math.max(1, ...cs.map((c) => c.count));
    const placed = cs.map((c) => ({ x: c.x * pxPerKm, y: c.y * pxPerKm, e: markerExtentPx(c.count, c.attention, largest) }));
    let best: [number, number] | null = null;
    let bestD = Infinity;
    for (let i = 0; i < cs.length; i += 1) {
      for (let j = i + 1; j < cs.length; j += 1) {
        const a = placed[i];
        const b = placed[j];
        if (!a || !b || !overlapPx(a, b)) continue;
        const d = Math.hypot(a.x - b.x, a.y - b.y);
        if (d < bestD) { bestD = d; best = [i, j]; }
      }
    }
    if (!best) return cs;
    const [i, j] = best;
    const merged = clusterOf([...(cs[i]?.members ?? []), ...(cs[j]?.members ?? [])]);
    cs = cs.filter((_, k) => k !== i && k !== j).concat(merged);
  }
}

/** The start view's padding on each side (E2: 12 %) and its smallest side (300 km) */
export const FLEET_START_PADDING = 0.12;
export const FLEET_START_MIN_KM = 300;

/**
 * The start view's box (E2, decided 16 November 2026): the areas with devices In the field under the filters, their
 * centres' bounding box with 12 % padding on each side, square, never smaller than 300 km; null when no area holds one
 */
export function startBoxOf(areas: readonly FleetArea[]): [number, number, number, number] | null {
  const pts = areas.filter((a) => a.areaId !== null && a.lat !== null && a.lon !== null && a.inField > 0)
    .map((a) => projectKm(a.lon as number, a.lat as number));
  if (pts.length === 0) return null;
  const xs = pts.map((p) => p[0]);
  const ys = pts.map((p) => p[1]);
  const [x0, x1, y0, y1] = [Math.min(...xs), Math.max(...xs), Math.min(...ys), Math.max(...ys)];
  const side = Math.max(FLEET_START_MIN_KM, Math.max(x1 - x0, y1 - y0) * (1 + 2 * FLEET_START_PADDING));
  const cx = (x0 + x1) / 2;
  const cy = (y0 + y1) / 2;
  return [cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2];
}

/**
 * At the closest zoom a group cannot be split by zooming further (two areas of one city a few km apart): its areas are
 * shown each as a marker of its own, around the group's centre. Neighbours on that ring are apart by the whole reach of
 * the largest of them (its box, badge included) twice over, plus the gap, times √2: on screen the boxes of two neighbours
 * at any angle stay apart, as groupOnScreen's (E1). largest: the count the sizes are taken against
 */
export function spreadClusters(groups: readonly FleetCluster[], pxPerKm: number, largest: number): FleetCluster[] {
  return groups.flatMap((g) => {
    if (g.members.length <= 1) return [g];
    const n = g.members.length;
    const reach = Math.max(...g.members.map((m) => {
      const e = markerExtentPx(m.count, m.attention, largest);
      return Math.max(e.left, e.up, e.right, e.down);
    }));
    const apartKm = (Math.SQRT2 * (2 * reach + FLEET_MARKER_GAP_PX)) / pxPerKm;
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
