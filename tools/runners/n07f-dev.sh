#!/usr/bin/env bash
# tools/runners/n07f-dev.sh: addition 0009zt (N07f, #321) in dev, only if 240 has not run there yet.
#
#   cd ~/cma && git fetch -q origin && git checkout -q claude/clever-goodall-7wnx9z-n07f && git pull -q --ff-only && bash tools/runners/n07f-dev.sh
#
# Not run yet: 240, 241 normal and provoked, the verifies that read what 240 re-creates (77, 107, 113, 169 and 195:
# cma.audit_row; 197: cma.sync_run_hour_count), the migrations' rows. Run already: no migration; 241 normal and provoked
# show that R1 (0009zt after 0009zs) holds with 0009zu and 0009zv in between. Stops when 240 fails. Log and records
# check: records/0009zt-dev-<date>/.
source "$(dirname "$0")/lib.sh"
run_init n07f-dev "0009zt-dev-$(date +%F)"
[ -f db/240_audit_and_retention.sql ] || stop_run "db/240_audit_and_retention.sql is not in this checkout: check out the N07f branch (or main after #321)"

db_connect dev

VERSIONS="('0009zs', '0009zt', '0009zu', '0009zv')"
step "the additions in dev" 60 rc "psql_cma \"select version, applied_at from cma.schema_migration where version in ${VERSIONS} order by applied_at\"" \
  || stop_run "cannot read cma.schema_migration"

RAN240=0
if [ "$(psql_val "select count(*) from cma.schema_migration where version = '0009zt'")" = 1 ]; then
  note "240 ran in dev already ($(psql_val "select applied_at from cma.schema_migration where version = '0009zt'")): no migration"
else
  step "240_audit_and_retention.sql" 600 commit "psql_file db/240_audit_and_retention.sql" || stop_run "240 failed: nothing after it runs"
  RAN240=1
fi

PROVOKE_FROM="select set_config('verify.provoke', 'false', false);"
PROVOKE_TO="select set_config('verify.provoke', 'true', false);"
step "241_verify_audit_and_retention.sql" 600 verify "psql_file db/241_verify_audit_and_retention.sql"
step "241 provoked" 600 provoked "sed \"s/${PROVOKE_FROM}/${PROVOKE_TO}/\" db/241_verify_audit_and_retention.sql > \"\$RUN_TMP/241p.sql\" && grep -q \"'verify.provoke', 'true'\" \"\$RUN_TMP/241p.sql\" && psql \"\$PGCONN\" -X -v ON_ERROR_STOP=0 -f \"\$RUN_TMP/241p.sql\""

if [ "$RAN240" = 1 ]; then
  for f in 77_verify_audit_hardening.sql 107_verify_review_reference_guard.sql 113_verify_assets.sql 169_verify_pledge_lists.sql \
           195_verify_audit_bookkeeping.sql 197_verify_sync_run_reads.sql; do
    step "${f%%_*} rerun (${f})" 900 verify "psql_file db/${f}"
  done
else
  note "no reruns: this run did not run 240 (where 240's own run in dev lacked them, run this file's loop by hand)"
fi

step "the additions in dev, after" 60 rc "psql_cma \"select version, applied_at from cma.schema_migration where version in ${VERSIONS} order by applied_at\""
run_finish
