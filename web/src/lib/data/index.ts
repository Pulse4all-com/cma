import { config } from "@/lib/config";
import { mockData } from "./mock";
import { postgresData } from "./postgres";
import type { CmaData } from "./types";

export type * from "./types";

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
