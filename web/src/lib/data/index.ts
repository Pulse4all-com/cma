import { config } from "@/lib/config";
import { mockData } from "./mock";
import type { CmaData } from "./types";

export type * from "./types";

/** The one entry point for screens. Swapping the implementation happens here only. */
export function data(): CmaData {
  if (config.dataMode === "mock") return mockData;
  // The API implementation (Postgres via cma_app) lands with migration 0002
  throw new Error("CMA_DATA_MODE=api is not wired yet; set CMA_DATA_MODE=mock");
}

/** True when the screens must say that nothing is saved */
export const dataIsMock = config.dataMode === "mock";
