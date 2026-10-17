#!/bin/bash
# The ingest service cma-ingest (DESIGN §5; README Architecture, Ingest API) in one project.
#
#   bash docs/ingest/deploy.sh dev  [--tenant <slug>]... [--secret <name>]...
#   bash docs/ingest/deploy.sh prod --front <host> [--tenant <slug>]... [--secret <name>]...
#   bash docs/ingest/deploy.sh dev|prod --jobs [--reconcile-every "<cron>"] [--reconcile-lookback <minutes>]
#
#   --tenant <slug>   the tenant's hash pepper ingest-hash-pepper-<slug>: created with 32 random bytes
#                     when missing (the value is generated and stored without being shown), accessor
#                     granted; calls are not read back without it (pepper_unavailable)
#   --secret <name>   grant the service account the accessor on an existing secret, for example
#                     ingest-hubspot-dev-signing and ingest-hubspot-dev-token
#   --front <host>    the service only (not --jobs), prod: the service sits behind the web load balancer
#                     as https://<host> (docs/ingest/front.sh builds that front): ingress
#                     internal-and-cloud-load-balancing instead of all, so the run.app address refuses
#                     everyone, and INGEST_PUBLIC_URLS starts with https://<host>, so the URI HubSpot
#                     signs is the public host (the first deploy too). Prod requires it: since 16 October
#                     2026 a prod service deploy without --front stops (exit 2) before any gcloud call,
#                     because the ingress would go to all and HubSpot's signatures over the public host
#                     would fail (revision cma-ingest-00008; records/ingest-front-incident-2026-10-16).
#                     Dev needs none and keeps its run.app address
#   --jobs            the jobs and their schedules instead of the service (below)
#   --reconcile-every "<cron>"       with --jobs: the reconcile schedule (default "30 2 * * *", Europe/Amsterdam)
#   --reconcile-lookback <minutes>   with --jobs: the reconcile's look-back (default the job's 26 hours).
#                     The polling fallback of NIGHT_NOTES D3 (no v3 signature on the project app) is
#                     --reconcile-every "*/2 * * * *" --reconcile-lookback 10, a schedule change only
#
# Dev only, on the service and the jobs: INGEST_ALLOW_REPLAY=1, so a dev Aircall connection whose
# settings hold {"replay": true} takes a call from the replayed event itself (tools/replay.mjs
# --adapter aircall; there is no Aircall sandbox). Prod never sets it: --set-env-vars replaces every
# variable on each deploy, so a prod service or job never carries it and ignores the setting.
#
# Runs from Cloud Shell in ~/cma under your own account, on a clean checkout of main. Rerunnable.
# Steps: the APIs; the service account cma-ingest@<project> with Cloud SQL client and instance user;
# its IAM database user; the accessor per named secret; the image; the Cloud Run service with the
# settings of DESIGN §5; its public URLs as INGEST_PUBLIC_URLS (the URI HubSpot signs; with --front the
# public host first); INGEST_SHOPIFY_READBACK_BUDGET_MS=1500, the Shopify route's own inline read-back
# budget (Shopify allows a delivery five seconds in all; brief B10); startup CPU boost (--cpu-boost: a new
# instance starts with extra CPU, so a cold start answers sooner; sixth Gemini audit FIND-04, 13 October
# 2026). Prints the Studio statement that makes the database user a member of cma_app,
# the service URL and /health.
#
# With --jobs (DESIGN §5, brief B8), the same steps up to the image, then instead of the service: the
# Cloud Run jobs on the same image by tag, each `node jobs/<name>.mjs` as cma-ingest@<project> with
# the service's database settings, and their Cloud Scheduler entries (Europe/Amsterdam) calling the
# jobs' run endpoints as cma-ingest-scheduler@<project>, which holds run.invoker on the scheduled jobs
# only:
#   ingest-sweep       every minute   due events, the second read, telephony catalogs (hourly), link_calls
#   ingest-poll-forms  every minute   HubSpot forms: catalog hourly, submissions until the cursor
#   ingest-poll-email  every minute   HubSpot email engagements and inbox conversations (brief B17b), for connections
#                                     whose settings hold email_poll true: catalogs and owners hourly, threads and
#                                     messages after their cursors, the open check every ten minutes
#   ingest-reconcile   02:30          everything modified in the last 26 hours (HubSpot also email engagements and inbox
#                                     threads, and the inbox trash); Aircall: calls of the last 26 hours and the webhook;
#                                     Shopify: customers and orders of the last 26 hours and the store's subscriptions
#   ingest-outbox      no schedule    CRM contact write-backs (0007c): claimed, applied by mode, one batch update per connection.
#                                     Generic and unused since 0008h (the CMA writes nothing back for commerce), so it is deployed
#                                     without a schedule, and a schedule an earlier deploy made is paused (gcloud scheduler jobs
#                                     resume ingest-outbox … turns it on again when a write-back is configured)
#   ingest-backfill    no schedule    gcloud run jobs execute ingest-backfill --args=--connection,<id>,--object,<type>,--from,<date>
# The arguments of an execution are appended to the job's command (node jobs/<name>.mjs).
#
# The image is built once, in p4a-cma-prod, never in dev (README Architecture, Build and deploy;
# Decision log, 5 October 2026): Cloud Build in europe-west4 (ingest/cloudbuild.yaml) as service
# account cma-build@p4a-cma-prod, source staged in gs://p4a-cma-prod-build-src (the default staging
# bucket is in the US and the EU-only policy refuses it), pushed to
# europe-west4-docker.pkg.dev/p4a-cma-prod/cma/ingest:<short sha>, the sha of the last commit that
# touched ingest/ (not HEAD), so a merge of docs or README only reuses the image dev tested; when the
# two differ the script prints both. When that tag already exists the build is skipped, so a prod
# deploy after dev runs exactly the bytes dev tested. Dev and prod both deploy that image by tag;
# dev has no repository and no build of its own, and pulls through its
# Cloud Run service agent's Artifact Registry reader on the prod repository cma. Before a dev deploy
# the script checks that grant and, when it is missing, prints the command that adds it and stops.
set -euo pipefail

