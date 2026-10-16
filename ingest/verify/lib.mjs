/**
 * The verifiers' harness, as in web/verify: expect(name, actual, expected, provoked). Normal runs
 * compare with expected and must all PASS; --provoke compares with a wrong value and every check
 * must FAIL, which proves each check can fail. writesOutside is the flow verifiers' guard on their
 * own tenants.
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
