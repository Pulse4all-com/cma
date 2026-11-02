/**
 * The Flash snapshot (addition 0008zn; Decision log, 1 November 2026): once a day per tenant, the figures of every
 * Reports → Flash overview for the business date that just ended, stored immutably (cma.flash_snapshot_take: the live
 * computation's rows, the id lists at a month end, the watch), as each tenant's own Scheduler user (flash.snapshot).
 *
 * Runs as a Cloud Run job on the web image (command: node jobs/snapshot-flash.mjs), started by Cloud Scheduler hourly
 * at minute 20 in UTC (docs/scheduler/deploy-flash.sh). Each run visits every tenant; the database decides which date
 * that is: date D is due at D + 1 at flash.snapshot_local_time in the tenant's zone, and at every instant there is a
 * latest due date, which the take stores once (a later run finds it taken). A date that stops being the latest due date
 * without a succeeded take is recorded by the next take as a missed run row, never taken afterwards. So time zones and
 * summer time need no schedule change. With the same database variables as the service:
 *   CMA_DB_INSTANCE  <project>:<region>:<instance>   with the Cloud SQL connector and IAM auth
 *   CMA_DB_USER      <service account>@<project>.iam  member of cma_app
 *   CMA_DB_NAME      cma
 *   CMA_DB_POOL_MAX  1 (README, Database connection budget; the deploy script sets it; 1 when absent, at most 2)
 *   CMA_DB_HOST/PORT/PASSWORD  the local path for a verifier run (never set on Cloud Run)
 *   CMA_DB_SET_ROLE=cma_app    a verifier aid for a personal login that holds cma_app without inheritance; never set on
 *                              Cloud Run
 * Plain JavaScript on pg and the connector, no build step. Every tenant is served in turn and one tenant's failure never
 * stops the others. Each tenant leaves one sync_run row (job flash_snapshot, no connection) through cma.job_run_start()
 * and cma.job_run_finish(): succeeded with taken 1 and the rows stored, with already 1 (the date taken by an earlier
 * run) or missed 1 (the date recorded as missed earlier) when there was nothing to take; failed with the error's code
 * (the take's own failure leaves its failed run row in cma.flash_snapshot_run too), so Configuration → System health
 * shows the job ("Flash snapshot"); and one JSON log line: the tenant's id, the date, the rows, duration_ms. Never a
 * name or a record id. Exit code 0 when every tenant was served, 1 when any failed. No retries by Cloud Scheduler: the
 * next hour is the retry (a date stays the latest due date for a whole local day).
 *
 * A dropped database connection (jobs/lib/connection.mjs): as the follow-up refresh, a tenant's unit is retried once on a
 * fresh connection after a connection error, its run row kept. The take is idempotent (a date already taken answers
 * taken false, reason taken, with that run's start and its stored counts), and the retry reports what the first attempt
 * did, never a second outcome:
 *   - the take's answer received before the connection was lost: kept, the take not sent again;
 *   - the take sent but its answer lost: a reason taken whose run started at or after this tenant's run row (the
 *     database's clock) is this run's own take, reported as taken with the stored counts;
 *   - the run row's finish sent but its answer lost: cma.job_run_finish answering CMA03 (finished already) is done,
 *     the first attempt's counts stand, the tenant is not failed; its log line says so once.
 */
import pg from "pg";
import { codeOf, hearIdleErrors, isConnectionError, isMain, retryOnce, withClient } from "./lib/connection.mjs";

const LOGIN_SYSTEM = "scheduler";   // the login id of each tenant's system user, as 0005a writes it
const LOGIN_ID = "scheduler";
const ACTOR_LABEL = "scheduler";
const JOB = "flash_snapshot";
// A take that runs past this is cancelled (57014) and the tenant's row says so; 123_verify_flash.sql reads the same value
// (verify.job_statement_timeout_ms) and holds a full take at volume under half of it
export const STATEMENT_TIMEOUT_MS = 240_000;

