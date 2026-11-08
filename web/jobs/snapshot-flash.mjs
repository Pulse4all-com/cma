/**
 * The Flash snapshot (addition 0008zn; Decision log, 1 November 2026): once a day per tenant, the figures of every
 * Reports → Flash overview for the business date that just ended, stored immutably (cma.flash_snapshot_take: the live
 * computation's rows, the id lists at a month end, the watch), as each tenant's own Scheduler user (flash.snapshot).
 * Since addition 0009e (Decision log, 8 November 2026) each run first refreshes the tenant's current takes that are due
 * (cma.flash_current_refresh: the now of each overview of flash.current_overviews, Installed base by default, taken again
 * when older than flash.current_refresh_minutes), which the page reads with its Refreshed at.
 *
 * Runs as a Cloud Run job on the web image (command: node jobs/snapshot-flash.mjs), started by Cloud Scheduler every
 * minute since 0009e (hourly at minute 20 in UTC before it; docs/scheduler/deploy-flash.sh). Each run visits every
 * tenant; the database decides what is due. The current takes: one older than the tenant's setting (5 minutes by
 * default) is taken again, a younger one kept (current_fresh), so the setting is the cadence and the schedule only the
 * clock. The dated take: date D is due at D + 1 at flash.snapshot_local_time in the tenant's zone, and at every instant
 * there is a latest due date, which the take stores once (a later run finds it taken: at a run every minute, every run
 * but the first of a date answers taken, which writes nothing). A date that stops being the latest due date without a
 * succeeded take is recorded by the next take as a missed run row, never taken afterwards. So time zones and summer
 * time need no schedule change. With the same database variables as the service:
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
 * run) or missed 1 (the date recorded as missed earlier) when there was nothing to take, and the current takes' counts
 * (current_refreshed, current_fresh, current_running, current_not_set_up, current_failed, current_rows,
 * current_duration_ms); failed with
 * the error's code when the take failed (its own failure leaves its failed run row in cma.flash_snapshot_run too) or a
 * current take could not be refreshed ("current_take <code>"; the page then reads that overview live once its take is
 * older than three times the setting, and the watch's current_stale says so), so Configuration → System health shows
 * the job ("Flash snapshot"); and one JSON log line: the tenant's id, the date, the rows, the current takes refreshed
 * and failed, duration_ms. Never a name or a record id. Exit code 0 when every tenant was served, 1 when any failed. No
 * retries by Cloud Scheduler: the next run is the retry (a date stays the latest due date for a whole local day).
 *
 * A dropped database connection (jobs/lib/connection.mjs): as the follow-up refresh, a tenant's unit is retried once on a
 * fresh connection after a connection error, its run row kept. The current refresh is idempotent (a take refreshed by a
 * first attempt whose answer was lost is fresh: the retry's answer says so), its answer kept once received. The take is
 * idempotent (a date already taken answers taken false, reason taken, with that run's start and its stored counts), and
 * the retry reports what the first attempt did, never a second outcome. (A take that failed within the last
 * TAKE_RETRY_MINUTES, with no succeeded take since, is not sent again: reason backoff, the run row failed with
 * "take_backoff <code>" until the next try, so a failing take is retried hourly, as before the every-minute cadence.)
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
// A dated take that failed is tried again after this, not at every run (addition 0009e: the job runs every minute, the
// take stays retried hourly as before; a take computes every overview, 5.5 s in prod on 3 November 2026, and a failure
// writes a failed run row each time). The run row says take_backoff with the failure's code meanwhile, so System health
// keeps showing the job failing
export const TAKE_RETRY_MINUTES = 60;

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
 * A take's answer as the run row's counts (whole numbers only): taken, already, backoff, missed, failed (one of them 1; not_due
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
    backoff: r?.reason === "backoff" ? 1 : 0,
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

/** The current takes' counts (addition 0009e) of cma.flash_current_refresh's answer, whole numbers; all 0 without one */
export const CURRENT_COUNTS = ["current_refreshed", "current_fresh", "current_running", "current_not_set_up", "current_failed", "current_rows",
  "current_duration_ms"];
export function currentCountsOf(c) {
  const n = (v) => (Number.isFinite(Number(v)) ? Math.max(0, Math.round(Number(v))) : 0);
  return Object.fromEntries(CURRENT_COUNTS.map((k) => [k, n(c?.[k])]));
}

