#!/usr/bin/env bash
# tools/runners/n07f-prod.sh: addition 0009zt (N07f, #321) in prod, after 244 (0009zv).
#
#   cd ~/cma && git fetch -q origin && git checkout -q claude/clever-goodall-7wnx9z-n07f && git pull -q --ff-only && bash tools/runners/n07f-prod.sh
#
# Checks that 0009zs, 0009zu and 0009zv are in prod; then 240, 241 normal and provoked, and the verifies that read what
# 240 re-creates: 77 and 107 (cma.audit_row; dev only, they refuse prod, which is their expected answer), 113, 169 and
# 195 (cma.audit_row), 197 (cma.sync_run_hour_count). Stops when 240 fails. A rerun is safe: 240 is rerunnable (INSERT 0
# 0). Log and records check: records/0009zt-prod-<date>/.
source "$(dirname "$0")/lib.sh"
run_init n07f-prod "0009zt-prod-$(date +%F)"
[ -f db/240_audit_and_retention.sql ] || stop_run "db/240_audit_and_retention.sql is not in this checkout: check out the N07f branch (or main after #321)"

db_connect prod

VERSIONS="('0009zs', '0009zt', '0009zu', '0009zv')"
step "the additions in prod" 60 rc "psql_cma \"select version, applied_at from cma.schema_migration where version in ${VERSIONS} order by applied_at\"" \
  || stop_run "cannot read cma.schema_migration"
[ "$(psql_val "select count(*) from cma.schema_migration where version in ('0009zs', '0009zu', '0009zv')")" = 3 ] \
  || stop_run "0009zs, 0009zu and 0009zv must be in prod before 240"
[ "$(psql_val "select count(*) from cma.schema_migration where version = '0009zt'")" = 0 ] \
  || note "0009zt is recorded already: 240 reruns (rerunnable, INSERT 0 0)"

step "240_audit_and_retention.sql" 600 commit "psql_file db/240_audit_and_retention.sql" || stop_run "240 failed: nothing after it runs"

PROVOKE_FROM="select set_config('verify.provoke', 'false', false);"
PROVOKE_TO="select set_config('verify.provoke', 'true', false);"
step "241_verify_audit_and_retention.sql" 600 verify "psql_file db/241_verify_audit_and_retention.sql"
step "241 provoked" 600 provoked "sed \"s/${PROVOKE_FROM}/${PROVOKE_TO}/\" db/241_verify_audit_and_retention.sql > \"\$RUN_TMP/241p.sql\" && grep -q \"'verify.provoke', 'true'\" \"\$RUN_TMP/241p.sql\" && psql \"\$PGCONN\" -X -v ON_ERROR_STOP=0 -f \"\$RUN_TMP/241p.sql\""

step "77 rerun (dev only: refuses prod)" 300 refused "psql_file db/77_verify_audit_hardening.sql"
step "107 rerun (dev only: refuses prod)" 300 refused "psql_file db/107_verify_review_reference_guard.sql"
for f in 113_verify_assets.sql 169_verify_pledge_lists.sql 195_verify_audit_bookkeeping.sql 197_verify_sync_run_reads.sql; do
  step "${f%%_*} rerun (${f})" 900 verify "psql_file db/${f}"
done

step "the additions in prod, after" 60 rc "psql_cma \"select version, applied_at from cma.schema_migration where version in ${VERSIONS} order by applied_at\""
run_finish
