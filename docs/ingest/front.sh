#!/bin/bash
# The public front of cma-ingest in prod (README Architecture, Ingest API; Decision log, 12 October 2026):
# a host on the existing web load balancer, so the run.app address can refuse everyone.
#
#   bash docs/ingest/front.sh prod --host <host> [--rate-per-minute <n>] [--shopify-rate-per-minute <n>] [--dry-run]
#
#   --host <host>            the public name, for example ingest.pulse4all.app (an A record at IONOS)
#   --rate-per-minute <n>    Cloud Armor's throttle per client IP (default 600); excess answers 429
#   --shopify-rate-per-minute <n>   the throttle per client IP on /shopify/ (default 2400; sixth Gemini
#                            audit, 13 October 2026): a store's renewal run sends its deliveries in bursts
#   --dry-run                prints the Cloud Armor rules and the commands of step c, then stops; no
#                            gcloud call, nothing read or changed
#
# Runs from Cloud Shell in ~/cma under your own account, after `bash docs/ingest/deploy.sh prod --front <host>`
# (the Cloud Run service must exist). Rerunnable: every step skips what exists. In p4a-cma-prod:
#   a. serverless NEG cma-ingest-neg (europe-west4) on the Cloud Run service cma-ingest
#   b. global backend service cma-ingest-backend: the load-balancing scheme of cma-web-backend, no
#      --protocol (gcloud sets HTTP with port name http, which a serverless NEG accepts; --protocol=HTTPS
#      sets port name https, which add-backend refuses: "Port name is not supported for a backend
#      service with Serverless network endpoint groups", 12 October 2026), the NEG as backend, no
#      IAP, logging off (the Cloud Run request log is the one record). No backend timeout is set:
#      Google refuses timeoutSec on a backend with a serverless NEG, and the Cloud Run service's own
#      request timeout (30s, deploy.sh) applies
#   c. Cloud Armor policy cma-ingest-armor, rules by priority (the lowest number is evaluated first, and
#      a request a throttle rule matches stops there): rule 900 throttles request.path.startsWith('/shopify/')
#      per IP (2400 per 60 s, deny-429), rule 1000 every other request per IP (<n> per 60 s, deny-429),
#      the default rule allows; no IP allow-list; attached to cma-ingest-backend. Each rule is created,
#      or updated to these values when it exists
#   d. Google-managed certificate cma-ingest-cert for <host>, added to cma-web-proxy next to the
#      certificates it holds (cma-web-cert); never replacing one
#   e. host rule on cma-web-urlmap: path matcher cma-ingest, default service cma-ingest-backend, host <host>
#   f. prints the IONOS A record, the certificate's status and the checks to run afterwards
set -euo pipefail

usage () {
  echo "usage: bash docs/ingest/front.sh prod --host <host> [--rate-per-minute <n>] [--shopify-rate-per-minute <n>] [--dry-run]"
  echo "       builds cma-ingest's public front on the web load balancer in p4a-cma-prod (header of this file)"
}
[ $# -gt 0 ] || { usage; exit 1; }

ENV="$1"
shift
HOST=""
RATE=600
SHOPIFY_RATE=2400
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:?--host needs a host name}"; shift 2 ;;
    --rate-per-minute) RATE="${2:?--rate-per-minute needs a number}"; shift 2 ;;
    --shopify-rate-per-minute) SHOPIFY_RATE="${2:?--shopify-rate-per-minute needs a number}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
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
[[ "$SHOPIFY_RATE" =~ ^[1-9][0-9]{0,6}$ ]] || { echo "--shopify-rate-per-minute is not a positive number"; exit 2; }

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
# The throttle rules of step c: priority, what the rule matches, requests per 60 s per client IP
SHOPIFY_PRIORITY=900
SHOPIFY_MATCH="--expression=request.path.startsWith('/shopify/')"
ALL_PRIORITY=1000
ALL_MATCH="--src-ip-ranges=*"

throttle_args () {  # <priority> <match flag> <requests per 60 s>: the arguments after the verb
  printf '%s\n' "$1" "--project=${PROJECT}" "--security-policy=${POLICY}" "$2" --action=throttle \
    "--rate-limit-threshold-count=$3" --rate-limit-threshold-interval-sec=60 \
    --conform-action=allow --exceed-action=deny-429 --enforce-on-key=IP
}

