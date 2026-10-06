import "server-only";
import { NextResponse } from "next/server";
import { getAccess, type Principal } from "@/lib/auth/identity";
import { CmaDbError } from "@/lib/db/client";

/**
 * Shared plumbing for the /api/v1/me routes.
 *
 * Same rules as the screens: the identity comes from proxy.ts only, the principal from the
 * data layer only, and there is no tenant or user parameter anywhere, so a caller can only
 * ever read or change their own day. Every answer is no-store: hours are pay data.
 *
 * Body shape: { data: ... } on success, { error: { code, message } } otherwise.
 */

const NO_STORE = { "cache-control": "no-store" } as const;

export class ApiError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) {
    super(message);
    this.name = "ApiError";
  }
}

export function ok(data: unknown, status = 200): NextResponse {
  return NextResponse.json({ data }, { status, headers: NO_STORE });
}

function fail(status: number, code: string, message: string): NextResponse {
  return NextResponse.json({ error: { code, message } }, { status, headers: NO_STORE });
}

/** SQLSTATEs of migration 0002 and connection failures, as HTTP. Never the SQL text. */
const DB_STATUS: Record<CmaDbError["sqlState"], [number, string]> = {
  CMA01: [403, "not_active"],
  CMA02: [404, "not_found"],
  CMA03: [409, "already_ended"],
  CMA04: [400, "invalid"],
  CMA05: [500, "tenant_configuration_missing"],
  DB_UNAVAILABLE: [503, "database_unavailable"],
  DB_ERROR: [500, "database_error"],
};

/**
 * Runs a handler for the signed-in principal and turns every outcome into JSON.
 * No identity: 401 (proxy.ts normally answers first). Identity without access: 403.
 */
export async function forPrincipal(handler: (me: Principal) => Promise<NextResponse>): Promise<NextResponse> {
  try {
    const access = await getAccess();
    if (!access) return fail(401, "not_authenticated", "Not authenticated");
    if (access.kind !== "granted") return fail(403, "no_access", "No access yet");
    return await handler(access.principal);
  } catch (e) {
    if (e instanceof ApiError) return fail(e.status, e.code, e.message);
    if (e instanceof CmaDbError) {
      const [status, code] = DB_STATUS[e.sqlState];
      if (status >= 500) console.error(`[cma-api] ${e.sqlState}: ${e.detail ?? e.message}`);
      return fail(status, code, e.message);
    }
    console.error("[cma-api] unexpected", e instanceof Error ? e.message : e);
    return fail(500, "internal", "Internal error");
  }
}

/**
 * Cross-site request forgery guard for state-changing routes. Behind IAP the browser sends the
 * IAP session with any request to this host, so a foreign page could otherwise POST here.
 * A custom header makes the request non-simple (a foreign origin cannot add it without CORS,
 * which this app never grants), and Sec-Fetch-Site rejects cross-site requests outright.
 */
export function assertSameSiteWrite(request: Request): void {
  const site = request.headers.get("sec-fetch-site");
  if (site && site !== "same-origin" && site !== "none") {
    throw new ApiError(403, "cross_site", "Cross-site request refused");
  }
  if (request.headers.get("x-cma-request") !== "1") {
    throw new ApiError(400, "missing_request_header", "Header x-cma-request: 1 is required");
  }
}

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

/** A real calendar date in YYYY-MM-DD, or a 400 */
export function dateParam(value: string | null, name: string): string {
  if (!value || !DATE_RE.test(value) || Number.isNaN(Date.parse(`${value}T00:00:00Z`)) ||
      new Date(`${value}T00:00:00Z`).toISOString().slice(0, 10) !== value) {
    throw new ApiError(400, "invalid_date", `${name} must be a date in YYYY-MM-DD`);
  }
  return value;
}

/** Whole days from a to b, inclusive */
export function daysInclusive(from: string, to: string): number {
  return Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000) + 1;
}

/** The JSON body of a write as an object, or a 400. Read after assertSameSiteWrite. */
export async function jsonBody(request: Request): Promise<Record<string, unknown>> {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    throw new ApiError(400, "invalid_body", "Body must be JSON");
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new ApiError(400, "invalid_body", "Body must be a JSON object");
  }
  return body as Record<string, unknown>;
}
