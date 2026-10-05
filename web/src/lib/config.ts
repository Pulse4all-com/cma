/**
 * Runtime configuration, read once from the environment.
 *
 * Fail closed: without CMA_AUTH_MODE the app expects a verified IAP token on
 * every request, and without CMA_DATA_MODE it expects the API. Mock modes must be
 * switched on explicitly in the Cloud Run service (done for this increment only,
 * while no real data is involved).
 */
export type AuthMode = "iap" | "mock";
export type DataMode = "api" | "mock";

function pick<T extends string>(name: string, allowed: readonly T[], fallback: T): T {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  if ((allowed as readonly string[]).includes(raw)) return raw as T;
  throw new Error(`${name} must be one of ${allowed.join(", ")}, got "${raw}"`);
}

export const config = {
  authMode: pick<AuthMode>("CMA_AUTH_MODE", ["iap", "mock"], "iap"),
  dataMode: pick<DataMode>("CMA_DATA_MODE", ["api", "mock"], "api"),
  /** IAP JWT audience: /projects/<number>/global/backendServices/<backend id> */
  iapAudience: process.env.IAP_AUDIENCE ?? "",
  /** Default copy language until the per-user preference exists (handover open item) */
  defaultLocale: pick("CMA_DEFAULT_LOCALE", ["en", "nl"] as const, "en"),
  /** Git short SHA injected by Cloud Build, "dev" locally */
  version: process.env.CMA_VERSION ?? "dev",
} as const;
