#!/bin/bash
# The alert on Cloud Armor's 429s for cma-ingest (README Decision log, 13 October 2026: fifth Gemini audit
# FIND-02, sixth audit FIND-01). Cloud Armor answers a throttled request at the load balancer, so it never
# reaches the Cloud Run request log, and the backend's own logging is off (front.sh); the load balancer's
# request count is the one place a 429 shows. One alert policy per project:
#
#   bash docs/ingest/alert.sh prod|dev --email <address> [--dry-run]
#
#   --email <address>   where the alert goes: an email notification channel with that address, created
#                       when the project has none (display name "CMA ingest alerts")
#   --dry-run           prints the policy, then stops; no gcloud call, nothing read or changed
#
# The policy "cma-ingest 429": metric loadbalancing.googleapis.com/https/request_count (resource
# https_lb_rule), filtered to backend_target_name = cma-ingest-backend and response_code = 429, summed
# over 5 minutes (ALIGN_SUM, 300 s, all series together), firing when that sum is above 0; the incident
# closes itself when no 429 has been counted for 30 minutes. Idempotent: an existing policy with that
# display name is updated (replaced by this one, the channel included), never duplicated; two or more
# with that name stop the script.
#
# gcloud surface (Cloud SDK 570.0.0, 13 October 2026): `gcloud monitoring policies` is GA (create,
# update, list); notification channels exist only in beta and alpha, so the channel steps use
# `gcloud beta monitoring channels` (Cloud Shell has the beta component). The policy is passed as JSON
# with --policy, because update's flags cannot replace a condition; no policy file is kept.
#
# Dev has no load balancer (cma-ingest keeps its run.app address there), so the policy finds no series
# and stays quiet in dev; it exists there to try the script. Runs from Cloud Shell in ~/cma under your
# own account. Rerunnable.
set -euo pipefail

usage () {
  echo "usage: bash docs/ingest/alert.sh prod|dev --email <address> [--dry-run]"
  echo "       the alert policy \"cma-ingest 429\" on the ingest backend's 429s (header of this file)"
}
[ $# -gt 0 ] || { usage; exit 1; }

ENV="$1"
shift
EMAIL=""
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --email) EMAIL="${2:?--email needs an address}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "unknown argument $1"; usage; exit 2 ;;
  esac
done

case "$ENV" in
  prod) PROJECT=p4a-cma-prod ;;
  dev) PROJECT=p4a-cma-dev ;;
  *) echo "first argument is prod or dev"; usage; exit 2 ;;
