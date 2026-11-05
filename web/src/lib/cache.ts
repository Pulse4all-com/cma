import "server-only";
import { createTenantCache, type TenantCache } from "./cache-core";

/** The one per-instance tenant cache (lib/cache-core holds the logic, verified by verify/cache.mjs); on globalThis, as the pool is */
export type { TenantCache } from "./cache-core";
const g = globalThis as unknown as { __cmaTenantCache?: TenantCache };
export const tenantCache: TenantCache = (g.__cmaTenantCache ??= createTenantCache());
