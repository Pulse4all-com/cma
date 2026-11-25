/**
 * Telemetry (brief N07, WP1, 25 November 2026): the rules the request log line, the navigation beacon and its route share.
 * Pure: no server or browser module, so the server (instrumentation, the route), the browser (NavigationBeacon) and the
 * verifier (verify/telemetry.mjs) read the same rules.
 *
 * What is measured and logged is routes and milliseconds only: never a person, a tenant, a path with an id or a query
 * string (Decision log, 25 November 2026, D10). Nothing is stored in the database; Cloud Logging holds the lines.
 */
import type { NavHref } from "@/lib/nav";

/** The kind of a request in the request log line (instrumentation.node.ts) */
export type RequestKind = "document" | "navigation" | "prefetch" | "api";

/**
 * A request's kind from what the server sees: a route under /api/ is api; otherwise the client router's requests (the
 * RSC header) are a navigation, or a prefetch when the router marked them so (Next-Router-Prefetch); everything else
 * (a page opened, reloaded or typed) is a document.
 */
export function requestKindOf(r: { route: string | null; rsc: boolean; prefetch: boolean }): RequestKind {
  if (r.route?.startsWith("/api/")) return "api";
  if (r.prefetch) return "prefetch";
  if (r.rsc) return "navigation";
  return "document";
}

/**
 * The route patterns a beacon may name: the navigation model's pages (lib/nav, NavHref), with a contact center's Live
 * board as its pattern (never its key), and the three pages the model reaches outside the rail (My account, My follow-up,
 * Send a message). Any other path is "other".
 */
export const BEACON_ROUTES = [
  "/", "/messages", "/live/[org]", "/team/people", "/team/quality-monitoring", "/roster/planner", "/day", "/hours", "/schedule",
  "/team/hours", "/reports/dashboard", "/reports/speed-to-lead", "/reports/attempts", "/reports/attempts-per-agent", "/reports/funnel",
  "/reports/cancellations", "/reports/follow-up", "/reports/intake", "/reports/inbound", "/reports/calls", "/reports/calls-per-agent",
  "/reports/forms", "/reports/email", "/reports/email-per-agent", "/reports/first-orders", "/reports/orders-per-person",
  "/reports/lead-cohorts", "/reports/reviews", "/reports/courtesy", "/reports/active", "/reports/maintenance", "/reports/pledge-lists",
  "/reports/subscriptions", "/reports/payments", "/reports/compliance", "/reports/purchase-orders", "/reports/fulfillment",
  "/reports/storage", "/reports/fleet-management", "/reports/installed-base", "/reports/data-quality", "/reports/flash", "/campaigns",
  "/configuration/statuses", "/configuration/teams", "/configuration/absences", "/configuration/exports", "/configuration/app-links",
  "/configuration/sources", "/configuration/markets", "/configuration/alert-rules", "/configuration/metrics", "/configuration/health",
  "/account", "/me/follow-up", "/messages/send",
] as const;
export type BeaconRoute = (typeof BEACON_ROUTES)[number] | "other";

// The list follows the navigation model: a NavHref missing here fails the typecheck (a contact center's board is its pattern)
type Covered = Exclude<NavHref, `/live/${string}`> extends (typeof BEACON_ROUTES)[number] ? true : never;
const covered: Covered = true;
void covered;

const LIVE_BOARD = /^\/live\/[^/]+$/;
const KNOWN = new Set<string>(BEACON_ROUTES);

