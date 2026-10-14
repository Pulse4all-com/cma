#!/bin/bash
# The signed-out page outside IAP (README Authentication and Infrastructure; Decision log, 15 October 2026).
#
#   bash docs/signed-out/deploy.sh <dev|prod> --logo <path> --name <display name> [--host <workspace host>] [--apply]
#
#   --logo <path>    the logo shown on the page: a PNG, WebP or JPEG (no SVG: the bucket is served on the
#                    Workspace's own host, so nothing that can carry a script goes in it), for example
#                    web/public/brand/logo-blue.png; uploaded as signed-out/<file name>
#   --name <name>    the display name in the page's title and the logo's alt text, for example the
#                    organisation's display name; written into the page at upload, never in the repository
#   --host <host>    prod only: the Workspace's host; default the domain of the certificate cma-web-cert
#   --apply          make the changes. Without it the script is a dry run: it reads (describe, list,
#                    export, the org policy, url-maps validate), renders the page into a local folder and
#                    prints every command that would change something; it changes nothing in Google Cloud
#
# Runs from Cloud Shell in ~/cma under your own account. Rerunnable: every step skips or updates what exists.
#   a. org policy: when storage.publicAccessPrevention is enforced for the project, stop before anything is
#      created (a public bucket is impossible there; nothing else is changed)
#   b. bucket <project>-signed-out in europe-west4, uniform bucket-level access, public access prevention
#      inherited, public read (allUsers objectViewer) on this bucket only
#   c. the page rendered from web/signed-out/index.html (name and logo written in, HTML-escaped; the inline
#      script's hash checked against the page's CSP) and uploaded as the object signed-out, with the logo and
#      web/src/fonts/Montserrat-VF.ttf under signed-out/; Cache-Control "public, max-age=300"; then the
#      bucket must hold exactly these three objects
#   prod only (dev has no load balancer and no IAP: there it stops after c and says so):
#   d. backend bucket cma-signed-out-backend on the bucket, Cloud CDN off, with response headers: the page's
#      Content-Security-Policy plus frame-ancestors 'none', X-Content-Type-Options nosniff, Referrer-Policy
#      no-referrer
#   e. URL map cma-web-urlmap, planned before step b (read only, so a map the script does not expect stops it
#      before anything is created) and imported after d: exported first to a timestamped file (the restore
#      command is printed); for the
#      Workspace's host two route rules, the default service and every other host rule (cma-ingest) kept as
#      they are:
#        priority 1  prefix /signed-out with query gcp-iap-mode=CLEAR_LOGIN_COOKIE -> cma-web-backend (IAP
#                    clears its cookie and redirects to /signed-out)
#        priority 2  prefix /signed-out -> cma-signed-out-backend
#      Without a host rule for the Workspace's host (it is served by the map's default service) a path
#      matcher cma-web is added for it, with cma-web-backend as its default. A path matcher with pathRules
#      is converted to routeRules with the same matching (an exact path to fullPathMatch, a path ending in
#      /* to prefixMatch, longer paths first). The new map must differ from the export only there (anything
#      else stops the script), passes `gcloud compute url-maps validate` with tests for every existing path,
#      the default and the new route (once the backend bucket exists; in a dry run before d it says so), and
#      only then is imported
#   f. prints what to check (docs/signed-out/README.md, test plan a to e)
set -euo pipefail

usage () {
  echo "usage: bash docs/signed-out/deploy.sh <dev|prod> --logo <path> --name <display name> [--host <workspace host>] [--apply]"
  echo "       the static signed-out page outside IAP: bucket, upload and, in prod, the load balancer's route (header of this file)"
}
[ $# -gt 0 ] || { usage; exit 1; }

ENV="$1"; shift
LOGO=""; NAME=""; HOST=""; APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --logo) LOGO="${2:?--logo needs a file}"; shift 2 ;;
    --name) NAME="${2:?--name needs a display name}"; shift 2 ;;
    --host) HOST="${2:?--host needs a host name}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    *) echo "unknown argument $1"; usage; exit 2 ;;
  esac
done
case "$ENV" in
  prod) PROJECT=p4a-cma-prod ;;
  dev) PROJECT=p4a-cma-dev ;;
  *) echo "first argument is dev or prod"; usage; exit 2 ;;
