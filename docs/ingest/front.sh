#!/bin/bash
# The public front of cma-ingest in prod (README Architecture, Ingest API; Decision log, 12 October 2026):
# a host on the existing web load balancer, so the run.app address can refuse everyone.
#
#   bash docs/ingest/front.sh prod --host <host> [--rate-per-minute <n>]
#
#   --host <host>            the public name, for example ingest.pulse4all.app (an A record at IONOS)
#   --rate-per-minute <n>    Cloud Armor's throttle per client IP (default 600); excess answers 429
#
# Runs from Cloud Shell in ~/cma under your own account, after `bash docs/ingest/deploy.sh prod --front <host>`
# (the Cloud Run service must exist). Rerunnable: every step skips what exists. In p4a-cma-prod:
#   a. serverless NEG cma-ingest-neg (europe-west4) on the Cloud Run service cma-ingest
#   b. global backend service cma-ingest-backend: the load-balancing scheme of cma-web-backend, HTTPS,
#      the NEG as backend, no IAP, logging off (the Cloud Run request log is the one record). No
#      backend timeout is set: Google refuses timeoutSec on a backend with a serverless NEG, and the
#      Cloud Run service's own request timeout (30s, deploy.sh) applies
#   c. Cloud Armor policy cma-ingest-armor: rule 1000 throttles per IP (<n> per 60 s, deny-429), the
#      default rule allows; no IP allow-list; attached to cma-ingest-backend
#   d. Google-managed certificate cma-ingest-cert for <host>, added to cma-web-proxy next to the
#      certificates it holds (cma-web-cert); never replacing one
#   e. host rule on cma-web-urlmap: path matcher cma-ingest, default service cma-ingest-backend, host <host>
#   f. prints the IONOS A record, the certificate's status and the checks to run afterwards
set -euo pipefail

usage () {
  echo "usage: bash docs/ingest/front.sh prod --host <host> [--rate-per-minute <n>]"
  echo "       builds cma-ingest's public front on the web load balancer in p4a-cma-prod (header of this file)"
}
[ $# -gt 0 ] || { usage; exit 1; }

ENV="$1"
shift
HOST=""
RATE=600
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:?--host needs a host name}"; shift 2 ;;
    --rate-per-minute) RATE="${2:?--rate-per-minute needs a number}"; shift 2 ;;
    *) echo "unknown argument $1"; usage; exit 2 ;;
  esac
done

case "$ENV" in
  prod) PROJECT=p4a-cma-prod ;;
  dev) echo "dev has no load balancer: cma-ingest in dev stays on its run.app address (ingress all)"; exit 2 ;;
  *) echo "first argument is prod"; usage; exit 2 ;;
