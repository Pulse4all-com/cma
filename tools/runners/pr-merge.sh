#!/usr/bin/env bash
# tools/runners/pr-merge.sh: Martin's squash-merge of a reviewed pull request, then the prod build it triggers, polled.
#
#   cd ~/cma && bash tools/runners/pr-merge.sh <number> <head commit sha>
#
# Refuses unless the pull request is open and its head is the commit named (gh pr merge --squash --match-head-commit:
# GitHub refuses a head that moved too). A merge that touches cloudbuild.yaml, or web/ outside web/verify/, builds and
# deploys prod (Cloud Build trigger cma-web-main): that build is polled until it ends. Otherwise the runner watches for
# 2 minutes that no build starts. The merge is checked by a read (state MERGED, the merge commit) whatever its exit said.
# Log and records check: records/pr-<number>-merge-<date>/.
source "$(dirname "$0")/lib.sh"
PR="${1:-}"
HEAD_SHA="${2:-}"
[[ "$PR" =~ ^[0-9]+$ ]] && [[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "usage: bash tools/runners/pr-merge.sh <number> <full head commit sha>"; exit 2; }
export PR HEAD_SHA
run_init "pr-${PR}-merge" "pr-${PR}-merge-$(date +%F)"

step "the pull request (read)" 120 rc \
  'timeout 60 gh pr view "$PR" --json number,title,state,headRefName,headRefOid,baseRefName,mergeable,mergeStateStatus \
     --jq "\"#\(.number) \(.title)\n\(.state) \(.headRefName) → \(.baseRefName), head \(.headRefOid), mergeable \(.mergeable), \(.mergeStateStatus)\""' \
  || stop_run "gh cannot read #${PR}"
[ "$(timeout 60 gh pr view "$PR" --json state --jq .state)" = OPEN ] || stop_run "#${PR} is not open"
[ "$(timeout 60 gh pr view "$PR" --json headRefOid --jq .headRefOid)" = "$HEAD_SHA" ] || stop_run "#${PR}'s head is not ${HEAD_SHA}: someone pushed since; look again"

step "the files: does the merge build prod?" 120 rc '
  timeout 60 gh pr diff "$PR" --name-only > "$RUN_TMP/files" || exit 1
  echo "$(wc -l < "$RUN_TMP/files") files"
  grep -E "^(cloudbuild\.yaml|web/)" "$RUN_TMP/files" | grep -vE "^web/verify/" > "$RUN_TMP/building" || true
  if [ -s "$RUN_TMP/building" ]; then echo "builds prod, through:"; head -10 "$RUN_TMP/building"; else echo "no web build: no cloudbuild.yaml, nothing under web/ outside web/verify/"; fi' \
  || stop_run "gh cannot list #${PR}'s files"
BUILD=0; [ -s "$RUN_TMP/building" ] && BUILD=1

step "squash-merge #${PR} at ${HEAD_SHA:0:7}" 180 rc 'gh pr merge "$PR" --squash --match-head-commit "$HEAD_SHA"' \
  || note "the merge's exit is not trusted on its own: the read below decides"
step "merged? (read)" 180 rc '
  for i in $(seq 1 12); do
    s="$(timeout 60 gh pr view "$PR" --json state,mergeCommit --jq "\(.state) \(.mergeCommit.oid // \"\")")"
    echo "$s"
    case "$s" in "MERGED "[0-9a-f]*) echo "${s#MERGED }" > "$RUN_TMP/merge_sha"; exit 0 ;; esac
    sleep 15
  done; exit 1' || stop_run "#${PR} is not merged"
MERGE_SHA="$(cat "$RUN_TMP/merge_sha")"
export MERGE_SHA
note "merge commit ${MERGE_SHA}"

BUILDS='timeout 60 gcloud builds list --project=p4a-cma-prod --region=europe-west4 --filter="substitutions.COMMIT_SHA=$MERGE_SHA" --format="value(id,status)" --limit=1'
export BUILDS
if [ "$BUILD" = 1 ]; then
  step "the cma-web-main build of ${MERGE_SHA:0:7} (polled)" 2700 rc '
    last=""; waited=0
    while true; do
      s="$(eval "$BUILDS" 2>/dev/null | tr "\t" " ")"
      [ "$s" = "$last" ] || { echo "build: ${s:-not started yet}"; last="$s"; }
      case "$s" in
        *" SUCCESS") exit 0 ;;
        *" FAILURE"|*" TIMEOUT"|*" CANCELLED"|*" INTERNAL_ERROR"|*" EXPIRED") exit 1 ;;
        "") waited=$(( waited + 15 )); [ "$waited" -ge 600 ] && { echo "no build after 10 minutes"; exit 1; } ;;
      esac
      sleep 15
    done'
else
  step "no build expected: none starts within 2 minutes (read)" 300 rc '
    for i in $(seq 1 8); do
      s="$(eval "$BUILDS" 2>/dev/null)"
      [ -n "$s" ] && { echo "a build started after all: ${s}"; exit 1; }
      sleep 15
    done; echo "no build for ${MERGE_SHA:0:7}, as expected"'
fi
run_finish
