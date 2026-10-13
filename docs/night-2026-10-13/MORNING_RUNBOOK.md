# Morning runbook, 13 October 2026: 0008e, the new configuration screens, then Aircall and Shopify

Read `NIGHT_NOTES.md` first (five minutes). Labels: **Browser**, **Terminal** (Cloud Shell, in `~/cma` unless stated), **Studio** (the instance named), **File** (a repository path). SQL and shell never share a block. Every step ends with what you should see.

**Order matters:** the merged web reads the functions of addition 0008e on every new screen and on People (the linked accounts), so 0008e runs in dev and prod from the pull request's branch **before** the merge. Until it runs in prod, a merged `main` would show People with an error.

| Step | What | Elapsed |
|---|---|---|
| 1 | Review the pull request, build it in Cloud Shell | 30 min |
| 2 | 0008e in dev with its verify | 10 min |
| 3 | 0008e in prod with a read-only check | 10 min |
| 4 | Merge, watch the prod build | 10 min |
| 5 | Dev on the merged image: the API verifier, then theme, layout and hints locally | 20 min |
| 6 | Browser check of each new screen in prod | 15 min |
| 7 | `docs/ingest/PROD_RUNBOOK.md` phases 8 and 9, as far as their gates allow | see there |

---

## Helpers (define in every new Cloud Shell)

The helpers of `docs/night-2026-10-10/MORNING_RUNBOOK.md`, unchanged.

**Terminal**
```bash
command -v nvm >/dev/null || source /usr/local/nvm/nvm.sh; nvm use 22 >/dev/null; cd ~/cma
cma_db () {  # usage: cma_db dev|prod  → starts the proxy once and sets PGCONN
  local env=$1 port; [ "$env" = dev ] && port=5433 || port=5434
  pgrep -f "cloud-sql-proxy.*cma-$env-pg" >/dev/null || \
    (cloud-sql-proxy --auto-iam-authn --port $port "p4a-cma-$env:europe-west4:cma-$env-pg" >/tmp/proxy-$env.log 2>&1 &)
  sleep 3
  export PGCONN="host=127.0.0.1 port=$port dbname=cma user=$(gcloud config get-value account 2>/dev/null) sslmode=disable"
  psql "$PGCONN" -Atc "select 'connected to ' || current_database() || ' as ' || current_user"
}
run_migration () {  # usage: run_migration <env> <nn_migration.sql> <nn_verify.sql> <records dir> [earlier verify files...]
  local env=$1 mig=$2 ver=$3 rec=$4; shift 4
  cd ~/cma && mkdir -p "records/$rec" && cma_db "$env" || return 1
  psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$mig" > "records/$rec/${mig%%_*}.txt" 2>&1 && tail -3 "records/$rec/${mig%%_*}.txt"
  psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$ver" > "records/$rec/${ver%%_*}.txt" 2>&1; tail -6 "records/$rec/${ver%%_*}.txt"
  sed "s/select set_config('verify.provoke', 'false', false);/select set_config('verify.provoke', 'true', false);/" "db/$ver" > /tmp/provoke.sql
  psql "$PGCONN" -v ON_ERROR_STOP=0 -f /tmp/provoke.sql > "records/$rec/${ver%%_*}-provoked.txt" 2>&1
  grep -cE "FAIL" "records/$rec/${ver%%_*}-provoked.txt" | sed 's/^/provoked FAIL lines: /'; grep -E "PROVOKED" "records/$rec/${ver%%_*}-provoked.txt" | tail -2
  for f in "$@"; do psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$f" > "records/$rec/${f%%_*}-rerun.txt" 2>&1; echo "$f: $(grep -cE '\| PASS' "records/$rec/${f%%_*}-rerun.txt") PASS rows"; done
}
```
Expected: `v22.…` is active (`node -v`), no other output. `type cma_db run_migration` prints both functions.

---

## 1. Review the pull request and build it

