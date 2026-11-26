# shellcheck shell=bash
# tools/runners/lib.sh: the frame of the Terminal runners (night N07, 25 November 2026). Sourced by a runner, never run.
#
# Per step: a header "== HH:MM:SS  label", the output live on screen and in the log, "… still running, n s" every 15 s,
# then "done in n s" and one line with the exit code and the verdict. Every step has a timeout (exit 124 when it fires;
# the step is then killed, its remote work may still finish: a runner checks a gcloud write with a read afterwards). A
# runner ends with run_finish: a SUMMARY block and tools/check-records.mjs on its records folder. The operator's login
# (gcloud's account) is written as <operator> on screen and in the log, in any case and URL-encoded.
#
# Environment facts (Martin, 25 November 2026): the database through the cma_db helper (~/.cma_helpers.sh, RUNBOOK
# Setup 8: cloud-sql-proxy, PGCONN); his IAM login needs "set role cma_owner;" for a query on schema cma outside the db/
# scripts (psql_cma and psql_val below do it, with "reset role;"); a gcloud write can hang for minutes after the change is
# applied, and hangs while "gcloud run services proxy" runs (no_run_proxy stops one first).

set -o pipefail
HEARTBEAT_S=${HEARTBEAT_S:-15}
OPERATOR="$(gcloud config get-value account 2>/dev/null)"
export OPERATOR
export PGCONNECT_TIMEOUT=${PGCONNECT_TIMEOUT:-20}
RUN_SUMMARY=()
RUN_FAILED=0
RUN_T0=$(date +%s)

# stdin to stdout, line by line, unbuffered: the operator's login as <operator>
mask () {
  perl -pe 'BEGIN { $| = 1; $l = lc($ENV{OPERATOR} // ""); ($e = $l) =~ s/\@/%40/; }
            if ($l ne "") { s/\Q$l\E/<operator>/gi; s/\Q$e\E/<operator>/gi; }'
}

say () { printf '%s\n' "$*" | mask | tee -a "$RUN_LOG"; }

# run_init <runner name> <records folder under records/>
run_init () {
  cd "$(git rev-parse --show-toplevel)" || exit 2
  [ -n "$OPERATOR" ] || { echo "no gcloud account: gcloud auth login first"; exit 2; }
  RUN_NAME=$1
  RUN_REC="records/$2"
  mkdir -p "$RUN_REC"
  RUN_LOG="$RUN_REC/$1.log"
  RUN_TMP="$(mktemp -d)"
  export RUN_TMP
  trap 'stop_run "interrupted"' INT TERM HUP
  say ""
  say "== $(date +%T)  $RUN_NAME on $(git rev-parse --abbrev-ref HEAD) $(git rev-parse --short=7 HEAD), log $RUN_LOG"
}

# The verdict of a step's output: "OK …" or "FAIL …"
#   rc        exit 0
#   commit    a migration: exit 0 and COMMIT (with its last "INSERT 0 n", the schema_migration row)
#   verify    a verify: exit 0 and a verdict row that says PASS or verified, no failure count, not PROVOKED
#   provoked  a provoked verify: the verdict row says PROVOKED and counts no passing check (0 OK / 0 PASS)
#   refused   a dev-only verify in prod: the script refused the database (REFUSED: …)
#   info      reported, never gating: OK with the output's last line (a verifier whose known problems are compared by hand)
verdict_of () {
  local check=$1 f=$2 rc=$3 row
  row="$(grep -E '^[[:space:]]*verdict[[:space:]]*\|' "$f" | tail -1 | tr -s ' ' | sed 's/^ //')"
  case "$check" in
    rc)       if [ "$rc" = 0 ]; then echo "OK"; else echo "FAIL"; fi ;;
    commit)   if [ "$rc" = 0 ] && grep -qx 'COMMIT' "$f"; then echo "OK $(grep -E '^INSERT 0 [0-9]+$' "$f" | tail -1), COMMIT"; else echo "FAIL no COMMIT"; fi ;;
    verify)   if [ "$rc" = 0 ] && grep -qE 'PASS|verified' <<<"$row" && ! grep -qE '\| FAIL( |$)|(^|[^0-9])[1-9][0-9]* FAIL|PROVOKED' <<<"$row"; then
                echo "OK $row"; else echo "FAIL ${row:-no verdict row}"; fi ;;
    provoked) if grep -q 'PROVOKED' <<<"$row" && ! grep -qE '(^|[^0-9])[1-9][0-9]* (OK|PASS|ok)' <<<"$row"; then
                echo "OK $row"; else echo "FAIL not provoked, or a check passed: ${row:-no verdict row}"; fi ;;
    refused)  if grep -q 'REFUSED: ' "$f"; then echo "OK refused, as expected: $(grep -o 'REFUSED: [^"]*' "$f" | head -1 | cut -c1-90)"; else echo "FAIL no refusal"; fi ;;
    info)     echo "OK info, exit ${rc}: $(grep -v '^[[:space:]]*$' "$f" | tail -1 | tr -s ' ' | cut -c1-120)" ;;
    *)        echo "FAIL unknown check $check" ;;
  esac
}

