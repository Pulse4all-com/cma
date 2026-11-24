/**
 * The web minute jobs' gate (addition 0009zr, brief N07, decision D7): before its heavy step a job asks
 * cma.job_gate_of(job) whether to compute the current tenant now. The database answers from the job's own run rows and
 * the web's load: nothing_to_read (no source the job reads), backoff (its latest runs were cancelled by the statement
 * timeout, 57014: 5, 10, 20, 40, at most 60 minutes after the last), deferred (the web is busy: jobs.defer_web_statements
 * active statements or more, at most jobs.defer_max_in_a_row minutes in a row), else go. A gated run finishes its run
 * row succeeded with skipped 1 and the wait it was in (backoff_wait, defer_wait or nothing_to_read), so System health
 * counts both waits. A database without 0009zr has no gate: the job computes as before.
 */

/** The run row's counts of a gated run */
export function gatedCounts(g) {
  const wait = g.reason === "backoff" ? "backoff_wait" : g.reason === "deferred" ? "defer_wait" : "nothing_to_read";
  return { rows: 0, duration_ms: 0, skipped: 1, [wait]: 1 };
}

/** A gated run's log severity: a backoff follows failures (WARNING); a deferral or nothing to read is normal (INFO) */
export function gatedSeverity(reason) {
  return reason === "backoff" ? "WARNING" : "INFO";
}

/**
 * The gate for the current tenant. `query(text, values)` runs one statement as the tenant's scheduler user. Answers
 * { go: true } on a database without cma.job_gate_of, else the database's answer ({ go, reason, … }).
 */
export async function gateOf(query, job) {
  const has = (await query("select to_regprocedure('cma.job_gate_of(text)') is not null as has")).rows[0]?.has;
  if (!has) return { go: true };
  return (await query("select cma.job_gate_of($1) as g", [job])).rows[0].g;
}