/** The pool's size: CMA_DB_POOL_MAX, 1 when absent, never more than 2 (the connection budget) */
export function poolMax(value) {
  const n = Number.parseInt(String(value ?? ""), 10);
  return Number.isInteger(n) && n >= 1 ? Math.min(n, 2) : 1;
}

async function openPool() {
  const database = process.env.CMA_DB_NAME ?? "cma";
  const common = { database, max: poolMax(process.env.CMA_DB_POOL_MAX), statement_timeout: STATEMENT_TIMEOUT_MS, connectionTimeoutMillis: 10_000 };
  if (process.env.CMA_DB_HOST) {
    return { pool: new pg.Pool({ host: process.env.CMA_DB_HOST, port: Number(process.env.CMA_DB_PORT ?? 5432), user: required("CMA_DB_USER"),
      password: process.env.CMA_DB_PASSWORD || undefined, ...common, application_name: "cma-snapshot-flash-local" }), close: () => undefined };
  }
  const { Connector, AuthTypes, IpAddressTypes } = await import("@google-cloud/cloud-sql-connector");
  const connector = new Connector();
  try {
    const opts = await connector.getOptions({
      instanceConnectionName: required("CMA_DB_INSTANCE"),
      authType: AuthTypes.IAM,
      ipType: process.env.CMA_DB_IP === "PRIVATE" ? IpAddressTypes.PRIVATE : IpAddressTypes.PUBLIC,
    });
    return { pool: new pg.Pool({ ...opts, user: required("CMA_DB_USER"), ...common, application_name: "cma-snapshot-flash" }), close: () => connector.close() };
  } catch (e) {
    connector.close();
    throw e;
  }
}

