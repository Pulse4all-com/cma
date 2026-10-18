import { config } from "@/lib/config";

/**
 * Liveness for Cloud Run and for the deploy step's smoke test. No user data.
 *
 * Since the IT audit of 17 October 2026 it also answers 503 when the running configuration cannot
 * serve anyone: iap mode without an audience (every page would be 401) or api mode without the
 * database variables (every read would be 503). A startup probe on this route then keeps such a
 * revision from taking traffic (cloudbuild.yaml), and the smoke test after a deploy sees it at once.
 */
export function GET() {
  const problems: string[] = [];
  if (config.authMode === "iap" && !config.iapAudience) problems.push("iap_audience_missing");
  if (config.dataMode === "api" && !process.env.CMA_DB_HOST && (!process.env.CMA_DB_INSTANCE || !process.env.CMA_DB_USER)) problems.push("database_configuration_missing");
  const status = problems.length ? 503 : 200;
  return Response.json(
    { status: problems.length ? "misconfigured" : "ok", version: config.version, auth: config.authMode, data: config.dataMode, ...(problems.length ? { problems } : {}) },
    { status, headers: { "cache-control": "no-store" } },
  );
}