/** A pathname's pattern for the beacon: a known page, a Live board, else "other". Query and hash are never read */
export function routePatternOf(pathname: string): BeaconRoute {
  const path = (pathname.split(/[?#]/, 1)[0] ?? "").replace(/\/+$/, "") || "/";
  if (KNOWN.has(path)) return path as BeaconRoute;
  if (LIVE_BOARD.test(path)) return "/live/[org]";
  return "other";
}

/** How a destination was reached: a page loaded as a document, or a client navigation (a link, Back or Forward) */
export type BeaconKind = "document" | "navigation";
export const BEACON_KINDS: readonly BeaconKind[] = ["document", "navigation"];

/** The latest interaction's delay (the Event Timing API's duration of the last interaction), in buckets */
export const INTERACTION_BUCKETS = ["none", "0-100", "100-200", "200-500", "500+"] as const;
export type InteractionBucket = (typeof INTERACTION_BUCKETS)[number];
export function interactionBucketOf(ms: number | null | undefined): InteractionBucket {
  if (ms === null || ms === undefined || !Number.isFinite(ms) || ms < 0) return "none";
  if (ms < 100) return "0-100";
  if (ms < 200) return "100-200";
  if (ms < 500) return "200-500";
  return "500+";
}

/** The beacon's body: routes, a kind, milliseconds and a bucket; nothing else is accepted */
export interface NavigationBeacon {
  route: BeaconRoute;
  kind: BeaconKind;
  /** Time to first frame: from the click (a navigation) or the navigation's start (a document) to the destination's first frame */
  firstFrameMs: number;
  /** Time to content: from the same start to the first frame without the destination's route skeleton; null when not reached */
  contentMs: number | null;
  interaction: InteractionBucket;
}

export const BEACON_PATH = "/api/v1/telemetry/navigation";
/** The largest body the route reads */
export const MAX_BEACON_BYTES = 1024;
/** A measurement longer than this is not a navigation the beacon describes (a tab left in the background) */
export const MAX_BEACON_MS = 120_000;
/** While this selector matches, the destination still shows its route skeleton (RouteSkeleton, data-route-skeleton) */
export const CONTENT_PENDING_SELECTOR = "[data-route-skeleton]";

const BEACON_KEYS = ["route", "kind", "firstFrameMs", "contentMs", "interaction"] as const;
const ROUTES_AND_OTHER = new Set<string>([...BEACON_ROUTES, "other"]);

function msOk(v: unknown): v is number {
  return typeof v === "number" && Number.isInteger(v) && v >= 0 && v <= MAX_BEACON_MS;
}

/**
 * The route's reading of a body: the beacon, or the reason it is refused. Exact: every key present, no other key, every
 * value of its kind; a route outside the list (a path, an id) is refused, never logged.
 */
export function parseNavigationBeacon(text: string): { ok: true; beacon: NavigationBeacon } | { ok: false; reason: "too_large" | "invalid" } {
  if (new TextEncoder().encode(text).length > MAX_BEACON_BYTES) return { ok: false, reason: "too_large" };
  let v: unknown;
  try {
    v = JSON.parse(text);
  } catch {
    return { ok: false, reason: "invalid" };
  }
  if (!v || typeof v !== "object" || Array.isArray(v)) return { ok: false, reason: "invalid" };
  const o = v as Record<string, unknown>;
  const keys = Object.keys(o);
  if (keys.length !== BEACON_KEYS.length || !BEACON_KEYS.every((k) => k in o)) return { ok: false, reason: "invalid" };
  if (typeof o.route !== "string" || !ROUTES_AND_OTHER.has(o.route)) return { ok: false, reason: "invalid" };
  if (typeof o.kind !== "string" || !(BEACON_KINDS as readonly string[]).includes(o.kind)) return { ok: false, reason: "invalid" };
  if (!msOk(o.firstFrameMs)) return { ok: false, reason: "invalid" };
  if (o.contentMs !== null && !msOk(o.contentMs)) return { ok: false, reason: "invalid" };
  if (typeof o.interaction !== "string" || !(INTERACTION_BUCKETS as readonly string[]).includes(o.interaction)) return { ok: false, reason: "invalid" };
  return {
    ok: true,
    beacon: { route: o.route as BeaconRoute, kind: o.kind as BeaconKind, firstFrameMs: o.firstFrameMs, contentMs: o.contentMs as number | null,
              interaction: o.interaction as InteractionBucket },
  };
}

/** The one log line a beacon writes (Cloud Logging's jsonPayload): its message "navigation" and the beacon's fields only */
export function navigationLogLine(b: NavigationBeacon): string {
  return JSON.stringify({ severity: "INFO", message: "navigation", route: b.route, kind: b.kind, firstFrameMs: b.firstFrameMs,
                          contentMs: b.contentMs, interaction: b.interaction });
}

/** The Server-Timing header's value: the database's milliseconds and the total, nothing else */
export function serverTimingOf(dbMs: number, totalMs: number): string {
  const r = (x: number) => Math.max(0, Math.round(x * 10) / 10);
  return `db;dur=${r(dbMs)}, total;dur=${r(totalMs)}`;
}
