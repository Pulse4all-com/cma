/**
 * verify/cache.mjs: the per-instance tenant cache (src/lib/cache-core.ts, night N06; src/lib/cache.ts holds the app's instance) never crosses tenants or roles and
 * honours its time to live and its invalidation. Pure: no server, no database.
 *
 *   npm run verify:cache              expect ALL n PASS
 *   npm run verify:cache -- --provoke every check must fail
 *
 * What it proves: two tenants with the same entry name read their own value and never each other's; an entry under a
 * name that carries the permission set is apart per set; a read is served from the cache within the time to live and
 * read again after it; an invalidation drops one tenant's entry and leaves the other's; a failed read is not kept; a
 * time to live of 0 switches the cache off; an entry without a tenant is refused.
 */
import { createTenantCache } from "../src/lib/cache-core.ts";

const PROVOKE = process.argv.includes("--provoke");
let n = 0, passed = 0;
function expect(name, actual, expected, provoked) {
  n += 1;
  const want = PROVOKE ? provoked : expected;
  const ok = JSON.stringify(actual) === JSON.stringify(want);
  if (ok) passed += 1;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${ok ? "" : ` got ${JSON.stringify(actual)} wanted ${JSON.stringify(want)}`}`);
}

let clock = 1_000_000;
let ttl = 30_000;
const cache = createTenantCache({ ttlMs: () => ttl, now: () => clock });
const T1 = "00000000-0000-7000-8000-000000000001";
const T2 = "00000000-0000-7000-8000-000000000002";
let reads = 0;
const readerOf = (value) => async () => { reads += 1; return value; };

// two tenants, one name: each its own value, never the other's
const a1 = await cache.get(T1, "settings", readerOf("t1-settings"));
const a2 = await cache.get(T2, "settings", readerOf("t2-settings"));
const a1again = await cache.get(T1, "settings", readerOf("t1-NEW"));
expect("two tenants, one entry name: each reads its own value, and the second read of tenant 1 is tenant 1's cached value, never tenant 2's",
  [a1, a2, a1again, reads], ["t1-settings", "t2-settings", "t1-settings", 2], ["t1-settings", "t2-settings", "t2-settings", 2]);

// a name that carries the permission set: two roles apart
const r1 = await cache.get(T1, "nav:workday.own", readerOf("agent-nav"));
const r2 = await cache.get(T1, "nav:monitoring.live,workday.team", readerOf("manager-nav"));
const r1again = await cache.get(T1, "nav:workday.own", readerOf("agent-NEW"));
expect("two permission sets under one tenant are two entries: the agent's read never answers the manager's", [r1, r2, r1again], ["agent-nav", "manager-nav", "agent-nav"], ["agent-nav", "agent-nav", "agent-nav"]);

// the time to live
clock += 29_999;
const within = await cache.get(T1, "settings", readerOf("t1-after"));
clock += 2;
const after = await cache.get(T1, "settings", readerOf("t1-after"));
expect("within the time to live the cached value, after it a fresh read", [within, after], ["t1-settings", "t1-after"], ["t1-after", "t1-settings"]);

// invalidation: one tenant's entry dropped, the other's kept
await cache.get(T2, "settings", readerOf("t2-settings"));
cache.invalidate(T1, "settings");
const inv1 = await cache.get(T1, "settings", readerOf("t1-invalidated"));
const inv2 = await cache.get(T2, "settings", readerOf("t2-NEW"));
expect("invalidating tenant 1's settings drops that entry alone: tenant 1 reads again, tenant 2 keeps its value", [inv1, inv2], ["t1-invalidated", "t2-settings"], ["t1-settings", "t2-NEW"]);

// a failed read is not kept
let failed = null;
try { await cache.get(T1, "roles", async () => { throw new Error("database unavailable"); }); } catch (e) { failed = e.message; }
await new Promise((r) => setTimeout(r, 0));
const afterFailure = await cache.get(T1, "roles", readerOf("roles-ok"));
expect("a failed read is thrown to the caller and not kept: the next read reads again", [failed, afterFailure], ["database unavailable", "roles-ok"], [null, "roles-ok"]);

// a time to live of 0 switches the cache off
ttl = 0;
const off1 = await cache.get(T1, "off", readerOf("first"));
const off2 = await cache.get(T1, "off", readerOf("second"));
ttl = 30_000;
expect("CMA_CACHE_TTL_MS 0: every read reads", [off1, off2], ["first", "second"], ["first", "first"]);

// no entry without a tenant
let refused = null;
try { await cache.get("", "settings", readerOf("x")); } catch (e) { refused = e.message; }
expect("an entry without a tenant is refused", refused, "a cache entry needs a tenant", null);

// what is held: only live entries count
expect("the entries held count the live ones", cache.size() >= 1, true, false);

if (PROVOKE) {
  const allFailed = passed === 0;
  console.log(`\n${allFailed ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(allFailed ? 0 : 1);
}
console.log(`\n${passed === n ? `ALL ${n} PASS` : `${n - passed} of ${n} FAILED`}`);
process.exit(passed === n ? 0 : 1);
