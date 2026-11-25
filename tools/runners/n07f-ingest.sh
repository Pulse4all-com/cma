#!/usr/bin/env bash
# tools/runners/n07f-ingest.sh: the ingest jobs with the reconcile's purge (N07f, #321, decision D13), dev, then prod.
#
#   cd ~/cma && git switch -q main && git pull -q --ff-only && bash tools/runners/n07f-ingest.sh
#
# After #321 is merged and after 240 ran in dev and prod (n07f-dev.sh, n07f-prod.sh). Builds the image if it does not
# exist (in p4a-cma-prod, docs/ingest/README.md, Deploy), deploys the jobs in dev, runs the reconcile once in dev and reads
# its retention lines, then deploys the jobs in prod. Every deploy is checked by reads afterwards (each job's image, the
# reconcile's schedule), whatever the deploy's exit said; a deploy that left a job on the old image is run once more.
# The service (cma-ingest) is not redeployed: only the reconcile changed. From the night after the prod deploy, the
# scheduled reconcile (03:30) purges; n07f-first-purge.sh runs the first purge by hand, watched, before that.
# Log and records check: records/0009zt-ingest-<date>/.
source "$(dirname "$0")/lib.sh"
run_init n07f-ingest "0009zt-ingest-$(date +%F)"
on_main
JOBS="$(ingest_jobs | tr '\n' ' ')"
export JOBS
note "the jobs deploy.sh deploys: ${JOBS}"

db_connect dev
has_0009zt || stop_run "0009zt is not in dev: run tools/runners/n07f-dev.sh first"
db_connect prod
has_0009zt || stop_run "0009zt is not in prod: run tools/runners/n07f-prod.sh first"

step "what ships: prod's reconcile image now, and the ingest commits since" 120 rc '
  old="$(timeout 60 gcloud run jobs describe ingest-reconcile --project=p4a-cma-prod --region="$REGION" \
    --format="value(spec.template.spec.template.spec.containers[0].image)")"
  echo "prod ingest-reconcile: ${old:-unknown}"
  tag="${old##*:}"
  if git cat-file -e "${tag}^{commit}" 2>/dev/null; then git log --oneline "${tag}..HEAD" -- ingest/; else echo "(tag ${tag:-?} is not a commit here)"; fi'

no_run_proxy
step "deploy.sh dev --jobs (builds the image if it is missing)" 2700 rc "bash docs/ingest/deploy.sh dev --jobs" \
  || note "the dev deploy's exit is not trusted (a gcloud write can hang after it applied): the reads below decide"
step "the image exists" 1500 rc '
  for i in $(seq 1 80); do
    d="$(timeout 60 gcloud artifacts docker images describe "$IMAGE" --format="value(image_summary.digest)" 2>/dev/null)"
    [ -n "$d" ] && { echo "$IMAGE $d"; exit 0; }
    echo "not there yet (${i} of 80): the build may still run"; sleep 15
  done; exit 1' || stop_run "no image ${IMAGE}"
if ! step "dev: every job on the image (read)" 900 rc 'jobs_on_image p4a-cma-dev "$IMAGE"'; then
  no_run_proxy
  step "deploy.sh dev --jobs, once more" 1800 rc "bash docs/ingest/deploy.sh dev --jobs" || note "the second dev deploy's exit is not trusted either"
  step "dev: every job on the image (read), again" 900 rc 'jobs_on_image p4a-cma-dev "$IMAGE"' || stop_run "dev's jobs are not on ${IMAGE}"
fi
step "dev: the reconcile's schedule (read)" 120 rc \
  'timeout 60 gcloud scheduler jobs describe ingest-reconcile --project=p4a-cma-dev --location="$REGION" --format="value(schedule,timeZone,state)"'

no_run_proxy
step "dev: execute ingest-reconcile" 240 rc 'execute_job p4a-cma-dev ingest-reconcile' || stop_run "the dev reconcile did not start"
step "dev: the reconcile runs (polled)" 3900 rc 'wait_execution p4a-cma-dev' || stop_run "the dev reconcile failed"
step "dev: the retention lines, one per tenant" 600 rc 'purge_lines p4a-cma-dev' || stop_run "no clean retention line in dev"

no_run_proxy
step "deploy.sh prod --jobs (no build: the image dev ran)" 1800 rc "bash docs/ingest/deploy.sh prod --jobs" \
  || note "the prod deploy's exit is not trusted (a gcloud write can hang after it applied): the reads below decide"
if ! step "prod: every job on the image (read)" 900 rc 'jobs_on_image p4a-cma-prod "$IMAGE"'; then
  no_run_proxy
  step "deploy.sh prod --jobs, once more" 1800 rc "bash docs/ingest/deploy.sh prod --jobs" || note "the second prod deploy's exit is not trusted either"
  step "prod: every job on the image (read), again" 900 rc 'jobs_on_image p4a-cma-prod "$IMAGE"' || stop_run "prod's jobs are not on ${IMAGE}"
fi
step "prod: the reconcile's schedule (read)" 120 rc \
  'timeout 60 gcloud scheduler jobs describe ingest-reconcile --project=p4a-cma-prod --location="$REGION" --format="value(schedule,timeZone,state)"'
note "from tonight the scheduled reconcile (03:30 Amsterdam) purges in prod; run tools/runners/n07f-first-purge.sh before then to watch the first purge"
run_finish
