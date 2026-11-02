#!/bin/bash
# The Flash snapshot (addition 0008zn; Decision log, 1 November 2026): a Cloud Run job on the web image that takes
# every tenant's daily Flash snapshot when its date is due (jobs/snapshot-flash.mjs), started by Cloud Scheduler
# hourly at minute 20 in UTC. The sibling of deploy-follow-up.sh, with the same account, image and variables, and a
# pool of 1.
#
#   docs/scheduler/deploy-flash.sh dev  <short sha>     creates or updates the job and the schedule in p4a-cma-dev
#   docs/scheduler/deploy-flash.sh prod <short sha>     the same in p4a-cma-prod
#
# Runs from Cloud Shell or your own terminal under your own account, after 122_flash.sql ran in that database, with
# the short sha of an image that holds jobs/snapshot-flash.mjs: the merge that brings it, or any later one
# (docs/RUNBOOK.md, 7a). Rerunnable: `gcloud run jobs deploy` creates or updates, the schedule is created once and
# updated after that. The job runs as the service's own account cma-web@<project>.iam (member of cma_app through its
# IAM database user, no SET ROLE), with a pool of 1 (CMA_DB_POOL_MAX=1; README, Database connection budget). Hourly at
# minute 20 in UTC: each run visits every tenant as its Scheduler user and calls cma.flash_snapshot_take, which takes
# the tenant's date once its local time is past flash.snapshot_local_time (so time zones and summer time need no
# schedule change) and answers "taken" for a date already held. No task retries (--max-retries=0): the next hour is
# the retry (the job itself tries a tenant once more on a fresh connection after a dropped one, as the follow-up
# refresh; the take is idempotent). The scheduler's service account needs to invoke the job (run.invoker).
set -euo pipefail

ENV="${1:?dev or prod}"
SHA="${2:?short sha of the image on main}"
case "$ENV" in
  dev)  PROJECT=p4a-cma-dev;  INSTANCE=p4a-cma-dev:europe-west4:cma-dev-pg ;;
  prod) PROJECT=p4a-cma-prod; INSTANCE=p4a-cma-prod:europe-west4:cma-prod-pg ;;
  *) echo "first argument is dev or prod"; exit 2 ;;
esac
REGION=europe-west4
IMAGE="europe-west4-docker.pkg.dev/p4a-cma-prod/cma/web:${SHA}"   # built once by prod's trigger, deployed many
SA="cma-web@${PROJECT}.iam.gserviceaccount.com"
DB_USER="cma-web@${PROJECT}.iam"
JOB=cma-snapshot-flash
SCHEDULE=cma-snapshot-flash-hourly

gcloud services enable run.googleapis.com cloudscheduler.googleapis.com --project="$PROJECT" --quiet

gcloud run jobs deploy "$JOB" \
  --project="$PROJECT" --region="$REGION" \
  --image="$IMAGE" \
  --command=node --args=jobs/snapshot-flash.mjs \
  --service-account="$SA" \
  --set-cloudsql-instances="$INSTANCE" \
  --set-env-vars="CMA_DB_INSTANCE=${INSTANCE},CMA_DB_USER=${DB_USER},CMA_DB_NAME=cma,CMA_DB_POOL_MAX=1" \
  --cpu=1 --memory=512Mi \
  --tasks=1 --max-retries=0 --task-timeout=15m \
  --quiet

# Cloud Scheduler calls the job's run endpoint with an OAuth token of the same service account
gcloud run jobs add-iam-policy-binding "$JOB" \
  --project="$PROJECT" --region="$REGION" \
  --member="serviceAccount:${SA}" --role=roles/run.invoker --quiet

URI="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT}/jobs/${JOB}:run"
if gcloud scheduler jobs describe "$SCHEDULE" --project="$PROJECT" --location="$REGION" >/dev/null 2>&1; then
  gcloud scheduler jobs update http "$SCHEDULE" \
    --project="$PROJECT" --location="$REGION" \
    --schedule="20 * * * *" --time-zone="Etc/UTC" \
    --uri="$URI" --http-method=POST \
    --oauth-service-account-email="$SA" --quiet
else
  gcloud scheduler jobs create http "$SCHEDULE" \
    --project="$PROJECT" --location="$REGION" \
    --schedule="20 * * * *" --time-zone="Etc/UTC" \
    --uri="$URI" --http-method=POST \
    --oauth-service-account-email="$SA" --quiet
fi

echo "job ${JOB} on ${IMAGE}, schedule ${SCHEDULE} hourly at minute 20 (UTC) in ${PROJECT}"
echo "run it now:   gcloud run jobs execute ${JOB} --project=${PROJECT} --region=${REGION} --wait"
echo "its log:      gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=${JOB} AND jsonPayload.message=\"snapshot-flash\"' --project=${PROJECT} --limit=20 --format='value(jsonPayload)'"
echo "pause it:     gcloud scheduler jobs pause ${SCHEDULE} --project=${PROJECT} --location=${REGION}"