**Browser:** GitHub → Pulse4all-com/cma → Pull requests → "Night 13 October: Sources and alert rules configuration, linked accounts, Aircall and Shopify prod runbook". Read the description and the diff; the night's local outputs are under `docs/night-2026-10-13/local-records/`, the screenshots in its `screenshots/` folder.

Expected: one pull request from `night-2026-10-13`, no change to `cloudbuild.yaml`, `ingest/` or `records/`.

**Terminal** (the pull request's number from the page)
```bash
cd ~/cma && gh pr checkout <number> && cd web && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run build 2>&1 | tail -5; echo "build exit: ${PIPESTATUS[0]}"; cd ~/cma
```
Expected: the route list with `/configuration/sources`, `/configuration/sources/[id]`, `/configuration/markets`, `/configuration/alert-rules`, then `build exit: 0`. **Do not merge yet.**

## 2. Addition 0008e in dev

**Terminal** (still on the pull request's branch)
```bash
run_migration dev 52_sources_configuration.sql 53_verify_sources_configuration.sql 0008e-dev-$(date +%F) 33_verify_intake_core.sql 31_verify_ingest_crm_records.sql
```
Expected: `connected to cma as martin@pulse4all.com`; the last lines of `52` are `INSERT 0 1`, `COMMIT`, `RESET` (no `ERROR`); `53` ends with the verdict row `PASS | 16 PASS, 0 FAIL`; `provoked FAIL lines: 4` and the verdict `PROVOKED, NOT A PASS | 13 PASS, 3 FAIL` (A1, B1 and B8); `33_verify_intake_core.sql: 2 PASS rows`, `31_verify_ingest_crm_records.sql: 2 PASS rows`. A `REFUSED` line means the session is not on dev: check `cma_db dev`. If `52` stops with `adapter names must be lower-case letters and digits only before 0008e; these connections break the rule: …`, nothing was applied: the line names the tenant, adapter and name; send it to me before going on.

**Studio (cma-dev-pg)** (what the migration set on the existing connections)
```sql
set role cma_owner;
select t.slug, c.adapter, c.name, c.kind, c.status from cma.integration_connection c join cma.tenant t on t.id = c.tenant_id order by 1, 2, 3;
reset role;
```
Expected: the dev HubSpot connection `crm`; an Aircall replay connection `telephony` and a Shopify dev connection `commerce` if they hold rows; an automation connection, or one without events yet, with an empty kind (set it on the Sources page after step 4).

## 3. Addition 0008e in prod

**Terminal** (point-in-time recovery on, as before every prod migration)
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.backupConfiguration.transactionLogRetentionDays)"
```
Expected: `True	7`.

`53` refuses prod (it writes throwaway tenants and runs in dev only, like `49`), so prod runs the migration and the two earlier verifies, then a read-only check in Studio.

**Terminal**
```bash
rec=records/0008e-prod-$(date +%F); mkdir -p "$rec" && cma_db prod && psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/52_sources_configuration.sql > "$rec/52.txt" 2>&1; tail -3 "$rec/52.txt"
for f in 33_verify_intake_core.sql 31_verify_ingest_crm_records.sql; do psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$f" > "$rec/${f%%_*}-rerun.txt" 2>&1; echo "$f: $(grep -cE '\| PASS' "$rec/${f%%_*}-rerun.txt") PASS rows"; done
```
Expected: `connected to cma as martin@pulse4all.com`; `INSERT 0 1`, `COMMIT`, `RESET` (on a rerun `INSERT 0 0`; the pre-flight's `adapter names must be …` line instead means nothing was applied, as in step 2); `33_verify_intake_core.sql: 2 PASS rows`, `31_verify_ingest_crm_records.sql: 2 PASS rows`.

**Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select version, applied_at, applied_by from cma.schema_migration where version = '0008e';
select t.slug, c.adapter, c.name, c.kind, c.status from cma.integration_connection c join cma.tenant t on t.id = c.tenant_id order by 1, 2, 3;
select p.oid::regprocedure as fn, has_function_privilege('cma_app', p.oid, 'execute') as app,
       has_function_privilege('cma_readonly', p.oid, 'execute') as reader
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'cma' and p.proname in ('connection_held_kinds_of', 'set_connection_kind', 'sources', 'connection_catalogs',
  'markets_all', 'business_hours_all', 'business_holidays_all', 'message_rules', 'linked_account_systems', 'linked_accounts',
  'set_user_external_id', 'remove_user_external_id', 'find_tenants_for_identity', 'add_person', 'upsert_connection')
order by 1;
select adapter from cma.integration_connection where adapter !~ '^[a-z0-9]+$';
select count(*) as ids_linked from cma.app_user_external_id where system ~ '^[a-z0-9]+_(owner|user)$';
reset role;
```
Expected: one row `0008e` with today's time and your login; `HubSpot Subscriptions` `hubspot` `crm` `active` (and the Make automation connection of `GO_LIVE_RUNBOOK.md` 2b, if you created it, with an empty kind); fifteen functions (the twelve of 0008e and the three it replaced), `app` true and `reader` false on every row; the adapter query returns 0 rows (prod holds only `hubspot`, which `52`'s pre-flight checked as well); `ids_linked` equal to the owners you linked on 12 October (7.6), unchanged by the migration.

