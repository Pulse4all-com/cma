/**
 * Observability hooks (Next.js instrumentation file, Node runtime only; the IT audit of 17 October 2026,
 * section 5.6): registers the tracer provider whose span processor writes one JSON line per request (route
 * pattern, method, status, total ms, database ms, transactions and round trips; never a path parameter, a
 * header, a query string or an identity), and in api data mode opens the database pool before the first
 * request so a cold start does not pay the connector's handshake on someone's first page.
 */
export async function register() {
  if (process.env.NEXT_RUNTIME === "nodejs") {
    await import("./instrumentation.node");
  }
}