esac
[ -n "$EMAIL" ] || { echo "--email is required"; usage; exit 2; }
[[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || { echo "--email $EMAIL is not an email address"; exit 2; }

POLICY_NAME="cma-ingest 429"
BACKEND=cma-ingest-backend
CHANNEL_NAME="CMA ingest alerts"
WINDOW=300s
AUTO_CLOSE=1800s
FILTER="resource.type = \"https_lb_rule\" AND metric.type = \"loadbalancing.googleapis.com/https/request_count\" AND resource.labels.backend_target_name = \"${BACKEND}\" AND metric.labels.response_code = 429"
FILTER_JSON="${FILTER//\"/\\\"}"   # the filter as a JSON string's content: every " escaped

policy_json () {  # <notification channel name>: the whole policy, as create and update take it
  cat <<JSON
{
  "displayName": "${POLICY_NAME}",
  "documentation": {
    "mimeType": "text/markdown",
    "content": "Cloud Armor answered 429 to requests for cma-ingest (backend ${BACKEND}, policy cma-ingest-armor) in the last 5 minutes: a client went over its rate limit (rule 900: 2,400 per minute per IP on /shopify/; rule 1000: 600 per minute per IP otherwise). These requests never reach the Cloud Run request log. Check whether a source retries (HubSpot, Aircall and Shopify retry with backoff) or someone floods the endpoint; the limits are set by docs/ingest/front.sh (README Decision log, 13 October 2026)."
  },
  "combiner": "OR",
  "conditions": [
    {
      "displayName": "429 from the load balancer for ${BACKEND}, summed over 5 minutes, above 0",
      "conditionThreshold": {
        "filter": "${FILTER_JSON}",
        "aggregations": [
          {
            "alignmentPeriod": "${WINDOW}",
            "perSeriesAligner": "ALIGN_SUM",
            "crossSeriesReducer": "REDUCE_SUM"
          }
        ],
        "comparison": "COMPARISON_GT",
        "thresholdValue": 0,
        "duration": "0s",
        "trigger": { "count": 1 },
        "evaluationMissingData": "EVALUATION_MISSING_DATA_INACTIVE"
      }
    }
  ],
  "alertStrategy": { "autoClose": "${AUTO_CLOSE}" },
  "notificationChannels": [ "$1" ],
  "userLabels": { "service": "cma-ingest" },
  "enabled": true
}
JSON
}

if [ "$DRY_RUN" = 1 ]; then
  echo "== dry run: alert policy \"${POLICY_NAME}\" in ${PROJECT}; no gcloud call, nothing read or changed"
  echo "a real run finds or creates the email channel \"${CHANNEL_NAME}\" for ${EMAIL}, then creates the policy, or updates the one with this name"
  policy_json "projects/${PROJECT}/notificationChannels/<the email channel for ${EMAIL}>"
  exit 0
fi

echo "== alert policy \"${POLICY_NAME}\" → ${PROJECT}"
[ "$ENV" = prod ] || echo "note: dev has no load balancer; the policy finds no series there and stays quiet"
gcloud services enable monitoring.googleapis.com --project="$PROJECT" --quiet

# a. The email channel: an existing one with this address, else a new one
if ! channels="$(gcloud beta monitoring channels list --project="$PROJECT" \
    --filter="type=\"email\" AND labels.email_address=\"${EMAIL}\"" --format='value(name)' </dev/null)"; then
  echo "cannot list notification channels with gcloud beta (Cloud Shell has the beta component; elsewhere: gcloud components install beta); stopped"
  exit 1
fi
CHANNEL="$(head -n1 <<<"$channels")"
if [ -n "$CHANNEL" ]; then
  echo "a. email channel exists: ${CHANNEL}"
else
  CHANNEL="$(gcloud beta monitoring channels create --project="$PROJECT" --type=email \
    --display-name="$CHANNEL_NAME" --channel-labels="email_address=${EMAIL}" --format='value(name)' --quiet </dev/null)"
  [ -n "$CHANNEL" ] || { echo "the channel was not created; stopped"; exit 1; }
  echo "a. email channel created: ${CHANNEL}"
fi

# b. The policy: updated when one with this display name exists, else created
existing="$(gcloud monitoring policies list --project="$PROJECT" --filter="displayName=\"${POLICY_NAME}\"" --format='value(name)')"
count="$(grep -c . <<<"$existing" || true)"
POLICY="$(policy_json "$CHANNEL")"
if [ "$count" -gt 1 ]; then
  echo "${count} policies are named \"${POLICY_NAME}\" in ${PROJECT}:"; echo "$existing"
  echo "delete all but one (gcloud monitoring policies delete <name> --project=${PROJECT}), then rerun; stopped"
  exit 1
elif [ "$count" = 1 ]; then
  gcloud monitoring policies update "$existing" --project="$PROJECT" --policy="$POLICY" --quiet >/dev/null
  echo "b. policy updated: ${existing}"
  NAME="$existing"
else
  NAME="$(gcloud monitoring policies create --project="$PROJECT" --policy="$POLICY" --format='value(name)' --quiet)"
  echo "b. policy created: ${NAME}"
fi

# c. What it holds now
echo
echo "== check"
gcloud monitoring policies describe "$NAME" --project="$PROJECT" \
  --format='value(displayName,enabled,conditions[0].conditionThreshold.filter,conditions[0].conditionThreshold.aggregations[0].alignmentPeriod,notificationChannels)'
echo "expected: ${POLICY_NAME}, True, the filter on ${BACKEND} and response_code = 429, ${WINDOW}, ${CHANNEL}"
