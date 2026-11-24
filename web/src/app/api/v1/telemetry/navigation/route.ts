import { NextResponse } from "next/server";
import { getIdentity } from "@/lib/auth/identity";
import { dbTraceHeader } from "@/lib/api/respond";
import { MAX_BEACON_BYTES, navigationLogLine, parseNavigationBeacon } from "@/lib/telemetry";

export const dynamic = "force-dynamic";

const NO_STORE = { "cache-control": "no-store" } as const;

/**
 * The navigation beacon (brief N07, WP1; Decision log, 25 November 2026, D10): after each page load and client
 * navigation the browser sends the route pattern, the kind, the time to first frame, the time to content and the latest
 * interaction's delay in buckets (src/lib/telemetry.ts, NavigationBeacon). The route stores nothing: it writes one JSON
 * log line with message "navigation" (Cloud Logging only; tools/perf/request-percentiles.mjs --navigation reads it)
 * and answers 204. No person, no tenant, no path with ids, no query string is read or written.
 *
 * Guards: an identity from proxy.ts (IAP's verified token, or the mock sign-in) or 401, read from the request's headers
 * without a database read, so a beacon never costs a transaction; same-origin requests only (Sec-Fetch-Site, which the
 * browser sets and a page cannot): 403 otherwise; a body of at most 1 kB (413) that is exactly a beacon (400 otherwise,
 * nothing logged).
 */
export async function POST(request: Request) {
  if (!(await getIdentity())) return fail(401, "not_authenticated");
  if (request.headers.get("sec-fetch-site") !== "same-origin") return fail(403, "cross_site");
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > MAX_BEACON_BYTES) return fail(413, "too_large");
  const text = await readAtMost(request, MAX_BEACON_BYTES);
  if (text === null) return fail(413, "too_large");
  const parsed = parseNavigationBeacon(text);
  if (!parsed.ok) return fail(parsed.reason === "too_large" ? 413 : 400, parsed.reason);
  console.log(navigationLogLine(parsed.beacon));
  // x-cma-db only with the verification trace (mock sign-in): verify:round-trips holds the beacon to 0 transactions
  return new NextResponse(null, { status: 204, headers: { ...NO_STORE, ...dbTraceHeader() } });
}

function fail(status: number, code: string): NextResponse {
  return NextResponse.json({ error: { code, message: code } }, { status, headers: NO_STORE });
}

/** The body as text, or null once it passes the limit (a sender without a content-length is read up to the limit only) */
async function readAtMost(request: Request, limit: number): Promise<string | null> {
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) {
      await reader.cancel().catch(() => undefined);
      return null;
    }
    chunks.push(value);
  }
  const all = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) {
    all.set(c, at);
    at += c.byteLength;
  }
  return new TextDecoder().decode(all);
}
