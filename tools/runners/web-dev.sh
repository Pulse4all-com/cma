#!/usr/bin/env bash
# tools/runners/web-dev.sh: a web merge's image on dev, then the verifiers named (27 November 2026; n07e-dev.sh's frame).
#
#   cd ~/cma && git switch -q main && git pull -q --ff-only && bash tools/runners/web-dev.sh [--sha <short sha>] <verifier>…
#   for example: bash tools/runners/web-dev.sh security csp theme
#
# Each verifier is npm run verify:<name> in web/ against dev through the proxy, gating; layout is reported (info).
# The short sha is Cloud Build's SHORT_SHA of the merge, 7 characters (main's HEAD when none is given). As RUNBOOK 4 and 5:
# the image exists in prod's registry (polled while the build may still run); no "gcloud run services proxy" during the
# write; dev's cma-web onto the image under timeout 300, then a describe decides (the image :sha, the latest created
# revision ready), whatever the update's exit said; only then the proxy, its port waited for up to 120 s; the health
# answer's version; then the verifiers named, in order (layout reported, its known problems compared by hand); the proxy
# stopped at the end, also when the runner stops. Log and records check: records/web-dev-<date>/.
source "$(dirname "$0")/lib.sh"
SHA_ARG=""
if [ "${1:-}" = --sha ]; then SHA_ARG="${2:-}"; shift 2; fi
VERIFIERS=("$@")
[ ${#VERIFIERS[@]} -gt 0 ] || { echo "name the verifiers to run against dev: bash tools/runners/web-dev.sh [--sha <short sha>] security csp …"; exit 2; }
for v in "${VERIFIERS[@]}"; do [[ "$v" =~ ^[a-z-]+$ ]] || { echo "not a verifier name: $v"; exit 2; }; done
run_init web-dev "web-dev-$(date +%F)"

for v in "${VERIFIERS[@]}"; do grep -q "\"verify:${v}\"" web/package.json || stop_run "web/package.json has no verify:${v}: switch to main after the merge"; done
[ -d web/node_modules ] || stop_run "web/node_modules is missing: cd web && npm ci, then rerun"
timeout 60 git fetch -q origin main || stop_run "git fetch origin main did not answer"
SHA="${SHA_ARG:-$(git rev-parse --short=7 origin/main)}"
[[ "$SHA" =~ ^[0-9a-f]{7}$ ]] || stop_run "the short sha is 7 hex characters (Cloud Build's SHORT_SHA), not ${SHA}"
IMAGE="${REGION}-docker.pkg.dev/p4a-cma-prod/cma/web:${SHA}"
PORT=8080
export SHA IMAGE PORT
note "dev's cma-web onto ${IMAGE}"

# the dev proxy this runner started, and no other (a prod proxy in another terminal stays); also on a stop or a closed
# terminal (lib.sh's traps: INT, TERM, HUP)
DEV_PROXY='gcloud(\.py)? run services proxy cma-web --project=p4a-cma-dev'
stop_proxy () {
  if pgrep -f "$DEV_PROXY" >/dev/null; then
    pkill -f "$DEV_PROXY"; sleep 2
    pgrep -f "$DEV_PROXY" >/dev/null && pkill -KILL -f "$DEV_PROXY"
    say "-- the dev proxy is stopped"
  fi
}
RUN_ON_FINISH=stop_proxy

step "the image exists in prod's registry (polled while the build may still run)" 1500 rc '
  for i in $(seq 1 80); do
    d="$(timeout 60 gcloud artifacts docker images describe "$IMAGE" --format="value(image_summary.digest)" 2>/dev/null)"
    [ -n "$d" ] && { echo "$IMAGE $d"; exit 0; }
    echo "not there yet (${i} of 80)"; sleep 15
  done; exit 1' || stop_run "no image ${IMAGE}: is the cma-web-main build of the merge done?"

no_run_proxy
# the write's exit is reported, never gating (a gcloud write can hang or fail after it applied): the describe decides
step "dev: cma-web onto the image (a gcloud write, timeout 300; the describe decides)" 330 info \
  'timeout 300 gcloud run services update cma-web --project=p4a-cma-dev --region="$REGION" --image="$IMAGE"'
step "dev: the image and the revision ready (describe, polled up to 10 minutes)" 660 rc '
  for i in $(seq 1 40); do
    IFS=, read -r img created ready <<<"$(timeout 60 gcloud run services describe cma-web --project=p4a-cma-dev --region="$REGION" \
      --format="csv[no-heading](spec.template.spec.containers[0].image,status.latestCreatedRevisionName,status.latestReadyRevisionName)" 2>/dev/null)"
    echo "image ${img:-?}, created ${created:-?}, ready ${ready:-?}"
    [ "$img" = "$IMAGE" ] && [ -n "$created" ] && [ "$created" = "$ready" ] && exit 0
    sleep 15
  done; exit 1' || stop_run "dev's cma-web is not on ${IMAGE} with its revision ready"

curl -s -m 3 -o /dev/null "localhost:${PORT}" && stop_run "something already answers on port ${PORT}: stop it (a local server?), then rerun"
say ""
say "== $(date +%T)  the proxy on port ${PORT} (it stays up for the verifiers, stopped at the end)"
gcloud run services proxy cma-web --project=p4a-cma-dev --region="$REGION" --port="$PORT" > "$RUN_TMP/proxy.log" 2>&1 &
step "the proxy's port (up to 120 s)" 130 rc '
  for i in $(seq 1 120); do
    curl -s -m 5 -o /dev/null "localhost:${PORT}" && { echo "proxy listening after ${i} s"; exit 0; }
    sleep 1
  done; tail -5 "$RUN_TMP/proxy.log"; exit 1' || stop_run "the proxy did not listen within 120 s"
step "health: the version is the sha, mock sign-in" 60 rc '
  h="$(timeout 20 curl -s "localhost:${PORT}/api/health")"; echo "$h"
  [ "$(node -e "const h=JSON.parse(process.argv[1]); console.log(h.version + \" \" + h.auth)" "$h")" = "${SHA} mock" ]' \
  || stop_run "dev does not answer with version ${SHA}"

for v in "${VERIFIERS[@]}"; do
  if [ "$v" = layout ]; then
    step "verify:layout against dev (reported; compare its problems with main's; about 8 min)" 2400 info 'cd web && BASE="http://localhost:${PORT}" npm run -s verify:layout'
  else
    export V="$v"
    step "verify:${v} against dev (about 1 to 3 min)" 1500 rc 'cd web && BASE="http://localhost:${PORT}" npm run -s "verify:${V}"'
  fi
done
run_finish
