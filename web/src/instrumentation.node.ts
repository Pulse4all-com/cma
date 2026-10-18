import { AlwaysOnSampler, NodeTracerProvider } from "@opentelemetry/sdk-trace-node";
import type { ReadableSpan, SpanProcessor } from "@opentelemetry/sdk-trace-base";
import { takeDbStats, warmDatabase } from "@/lib/db/client";

/** Next's request span (its own tracer, next.span_type BaseServer.handleRequest): it ends when the response is complete */
const REQUEST_SPAN = "BaseServer.handleRequest";
/** A request slower than this is logged as WARNING, so a Cloud Logging alert can count them */
const SLOW_MS = 800;
/** How long a route pattern seen on a span waits for its request span to end */
const ROUTE_TTL_MS = 60_000;

/**
 * The route pattern per trace, from the spans of a request that name one before its request span ends: Next's
 * "resolve page components", "render route (app)" and "executing api route (app)" spans carry next.route as the
 * pattern (/api/v1/configuration/documents/[name]), never the path. The request span carries it itself only when
 * Next copied it in time; on 18 October 2026 prod's page requests ended without it (follow-up to the IT audit of
 * 17 October 2026, section 5.6). Insertion order is age order, so expired entries are dropped from the front.
 */
const routes = new Map<string, { route: string; at: number }>();

function remember(span: ReadableSpan): void {
  const route = span.attributes["next.route"];
  const traceId = span.spanContext().traceId;
  if (typeof route === "string" && route.startsWith("/") && !routes.has(traceId)) routes.set(traceId, { route, at: Date.now() });
}

function routeOf(span: ReadableSpan): string | null {
  const own = span.attributes["next.route"];
  const traceId = span.spanContext().traceId;
  const seen = routes.get(traceId)?.route ?? null;
  routes.delete(traceId);
  const now = Date.now();
  for (const [id, r] of routes) {
    if (now - r.at <= ROUTE_TTL_MS) break;
    routes.delete(id);
  }
  return typeof own === "string" && own.startsWith("/") ? own : seen;
}

const requestLog: SpanProcessor = {
  onStart() {},
  onEnd(span: ReadableSpan) {
    if (span.attributes["next.span_type"] !== REQUEST_SPAN) {
      remember(span);
      return;
    }
    // The router's run of proxy.ts (next.bubble): it ends before the request's own span, so logging it would count the
    // request twice. When proxy.ts answers itself (401 without a valid IAP token, the mock switch's 303 and 400) it is
    // the only span; such a request reaches no route and no database, and this span's status is not the answer's.
    if (span.attributes["next.bubble"] === true) return;
    // One line per page request, RSC request and API request, with the route pattern or null: never the path
    const route = routeOf(span);
    if (route?.startsWith("/_next") || String(span.attributes["http.target"] ?? "").startsWith("/_next/")) return;
    const db = takeDbStats(span.spanContext().traceId);
    const [s, ns] = span.duration;
    const totalMs = s * 1000 + ns / 1e6;
    const status = Number(span.attributes["http.status_code"] ?? 0);
    console.log(JSON.stringify({
      severity: status >= 500 ? "ERROR" : totalMs > SLOW_MS ? "WARNING" : "INFO",
      message: "request",
      route,
      method: span.attributes["http.method"] ?? null,
      status,
      rsc: span.attributes["next.rsc"] === true,
      // dbMs sums the time each transaction held a connection; a page's parallel reads overlap, so it can exceed totalMs
      totalMs: Math.round(totalMs * 10) / 10,
      dbMs: db ? Math.round(db.dbMs * 10) / 10 : 0,
      tx: db?.tx ?? 0,
      rt: db?.rt ?? 0,
    }));
  },
  forceFlush: async () => {},
  shutdown: async () => {},
};

// No exporter: the processor above is the only consumer of the spans. Every request is recorded (AlwaysOnSampler):
// the default sampler follows an incoming traceparent, and Google's front end sends one on every request, marked not
// sampled for most of them, so before 18 October 2026 most requests wrote no line
const provider = new NodeTracerProvider({ sampler: new AlwaysOnSampler(), spanProcessors: [requestLog] });
provider.register();

// The pool before the first request (api data mode only; mock mode has no database)
if ((process.env.CMA_DATA_MODE ?? "api") === "api") void warmDatabase();
