#!/usr/bin/env bash
# The roster's minute job (addition 0010a, brief B, E2; Decision log, 26 Nov 2026): a Cloud Run job on the web image that
# switches agents along today's published roster (jobs/roster-switch.mjs: one statement for all tenants,
# cma.roster_switch_all()), started by Cloud Scheduler every minute. The sibling of deploy-follow-up.sh, with the same
# account, image and variables, and the frame of the Terminal runners (tools/runners/lib.sh: each step timed and logged
# live, a heartbeat every 15 s, a timeout per command, the exit and verdict per step).
#
#   cd ~/cma && git switch -q main && git pull -q --ff-only && bash docs/scheduler/deploy-roster-switch.sh dev  <short sha>
#   cd ~/cma && git switch -q main && git pull -q --ff-only && bash docs/scheduler/deploy-roster-switch.sh prod <short sha>
#
# After 254_roster_drives_the_day.sql ran in that database, with the short sha of an image that holds
# jobs/roster-switch.mjs: the merge that brings it, or any later one (docs/RUNBOOK.md, 7a). Rerunnable: the deploy creates
# or updates, the schedule is created once and updated after that. Every gcloud write runs under a timeout with no
# "gcloud run services proxy" running, and is checked afterwards by a read, never by its exit code (CLAUDE.md, Instructions
# for Martin). The job runs as cma-web@<project>.iam (member of cma_app through its IAM database user), a pool of 1, every
# minute in UTC, no retries: the next minute is the retry; the switch is idempotent, so an overlapping run writes nothing.
# Expected: about 2 minutes in all (the deploy 30 to 90 s, each read a few seconds, the first execution under 30 s).
# Log and records check: records/0010a-roster-switch-<env>-<date>/.
set -uo pipefail
source "$(dirname "$0")/../../tools/runners/lib.sh"

ENV="${1:?dev or prod}"
SHA="${2:?short sha of the image on main}"
case "$ENV" in
  dev)  PROJECT=p4a-cma-dev;  INSTANCE=p4a-cma-dev:europe-west4:cma-dev-pg ;;
  prod) PROJECT=p4a-cma-prod; INSTANCE=p4a-cma-prod:europe-west4:cma-prod-pg ;;
  *) echo "first argument is dev or prod"; exit 2 ;;
esac
IMAGE="europe-west4-docker.pkg.dev/p4a-cma-prod/cma/web:${SHA}"   # built once by prod's trigger, deployed many
SA="cma-web@${PROJECT}.iam.gserviceaccount.com"
DB_USER="cma-web@${PROJECT}.iam"
JOB=cma-roster-switch
SCHEDULE=cma-roster-switch-minutely
URI="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT}/jobs/${JOB}:run"
export PROJECT INSTANCE IMAGE SA DB_USER JOB SCHEDULE URI

run_init "deploy-roster-switch-${ENV}" "0010a-roster-switch-${ENV}-$(date +%F)"
no_run_proxy

step "the services Run and Scheduler on (expected under 30 s)" 120 rc \
  'timeout 100 gcloud services enable run.googleapis.com cloudscheduler.googleapis.com --project="$PROJECT" --quiet'
step "deploy the job ${JOB} on ${SHA} (expected 30 to 90 s; its exit is not trusted, the read below decides)" 300 rc '
  timeout 280 gcloud run jobs deploy "$JOB" --project="$PROJECT" --region="$REGION" --image="$IMAGE" \
    --command=node --args=jobs/roster-switch.mjs --service-account="$SA" --set-cloudsql-instances="$INSTANCE" \
    --set-env-vars="CMA_DB_INSTANCE=${INSTANCE},CMA_DB_USER=${DB_USER},CMA_DB_NAME=cma,CMA_DB_SESSION_OPTIONS=${DB_SESSION_OPTIONS:-}" \
    --cpu=1 --memory=512Mi --tasks=1 --max-retries=0 --task-timeout=2m --quiet' \
  || note "the deploy's exit is not trusted (a gcloud write can hang after it applied): the read below decides"
step "the job is on ${IMAGE} (read)" 120 rc '
  img="$(timeout 60 gcloud run jobs describe "$JOB" --project="$PROJECT" --region="$REGION" --format="value(spec.template.spec.template.spec.containers[0].image)")"
  echo "$JOB: ${img:-missing}"; [ "$img" = "$IMAGE" ]' || stop_run "the job is not on ${IMAGE}: run this script again"
step "Cloud Scheduler may start it (run.invoker for ${SA})" 120 rc '
  timeout 100 gcloud run jobs add-iam-policy-binding "$JOB" --project="$PROJECT" --region="$REGION" \
    --member="serviceAccount:${SA}" --role=roles/run.invoker --quiet >/dev/null && echo "binding set"'
step "the schedule ${SCHEDULE}, every minute in UTC (expected under 30 s)" 180 rc '
  if timeout 60 gcloud scheduler jobs describe "$SCHEDULE" --project="$PROJECT" --location="$REGION" >/dev/null 2>&1; then verb=update; else verb=create; fi
  timeout 100 gcloud scheduler jobs "$verb" http "$SCHEDULE" --project="$PROJECT" --location="$REGION" \
    --schedule="* * * * *" --time-zone="Etc/UTC" --uri="$URI" --http-method=POST --oauth-service-account-email="$SA" --quiet >/dev/null
  echo "schedule ${verb}d"' || note "the schedule write's exit is not trusted: the read below decides"
step "the schedule reads every minute and is enabled (read)" 120 rc '
  s="$(timeout 60 gcloud scheduler jobs describe "$SCHEDULE" --project="$PROJECT" --location="$REGION" --format="value(schedule,state)")"
  echo "$SCHEDULE: ${s:-missing}"; echo "$s" | grep -q "^\* \* \* \* \*.*ENABLED"' || stop_run "the schedule is missing or paused"
step "one execution now (expected under 30 s)" 240 rc 'execute_job "$PROJECT" "$JOB"' || stop_run "the job did not start"
step "the execution ends (polled)" 300 rc 'wait_execution "$PROJECT"' || stop_run "the execution failed: read its log below"
step "its log line: tenants, switched, ended, failed (read)" 120 rc '
  timeout 100 gcloud logging read "resource.type=cloud_run_job AND resource.labels.job_name=${JOB} AND jsonPayload.message=\"roster-switch\"" \
    --project="$PROJECT" --limit=5 --freshness=10m --format="value(jsonPayload)"'
run_finish