## 4. Merge and watch the prod build

**Browser:** the pull request → **Squash and merge** (the title as it stands) → Confirm.

**Terminal** (`docs/RUNBOOK.md` section 3)
```bash
cd ~/cma && git switch -q main && git pull -q --ff-only && sha=$(git rev-parse --short HEAD) && echo $sha
gcloud builds list --project=p4a-cma-prod --region=europe-west4 --limit=1 --format="value(substitutions.SHORT_SHA,status)"
```
Expected: the merge's short SHA, then the same SHA with `WORKING`, later `SUCCESS` (rerun the second line every two minutes).

## 5. Dev on the merged image, then the verifiers

**Terminal** (`docs/RUNBOOK.md` section 4; inside 07:00 to 22:00 Amsterdam time, the workday window)
```bash
gcloud run services update cma-web --project=p4a-cma-dev --region=europe-west4 \
  --image=europe-west4-docker.pkg.dev/p4a-cma-prod/cma/web:$sha 2>&1 | tail -1
pkill -f "run services proxy"; gcloud run services proxy cma-web --project=p4a-cma-dev \
  --region=europe-west4 --port=8080 >/tmp/proxy.log 2>&1 & sleep 6
curl -s localhost:8080/api/health; echo
```
Expected: the new revision serving 100 %, then `version` = `$sha`, `auth` `mock`, `data` `api`.

**Terminal**
```bash
cd ~/cma/web && mkdir -p ../records/0008e-dev-$(date +%F) && node verify/api.mjs | tee ../records/0008e-dev-$(date +%F)/verify-api.txt | tail -2; node verify/api.mjs --provoke | tail -1
node verify/api.mjs --sources | tail -1; node verify/api.mjs --sources --provoke | tail -1; cd ~/cma
```
Expected: `ALL 219 PASS`, `ALL 219 PROVOKED CHECKS FAILED, as they must`, `ALL 32 PASS`, `ALL 32 PROVOKED CHECKS FAILED, as they must`. The run leaves one switched-off rule `API verifier rule` on dev's Alert rules (rules are never deleted; it alerts nobody). A count other than 219 or a `FAIL` line: send me the output.

The browser verifiers run against a local server in mock mode (README, Code: the static files copied in first).

**Terminal** (second tab: the server; stop it with Ctrl+C when done)
```bash
cd ~/cma/web && npm run build 2>&1 | tail -1 && cp -r .next/static .next/standalone/.next/ && ([ -d public ] && cp -r public .next/standalone/ || true) && CMA_AUTH_MODE=mock CMA_DATA_MODE=mock PORT=8080 npm start
```
Expected: `Ready` on port 8080. (Stop the dev proxy of the previous block first if it still holds 8080: `pkill -f "run services proxy"`.)

