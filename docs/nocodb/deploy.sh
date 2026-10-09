#!/bin/bash
# Deploys NocoDB (the read-only table browser over cma_read) as the Cloud Run service cma-nocodb.
#
#   docs/nocodb/deploy.sh dev  [--dry-run]     renders service.template.yaml for p4a-cma-dev
#   docs/nocodb/deploy.sh prod [--dry-run]     the same for p4a-cma-prod
#
# --dry-run prints the rendered YAML and deploys nothing. Otherwise `gcloud run services replace`
# creates or updates the service, then the service URL and the latest ready revision are printed.
# Runs from Cloud Shell under your own account. See docs/nocodb/README.md for the setup order.
set -euo pipefail

usage() { echo "usage: $0 dev|prod [--dry-run]" >&2; exit 2; }

ENV="${1:-}"
DRY_RUN=false
case "${2:-}" in
  "") ;;
  --dry-run) DRY_RUN=true ;;
  *) usage ;;
esac
[ $# -le 2 ] || usage

case "$ENV" in
  dev)  PROJECT=p4a-cma-dev;  PROJECT_NUMBER=420011670185; INSTANCE=cma-dev-pg ;;
  prod) PROJECT=p4a-cma-prod; PROJECT_NUMBER=467777891162; INSTANCE=cma-prod-pg ;;
  *) usage ;;
esac
REGION=europe-west4
SERVICE=cma-nocodb

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENDERED="$(mktemp "${TMPDIR:-/tmp}/cma-nocodb.XXXXXX.yaml")"
trap 'rm -f "$RENDERED"' EXIT

sed \
  -e "s/__PROJECT_NUMBER__/${PROJECT_NUMBER}/g" \
  -e "s/__PROJECT__/${PROJECT}/g" \
  -e "s/__INSTANCE__/${INSTANCE}/g" \
  -e "s/__ENV__/${ENV}/g" \
  "$HERE/service.template.yaml" > "$RENDERED"

if LEFT="$(grep -oE '__[A-Z_]+__' "$RENDERED" | sort -u)"; then
  echo "refusing: placeholders left in the rendered YAML:" >&2
  echo "$LEFT" >&2
  exit 1
fi

if [ "$DRY_RUN" = true ]; then
  cat "$RENDERED"
  exit 0
fi

gcloud run services replace "$RENDERED" --region="$REGION" --project="$PROJECT"

echo "service URL:"
gcloud run services describe "$SERVICE" --region="$REGION" --project="$PROJECT" \
  --format='value(status.url)'
echo "latest ready revision:"
gcloud run services describe "$SERVICE" --region="$REGION" --project="$PROJECT" \
  --format='value(status.latestReadyRevisionName)'