esac
[ -n "$HOST" ] || { echo "--host is required"; usage; exit 2; }
[[ "$HOST" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || { echo "--host $HOST is not a host name"; exit 2; }
[[ "$RATE" =~ ^[1-9][0-9]{0,6}$ ]] || { echo "--rate-per-minute is not a positive number"; exit 2; }

REGION=europe-west4
SERVICE=cma-ingest
NEG=cma-ingest-neg
BACKEND=cma-ingest-backend
POLICY=cma-ingest-armor
CERT=cma-ingest-cert
MATCHER=cma-ingest
WEB_BACKEND=cma-web-backend
WEB_CERT=cma-web-cert
PROXY=cma-web-proxy
URLMAP=cma-web-urlmap
ADDRESS=cma-web-ip

echo "== front of ${SERVICE} → https://${HOST} (${PROJECT})"

# a. The serverless NEG, on the Cloud Run service that deploy.sh created
if ! gcloud run services describe "$SERVICE" --project="$PROJECT" --region="$REGION" --format='value(metadata.name)' >/dev/null 2>&1; then
  echo "the Cloud Run service ${SERVICE} does not exist in ${PROJECT} yet: run bash docs/ingest/deploy.sh prod --front ${HOST} first, then rerun this"
  exit 1
fi
if gcloud compute network-endpoint-groups describe "$NEG" --project="$PROJECT" --region="$REGION" >/dev/null 2>&1; then
  echo "a. NEG ${NEG} exists"
else
  gcloud compute network-endpoint-groups create "$NEG" --project="$PROJECT" --region="$REGION" \
    --network-endpoint-type=serverless --cloud-run-service="$SERVICE" --quiet
  echo "a. NEG ${NEG} created"
fi

# b. The backend service: the web backend's scheme (read, never hardcoded), HTTPS, no IAP, no logging
SCHEME="$(gcloud compute backend-services describe "$WEB_BACKEND" --project="$PROJECT" --global --format='value(loadBalancingScheme)')"
[ -n "$SCHEME" ] || { echo "cannot read the load-balancing scheme of ${WEB_BACKEND}; stopped"; exit 1; }
if gcloud compute backend-services describe "$BACKEND" --project="$PROJECT" --global >/dev/null 2>&1; then
  echo "b. backend ${BACKEND} exists"
  own="$(gcloud compute backend-services describe "$BACKEND" --project="$PROJECT" --global --format='value(loadBalancingScheme)')"
  [ "$own" = "$SCHEME" ] || { echo "${BACKEND} has scheme ${own}, ${WEB_BACKEND} has ${SCHEME}; one URL map cannot serve both, stopped"; exit 1; }
else
  gcloud compute backend-services create "$BACKEND" --project="$PROJECT" --global \
    --load-balancing-scheme="$SCHEME" --protocol=HTTPS --no-enable-logging --quiet
  echo "b. backend ${BACKEND} created (${SCHEME}, HTTPS, logging off)"
fi
if [ "$(gcloud compute backend-services describe "$BACKEND" --project="$PROJECT" --global --format='value(logConfig.enable)')" = "True" ]; then
  gcloud compute backend-services update "$BACKEND" --project="$PROJECT" --global --no-enable-logging --quiet
  echo "b. logging turned off on ${BACKEND}"
fi
if [ "$(gcloud compute backend-services describe "$BACKEND" --project="$PROJECT" --global --format='value(iap.enabled)')" = "True" ]; then
  echo "${BACKEND} has IAP on; HubSpot cannot sign in through IAP. Turn it off (Decision log, 12 October 2026), then rerun:"
  echo "gcloud compute backend-services update ${BACKEND} --project=${PROJECT} --global --no-iap"
  exit 1
fi
if gcloud compute backend-services describe "$BACKEND" --project="$PROJECT" --global --format='value(backends[].group)' | grep -qE "/networkEndpointGroups/${NEG}(;|$)"; then
  echo "b. ${NEG} is the backend of ${BACKEND}"
else
  gcloud compute backend-services add-backend "$BACKEND" --project="$PROJECT" --global \
    --network-endpoint-group="$NEG" --network-endpoint-group-region="$REGION" --quiet
  echo "b. ${NEG} added to ${BACKEND}"
fi

# c. Cloud Armor: one policy, one throttle rule per client IP, the default rule stays allow
if gcloud compute security-policies describe "$POLICY" --project="$PROJECT" >/dev/null 2>&1; then
  echo "c. policy ${POLICY} exists"
else
  gcloud compute security-policies create "$POLICY" --project="$PROJECT" --type=CLOUD_ARMOR \
    --description="cma-ingest: rate limit per client IP (README Decision log, 12 October 2026)" --quiet
  echo "c. policy ${POLICY} created"
fi
RULE_VERB=create
gcloud compute security-policies rules describe 1000 --project="$PROJECT" --security-policy="$POLICY" >/dev/null 2>&1 && RULE_VERB=update
gcloud compute security-policies rules "$RULE_VERB" 1000 --project="$PROJECT" --security-policy="$POLICY" \
  --src-ip-ranges='*' --action=throttle \
  --rate-limit-threshold-count="$RATE" --rate-limit-threshold-interval-sec=60 \
  --conform-action=allow --exceed-action=deny-429 --enforce-on-key=IP --quiet >/dev/null
echo "c. rule 1000 (${RULE_VERB}): ${RATE} requests per 60 s per IP, then 429"
if gcloud compute backend-services describe "$BACKEND" --project="$PROJECT" --global --format='value(securityPolicy)' | grep -q "/securityPolicies/${POLICY}$"; then
  echo "c. ${POLICY} is attached to ${BACKEND}"
else
  gcloud compute backend-services update "$BACKEND" --project="$PROJECT" --global --security-policy="$POLICY" --quiet
  echo "c. ${POLICY} attached to ${BACKEND}"
fi

# d. The certificate for the host only, next to the proxy's existing certificates
if gcloud compute ssl-certificates describe "$CERT" --project="$PROJECT" --global >/dev/null 2>&1; then
  domains="$(gcloud compute ssl-certificates describe "$CERT" --project="$PROJECT" --global --format='value(managed.domains)')"
  [ "$domains" = "$HOST" ] || { echo "${CERT} exists for ${domains}, not ${HOST}; a managed certificate's domains cannot change: delete it first or use the same host"; exit 1; }
  echo "d. certificate ${CERT} exists for ${HOST}"
else
  gcloud compute ssl-certificates create "$CERT" --project="$PROJECT" --global --domains="$HOST" --quiet
  echo "d. certificate ${CERT} created for ${HOST}"
fi
current="$(gcloud compute target-https-proxies describe "$PROXY" --project="$PROJECT" --global --format='value(sslCertificates)' \
  | tr ';' '\n' | sed 's#.*/##' | grep -v '^$' || true)"
grep -qx "$WEB_CERT" <<<"$current" || { echo "${PROXY} does not hold ${WEB_CERT} (it holds: ${current//$'\n'/, }); stopped before changing it"; exit 1; }
if grep -qx "$CERT" <<<"$current"; then
  echo "d. ${PROXY} holds ${CERT}"
else
  certs="$(paste -sd, <<<"$current"),${CERT}"
  gcloud compute target-https-proxies update "$PROXY" --project="$PROJECT" --global --ssl-certificates="$certs" --quiet
  echo "d. ${PROXY} now holds ${certs}"
fi

# e. The host rule on the web URL map
if gcloud compute url-maps describe "$URLMAP" --project="$PROJECT" --global --format='value(pathMatchers[].name)' | tr ';' '\n' | grep -qx "$MATCHER"; then
  echo "e. path matcher ${MATCHER} exists on ${URLMAP}"
else
  gcloud compute url-maps add-path-matcher "$URLMAP" --project="$PROJECT" --global \
    --path-matcher-name="$MATCHER" --default-service="$BACKEND" --new-hosts="$HOST" --quiet
  echo "e. path matcher ${MATCHER} added to ${URLMAP}: ${HOST} → ${BACKEND}"
fi

# f. What Martin does next
IP="$(gcloud compute addresses describe "$ADDRESS" --project="$PROJECT" --global --format='value(address)')"
STATUS="$(gcloud compute ssl-certificates describe "$CERT" --project="$PROJECT" --global --format='value(managed.status,managed.domainStatus)')"
RUN_URL="$(gcloud run services describe "$SERVICE" --project="$PROJECT" --region="$REGION" --format='value(status.url)')"
echo
echo "== DNS (IONOS for pulse4all.app): one A record, the other records untouched"
echo "A  ${HOST}  →  ${IP}   (the address of ${ADDRESS})"
echo
echo "== certificate ${CERT}: ${STATUS}"
echo "ACTIVE follows the A record, up to an hour; check with:"
echo "gcloud compute ssl-certificates describe ${CERT} --project=${PROJECT} --global --format=\"value(managed.status,managed.domainStatus)\""
echo
echo "== afterwards"
CHECK='curl -sS -o /dev/null -w "%{http_code}\n"'
printf '%s %s      # %s\n' "$CHECK" "https://${HOST}/health" "expected 200"
printf '%s %s      # %s\n' "$CHECK" "${RUN_URL}/health" "expected 403 (refused) once deploy.sh ran with --front"
