/**
 * A small per-instance cache for tenant-scoped catalogs (night N06, 5 November 2026; the rules of the Decision log of
 * that day): entries keyed by tenant and name, kept for CMA_CACHE_TTL_MS (an ops setting; 30 seconds by default, 0
 * switches the cache off), invalidated by the write paths that change the catalog, never shared across tenants and
 * never holding a report, a person's data, an inbox or anything under a per-user permission check. Today it holds
 * the tenant's settings (cma.tenant_settings(): keys and values, no personal data), read by the Live board's poll and
 * several pages, and invalidated by setTenantSetting. A key carries the tenant id first, so no lookup can cross
 * tenants (verify/cache.mjs proves it, provoked). One instance's cache knows nothing of another's: a tenant setting
 * changed on one instance is seen by another within the time to live; that is the setting's meaning.
 */
const DEFAULT_TTL_MS = 30_000;

function ttlMs(): number {
  const v = Number(process.env.CMA_CACHE_TTL_MS ?? DEFAULT_TTL_MS);
  return Number.isFinite(v) && v >= 0 ? v : DEFAULT_TTL_MS;
}

export interface TenantCache {
  /** The entry for the tenant and name, or the result of reading it (stored until its time to live ends) */
  get<T>(tenantId: string, name: string, read: () => Promise<T>): Promise<T>;
  /** Drops the tenant's entry for the name (a write path changed the catalog) */
  invalidate(tenantId: string, name: string): void;
  /** The entries held, for the verifier */
  size(): number;
}

/** A cache with its own clock and time to live, so the verifier can drive it; the app uses the one below */
export function createTenantCache(opts: { ttlMs: () => number; now?: () => number } = { ttlMs }): TenantCache {
  const entries = new Map<string, { until: number; value: Promise<unknown> }>();
  const now = opts.now ?? (() => Date.now());
  const keyOf = (tenantId: string, name: string) => {
    if (!tenantId) throw new Error("a cache entry needs a tenant");
    return `${tenantId}\u0000${name}`;
  };
  return {
    async get<T>(tenantId: string, name: string, read: () => Promise<T>): Promise<T> {
      const ttl = opts.ttlMs();
      if (ttl <= 0) return read();
      const key = keyOf(tenantId, name);
      const hit = entries.get(key);
      if (hit && hit.until > now()) return hit.value as Promise<T>;
      const value = read();
      entries.set(key, { until: now() + ttl, value });
      // A failed read is never kept: the next call reads again
      value.catch(() => { if (entries.get(key)?.value === value) entries.delete(key); });
      return value;
    },
    invalidate(tenantId: string, name: string) {
      entries.delete(keyOf(tenantId, name));
    },
    size() {
      let n = 0;
      for (const e of entries.values()) if (e.until > now()) n += 1;
      return n;
    },
  };
}