esac
[ -n "$LOGO" ] && [ -n "$NAME" ] || { echo "--logo and --name are required"; usage; exit 2; }
[ -f "$LOGO" ] || { echo "--logo $LOGO is not a file"; exit 2; }
LOGO_FILE="$(basename "$LOGO")"
[[ "$LOGO_FILE" =~ ^[A-Za-z0-9._-]{1,80}\.(png|webp|jpg|jpeg)$ ]] || { echo "--logo must be a .png, .webp or .jpg file with a plain name (letters, digits, . _ -)"; exit 2; }
[ "${#NAME}" -le 80 ] || { echo "--name is at most 80 characters"; exit 2; }
[ -z "$HOST" ] || [[ "$HOST" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || { echo "--host $HOST is not a host name"; exit 2; }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PAGE_SRC="${ROOT}/web/signed-out/index.html"
FONT_SRC="${ROOT}/web/src/fonts/Montserrat-VF.ttf"
[ -f "$PAGE_SRC" ] && [ -f "$FONT_SRC" ] || { echo "run from a checkout of the repository: ${PAGE_SRC} or ${FONT_SRC} is missing"; exit 2; }

REGION=europe-west4
BUCKET="${PROJECT}-signed-out"
BACKEND_BUCKET=cma-signed-out-backend
WEB_BACKEND=cma-web-backend
WEB_CERT=cma-web-cert
URLMAP=cma-web-urlmap
MATCHER=cma-web
CACHE="public, max-age=300"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="${HOME}/signed-out-${ENV}-${STAMP}"
mkdir -p "$WORK"

# A change: printed always, run only with --apply
change () {
  printf '+'; for a in "$@"; do case "$a" in *[\ \'\"\;\*\(\)]*) printf ' "%s"' "$a" ;; *) printf ' %s' "$a" ;; esac; done; printf '\n'
  if [ "$APPLY" = 1 ]; then "$@"; fi
}

echo "== signed-out page, ${ENV} (${PROJECT}); $([ "$APPLY" = 1 ] && echo "applying" || echo "dry run: nothing in Google Cloud is changed")"
echo "   local files in ${WORK}"

# a. Public access prevention: a public bucket must be possible before anything is created
pap="$(gcloud org-policies describe storage.publicAccessPrevention --effective --project="$PROJECT" \
        --billing-project=p4a-cma-dev --format='value(spec.rules[0].enforce)' 2>/dev/null || true)"
if [ "${pap,,}" = "true" ]; then
  echo "a. STOP: the organisation policy storage.publicAccessPrevention is enforced for ${PROJECT}, so the bucket cannot be"
  echo "   public. Nothing was created or changed. A folder or project exception is a decision for Martin (README, Open decisions)."
  exit 1
fi
echo "a. storage.publicAccessPrevention is not enforced for ${PROJECT} (effective policy: ${pap:-not set})"

# e (planned first, read only). The URL map: export (the restore point) and compute the change locally, so a
# map this script does not expect stops it before anything is created
if [ "$ENV" = prod ]; then
  if [ -z "$HOST" ]; then
    HOST="$(gcloud compute ssl-certificates describe "$WEB_CERT" --project="$PROJECT" --global --format='value(managed.domains)' | tr ';' '\n' | head -1)"
    [ -n "$HOST" ] || { echo "e. STOP: cannot read the Workspace's host from ${WEB_CERT}; pass --host"; exit 1; }
  fi
  SCHEME="$(gcloud compute backend-services describe "$WEB_BACKEND" --project="$PROJECT" --global --format='value(loadBalancingScheme)')"
  [ -n "$SCHEME" ] || { echo "e. STOP: cannot read ${WEB_BACKEND}'s load-balancing scheme"; exit 1; }
  WEB_LINK="$(gcloud compute backend-services describe "$WEB_BACKEND" --project="$PROJECT" --global --format='value(selfLink)')"
  BUCKET_LINK="https://www.googleapis.com/compute/v1/projects/${PROJECT}/global/backendBuckets/${BACKEND_BUCKET}"
  EXPORT="${HOME}/cma-web-urlmap-${STAMP}.yaml"
  gcloud compute url-maps export "$URLMAP" --project="$PROJECT" --global --destination="$EXPORT" --quiet
  gcloud compute url-maps describe "$URLMAP" --project="$PROJECT" --global --format=json > "${WORK}/urlmap-before.json"
  echo "e. ${URLMAP} exported to ${EXPORT}. To put it back as it was:"
  echo "   gcloud compute url-maps import ${URLMAP} --project=${PROJECT} --global --source=${EXPORT} --quiet"
  python3 "${ROOT}/docs/signed-out/urlmap.py" plan "${WORK}/urlmap-before.json" "$HOST" "$WEB_LINK" "$BUCKET_LINK" \
    "${WORK}/urlmap-new.json" "${WORK}/urlmap-validate.json"
fi

# b. The bucket: EU, uniform access, public read on this bucket only
if gcloud storage buckets describe "gs://${BUCKET}" --project="$PROJECT" --format='value(name)' >/dev/null 2>&1; then
  echo "b. bucket gs://${BUCKET} exists"
  loc="$(gcloud storage buckets describe "gs://${BUCKET}" --project="$PROJECT" --format='value(location)')"
  [ "${loc,,}" = "$REGION" ] || { echo "b. STOP: gs://${BUCKET} is in ${loc}, not ${REGION}"; exit 1; }
else
  change gcloud storage buckets create "gs://${BUCKET}" --project="$PROJECT" --location="$REGION" \
    --uniform-bucket-level-access --public-access-prevention=inherited
fi
if [ "$APPLY" = 1 ] || gcloud storage buckets describe "gs://${BUCKET}" --project="$PROJECT" >/dev/null 2>&1; then
  pap_bucket="$(gcloud storage buckets describe "gs://${BUCKET}" --project="$PROJECT" --format='value(public_access_prevention)' 2>/dev/null || true)"
  if [ "${pap_bucket,,}" = "enforced" ]; then
    echo "b. STOP: public access prevention is enforced on gs://${BUCKET}; nothing else was changed. Martin decides on an exception."
    exit 1
  fi
fi
if gcloud storage buckets get-iam-policy "gs://${BUCKET}" --project="$PROJECT" --format=json 2>/dev/null \
     | grep -q '"allUsers"'; then
  echo "b. allUsers can read gs://${BUCKET}"
else
  change gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" --project="$PROJECT" \
    --member=allUsers --role=roles/storage.objectViewer
fi

# c. The page, rendered locally: the name and the logo written in, HTML-escaped; the script hash checked
python3 - "$PAGE_SRC" "${WORK}/signed-out.html" "$NAME" "$LOGO_FILE" "${WORK}/csp.txt" <<'PY'
import base64, hashlib, html, re, sys
src, out, name, logo, csp_out = sys.argv[1:6]
page = open(src, encoding="utf-8").read()
# the repository's own note at the top is for developers, not for the public page
page = re.sub(r"\A(<!doctype html>\s*)<!--.*?-->\s*", r"\1", page, count=1, flags=re.S | re.I)
for marker in ("{{DISPLAY_NAME}}", "{{LOGO_FILE}}"):
    if marker not in page:
        sys.exit(f"c. STOP: {marker} is missing from the page")
page = page.replace("{{DISPLAY_NAME}}", html.escape(name, quote=True)).replace("{{LOGO_FILE}}", logo)
scripts = re.findall(r"<script>(.*?)</script>", page, re.S)
if len(scripts) != 1:
    sys.exit("c. STOP: the page must hold exactly one inline script")
digest = base64.b64encode(hashlib.sha256(scripts[0].encode("utf-8")).digest()).decode()
csp = re.search(r'http-equiv="Content-Security-Policy" content="([^"]+)"', page)
if not csp or f"'sha256-{digest}'" not in csp.group(1):
    sys.exit(f"c. STOP: the page's CSP does not allow its script (sha256-{digest}); run web/verify/signed-out.mjs")
if "{{" in page:
    sys.exit("c. STOP: a placeholder is left in the page")
open(out, "w", encoding="utf-8").write(page)
open(csp_out, "w").write(csp.group(1))
print(f"c. page rendered: {out} (script sha256-{digest})")
PY
cp "$LOGO" "${WORK}/${LOGO_FILE}"
change gcloud storage cp "${WORK}/signed-out.html" "gs://${BUCKET}/signed-out" \
  --content-type="text/html; charset=utf-8" --cache-control="$CACHE"
change gcloud storage cp "${WORK}/${LOGO_FILE}" "gs://${BUCKET}/signed-out/${LOGO_FILE}" --cache-control="$CACHE"
change gcloud storage cp "$FONT_SRC" "gs://${BUCKET}/signed-out/Montserrat-VF.ttf" \
  --content-type=font/ttf --cache-control="$CACHE"
if [ "$APPLY" = 1 ]; then
  objects="$(gcloud storage ls "gs://${BUCKET}/**" --project="$PROJECT" | sed "s#^gs://${BUCKET}/##" | sort)"
  expected="$(printf '%s\n' signed-out "signed-out/${LOGO_FILE}" signed-out/Montserrat-VF.ttf | sort)"
  if [ "$objects" != "$expected" ]; then
    echo "c. STOP: gs://${BUCKET} must hold only the page and its two brand files; it holds:"
    printf '   %s\n' $objects
    echo "   Remove what does not belong there by hand (it is public), then rerun."
    exit 1
  fi
  echo "c. gs://${BUCKET} holds exactly: $(paste -sd' ' <<<"$objects")"
fi

if [ "$ENV" = dev ]; then
  echo "== dev has no load balancer and no IAP (README, Infrastructure): only the bucket is set up here. The page"
  echo "   can be looked at as https://storage.googleapis.com/${BUCKET}/signed-out (the logo and font load only on"
  echo "   the Workspace's host); the route and the Log out flag exist in prod only."
  exit 0
fi

# d. The backend bucket, with the page's CSP (plus frame-ancestors) as a response header on every object
CSP="$(cat "${WORK}/csp.txt"); frame-ancestors 'none'"
HEADERS=("--custom-response-header=Content-Security-Policy: ${CSP}"
         "--custom-response-header=X-Content-Type-Options: nosniff"
         "--custom-response-header=Referrer-Policy: no-referrer")
if gcloud compute backend-buckets describe "$BACKEND_BUCKET" --project="$PROJECT" >/dev/null 2>&1; then
  bound="$(gcloud compute backend-buckets describe "$BACKEND_BUCKET" --project="$PROJECT" --format='value(bucketName)')"
  [ "$bound" = "$BUCKET" ] || { echo "d. STOP: ${BACKEND_BUCKET} serves ${bound}, not ${BUCKET}"; exit 1; }
  change gcloud compute backend-buckets update "$BACKEND_BUCKET" --project="$PROJECT" --no-enable-cdn "${HEADERS[@]}"
else
  change gcloud compute backend-buckets create "$BACKEND_BUCKET" --project="$PROJECT" --gcs-bucket-name="$BUCKET" \
    --no-enable-cdn "${HEADERS[@]}"
fi

# e. The URL map, as planned above: validated with its tests once the backend bucket exists (validate reads
#    only), then imported
if [ "$APPLY" = 1 ] || gcloud compute backend-buckets describe "$BACKEND_BUCKET" --project="$PROJECT" >/dev/null 2>&1; then
  gcloud compute url-maps validate --project="$PROJECT" --global --load-balancing-scheme="$SCHEME" \
    --source="${WORK}/urlmap-validate.json" --format=json > "${WORK}/urlmap-validate-result.json" \
    || { cat "${WORK}/urlmap-validate-result.json"; echo "e. STOP: the new URL map does not validate; nothing was imported"; exit 1; }
  python3 "${ROOT}/docs/signed-out/urlmap.py" check "${WORK}/urlmap-validate-result.json"
else
  echo "e. validate runs with --apply, once ${BACKEND_BUCKET} exists (the new map names it)"
fi
change gcloud compute url-maps import "$URLMAP" --project="$PROJECT" --global --source="${WORK}/urlmap-new.json" --quiet

# f. What to check next
echo "== $([ "$APPLY" = 1 ] && echo done || echo "dry run done: rerun with --apply to make the changes printed with +")"
echo "   Then the test plan in docs/signed-out/README.md (a to e), in a browser:"
echo "   https://${HOST}/signed-out?gcp-iap-mode=CLEAR_LOGIN_COOKIE should land on https://${HOST}/signed-out, signed out."
echo "   Only after a to e: set _LOGOUT_TARGET=signed-out on the trigger and rebuild (README, Build and deploy)."
echo "   To undo the route: the import command above, then _LOGOUT_TARGET=legacy."