# step <label> <timeout s> <check> <command>: returns 0 when the verdict is OK. The command runs in bash -c with pipefail
# (a pipe fails when any part fails), so it sees the exported variables and functions only (PGCONN, RUN_TMP, OPERATOR,
# psql_file, psql_cma, psql_val, …). Its timeout process is kept in STEP_PID_FILE: an interrupt ends the step first
# (end_step), so nothing keeps running behind the summary; a migration ended mid-way rolls back (one transaction)
step () {
  local label=$1 limit=$2 check=$3 cmd=$4
  local n=$(( ${#RUN_SUMMARY[@]} + 1 ))
  local out="$RUN_TMP/$n.out" rcf="$RUN_TMP/$n.rc" t0 el next pid rc verdict
  say ""
  say "== $(date +%T)  $label"
  t0=$(date +%s)
  next=$HEARTBEAT_S
  STEP_PID_FILE="$RUN_TMP/$n.pid"
  STEP_LABEL="$label"
  ( timeout -k 20 "$limit" bash -c "set -o pipefail; $cmd" </dev/null & echo $! > "$STEP_PID_FILE"; wait $!; echo $? > "$rcf" ) 2>&1 \
    | mask | tee -a "$RUN_LOG" "$out" &
  pid=$!
  STEP_PIPE_PID=$pid
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    el=$(( $(date +%s) - t0 ))
    if [ "$el" -ge "$next" ] && kill -0 "$pid" 2>/dev/null; then
      say "… still running, ${el} s"
      next=$(( next + HEARTBEAT_S ))
    fi
  done
  wait "$pid"
  STEP_PID_FILE=""
  STEP_PIPE_PID=""
  el=$(( $(date +%s) - t0 ))
  rc="$(cat "$rcf" 2>/dev/null || echo 255)"
  verdict="$(verdict_of "$check" "$out" "$rc")"
  say "done in ${el} s"
  say "-- ${label}: exit ${rc}$([ "$rc" = 124 ] && echo ' (timeout)'), ${verdict}"
  local detail=""
  [ "$verdict" = "${verdict%% *}" ] || detail="${verdict#* }"
  RUN_SUMMARY+=("$(printf '%-4s %-62s exit %-3s %5s s  %s' "${verdict%% *}" "$label" "$rc" "$el" "$detail" | cut -c1-230)")
  if [ "${verdict%% *}" = OK ]; then return 0; fi
  RUN_FAILED=1
  return 1
}

# A note in the summary without a command (a branch the runner took)
note () { say "-- $*"; RUN_SUMMARY+=("$(printf '%-4s %s' NOTE "$*" | cut -c1-230)"); }

run_finish () {
  local el=$(( $(date +%s) - RUN_T0 )) rc
  trap - INT TERM HUP
  # a runner's own cleanup (RUN_ON_FINISH, a function name: the dev proxy), also when it stopped
  if [ -n "${RUN_ON_FINISH:-}" ]; then "$RUN_ON_FINISH"; fi
  say ""
  say "== $(date +%T)  SUMMARY ${RUN_NAME} (${el} s)"
  local l
  for l in "${RUN_SUMMARY[@]}"; do say "$l"; done
  say ""
  say "== $(date +%T)  records check: ${RUN_REC}"
  node tools/check-records.mjs --login "$OPERATOR" "$RUN_REC" 2>&1 | mask | tee -a "$RUN_LOG"
  rc=${PIPESTATUS[0]}
  if [ "$RUN_FAILED" = 0 ] && [ "$rc" = 0 ]; then say "RESULT ${RUN_NAME}: OK"; else say "RESULT ${RUN_NAME}: FAIL (records check exit ${rc}; see the lines marked FAIL)"; fi
  rm -rf "$RUN_TMP"
  [ "$RUN_FAILED" = 0 ] && [ "$rc" = 0 ]
}

# end_step: a step still running (an interrupt) gets TERM through its timeout, which passes it on to the command, and is
# waited for (30 s, then KILL), so its output lands before the summary and nothing runs on unseen
end_step () {
  local tpid i
  [ -n "${STEP_PID_FILE:-}" ] && [ -s "$STEP_PID_FILE" ] || return 0
  tpid="$(cat "$STEP_PID_FILE")"
  kill -0 "$tpid" 2>/dev/null || return 0
  say "… ending the running step (TERM to its process ${tpid})"
  kill -TERM "$tpid" 2>/dev/null
  for i in $(seq 1 30); do kill -0 "$tpid" 2>/dev/null || break; sleep 1; done
  kill -0 "$tpid" 2>/dev/null && { kill -KILL "$tpid" 2>/dev/null; pkill -KILL -P "$tpid" 2>/dev/null; say "… killed it after 30 s"; }
  [ -n "${STEP_PIPE_PID:-}" ] && wait "$STEP_PIPE_PID" 2>/dev/null
  RUN_SUMMARY+=("$(printf '%-4s %-62s ended by the interrupt' FAIL "${STEP_LABEL:-a step}" | cut -c1-230)")
  STEP_PID_FILE=""
}

stop_run () { trap - INT TERM HUP; end_step; say ""; say "== $(date +%T)  STOPPED: $*"; RUN_FAILED=1; run_finish; exit 1; }

# The database ------------------------------------------------------------------------------------------------------

psql_file () { psql "$PGCONN" -X -v ON_ERROR_STOP=1 -f "$1"; }
psql_cma () { psql "$PGCONN" -X -q -v ON_ERROR_STOP=1 -c "set role cma_owner;" -c "$1" -c "reset role;"; }
# psql_val: one value or a few lines, unaligned; the client's timeout PSQL_TIMEOUT (60 s) and the same less 5 s on the
# server, so a read the client gave up on does not keep running in the database
psql_val () {
  local t="${PSQL_TIMEOUT:-60}"
  timeout "$t" psql "$PGCONN" -X -q -At -v ON_ERROR_STOP=1 -c "set statement_timeout = '$(( t > 10 ? t - 5 : t ))s';" \
    -c "set role cma_owner;" -c "$1" -c "reset role;" </dev/null
}
export -f psql_file psql_cma psql_val

# db_connect dev|prod: cma_db in this shell (PGCONN stays set), up to five tries while the proxy comes up, then the
# guard: dev holds the dev seed's active agent.two@example.com, prod never does (as 77 and 107 decide it)
db_connect () {
  local env=$1 i rc=1 seed want
  [ "$(type -t cma_db)" = function ] || . ~/.cma_helpers.sh
  say ""
  say "== $(date +%T)  connect to ${env} (cma_db)"
  for i in 1 2 3 4 5; do
    cma_db "$env" > "$RUN_TMP/connect.out" 2>&1 && grep -q '^connected to ' "$RUN_TMP/connect.out" && { rc=0; break; }
    say "… the proxy is not answering yet (try ${i} of 5)"
    sleep 6
  done
  mask < "$RUN_TMP/connect.out" | tee -a "$RUN_LOG"
  [ "$rc" = 0 ] || stop_run "no connection to ${env}"
  export PGCONN
  case "$env" in
    dev)  [[ "$PGCONN" == *"port=5433"* ]] || stop_run "PGCONN is not dev's proxy port (5433)"; want=t ;;
    prod) [[ "$PGCONN" == *"port=5434"* ]] || stop_run "PGCONN is not prod's proxy port (5434)"; want=f ;;
  esac
  pgrep -f "cloud-sql-proxy.*cma-${env}-pg" >/dev/null || stop_run "no cloud-sql-proxy for cma-${env}-pg is running"
  seed="$(psql_val "select exists (select 1 from cma.app_user u join cma.tenant t on t.id = u.tenant_id where u.email = 'agent.two@example.com' and u.status = 'active')")"
  [ "$seed" = "$want" ] || stop_run "the database does not look like ${env} (dev seed present: ${seed:-unknown})"
  note "connected to ${env}; dev seed present: ${seed}"
}

# Google Cloud ------------------------------------------------------------------------------------------------------

REGION=europe-west4
export REGION

# A gcloud write hangs while "gcloud run services proxy" runs: stop any first. The pattern names the gcloud command
# itself (gcloud, or gcloud.py as python runs it), so a shell whose command text only mentions the words is left alone
RUN_PROXY_RE='gcloud(\.py)? run services proxy'
export RUN_PROXY_RE
no_run_proxy () {
  if pgrep -f "$RUN_PROXY_RE" >/dev/null; then
    pkill -f "$RUN_PROXY_RE"
    sleep 3
    pgrep -f "$RUN_PROXY_RE" >/dev/null && { pkill -KILL -f "$RUN_PROXY_RE"; sleep 1; }
    pgrep -f "$RUN_PROXY_RE" >/dev/null && stop_run "a 'gcloud run services proxy' keeps running: stop it, then rerun"
    note "stopped a running 'gcloud run services proxy' (a gcloud write hangs while it runs)"
  fi
}

# The jobs deploy.sh deploys, read from the script itself
ingest_jobs () { grep -oE '^  deploy_job [a-z-]+' docs/ingest/deploy.sh | awk '{print $2}'; }

# jobs_on_image <project> <image>: every ingest job on the image (a read after the deploy, whatever its exit said)
jobs_on_image () {
  local project=$1 image=$2 job got bad=0
  for job in $JOBS; do
    got="$(timeout 60 gcloud run jobs describe "$job" --project="$project" --region="$REGION" \
      --format='value(spec.template.spec.template.spec.containers[0].image)' 2>&1)"
    if [ "$got" = "$image" ]; then echo "ok   $job"; else echo "OLD  $job: ${got:-no answer}"; bad=1; fi
  done
  return $bad
}

# execution_started <project> <job> <epoch>: the name of the job's newest execution created at or after <epoch>
execution_started () {
  local line name created
  line="$(timeout 60 gcloud run jobs executions list --job="$2" --project="$1" --region="$REGION" --limit=1 \
    --sort-by='~metadata.creationTimestamp' --format='value(metadata.name,metadata.creationTimestamp)' 2>/dev/null)"
  name="${line%%[[:space:]]*}"
  created="$(date -d "${line##*[[:space:]]}" +%s 2>/dev/null || echo 0)"
  [ -n "$name" ] && [ "$created" -ge "$(( $3 - 5 ))" ] && echo "$name"
}

# execute_job <project> <job>: starts an execution (--async, under a timeout); when the write hangs or its answer is
# lost, the execution is found by a read. Prints the execution's name to $RUN_TMP/execution
execute_job () {
  local project=$1 job=$2 t0 name
  t0=$(date +%s)
  name="$(timeout 120 gcloud run jobs execute "$job" --project="$project" --region="$REGION" --async \
    --format='value(metadata.name)' --quiet 2>/dev/null | tail -1)"
  if [ -z "$name" ]; then
    echo "the execute did not answer within 120 s: looking for the execution it started"
    sleep 10
    name="$(execution_started "$project" "$job" "$t0")"
  fi
  [ -n "$name" ] || { echo "no execution of ${job} started"; return 1; }
  echo "$name" > "$RUN_TMP/execution"
  echo "execution ${name}"
}

# wait_execution <project>: polls the execution in $RUN_TMP/execution until it completes; exit 0 when it succeeded
wait_execution () {
  local project=$1 name s last=""
  name="$(cat "$RUN_TMP/execution")"
  local done ok failed running
  while true; do
    # comma-separated: a count of 0 is left out by the API, an empty field that a comma keeps (a tab, being whitespace
    # to read, would collapse it and move the failed count into the succeeded one)
    s="$(timeout 60 gcloud run jobs executions describe "$name" --project="$project" --region="$REGION" \
      --format='csv[no-heading](status.completionTime,status.succeededCount,status.failedCount,status.runningCount)' 2>/dev/null)"
    IFS=, read -r done ok failed running <<<"$s"
    [ "$s" = "$last" ] || { echo "state: completed ${done:--}, succeeded ${ok:-0}, failed ${failed:-0}, running ${running:-0}"; last="$s"; }
    if [ -n "$done" ]; then
      [ "${ok:-0}" = 1 ] && [ "${failed:-0}" = 0 ] && return 0
      return 1
    fi
    sleep 15
  done
}

# purge_lines <project>: the reconcile's retention lines of the execution in $RUN_TMP/execution (logging lags: polled
# up to 4 minutes); exit 0 when every tenant's line is "reconcile: sync_run retention" and none says "stopped" or
# "skipped" (the function missing)
purge_lines () {
  local project=$1 name out i
  name="$(cat "$RUN_TMP/execution")"
  local prev=-1 count
  for i in $(seq 1 16); do
    out="$(timeout 90 gcloud logging read "resource.type=\"cloud_run_job\" AND labels.\"run.googleapis.com/execution_name\"=\"${name}\" AND jsonPayload.message:\"reconcile: sync_run retention\"" \
      --project="$project" --freshness=3h --order=asc \
      --format='value(jsonPayload.message,jsonPayload.tenant,jsonPayload.deleted,jsonPayload.batches,jsonPayload.more,jsonPayload.code,jsonPayload.ms)' 2>/dev/null)"
    count=0; [ -n "$out" ] && count="$(wc -l <<<"$out")"
    [ "$count" -gt 0 ] && [ "$count" = "$prev" ] && break
    echo "${count} retention line(s) so far (logging lags; read until the number holds), ${i} of 16"
    prev=$count
    sleep 15
  done
  echo "message | tenant | deleted | batches | more | code | ms"
  echo "$out" | tr '\t' '|'
  [ -n "$out" ] && ! grep -qE 'retention (stopped|skipped)' <<<"$out"
}

# on_main: this checkout is main and equal to origin/main (deploy.sh deploys from main only; the image tag is the last
# commit under ingest/)
on_main () {
  [ "$(git rev-parse --abbrev-ref HEAD)" = main ] || stop_run "check out main first: git switch -q main && git pull -q --ff-only"
  timeout 60 git fetch -q origin main || stop_run "git fetch origin main did not answer"
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || stop_run "main is not origin/main: git pull -q --ff-only first"
  grep -q 'PURGE_SIGNATURE = "cma.sync_run_purge(integer,text,uuid)"' ingest/src/jobs/reconcile.mjs \
    || stop_run "main's reconcile does not hold N07f's purge (merge #321 first)"
  INGEST_SHA="$(git log -1 --format=%h -- ingest/)"
  IMAGE="${REGION}-docker.pkg.dev/p4a-cma-prod/cma/ingest:${INGEST_SHA}"
  export INGEST_SHA IMAGE
  note "main $(git rev-parse --short=7 HEAD); the ingest image ${IMAGE}"
}

# has_0009zt: the connected database holds addition 0009zt
has_0009zt () { [ "$(psql_val "select count(*) from cma.schema_migration where version = '0009zt'")" = 1 ]; }
export -f jobs_on_image execution_started execute_job wait_execution purge_lines
