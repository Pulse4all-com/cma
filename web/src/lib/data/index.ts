import { config } from "@/lib/config";
import { DB_TRACE, dbStats, formatDbStats } from "@/lib/db/client";
import { mockData } from "./mock";
import { postgresData } from "./postgres";
import type { CmaData } from "./types";

export type * from "./types";
export { CmaDbError, CMA_SQLSTATE, type CmaSqlState } from "./errors";

/**
 * The one entry point for screens. Swapping the implementation happens here only.
 *   mock  in memory, fictional, nothing saved (the screens say so)
 *   api   Postgres as cma_app through the write functions of migration 0002 (lib/data/postgres)
 * The database connection opens lazily on the first api call, so mock mode never needs it.
 */
export function data(): CmaData {
  return config.dataMode === "api" ? postgresData : mockData;
}

/** True when the screens must say that nothing is saved */
export const dataIsMock = config.dataMode === "mock";

/**
 * The current request's database cost as "tx=…;rt=…;ms=…" for verify/round-trips.mjs, or null when the trace is
 * off: it is on only with CMA_DB_TRACE=1 and mock sign-in (lib/db/client DB_TRACE), never in iap mode. Read it
 * after the request's reads have completed (the Shell's meta, the API's x-cma-db header).
 */
export function requestDbTrace(): string | null {
  return DB_TRACE ? formatDbStats(dbStats()) : null;
}