/**
 * The run row's outcome from the take's answer and the current refresh's: failed with the take's code when the take
 * failed, else with "current_take <code>" when a current take could not be refreshed; null when it succeeded
 */
export function runErrorOf(answer, current) {
  if (answer?.reason === "failed") return String(answer.error ?? "failed").slice(0, 60);
  if (answer?.reason === "backoff") return `take_backoff ${String(answer.error ?? "failed")}`.slice(0, 60);
  if (currentCountsOf(current).current_failed > 0) return `current_take ${String(current?.current_error ?? "failed")}`.slice(0, 60);
  return null;
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
  // The tenant's one log line from the answers the unit holds (the take's, the current refresh's); note: what a retry
  // found the first attempt had done
  const report = (tenant_id, r, current, note = null) => {
    const counts = countsOf(r);
    const cur = currentCountsOf(current);
    const error = runErrorOf(r, current);
    log(error ? "ERROR" : r?.watch_error ? "WARNING" : "INFO", { tenant_id, date: r?.date ?? null, taken: Boolean(r?.taken),
      reason: r?.reason ?? null, rows: counts.rows, ids: counts.ids, watch_opened: counts.watch_opened, duration_ms: counts.duration_ms,
      current_refreshed: cur.current_refreshed, current_failed: cur.current_failed,
      ...(error ? { error } : {}), ...(r?.watch_error ? { watch_error: r.watch_error } : {}), ...(note ? { retry: note } : {}) });
    return error ? 1 : 0;
  };
  for (const { tenant_id } of tenants) {
    let runId = null;
    let unitAt = NaN;        // the database's time when this tenant's run row was started
    let me = null;
    let current = null;      // the current refresh's answer once received (0009e): final for this unit, never sent again
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
        // 3. The current takes first (addition 0009e), so a run whose dated take runs long never holds back the stored
        // figures the page reads. Idempotent (a take just refreshed is fresh), so a retry whose first answer was lost asks
        // again. A database error of the whole call (a timeout, a database without 0009e) is a failed refresh with its
        // code: the run row fails, and the dated take still runs
        if (!current) {
          try {
            current = (await asScheduler(client, tenant_id, me, "select cma.flash_current_refresh(cma.current_tenant_id()) as r")).rows[0].r;
          } catch (e) {
            if (isConnectionError(e)) throw e;
            current = { current_failed: 1, current_error: codeOf(e) };
          }
        }
        // 4. The take: the database decides the latest due date and takes it once. A retry whose first take went out
        // without an answer coming back claims a run that started after this run row as its own
        // A take that failed within the last TAKE_RETRY_MINUTES, with no succeeded take since, is not sent again yet
        if (!answer && !takeSent) {
          const failed = (await asScheduler(client, tenant_id, me,
            `select r.snapshot_date::text as date, r.error from cma.flash_snapshot_run r
              where r.tenant_id = cma.current_tenant_id() and r.status = 'failed' and r.started_at > now() - make_interval(mins => $1)
                and not exists (select 1 from cma.flash_snapshot_run s
                                where s.tenant_id = r.tenant_id and s.status = 'succeeded' and s.started_at > r.started_at)
              order by r.started_at desc limit 1`, [TAKE_RETRY_MINUTES])).rows[0];
          if (failed) answer = { taken: false, reason: "backoff", date: failed.date, error: failed.error ?? "failed" };
        }
        if (!answer) {
          const lost = takeSent;
          takeSent = true;
          const taken = (await asScheduler(client, tenant_id, me, "select cma.flash_snapshot_take(cma.current_tenant_id()) as r")).rows[0].r;
          answer = lost ? ownTakeOf(taken, unitAt) : taken;
          if (lost && answer !== taken) note = "taken by the first attempt, its answer lost";
        }
        // 5. The run row's finish; after a finish whose answer was lost, CMA03 means it landed: the first counts stand
        const counts = { ...countsOf(answer), ...currentCountsOf(current) };
        const runError = runErrorOf(answer, current);
        const lostFinish = finishSent;
        finishSent = true;
        try {
          if (runError) {
            await asScheduler(client, tenant_id, me, "select cma.job_run_finish($1::uuid, 'failed', $2::jsonb, $3)",
              [runId, JSON.stringify(counts), runError]);
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
      failed += report(tenant_id, r, current, note);
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
        failed += report(tenant_id, answer, current, "run row finished by an earlier attempt, its answer lost");
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