**Terminal** (first tab)
```bash
cd ~/cma/web && BASE=http://localhost:8080 node verify/theme.mjs | tail -1; BASE=http://localhost:8080 node verify/layout.mjs | tail -1; BASE=http://localhost:8080 node verify/hints.mjs | tail -1; cd ~/cma
```
Expected: `theme: PASS (33 pages, …)`, `layout: PASS (…, Sources, Markets and Alert rules; …)`, `hints: PASS (91 headers and 20 tiles on 9 pages, …)`. The layout verifier writes its screenshots to `records/layout/` as before.

## 6. The new screens in prod

**Browser:** `https://workspace.pulse4all.app`, as yourself (admin). Change nothing unless a step says so.

1. Configuration (C) → **Sources**. Expected: `HubSpot Subscriptions`, vendor `hubspot`, kind Customer records, account `147946837`, Active, events in the last 24 hours above 0, a last event minutes ago.
2. Open it. Expected: the address key, the two secret names (`ingest-hubspot-subs-signing`, `ingest-hubspot-subs-token`, names only); settings `app_host`, `record_url_deal`, `record_url_ticket` with a preview link that opens a real deal in the live portal; **Pipelines** as set on 12 October (Sales Pipeline - Self Serve counted, not a lead; the test pipeline not counted); **Forms** with the Quote, Contact and Info forms counted with lead source and market, the cancellation, replacement and support forms not; **Call outcomes** as the 12 October rule set them; **Fields** twelve, read-only. Press F: the form rule dialog opens; Esc closes it without saving.
3. **Markets**. Expected: the markets of 7.3 (ES among them, inactive or active as you left it), the 26 aliases and those added since as chips, the default office hours row and the markets' own weeks, holidays if any.
4. **Alert rules**. Expected: `New deal` and `Assigned deal` with their effect in words, urgency Urgent for Assigned deal ("Chime and pop-up"), the alerts of the last 30 days above 0 for Assigned deal.
5. Team → **People**. Expected: the **Linked** column; an agent you linked in 7.6 shows `1 of 1`; Edit person on that agent shows `Owner id in HubSpot Subscriptions` with the owner id; your own row's Edit stays disabled ("This is you"), so your own ids are linked by someone else.
6. Reports → **Data quality**. Expected: "Owners without a person" with a "Link ids on People" link when its count is above 0.
7. If the Make automation connection exists with an empty kind: Sources → it → Choose the kind → Automation → **Set kind**. Expected: the page shows its settings only ("An automation connection sends messages into the Workspace…").

## 7. Aircall and Shopify in prod

**File:** `docs/ingest/PROD_RUNBOOK.md`, phases 8 (Aircall) and 9 (Shopify). Both open with a gate: the Aircall adapter (B9) and the Shopify adapter (B10) with their scripts are not on `main` yet. Today run only what the gates allow:

- Phase 8: 8.1 (the plan check) and 8.2 (the API key into Secret Manager, checked with a `200`). Stop there until B9 is merged and deployed.
- Phase 9: 9.1 (the organisation check), 9.2 (the app and its version, the Email field) and 9.3 up to `put_secret` (the client secret). Stop there until B10 is merged and deployed.

Expected: `stored ingest-aircall-subs-token (version added)` and the `200` of 8.2; `stored ingest-shopify-app-signing (version added)`; the list of stores and organisations from 9.1 written down for B10. Neither phase changes anything the CMA reads until its gate opens.

---

## Afterwards

- **Records:** `records/0008e-dev-<date>/` and `records/0008e-prod-<date>/` (from steps 2, 3 and 5, plus the Studio outputs of steps 2 and 3 pasted into a `studio.txt`), committed as a records pull request.
- **Answers for the night notes' Part 4:** quiet hours (with Yordi) and the clock-in after the window end; each becomes a small increment once decided.
- **Briefs:** B9 and B10, so phases 8 and 9 can finish; the Open decision "Aircall tags as a refinement of connected" before B9.
