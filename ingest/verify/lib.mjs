/**
 * The verifiers' harness, as in web/verify: expect(name, actual, expected, provoked). Normal runs
 * compare with expected and must all PASS; --provoke compares with a wrong value and every check
 * must FAIL, which proves each check can fail. writesOutside is the flow verifiers' guard on their
 * own tenants; removeTenants takes a run's own tenants out again.
 */
export const PROVOKE = process.argv.includes("--provoke");
const results = [];

export function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  const shown = (v) => String(v === undefined ? "undefined" : JSON.stringify(v)).slice(0, 70);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(64)} got ${shown(actual)}${pass ? "" : `, wanted ${shown(want)}`}`);
  return pass;
}

/**
 * The flow verifiers' guard (B17b.1): what this run wrote to tenants other than its own, as
 * "table:changes" per table, [] when nothing. Every tenant table is audited (cma.setup_tenant_table),
 * so cma.audit_log holds every insert, update and delete; counted are the changes to other tenants'
 * rows since the run's start (`since`, the database's clock as text) by the run's own logins (the
 * job's and the admin's), which leaves out what the scheduled jobs write to the same database
 * meanwhile (dev). `q` queries as the owner.
 */
export async function writesOutside(q, { tenants, since, logins }) {
  return (await q(`select a.table_name, count(*) as n from cma.tenant t
      join cma.audit_log a on a.tenant_id = t.id and a.changed_at >= $2::timestamptz
     where t.id <> all($1::uuid[]) and a.actor_login = any($3::text[])
     group by 1 order by 1`, [tenants, since, [...new Set(logins)]])).map((r) => `${r.table_name}:${r.n}`);
}

/**
 * Removes a flow verifier's own throwaway tenants with every row they hold, and returns what still
 * holds one of their ids as "table:rows" per table, [] when nothing. Only for the tenants the run
 * created, in a database the verifier has already accepted as dev or local. Every tenant table carries
 * tenant_id (cma.setup_tenant_table): the rows go table by table in an order where no remaining table
 * still points to the next one (the foreign keys from the catalog), then the audit rows the deletes
 * wrote, then the tenants; one transaction, so a failure leaves everything as it was. `q` queries as
 * the owner.
 */
export async function removeTenants(q, tenants) {
  const tables = (await q(`select c.relname as t from pg_class c
      join pg_attribute a on a.attrelid = c.oid and a.attname = 'tenant_id' and not a.attisdropped
     where c.relnamespace = 'cma'::regnamespace and c.relkind in ('r', 'p') and not c.relispartition`)).map((r) => r.t);
  const refs = await q(`select ch.relname as child, pa.relname as parent from pg_constraint k
      join pg_class ch on ch.oid = k.conrelid join pg_class pa on pa.oid = k.confrelid
     where k.contype = 'f' and k.connamespace = 'cma'::regnamespace and k.conrelid <> k.confrelid`);
  const left = new Set(tables.filter((t) => t !== "audit_log"));
  const order = [];
  while (left.size) {
    const free = [...left].filter((t) => !refs.some((r) => r.parent === t && left.has(r.child)));
    if (!free.length) throw new Error(`removeTenants: the foreign keys among ${[...left].join(", ")} form a cycle`);
    for (const t of free) { order.push(t); left.delete(t); }
  }
  await q("begin");
  try {
    for (const t of order) await q(`delete from cma."${t}" where tenant_id = any($1::uuid[])`, [tenants]);
    await q("delete from cma.audit_log where tenant_id = any($1::uuid[])", [tenants]);
    await q("delete from cma.tenant where id = any($1::uuid[])", [tenants]);
    await q("commit");
  } catch (e) {
    await q("rollback");
    throw e;
  }
  const held = [];
  for (const t of [...tables, "tenant"]) {
    const [{ n }] = await q(`select count(*)::int as n from cma."${t}" where ${t === "tenant" ? "id" : "tenant_id"} = any($1::uuid[])`, [tenants]);
    if (n) held.push(`${t}:${n}`);
  }
  return held;
}

/** Prints the verdict line and sets the exit code. */
export function verdict() {
  const passed = results.filter(Boolean).length;
  const n = results.length;
  if (PROVOKE) {
    const ok = passed === 0;
    console.log(`\n${ok ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
    process.exitCode = ok ? 0 : 1;
  } else {
    const ok = passed === n;
    console.log(`\n${ok ? `ALL ${n} PASS` : `${n - passed} of ${n} FAILED`}`);
    process.exitCode = ok ? 0 : 1;
  }
}
