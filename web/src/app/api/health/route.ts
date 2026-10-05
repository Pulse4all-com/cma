import { config } from "@/lib/config";

// Liveness for Cloud Run and for the deploy step's smoke test. No user data.
export function GET() {
  return Response.json(
    { status: "ok", version: config.version, auth: config.authMode, data: config.dataMode },
    { headers: { "cache-control": "no-store" } },
  );
}