function required(name) {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set`);
  return v;
}

/** One line for Cloud Logging (jsonPayload): severity, message, the tenant's id, the date and counts only */
function log(severity, fields) {
  console.log(JSON.stringify({ severity, message: "snapshot-flash", ...fields }));
}

/** A statement in a transaction of its own, as the tenant's scheduler user */
async function asScheduler(client, tenantId, userId, text, values = []) {
  await client.query("begin");
  try {
    await client.query("select set_config('app.tenant_id', $1, true), set_config('app.user_id', $2, true), set_config('app.actor_label', $3, true)",
      [tenantId, userId, ACTOR_LABEL]);
    const r = await client.query(text, values);
    await client.query("commit");
    return r;
  } catch (e) {
    await client.query("rollback").catch(() => undefined);
    throw e;
  }
}

/**
 * A take's answer as the run row's counts (whole numbers only): taken, already, missed, failed (one of them 1; not_due
 * stays 0, kept so System health's rows keep one shape: no take answers it since 0008zn), late (the take started more
 * than an hour after its due time), the rows stored, the ids frozen at a month end and those left out (ids_skipped), the
 * watch's findings opened and open, watch_failed (the watch failed, the snapshot kept), the dates missed before, the
 * dates this take recorded as missed, duration_ms
 */
export function countsOf(r) {
  const n = (v) => (Number.isFinite(Number(v)) ? Math.max(0, Math.round(Number(v))) : 0);
  const overviews = ["customers", "subscriptions", "installed_base", "churn", "orders", "payments", "open_deals", "open_tickets", "open_tasks",
    "reviews", "data_quality"];
  return {
    taken: r?.taken ? 1 : 0,
    not_due: 0,
    already: r?.reason === "taken" ? 1 : 0,
    missed: r?.reason === "missed" ? 1 : 0,
    failed: r?.reason === "failed" ? 1 : 0,
    late: r?.late === true ? 1 : 0,
    rows: overviews.reduce((s, k) => s + n(r?.[k]), 0),
    ids: n(r?.ids_customer) + n(r?.ids_subscription) + n(r?.ids_device),
    ids_skipped: n(r?.ids_skipped),
    watch_opened: n(r?.watch_opened),
    watch_open: n(r?.watch_open),
    watch_failed: r?.watch_error ? 1 : 0,
    missed_before: n(r?.missed_before),
    missed_recorded: n(r?.missed_recorded),
    duration_ms: n(r?.duration_ms),
  };
}

/**
 * A retry's take answer after the first attempt's take was sent and its answer lost: a reason taken whose run started
 * at or after this tenant's run row (unitAt, the database's clock) is that lost take's own, so it is reported as taken
 * with the counts the run stored; a run that started before is an earlier run's (already). Any other answer as it is.
 */
export function ownTakeOf(answer, unitAt) {
  if (answer?.reason !== "taken" || !answer.stored || typeof answer.stored !== "object") return answer;
  const started = Date.parse(answer.run_started_at);
  if (!Number.isFinite(started) || !Number.isFinite(unitAt) || started < unitAt) return answer;
  return { ...answer.stored, taken: true, date: answer.date, run_id: answer.run_id };
}

/** A database time as milliseconds (pg gives a Date for timestamptz; a string is parsed) */
const msOf = (v) => (v instanceof Date ? v.getTime() : Date.parse(String(v ?? "")));

/**
 * Every tenant with a scheduler user, its date taken when due; connect() gives a client of the pool. Answers
 * { tenants, failed }. Exported for verify/jobs.mjs, which runs it on a mocked pool.
 */
export async function snapshotTenants({ connect, log }) {
  const tenants = await retryOnce(() => withClient(connect, async (client) =>
    (await client.query("select tenant_id from cma.find_tenants_for_identity($1, $2)", [LOGIN_SYSTEM, LOGIN_ID])).rows), { log, fields: { tenant_id: null, step: "tenants" } });
  let failed = 0;
  // The tenant's one log line from the answer the unit holds; note: what a retry found the first attempt had done
  const report = (tenant_id, r, note = null) => {
    const counts = countsOf(r);
    log(r?.reason === "failed" ? "ERROR" : r?.watch_error ? "WARNING" : "INFO", { tenant_id, date: r?.date ?? null, taken: Boolean(r?.taken),
      reason: r?.reason ?? null, rows: counts.rows, ids: counts.ids, watch_opened: counts.watch_opened, duration_ms: counts.duration_ms,
      ...(r?.error ? { error: r.error } : {}), ...(r?.watch_error ? { watch_error: r.watch_error } : {}), ...(note ? { retry: note } : {}) });
    return r?.reason === "failed" ? 1 : 0;
  };
  for (const { tenant_id } of tenants) {
    let runId = null;
    let unitAt = NaN;        // the database's time when this tenant's run row was started
    let me = null;
    let answer = null;       // the take's answer once received: final for this unit, the take never sent again
    let takeSent = false;    // a take went out: a retry without its answer cannot know whether its commit landed
    let finishSent = false;  // the run row's finish went out and no answer came back: likewise
    let note = null;
    const finishedFirst = (e) => answer !== null && e?.code === "CMA03";
    try {
      const r = await retryOnce(() => withClient(connect, async (client) => {
        // 1. The scheduler's own user in this tenant, as cma_app under row-level security
        if (!me) {
          const who = await asScheduler(client, tenant_id, "",
            `select u.id from cma.app_user_external_id x join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
              where x.tenant_id = cma.current_tenant_id() and x.system = $1 and x.external_id = $2 and u.status = 'active'`, [LOGIN_SYSTEM, LOGIN_ID]);
          me = who.rows[0]?.id ?? null;
          if (!me) throw Object.assign(new Error("no active scheduler user"), { code: "NO_SCHEDULER" });
        }
        // 2. The run row, before the take, so a take that fails still leaves a failed row; once per tenant and run
        if (!runId) {
          const run = (await asScheduler(client, tenant_id, me, "select cma.job_run_start($1) as id, now() as at", [JOB])).rows[0];
          runId = run.id;
          unitAt = msOf(run.at);
        }
        // 3. The take: the database decides the latest due date and takes it once. A retry whose first take went out
        // without an answer coming back claims a run that started after this run row as its own
        if (!answer) {
          const lost = takeSent;
          takeSent = true;
          const taken = (await asScheduler(client, tenant_id, me, "select cma.flash_snapshot_take(cma.current_tenant_id()) as r")).rows[0].r;
          answer = lost ? ownTakeOf(taken, unitAt) : taken;
          if (lost && answer !== taken) note = "taken by the first attempt, its answer lost";
        }
        // 4. The run row's finish; after a finish whose answer was lost, CMA03 means it landed: the first counts stand
        const counts = countsOf(answer);
        const lostFinish = finishSent;
        finishSent = true;
        try {
          if (answer?.reason === "failed") {
            await asScheduler(client, tenant_id, me, "select cma.job_run_finish($1::uuid, 'failed', $2::jsonb, $3)",
              [runId, JSON.stringify(counts), String(answer.error ?? "failed").slice(0, 60)]);
          } else {
            await asScheduler(client, tenant_id, me, "select cma.job_run_finish($1::uuid, 'succeeded', $2::jsonb)", [runId, JSON.stringify(counts)]);
          }
          finishSent = false;
        } catch (e) {
          if (lostFinish && finishedFirst(e)) {
            finishSent = false;
            note = "run row finished by an earlier attempt, its answer lost";
          } else {
            // an answer came back (a database error): the finish did not land; only a lost connection leaves it unknown
            if (!isConnectionError(e)) finishSent = false;
            throw e;
          }
        }
        return answer;
      }), { log, fields: { tenant_id } });
      failed += report(tenant_id, r, note);
    } catch (e) {
      // the run row failed with the code, unless the unit's finish whose answer was lost had landed (CMA03 at once):
      // then the unit's answer stands. CMA03 after this finish's own lost answer is this finish landing
      let done = false;
      if (runId && me) {
        let sent = false;
        done = await retryOnce(() => withClient(connect, async (client) => {
          const ownLost = sent;
          sent = true;
          try {
            await asScheduler(client, tenant_id, me, "select cma.job_run_finish($1::uuid, 'failed', '{}'::jsonb, $2)", [runId, codeOf(e)]);
            return false;
          } catch (f) {
            if (!ownLost && finishSent && finishedFirst(f)) return true;
            if (ownLost && f?.code === "CMA03") return false;
            throw f;
          }
        }), { log, fields: { tenant_id } })
          .catch((f) => {
            log("ERROR", { tenant_id, date: null, taken: false, rows: 0, duration_ms: 0, error: `run row not finished: ${codeOf(f)}` });
            return false;
          });
      }
      if (done) {
        failed += report(tenant_id, answer, "run row finished by an earlier attempt, its answer lost");
      } else {
        failed += 1;
        log("ERROR", { tenant_id, date: null, taken: false, rows: 0, duration_ms: 0, error: codeOf(e) });
      }
    }
  }
  if (tenants.length === 0) log("WARNING", { tenant_id: null, date: null, taken: false, rows: 0, duration_ms: 0, reason: "no tenant with a scheduler user" });
  return { tenants: tenants.length, failed };
}

if (isMain(import.meta.url)) {
  const setRole = process.env.CMA_DB_SET_ROLE;
  if (setRole && setRole !== "cma_app") throw new Error("CMA_DB_SET_ROLE can only be cma_app");
  let opened;
  try {
    opened = await retryOnce(openPool, { log, fields: { tenant_id: null, step: "pool" } });
  } catch (e) {
    log("ERROR", { tenant_id: null, date: null, taken: false, rows: 0, duration_ms: 0, error: codeOf(e), reason: "pool not opened" });
    process.exit(1);
  }
  const { pool, close } = opened;
  hearIdleErrors(pool, (severity, fields) => log(severity, { tenant_id: null, ...fields }));
  const connect = async () => {
    const client = await pool.connect();
    if (setRole) {
      try {
        await client.query("set role cma_app");
      } catch (e) {
        client.release(e);
        throw e;
      }
    }
    return client;
  };
  let failed = 1;
  try {
    ({ failed } = await snapshotTenants({ connect, log }));
  } catch (e) {
    log("ERROR", { tenant_id: null, date: null, taken: false, rows: 0, duration_ms: 0, error: codeOf(e), reason: "tenants not read" });
  } finally {
    await pool.end();
    close();
  }
  process.exit(failed === 0 ? 0 : 1);
}