ENV="${1:?dev or prod}"
shift
TENANTS=()
SECRETS=()
JOBS=0
RECONCILE_EVERY="30 2 * * *"
RECONCILE_LOOKBACK=""
FRONT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tenant) TENANTS+=("${2:?--tenant needs a slug}"); shift 2 ;;
    --secret) SECRETS+=("${2:?--secret needs a name}"); shift 2 ;;
    --jobs) JOBS=1; shift ;;
    --front) FRONT="${2:?--front needs a host}"; shift 2 ;;
    --reconcile-every) RECONCILE_EVERY="${2:?--reconcile-every needs a cron expression}"; shift 2 ;;
    --reconcile-lookback) RECONCILE_LOOKBACK="${2:?--reconcile-lookback needs minutes}"; shift 2 ;;
    *) echo "unknown argument $1"; exit 2 ;;
  esac
done

case "$ENV" in
  dev)  PROJECT=p4a-cma-dev;  INSTANCE_NAME=cma-dev-pg;  MIN=0; MAX=2; LOG_HEADERS=1; REPLAY_VARS=("INGEST_ALLOW_REPLAY=1") ;;
  prod) PROJECT=p4a-cma-prod; INSTANCE_NAME=cma-prod-pg; MIN=1; MAX=5; LOG_HEADERS=0; REPLAY_VARS=() ;;
  *) echo "first argument is dev or prod"; exit 2 ;;
esac
REGION=europe-west4
INSTANCE="${PROJECT}:${REGION}:${INSTANCE_NAME}"
SERVICE=cma-ingest
SA_NAME=cma-ingest
SA="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
DB_USER="${SA_NAME}@${PROJECT}.iam"
BUILD_PROJECT=p4a-cma-prod
BUILD_SA="cma-build@${BUILD_PROJECT}.iam.gserviceaccount.com"
BUILD_STAGING="gs://${BUILD_PROJECT}-build-src/source"
REPO="${REGION}-docker.pkg.dev/${BUILD_PROJECT}/cma"

cd "$(git rev-parse --show-toplevel)"
HEAD_SHA="$(git rev-parse --short HEAD)"
SHA="$(git log -1 --format=%h -- ingest/)"   # the image tag: the last commit that touched ingest/
if [ -n "$(git status --porcelain -- ingest)" ]; then
  echo "ingest/ has uncommitted changes; deploy from a clean checkout of main"; exit 2
