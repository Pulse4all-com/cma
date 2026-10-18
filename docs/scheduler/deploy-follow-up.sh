#!/bin/bash
# The follow-up refresh (addition 0008s; Decision log, 18 October 2026): a Cloud Run job on the web image that
# computes every tenant's follow-up snapshot (jobs/refresh-follow-up.mjs), started by Cloud Scheduler every minute.
# The sibling of deploy.sh (the hourly cma-close-forgotten-workdays), with the same account, image and variables.
#
#   docs/scheduler/deploy-follow-up.sh dev  <short sha>     creates or updates the job and the schedule in p4a-cma-dev
#   docs/scheduler/deploy-follow-up.sh prod <short sha>     the same in p4a-cma-prod
#
# Runs from Cloud Shell or your own terminal under your own account, after 80_follow_up_snapshot.sql ran in that
# database, with the short sha of an image that holds jobs/refresh-follow-up.mjs: the merge that brings it, or any
# later one (docs/RUNBOOK.md, 7a). Rerunnable: `gcloud run jobs deploy` creates or updates, the schedule is
# created once and updated after that. The job runs as the service's own account cma-web@<project>.iam (member of
# cma_app through its IAM database user, no SET ROLE), with a pool of 2 (README, Database connection budget). Every
# minute in UTC: each run refreshes every tenant in turn as that tenant's Scheduler user; a run that overlaps the
# next one finds the tenant's lock taken and skips it (its log line and its run row say so). No retries: the next
# minute is the retry. The scheduler's service account needs to invoke the job (run.invoker).
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
JOB=cma-refresh-follow-up
SCHEDULE=cma-refresh-follow-up-minutely

gcloud services enable run.googleapis.com cloudscheduler.googleapis.com --project="$PROJECT" --quiet

gcloud run jobs deploy "$JOB" \
  --project="$PROJECT" --region="$REGION" \
  --image="$IMAGE" \
  --command=node --args=jobs/refresh-follow-up.mjs \
  --service-account="$SA" \
  --set-cloudsql-instances="$INSTANCE" \
  --set-env-vars="CMA_DB_INSTANCE=${INSTANCE},CMA_DB_USER=${DB_USER},CMA_DB_NAME=cma" \
  --cpu=1 --memory=512Mi \
  --tasks=1 --max-retries=0 --task-timeout=5m \
  --quiet

# Cloud Scheduler calls the job's run endpoint with an OAuth token of the same service account
gcloud run jobs add-iam-policy-binding "$JOB" \
  --project="$PROJECT" --region="$REGION" \
  --member="serviceAccount:${SA}" --role=roles/run.invoker --quiet

URI="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT}/jobs/${JOB}:run"
if gcloud scheduler jobs describe "$SCHEDULE" --project="$PROJECT" --location="$REGION" >/dev/null 2>&1; then
  gcloud scheduler jobs update http "$SCHEDULE" \
    --project="$PROJECT" --location="$REGION" \
    --schedule="* * * * *" --time-zone="Etc/UTC" \
    --uri="$URI" --http-method=POST \
    --oauth-service-account-email="$SA" --quiet
else
  gcloud scheduler jobs create http "$SCHEDULE" \
    --project="$PROJECT" --location="$REGION" \
    --schedule="* * * * *" --time-zone="Etc/UTC" \
    --uri="$URI" --http-method=POST \
    --oauth-service-account-email="$SA" --quiet
fi

echo "job ${JOB} on ${IMAGE}, schedule ${SCHEDULE} every minute (UTC) in ${PROJECT}"
echo "run it now:   gcloud run jobs execute ${JOB} --project=${PROJECT} --region=${REGION} --wait"
echo "its log:      gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=${JOB} AND jsonPayload.message=\"refresh-follow-up\"' --project=${PROJECT} --limit=20 --format='value(jsonPayload)'"
echo "pause it:     gcloud scheduler jobs pause ${SCHEDULE} --project=${PROJECT} --location=${REGION}"