if [ "$DRY_RUN" = 1 ]; then
  echo "== dry run: Cloud Armor policy ${POLICY} on ${BACKEND} (${PROJECT}); no gcloud call, nothing read or changed"
  echo "rules by priority, the lowest first; a request a throttle rule matches stops there:"
  printf '  %-8s %-45s %s\n' "$SHOPIFY_PRIORITY" "request.path.startsWith('/shopify/')" "${SHOPIFY_RATE} requests per 60 s per IP, then 429"
  printf '  %-8s %-45s %s\n' "$ALL_PRIORITY" "every other request (source IP ranges *)" "${RATE} requests per 60 s per IP, then 429"
  printf '  %-8s %-45s %s\n' "default" "everything else" "allow"
  echo "step c runs, per rule, create (or update, when the rule exists):"
  for rule in "${SHOPIFY_PRIORITY}|${SHOPIFY_MATCH}|${SHOPIFY_RATE}" "${ALL_PRIORITY}|${ALL_MATCH}|${RATE}"; do
    IFS='|' read -r prio match n <<<"$rule"
    mapfile -t args < <(throttle_args "$prio" "$match" "$n")
    printf 'gcloud compute security-policies rules create'
    for a in "${args[@]}"; do
      case "$a" in *[\'\*\(\)]*) printf ' "%s"' "$a" ;; *) printf ' %s' "$a" ;; esac
    done
    printf ' --quiet\n'
  done
  exit 0
fi

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

# b. The backend service: the web backend's scheme (read, never hardcoded), no --protocol (header, b), no IAP, no logging
SCHEME="$(gcloud compute backend-services describe "$WEB_BACKEND" --project="$PROJECT" --global --format='value(loadBalancingScheme)')"
[ -n "$SCHEME" ] || { echo "cannot read the load-balancing scheme of ${WEB_BACKEND}; stopped"; exit 1; }
if gcloud compute backend-services describe "$BACKEND" --project="$PROJECT" --global >/dev/null 2>&1; then
  echo "b. backend ${BACKEND} exists"
  own="$(gcloud compute backend-services describe "$BACKEND" --project="$PROJECT" --global --format='value(loadBalancingScheme)')"
  [ "$own" = "$SCHEME" ] || { echo "${BACKEND} has scheme ${own}, ${WEB_BACKEND} has ${SCHEME}; one URL map cannot serve both, stopped"; exit 1; }
else
  gcloud compute backend-services create "$BACKEND" --project="$PROJECT" --global \
    --load-balancing-scheme="$SCHEME" --no-enable-logging --quiet
  echo "b. backend ${BACKEND} created (${SCHEME}, logging off)"
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

# c. Cloud Armor: one policy, two throttle rules per client IP (/shopify/ first), the default rule stays allow
if gcloud compute security-policies describe "$POLICY" --project="$PROJECT" >/dev/null 2>&1; then
  echo "c. policy ${POLICY} exists"
else
  gcloud compute security-policies create "$POLICY" --project="$PROJECT" --type=CLOUD_ARMOR \
    --description="cma-ingest: rate limit per client IP (README Decision log, 12 October 2026)" --quiet
  echo "c. policy ${POLICY} created"
fi
throttle_rule () {  # <priority> <match flag> <requests per 60 s> <what it matches>: created, or updated when it exists
  local verb=create args
  gcloud compute security-policies rules describe "$1" --project="$PROJECT" --security-policy="$POLICY" >/dev/null 2>&1 && verb=update
  mapfile -t args < <(throttle_args "$1" "$2" "$3")
  gcloud compute security-policies rules "$verb" "${args[@]}" --quiet >/dev/null
  echo "c. rule $1 (${verb}): $4, $3 requests per 60 s per IP, then 429"
}
throttle_rule "$SHOPIFY_PRIORITY" "$SHOPIFY_MATCH" "$SHOPIFY_RATE" "/shopify/"
throttle_rule "$ALL_PRIORITY" "$ALL_MATCH" "$RATE" "every other request"
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
printf '%s %s      # %s\n' "$CHECK" "${RUN_URL}/health" "expected 404 (refused) once deploy.sh ran with --front"