fi
[ -n "$SHA" ] || { echo "no commit touches ingest/"; exit 2; }
IMAGE="${REPO}/ingest:${SHA}"
for t in "${TENANTS[@]}"; do [[ "$t" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || { echo "tenant slug $t is not a slug"; exit 2; }; done
for s in "${SECRETS[@]}"; do [[ "$s" =~ ^[A-Za-z0-9_-]{1,255}$ ]] || { echo "secret name $s is not valid"; exit 2; }; done
[[ "$RECONCILE_EVERY" =~ ^[0-9*/,-]+( [0-9*/,-]+){4}$ ]] || { echo "--reconcile-every is not a five-field cron expression"; exit 2; }
[ -z "$RECONCILE_LOOKBACK" ] || [[ "$RECONCILE_LOOKBACK" =~ ^[1-9][0-9]{0,4}$ ]] || { echo "--reconcile-lookback is not a number of minutes"; exit 2; }
[ -z "$FRONT" ] || [[ "$FRONT" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || { echo "--front $FRONT is not a host name"; exit 2; }
if [ "$JOBS" = 1 ] && [ -n "$FRONT" ]; then
  echo "--front goes with the service deploy, not --jobs"; exit 2
fi
if [ "$ENV" = prod ] && [ "$JOBS" = 0 ] && [ -z "$FRONT" ]; then
  echo "prod service deploy needs --front <host> (ingest.pulse4all.app); without it ingress goes to all and HubSpot signatures fail"; exit 2
fi
if [ "$JOBS" = 0 ] && { [ "$RECONCILE_EVERY" != "30 2 * * *" ] || [ -n "$RECONCILE_LOOKBACK" ]; }; then
  echo "--reconcile-every and --reconcile-lookback go with --jobs"; exit 2
fi

if [ "$JOBS" = 1 ]; then echo "== ingest jobs ${SHA} → ${PROJECT}"; else echo "== ${SERVICE} ${SHA} → ${PROJECT}"; fi
[ "$SHA" = "$HEAD_SHA" ] || echo "image tag ${SHA}: the last commit under ingest/; HEAD is ${HEAD_SHA}"
gcloud services enable run.googleapis.com secretmanager.googleapis.com sqladmin.googleapis.com \
  --project="$PROJECT" --quiet
[ "$JOBS" = 0 ] || gcloud services enable cloudscheduler.googleapis.com --project="$PROJECT" --quiet

# The service account, its project roles, its IAM database user
gcloud iam service-accounts describe "$SA" --project="$PROJECT" >/dev/null 2>&1 || \
  gcloud iam service-accounts create "$SA_NAME" --project="$PROJECT" --display-name="CMA ingest" --quiet
for role in roles/cloudsql.client roles/cloudsql.instanceUser; do
  gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:${SA}" --role="$role" \
    --condition=None --quiet >/dev/null
done
if ! gcloud sql users list --instance="$INSTANCE_NAME" --project="$PROJECT" --format='value(name)' | grep -qx "$DB_USER"; then
  gcloud sql users create "$DB_USER" --instance="$INSTANCE_NAME" --project="$PROJECT" --type=cloud_iam_service_account --quiet
fi

# Secrets: the accessor per named secret; the peppers of the named tenants
grant_accessor () {
  gcloud secrets add-iam-policy-binding "$1" --project="$PROJECT" \
    --member="serviceAccount:${SA}" --role=roles/secretmanager.secretAccessor --quiet >/dev/null && echo "accessor on $1"
}
for s in "${SECRETS[@]}"; do
  if gcloud secrets describe "$s" --project="$PROJECT" >/dev/null 2>&1; then grant_accessor "$s"; else echo "secret $s does not exist yet: create it (runbook put_secret), then rerun with --secret $s"; fi
done
for t in "${TENANTS[@]}"; do
  p="ingest-hash-pepper-${t}"
  if ! gcloud secrets describe "$p" --project="$PROJECT" >/dev/null 2>&1; then
    gcloud secrets create "$p" --project="$PROJECT" --replication-policy=user-managed --locations="$REGION" --quiet >/dev/null
    openssl rand -hex 32 | tr -d '\n' | gcloud secrets versions add "$p" --project="$PROJECT" --data-file=- >/dev/null
    echo "created $p (value generated, not shown)"
  fi
  grant_accessor "$p"
done
[ ${#TENANTS[@]} -gt 0 ] || echo "note: no --tenant given; calls wait (pepper_unavailable) until ingest-hash-pepper-<tenant slug> exists"

# The image: dev pulls from the prod repository through its Cloud Run service agent
if [ "$PROJECT" != "$BUILD_PROJECT" ]; then
  AGENT="service-$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')@serverless-robot-prod.iam.gserviceaccount.com"
  READ_ROLES='roles/artifactregistry\.(reader|writer|repoAdmin|admin)'
  roles="$(gcloud artifacts repositories get-iam-policy cma --location="$REGION" --project="$BUILD_PROJECT" \
      --flatten='bindings[].members' --filter="bindings.members:serviceAccount:${AGENT}" --format='value(bindings.role)'
    gcloud projects get-iam-policy "$BUILD_PROJECT" \
      --flatten='bindings[].members' --filter="bindings.members:serviceAccount:${AGENT}" --format='value(bindings.role)')"
  if ! grep -qxE "$READ_ROLES" <<<"$roles"; then
    echo "${PROJECT}'s Cloud Run service agent cannot read ${REPO}; grant it (README, 5 October 2026), then rerun:"
    echo "gcloud artifacts repositories add-iam-policy-binding cma --project=${BUILD_PROJECT} --location=${REGION} --member=serviceAccount:${AGENT} --role=roles/artifactregistry.reader"
    exit 1
  fi
  echo "${AGENT} reads ${REPO}"
fi

# The image: built once in prod; an existing tag is deployed as it is
if out="$(gcloud artifacts docker images describe "$IMAGE" --format='value(image_summary.digest)' 2>&1)"; then
  echo "image ${IMAGE} exists (${out}); no build"
elif grep -qiE 'not.?found' <<<"$out"; then
  gcloud builds submit ingest --project="$BUILD_PROJECT" --region="$REGION" --config=ingest/cloudbuild.yaml \
    --gcs-source-staging-dir="$BUILD_STAGING" \
    --service-account="projects/${BUILD_PROJECT}/serviceAccounts/${BUILD_SA}" \
    --substitutions="_VERSION=${SHA},_REPO=${REPO}" --quiet
else
  echo "cannot tell whether ${IMAGE} exists:"; echo "$out"; exit 1
fi

# The service. Env vars as one list in gcloud's custom-delimiter form ^|^, because INGEST_PUBLIC_URLS
# holds commas and CMA_DB_USER holds @ (cma-ingest@<project>.iam). No value may hold |; env_list stops
# the script before gcloud runs when one does.
DELIM='|'
env_list () {  # KEY=VALUE... → ^|^KEY=VALUE|KEY=VALUE; fails when a value holds the delimiter
  local kv out=""
  for kv in "$@"; do
    case "${kv#*=}" in
      *"$DELIM"*) echo "env var ${kv%%=*} holds the delimiter ${DELIM} (${kv#*=}); gcloud would split it, stopped" >&2; return 1 ;;
    esac
    out+="${out:+$DELIM}${kv}"
  done
  printf '^%s^%s' "$DELIM" "$out"
}

if [ "$JOBS" = 1 ]; then
  # The jobs: the same image and service account as the service, the database settings, no public URL
  SCHED_SA_NAME=cma-ingest-scheduler
  SCHED_SA="${SCHED_SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
  gcloud iam service-accounts describe "$SCHED_SA" --project="$PROJECT" >/dev/null 2>&1 || \
    gcloud iam service-accounts create "$SCHED_SA_NAME" --project="$PROJECT" --display-name="CMA ingest scheduler" --quiet
  JOB_ENV="$(env_list "CMA_DB_INSTANCE=${INSTANCE}" "CMA_DB_USER=${DB_USER}" "CMA_DB_NAME=cma" "CMA_DB_POOL_MAX=3" \
    "INGEST_VERSION=${SHA}" "INGEST_PROJECT=${PROJECT}" ${REPLAY_VARS[@]+"${REPLAY_VARS[@]}"})"
  deploy_job () {  # <job> <script> <task timeout> <args, comma-separated; empty resets them>
    gcloud run jobs deploy "$1" \
      --project="$PROJECT" --region="$REGION" \
      --image="$IMAGE" \
      --command="node,jobs/$2" --args="$4" \
      --service-account="$SA" \
      --set-env-vars="$JOB_ENV" \
      --tasks=1 --max-retries=0 --task-timeout="$3" \
      --cpu=1 --memory=512Mi \
      --quiet
  }
  RECONCILE_ARGS=""
  [ -z "$RECONCILE_LOOKBACK" ] || RECONCILE_ARGS="--lookback-minutes,${RECONCILE_LOOKBACK}"
  deploy_job ingest-sweep sweep.mjs 10m ""
  deploy_job ingest-poll-forms poll-forms.mjs 10m ""
  deploy_job ingest-poll-email poll-email.mjs 10m ""
  deploy_job ingest-reconcile reconcile.mjs 60m "$RECONCILE_ARGS"
  deploy_job ingest-outbox outbox.mjs 10m ""
  deploy_job ingest-backfill backfill.mjs 24h ""

  # Cloud Scheduler calls each scheduled job's run endpoint as the scheduler account (run.invoker on those jobs only)
  schedule () {  # <job> <cron>
    gcloud run jobs add-iam-policy-binding "$1" --project="$PROJECT" --region="$REGION" \
      --member="serviceAccount:${SCHED_SA}" --role=roles/run.invoker --quiet >/dev/null
    local uri="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT}/jobs/$1:run"
    local verb=create
    gcloud scheduler jobs describe "$1" --project="$PROJECT" --location="$REGION" >/dev/null 2>&1 && verb=update
    gcloud scheduler jobs "$verb" http "$1" \
      --project="$PROJECT" --location="$REGION" \
      --schedule="$2" --time-zone="Europe/Amsterdam" \
      --uri="$uri" --http-method=POST \
      --oauth-service-account-email="$SCHED_SA" --quiet >/dev/null
    echo "schedule $1: $2 (Europe/Amsterdam)"
  }
  schedule ingest-sweep "* * * * *"
  schedule ingest-poll-forms "* * * * *"
  schedule ingest-poll-email "* * * * *"
  schedule ingest-reconcile "$RECONCILE_EVERY"
  # The outbox has nothing to deliver since 0008h: no schedule, and one left by an earlier deploy is paused
  if gcloud scheduler jobs describe ingest-outbox --project="$PROJECT" --location="$REGION" --format='value(state)' 2>/dev/null | grep -qx ENABLED; then
    gcloud scheduler jobs pause ingest-outbox --project="$PROJECT" --location="$REGION" --quiet >/dev/null && echo "schedule ingest-outbox: paused (nothing to deliver since 0008h)"
  else
    echo "schedule ingest-outbox: none (the job runs only when executed)"
  fi

  echo
  echo "== Studio (${INSTANCE_NAME}), once per database: the service's database user joins cma_app (the jobs run as it too)"
  echo "grant cma_app to \"${DB_USER}\";"
  echo
  echo "== jobs on ${IMAGE}"
  echo "ingest-sweep, ingest-poll-forms, ingest-poll-email (every minute), ingest-reconcile (${RECONCILE_EVERY}${RECONCILE_LOOKBACK:+, look-back ${RECONCILE_LOOKBACK} minutes}), ingest-outbox and ingest-backfill (manual)"
  echo "backfill:  gcloud run jobs execute ingest-backfill --project=${PROJECT} --region=${REGION} --wait --args=--connection,<id>,--object,<deal|ticket|crm_call|task|form_submission|contact|crm_email|inbox_thread|telephony_call|commerce_customer|commerce_order>,--from,<YYYY-MM-DD>"
  echo "run now:   gcloud run jobs execute ingest-sweep --project=${PROJECT} --region=${REGION} --wait"
  echo "logs:      gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=ingest-sweep' --project=${PROJECT} --limit=20 --format='value(jsonPayload.message,jsonPayload.code)'"
  exit 0
fi

# The service.
urls_of () {  # every public URL of the service (both address forms), comma-separated; empty before the first deploy
  { gcloud run services describe "$SERVICE" --project="$PROJECT" --region="$REGION" --format=json 2>/dev/null || echo '{}'; } | python3 -c '
import json, sys
s = json.load(sys.stdin)
urls = json.loads(s.get("metadata", {}).get("annotations", {}).get("run.googleapis.com/urls", "[]") or "[]")
main = s.get("status", {}).get("url")
if main and main not in urls: urls.insert(0, main)
print(",".join(urls))'
}
public_urls () {  # with --front: https://<host> first, then the service's own URLs
  local own
  own="$(urls_of)"
  if [ -n "$FRONT" ]; then echo "https://${FRONT}${own:+,${own}}"; else echo "$own"; fi
}
INGRESS_FLAG=--ingress=all
[ -z "$FRONT" ] || INGRESS_FLAG=--ingress=internal-and-cloud-load-balancing
URLS="$(public_urls)"
ENV_VARS="$(env_list "CMA_DB_INSTANCE=${INSTANCE}" "CMA_DB_USER=${DB_USER}" "CMA_DB_NAME=cma" "CMA_DB_POOL_MAX=5" \
  "INGEST_VERSION=${SHA}" "INGEST_PROJECT=${PROJECT}" "INGEST_LOG_HEADER_NAMES=${LOG_HEADERS}" \
  "INGEST_READBACK_BUDGET_MS=3000" "INGEST_SHOPIFY_READBACK_BUDGET_MS=1500" "INGEST_PUBLIC_URLS=${URLS}" ${REPLAY_VARS[@]+"${REPLAY_VARS[@]}"})"
gcloud run deploy "$SERVICE" \
  --project="$PROJECT" --region="$REGION" \
  --image="$IMAGE" \
  --service-account="$SA" \
  --no-invoker-iam-check \
  "$INGRESS_FLAG" \
  --port=8080 \
  --concurrency=20 \
  --min-instances="$MIN" --max-instances="$MAX" \
  --cpu=1 --memory=512Mi \
  --cpu-boost \
  --timeout=30s \
  --set-env-vars="$ENV_VARS" \
  --quiet

# First deploy: the URLs exist only now; set them so signatures verify against the public address
NEW_URLS="$(public_urls)"
if [ "$NEW_URLS" != "$URLS" ]; then
  URL_VARS="$(env_list "INGEST_PUBLIC_URLS=${NEW_URLS}")"
  gcloud run services update "$SERVICE" --project="$PROJECT" --region="$REGION" \
    --update-env-vars="$URL_VARS" --quiet
fi
URL="$(gcloud run services describe "$SERVICE" --project="$PROJECT" --region="$REGION" --format='value(status.url)')"

echo
echo "== Studio (${INSTANCE_NAME}), once per database: the service's database user joins cma_app"
echo "grant cma_app to \"${DB_USER}\";"
echo
echo "== ${SERVICE} ${SHA} at ${URL}"
echo "public URLs (signed by HubSpot): ${NEW_URLS}"
if [ -n "$FRONT" ]; then
  echo "ingress: internal-and-cloud-load-balancing (front https://${FRONT}: docs/ingest/front.sh, the A record, the certificate ACTIVE)"
  echo "health: $(curl -s --max-time 20 "https://${FRONT}/health" || echo 'no answer yet (front.sh, the A record and the certificate first)')"
  RUNAPP="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${URL}/health" || true)"
  case "$RUNAPP" in
    404) echo "run.app: 404 (refused)" ;;
    200) echo "FAIL run.app: 200, the run.app address answers although ingress is internal-and-cloud-load-balancing" ;;
    *) echo "run.app: ${RUNAPP:-no answer} (expected 404: refused)" ;;
  esac
  echo "webhook address per connection: https://${FRONT}/<adapter>/<connection key>"
else
  echo "health: $(curl -s --max-time 20 "${URL}/health" || echo 'no answer yet')"
  echo "webhook address per connection: ${URL}/<adapter>/<connection key>"
  [ "${#REPLAY_VARS[@]}" -eq 0 ] || echo "replay: INGEST_ALLOW_REPLAY=1 (dev only: an Aircall connection with the setting replay true reads calls from replayed events)"
fi
echo "logs: gcloud run services logs read ${SERVICE} --project=${PROJECT} --region=${REGION} --limit=30"
