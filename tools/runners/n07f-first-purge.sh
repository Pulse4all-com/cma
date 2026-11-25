#!/usr/bin/env bash
# tools/runners/n07f-first-purge.sh: the first sync_run purge in prod, by hand and watched (N07f, #321, decision D13;
# MORNING_RUNBOOK step 6). Outside office hours only: it refuses between 07:00 and 22:00 Amsterdam (--now insists), and
# between 03:00 and 04:30, around the scheduled reconcile at 03:30 (always).
#
#   cd ~/cma && git switch -q main && git pull -q --ff-only && bash tools/runners/n07f-first-purge.sh
#
# After n07f-ingest.sh (prod's reconcile on the image with the purge) and before the scheduled reconcile at 03:30. Counts
# only, never a row: the run rows per tenant (succeeded, failed, and those past their retention) and the hourly counts
# (cma.sync_run_hour, the hours before the run's start) before and after; one execution of ingest-reconcile, polled; its
# retention line per tenant. The hourly counts must stay the same (the purge leaves the bookkeeping as it is); the rows
# past their retention fall by what the lines say they deleted (at most 50 batches of 2,000 a tenant: "more" true means
# the next nights continue). The reconcile also does its nightly work (every stream), as at 03:30.
# Log and records check: records/0009zt-purge-<date>/.
source "$(dirname "$0")/lib.sh"
run_init n07f-first-purge "0009zt-purge-$(date +%F)"
hour=$((10#$(TZ=Europe/Amsterdam date +%H)))
minute=$((10#$(TZ=Europe/Amsterdam date +%M)))
if [ "$hour" -ge 7 ] && [ "$hour" -lt 22 ] && [ "${1:-}" != "--now" ]; then
  stop_run "outside office hours only: from 22:00 to 07:00 Amsterdam (it is $(TZ=Europe/Amsterdam date +%H:%M) there; --now insists)"
fi
if [ "$hour" = 3 ] || { [ "$hour" = 4 ] && [ "$minute" -lt 30 ]; }; then
  stop_run "not from 03:00 to 04:30 Amsterdam: the scheduled reconcile runs at 03:30 (it is $(TZ=Europe/Amsterdam date +%H:%M))"
fi
on_main
JOBS="ingest-reconcile"
export JOBS

db_connect prod
has_0009zt || stop_run "0009zt is not in prod: run tools/runners/n07f-prod.sh first"
step "prod: ingest-reconcile on the image with the purge (read)" 120 rc 'jobs_on_image p4a-cma-prod "$IMAGE"' \
  || stop_run "prod's reconcile is not on ${IMAGE}: run tools/runners/n07f-ingest.sh first"

BOUND="$(date -u +%Y-%m-%dT%H:00:00Z)"
export BOUND
note "the hourly counts are compared for the hours before ${BOUND}"
ROWS_SQL="select t.slug, x.succeeded, x.failed, x.succeeded_past, x.failed_past
from cma.tenant t
cross join lateral (select cma.setting_of(t.id, 'sync_run.retention_days')::integer as d,
                           cma.setting_of(t.id, 'sync_run.failed_retention_days')::integer as fd) s
cross join lateral (select count(*) filter (where r.status = 'succeeded') as succeeded,
                           count(*) filter (where r.status = 'failed') as failed,
                           count(*) filter (where r.status = 'succeeded' and r.finished_at < now() - make_interval(days => s.d)) as succeeded_past,
                           count(*) filter (where r.status = 'failed' and r.finished_at < now() - make_interval(days => s.fd)) as failed_past
                    from cma.sync_run r where r.tenant_id = t.id) x
where x.succeeded + x.failed > 0 order by t.slug collate \"C\""
HOURS_SQL="select t.slug, sum(h.runs) as runs, sum(h.failed) as failed from cma.tenant t
join cma.sync_run_hour h on h.tenant_id = t.id and h.hour < '${BOUND}'::timestamptz
group by t.slug order by t.slug collate \"C\""
export ROWS_SQL HOURS_SQL

step "prod: the run rows before (slug|succeeded|failed|succeeded past|failed past)" 600 rc 'PSQL_TIMEOUT=540 psql_val "$ROWS_SQL" | tee "$RUN_TMP/rows.before"'
step "prod: the hourly counts before (slug|runs|failed)" 300 rc 'psql_val "$HOURS_SQL" | tee "$RUN_TMP/hours.before" && test -s "$RUN_TMP/hours.before"' \
  || stop_run "the hourly counts could not be read: nothing to compare with"

# just before the execute: a reconcile running now (the advisory lock would make this one skip) is waited for
step "prod: no reconcile running now (read; a running one is waited for)" 3900 rc '
  name="$(timeout 60 gcloud run jobs executions list --job=ingest-reconcile --project=p4a-cma-prod --region="$REGION" \
    --limit=1 --sort-by="~metadata.creationTimestamp" --format="value(metadata.name)")" || exit 1
  [ -n "$name" ] || { echo "no execution yet"; exit 0; }
  echo "$name" > "$RUN_TMP/execution"
  wait_execution p4a-cma-prod; echo "the newest execution ${name} is complete"; exit 0' || stop_run "cannot tell whether a reconcile runs"
no_run_proxy
step "prod: execute ingest-reconcile" 240 rc 'execute_job p4a-cma-prod ingest-reconcile' || stop_run "the reconcile did not start"
step "prod: the reconcile runs (polled)" 3900 rc 'wait_execution p4a-cma-prod'
step "prod: the retention lines, one per tenant" 600 rc 'purge_lines p4a-cma-prod'

step "prod: the run rows after (slug|succeeded|failed|succeeded past|failed past)" 600 rc 'PSQL_TIMEOUT=540 psql_val "$ROWS_SQL" | tee "$RUN_TMP/rows.after"'
step "prod: the hourly counts after, the same as before" 300 rc 'psql_val "$HOURS_SQL" | tee "$RUN_TMP/hours.after" && test -s "$RUN_TMP/hours.after" && diff "$RUN_TMP/hours.before" "$RUN_TMP/hours.after" && echo "the same"'
note "Browser (prod): System health, the 24-hour counts as before the purge"
run_finish
