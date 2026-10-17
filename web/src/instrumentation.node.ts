import { NodeTracerProvider } from "@opentelemetry/sdk-trace-node";
import type { ReadableSpan, SpanProcessor } from "@opentelemetry/sdk-trace-base";
import { takeDbStats, warmDatabase } from "@/lib/db/client";

/** Next's request span (its own tracer, next.span_type BaseServer.handleRequest): it ends when the response is complete */
const REQUEST_SPAN = "BaseServer.handleRequest";
/** A request slower than this is logged as WARNING, so a Cloud Logging alert can count them */
const SLOW_MS = 800;

const requestLog: SpanProcessor = {
  onStart() {},
  onEnd(span: ReadableSpan) {
    if (span.attributes["next.span_type"] !== REQUEST_SPAN) return;
    const route = typeof span.attributes["next.route"] === "string" ? span.attributes["next.route"] : null;
    // Static assets and unknown paths carry no route pattern and are not timed here: no path is ever logged
    if (!route || route.startsWith("/_next")) return;
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

// No exporter and no sampling change: the processor above is the only consumer of the spans
const provider = new NodeTracerProvider({ spanProcessors: [requestLog] });
provider.register();

// The pool before the first request (api data mode only; mock mode has no database)
if ((process.env.CMA_DATA_MODE ?? "api") === "api") void warmDatabase();
