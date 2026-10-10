#!/bin/bash
# The ingest service cma-ingest (DESIGN §5; README Architecture, Ingest API) in one project.
#
#   bash docs/ingest/deploy.sh dev  [--tenant <slug>]... [--secret <name>]...
#   bash docs/ingest/deploy.sh prod [--tenant <slug>]... [--secret <name>]...
#
#   --tenant <slug>   the tenant's hash pepper ingest-hash-pepper-<slug>: created with 32 random bytes
#                     when missing (the value is generated and stored without being shown), accessor
#                     granted; calls are not read back without it (pepper_unavailable)
#   --secret <name>   grant the service account the accessor on an existing secret, for example
#                     ingest-hubspot-dev-signing and ingest-hubspot-dev-token
#   --jobs            the jobs and their schedules: brief B8 (not in this version)
#
# Runs from Cloud Shell in ~/cma under your own account, on a clean checkout of main. Rerunnable.
# Steps: the APIs; the service account cma-ingest@<project> with Cloud SQL client and instance user;
# its IAM database user; the accessor per named secret; the Artifact Registry repository cma; the image
# ingest:<short sha> built by Cloud Build (ingest/cloudbuild.yaml); the Cloud Run service with the
# settings of DESIGN §5; its public URLs as INGEST_PUBLIC_URLS (the URI HubSpot signs). Prints the
# Studio statement that makes the database user a member of cma_app, the service URL and /health.
set -euo pipefail

ENV="${1:?dev or prod}"
shift
TENANTS=()
SECRETS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --tenant) TENANTS+=("${2:?--tenant needs a slug}"); shift 2 ;;
    --secret) SECRETS+=("${2:?--secret needs a name}"); shift 2 ;;
    --jobs) echo "--jobs comes with brief B8 (the jobs); nothing deployed"; exit 2 ;;
    *) echo "unknown argument $1"; exit 2 ;;
  esac
done

case "$ENV" in
  dev)  PROJECT=p4a-cma-dev;  INSTANCE_NAME=cma-dev-pg;  MIN=0; MAX=2; LOG_HEADERS=1 ;;
  prod) PROJECT=p4a-cma-prod; INSTANCE_NAME=cma-prod-pg; MIN=1; MAX=5; LOG_HEADERS=0 ;;
  *) echo "first argument is dev or prod"; exit 2 ;;
esac
REGION=europe-west4
INSTANCE="${PROJECT}:${REGION}:${INSTANCE_NAME}"
SERVICE=cma-ingest
SA_NAME=cma-ingest
SA="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
DB_USER="${SA_NAME}@${PROJECT}.iam"
REPO="${REGION}-docker.pkg.dev/${PROJECT}/cma"

cd "$(git rev-parse --show-toplevel)"
SHA="$(git rev-parse --short HEAD)"
if [ -n "$(git status --porcelain -- ingest)" ]; then
  echo "ingest/ has uncommitted changes; deploy from a clean checkout of main"; exit 2
fi
IMAGE="${REPO}/ingest:${SHA}"
for t in "${TENANTS[@]}"; do [[ "$t" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || { echo "tenant slug $t is not a slug"; exit 2; }; done
for s in "${SECRETS[@]}"; do [[ "$s" =~ ^[A-Za-z0-9_-]{1,255}$ ]] || { echo "secret name $s is not valid"; exit 2; }; done

echo "== ${SERVICE} ${SHA} → ${PROJECT}"
gcloud services enable run.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com \
  secretmanager.googleapis.com sqladmin.googleapis.com --project="$PROJECT" --quiet

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

# The image
gcloud artifacts repositories describe cma --location="$REGION" --project="$PROJECT" >/dev/null 2>&1 || \
  gcloud artifacts repositories create cma --repository-format=docker --location="$REGION" --project="$PROJECT" --quiet
gcloud builds submit ingest --project="$PROJECT" --region="$REGION" --config=ingest/cloudbuild.yaml \
  --substitutions="_VERSION=${SHA},_REPO=${REPO}" --quiet

# The service. Env vars as one list, delimited by @ because INGEST_PUBLIC_URLS holds commas
urls_of () {  # every public URL of the service (both address forms), comma-separated; empty before the first deploy
  { gcloud run services describe "$SERVICE" --project="$PROJECT" --region="$REGION" --format=json 2>/dev/null || echo '{}'; } | python3 -c '
import json, sys
s = json.load(sys.stdin)
urls = json.loads(s.get("metadata", {}).get("annotations", {}).get("run.googleapis.com/urls", "[]") or "[]")
main = s.get("status", {}).get("url")
if main and main not in urls: urls.insert(0, main)
print(",".join(urls))'
}
URLS="$(urls_of)"
ENV_VARS="^@^CMA_DB_INSTANCE=${INSTANCE}@CMA_DB_USER=${DB_USER}@CMA_DB_NAME=cma@CMA_DB_POOL_MAX=5@INGEST_VERSION=${SHA}@INGEST_PROJECT=${PROJECT}@INGEST_LOG_HEADER_NAMES=${LOG_HEADERS}@INGEST_READBACK_BUDGET_MS=3000@INGEST_PUBLIC_URLS=${URLS}"
gcloud run deploy "$SERVICE" \
  --project="$PROJECT" --region="$REGION" \
  --image="$IMAGE" \
  --service-account="$SA" \
  --no-invoker-iam-check \
  --ingress=all \
  --port=8080 \
  --concurrency=20 \
  --min-instances="$MIN" --max-instances="$MAX" \
  --cpu=1 --memory=512Mi \
  --timeout=30s \
  --set-env-vars="$ENV_VARS" \
  --quiet

# First deploy: the URLs exist only now; set them so signatures verify against the public address
NEW_URLS="$(urls_of)"
if [ "$NEW_URLS" != "$URLS" ]; then
  gcloud run services update "$SERVICE" --project="$PROJECT" --region="$REGION" \
    --update-env-vars="^@^INGEST_PUBLIC_URLS=${NEW_URLS}" --quiet
fi
URL="$(gcloud run services describe "$SERVICE" --project="$PROJECT" --region="$REGION" --format='value(status.url)')"

echo
echo "== Studio (${INSTANCE_NAME}), once per database: the service's database user joins cma_app"
echo "grant cma_app to \"${DB_USER}\";"
echo
echo "== ${SERVICE} ${SHA} at ${URL}"
echo "public URLs (signed by HubSpot): ${NEW_URLS}"
echo "health: $(curl -s --max-time 20 "${URL}/health" || echo 'no answer yet')"
echo "webhook address per connection: ${URL}/hubspot/<connection key>"
echo "logs: gcloud run services logs read ${SERVICE} --project=${PROJECT} --region=${REGION} --limit=30"
