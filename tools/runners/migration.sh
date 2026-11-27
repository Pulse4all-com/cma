#!/usr/bin/env bash
# tools/runners/migration.sh: one addition in dev or prod, in the lib.sh frame (27 November 2026).
#
#   cd ~/cma && bash tools/runners/migration.sh dev|prod <migration>.sql <verify>.sql [<verify to rerun>.sql …]
#
# Steps, each with a timed header, the output live and in the log, a heartbeat every 15 s, a timeout, its exit and
# verdict: the connection (cma_db; the dev seed decides dev from prod); the additions recorded last; the migration (stops
# here when it fails); its verify, normal and provoked; each verify named to rerun. In prod a dev-only verify (its header
# says "Dev only") is expected to refuse, and that refusal is its OK; 07 is the old-style verify with expected error lines
# (RUNBOOK, Setup 8): it runs without stopping at its errors, its verdict is reported (info) and its error lines are
# compared by hand with its last record. Then the SUMMARY and the records check.
# Log and records check: records/<addition>-<env>-<date>/ (the addition read from the migration's schema_migration row).
source "$(dirname "$0")/lib.sh"
ENV="${1:-}"; MIG="${2:-}"; VER="${3:-}"
[ "$ENV" = dev ] || [ "$ENV" = prod ] || { echo "usage: bash tools/runners/migration.sh dev|prod <migration>.sql <verify>.sql [<rerun>.sql …]"; exit 2; }
shift 3 || exit 2
for f in "$MIG" "$VER" "$@"; do [ -f "db/${f#db/}" ] || { echo "db/${f#db/} is not in this checkout"; exit 2; }; done
MIG="${MIG#db/}"; VER="${VER#db/}"
ADDITION="$(grep -oE "values \('[0-9]{4}[a-z]*'" "db/$MIG" | head -1 | grep -oE "[0-9]{4}[a-z]*")"
[ -n "$ADDITION" ] || { echo "db/$MIG inserts no schema_migration row"; exit 2; }
run_init "migration-${ADDITION}-${ENV}" "${ADDITION}-${ENV}-$(date +%F)"
note "addition ${ADDITION}: ${MIG}, ${VER}; reruns: ${*:-none}"

db_connect "$ENV"

step "the additions recorded last (expected: a few seconds)" 60 rc \
  "psql_cma \"select version, applied_at from cma.schema_migration order by applied_at desc limit 6\"" \
  || stop_run "cannot read cma.schema_migration"

step "${MIG} (expected: seconds)" 900 commit "psql_file db/${MIG}" || stop_run "${MIG} failed: nothing after it runs"

PROVOKE_FROM="select set_config('verify.provoke', 'false', false);"
PROVOKE_TO="select set_config('verify.provoke', 'true', false);"
export VER PROVOKE_FROM PROVOKE_TO
step "${VER} (expected: seconds to a few minutes)" 1800 verify "psql_file db/${VER}"
step "${VER}, provoked (expected: as long as the normal run)" 1800 provoked \
  'sed "s/${PROVOKE_FROM}/${PROVOKE_TO}/" "db/${VER}" > "$RUN_TMP/provoked.sql" && grep -q "'"'"'verify.provoke'"'"', '"'"'true'"'"'" "$RUN_TMP/provoked.sql" && psql "$PGCONN" -X -v ON_ERROR_STOP=0 -f "$RUN_TMP/provoked.sql"'

for f in "$@"; do
  f="${f#db/}"
  if [ "${f%%_*}" = 07 ]; then
    step "${f} rerun (old style: errors expected, compare them with its last record)" 1800 info \
      "psql \"\$PGCONN\" -X -v ON_ERROR_STOP=0 -f db/${f} 2>&1 | tee \"\$RUN_TMP/07.out\"; echo \"error lines: \$(grep -c ERROR \"\$RUN_TMP/07.out\")\""
  elif [ "$ENV" = prod ] && grep -qi "dev only" <(head -12 "db/$f"); then
    step "${f} rerun (dev only: refuses prod)" 300 refused "psql_file db/${f}"
  else
    step "${f} rerun (expected: seconds to a few minutes)" 1800 verify "psql_file db/${f}"
  fi
done

step "the additions recorded last, after" 60 rc \
  "psql_cma \"select version, applied_at from cma.schema_migration order by applied_at desc limit 6\""
run_finish
