# Morning runbook, N04: split shifts, clock in again (addition 0008zp)

Labels: **Browser**, **Terminal** (Martin's own Linux terminal, Chromebook Linux or his Linux machine, in `~/cma` unless stated; a step against prod, `p4a-cma-prod` or `cma-prod-pg`, from the Chromebook only), **Studio** (the instance named), **File** (a repository path). SQL and shell never share a block. Through the Auth Proxy the terminal runs only `db/` scripts, whose output is schema, check rows, counts and ids; every query that reads rows runs in Studio (README, Where a command runs). Every step ends with what you should see. Claude Code's local outputs are in `local-records/` (its `README.md` lists them); `NIGHT_NOTES.md` has the design, the night defaults to confirm and every function checked.

**What changes** (Decision log, 3 November 2026; README, Data model: workday sessions):
- **0008zp** (`126`, `127`): the setting `workday.clock_in_again` (boolean, default `false`); `cma.workday_can_clock_in_again`, the one rule (the person's own log out, strictly after it, the same business date, within the workday window, time kept); `cma.refresh_workday` for a day of one or more sessions; `cma.open_workday` clocks in again under a lock. No table, view or column changes, so `docs/datamap/schema.json` needs no refresh.
- `02`: `workday.clock_in_again = true` for Pulse4all Subscriptions; Pulse4all Invest keeps the default (off).
- Web: on an ended day the person may clock in again on, Welcome and My day show the Clock in card again; "Back since" on a day of several sessions; End workday, Log out and the signed-out page say until when; My hours and Team hours mark "2 sessions"; the day editor knows sessions.

**The number.** The brief named 0008zo, `125` and `126`; the open pull request 216 (Flash watch cadence) holds 0008zo and `125`, so this change is 0008zp, `126` and `127` (`NIGHT_NOTES.md`, The number). It runs before or after 216.

**Order matters:**
- The migration runs in dev and prod **before** the merge: the merge builds and deploys prod's web, and its day read calls `cma.workday_can_clock_in_again`. Merged first, My day, Welcome and the Live board answer an error until `126` runs.
- The web of `main` runs unchanged on the migrated database: its day read and its Clock in call the same views and the same `cma.open_workday()`. Its screens offer no Clock in on an ended day, so between step 5 and the merge nobody clocks in again through them (only `POST /api/v1/me/day/start` would, with the setting on). Locally, `main`'s `verify/api.mjs` on a database at 0008zp with the setting on failed exactly its three checks that assume "an ended day stays ended" (`local-records/web/main-web-verify-api-setting-on.txt`).
- Dev runs the web images prod's build makes (`docs/RUNBOOK.md` section 4; a dev-only web build is backlog CMA-068), so this branch's web reaches dev only after the merge: the brief's steps 3 and 4 (`verify:api` and the hand check in dev) are steps 7 and 8 here, after the merge. Locally they passed on this branch's build against a database at 0008zp (`local-records/`).
- Scripts that have run in prod: none changes. `27_verify_configuration.sql` fails its A4 already before `126` (pre-existing since 0008s, `NIGHT_NOTES.md`); it is left out below.

| Step | What | Elapsed |
|---|---|---|
| 0 | Review the pull request, build it | 10 min |
| 1 | Dev: `126` twice, `127` normal and provoked, `02`, the earlier verifies | 10 min |
| 2 | Studio dev: the setting per tenant | 2 min |
| 5 | Prod, just before the merge: `126` twice, `02`, `127` | 10 min |
| 6 | Merge, watch the prod build | 10 min |
| 7 | Dev on the merge's image: `verify:api`, both branches explained | 15 min |
| 8 | Browser, dev hand check | 10 min |
| 9 | Prod hand check, your own day only | 5 min |
| | Rollback, if needed | 2 min |

---

## Helpers

The terminal is set up as `docs/RUNBOOK.md`, Setup (once per machine), step 8: the helpers `cma_db` and `run_migration` in `~/.cma_helpers.sh`. This runbook uses `cma_db` and adds none.

**Terminal**
```bash
cd ~/cma && node -v && bash -ic 'type -t cma_db run_migration'
```
Expected: `v22.…`, then `function` twice. Anything else: run `docs/RUNBOOK.md`, Setup, step 8 first.

## 0. Review the pull request, build it

**Browser:** GitHub → Pulse4all-com/cma → Pull requests → "N04: split shifts, clock in again (0008zp)". Read the description and the diff.

Expected: in `db/` the new `126_workday_sessions.sql` and `127_verify_workday_sessions.sql` and one block added at the end of `02_seed_pulse4all.sql`; changes under `web/` (types, the Postgres and mock data layers, Welcome, My day, Log out, My hours, Team hours, the Clock in card, the day editor, copy, three verifiers), `docs/` (decisions, definitions, features, api, data model 0008 and planned, open decisions, the data map's catalog, this folder), `README.md` (the documentation map) and `CHANGELOG.md`; none under `cloudbuild.yaml`, `ingest/`, `hubspot/` or `records/`.

**Terminal** (the pull request's number from the page)
```bash
cd ~/cma && gh pr checkout <number> && cd web && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run build 2>&1 | tail -2; echo "build exit: ${PIPESTATUS[0]}"; npm run --silent verify:corrections | tail -1; npm run --silent verify:copy; cd ~/cma
```
Expected: `found 0 vulnerabilities` (or the known advisories of README, Open decisions), the build's last lines and `build exit: 0`, `ALL 42 PASS`, `copy: PASS (3181 keys, en and nl)`. **Do not merge yet.**

**Studio (cma-dev-pg)** and **Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select version, applied_at from cma.schema_migration where version >= '0008zn' order by 1;
reset role;
```
Expected on both instances: `0008zn`, and `0008zo` only where pull request 216 has run its `125`. With `0008zp` already there, stop and tell me.

## 1. Dev: the migration, `127`, `02`, the earlier verifies

**Terminal** (dev, on the pull request's branch): the migration twice; the second run adds nothing.
```bash
cd ~/cma && rec=records/0008zp-dev-2026-11-04 && mkdir -p "$rec" && cma_db dev
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/126_workday_sessions.sql > "$rec/126.txt" 2>&1; echo "126: $(tail -3 "$rec/126.txt" | tr '\n' ' ')"
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/126_workday_sessions.sql > "$rec/126-rerun.txt" 2>&1; echo "126 again: $(tail -3 "$rec/126-rerun.txt" | tr '\n' ' ')"
```
Expected: `connected to cma as martin@pulse4all.com`; then `126: INSERT 0 1 COMMIT RESET`, `126 again: INSERT 0 0 COMMIT RESET`. An `ERROR` line: stop and send me `tail "$rec/126.txt"`. `addition 0008zn (122_flash.sql) must run before 0008zp`: dev is not at 0008zn; tell me.

**Terminal** (dev): the verify, normal and provoked (universal: a throwaway tenant, always rolled back)
```bash
cd ~/cma && psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/127_verify_workday_sessions.sql > "$rec/127.txt" 2>&1; echo "127: $(grep -E ' verdict' "$rec/127.txt" | tr -s ' ')"
sed "s/select set_config('verify.provoke', 'false', false);/select set_config('verify.provoke', 'true', false);/" db/127_verify_workday_sessions.sql > /tmp/provoke.sql
psql "$PGCONN" -v ON_ERROR_STOP=0 -f /tmp/provoke.sql > "$rec/127-provoked.txt" 2>&1; echo "provoked: $(grep -c 'ERROR:  FAIL' "$rec/127-provoked.txt") blocks failed, $(grep -E ' verdict' "$rec/127-provoked.txt" | tr -s ' ')"
```
Expected: `127:  verdict | PASS | 31 PASS, 0 FAIL`; `provoked: 9 blocks failed,  verdict | PROVOKED, NOT A PASS | 0 PASS, 31 FAIL`. Any other `127` line: send me `grep -E 'FAIL|ERROR' "$rec/127.txt"`.

**Terminal** (dev): the Pulse4all seed, then the earlier verifies (unchanged, still passing)
```bash
cd ~/cma && psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/02_seed_pulse4all.sql > "$rec/02-after-126.txt" 2>&1; echo "02 exit $?"; grep -E "ERROR|NOTICE" "$rec/02-after-126.txt"
psql "$PGCONN" -v ON_ERROR_STOP=0 -f db/07_verify_time_model.sql > "$rec/07-rerun.txt" 2>&1; echo "07 block C: $(awk '/zero_length/{f=1} f&&/^ (open|ended)/{printf "%s ", $1; n++} n==2{exit}' "$rec/07-rerun.txt")"
for f in 10_verify_corrections 18_verify_clock_in_app_links 20_verify_team_now 47_verify_workday_window 51_verify_legacy_time_import 111_verify_import_status_reuse; do
  psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$f.sql" > "$rec/${f%%_*}-rerun.txt" 2>&1; echo "$f: exit $?, $(grep -cE '\| PASS|^ PASS|NOTICE:  PASS' "$rec/${f%%_*}-rerun.txt") PASS lines"
done
```
Expected: `02 exit 0` and no line after it; `07 block C: ended ended ` (block C ends the day it opened, in the same transaction, then presses Clock in at that same instant: the day stays ended, N3; it opens a day only inside 07:00 to 22:00 Amsterdam); `10_verify_corrections: exit 0, 10 PASS lines`, `18_verify_clock_in_app_links: exit 0, 2 PASS lines`, `20_verify_team_now: exit 0, 2 PASS lines`, `47_verify_workday_window: exit 0, 2 PASS lines`, `51_verify_legacy_time_import: exit 0, 2 PASS lines`, `111_verify_import_status_reuse: exit 0, 1 PASS lines`. `07`'s other expected errors are in its file, as before.

## 2. Dev: the setting per tenant

**Studio (cma-dev-pg)** (read only)
```sql
set role cma_owner;
select t.slug, cma.setting_of(t.id, 'workday.clock_in_again') as clock_in_again,
       exists (select 1 from cma.tenant_setting s where s.tenant_id = t.id and s.key = 'workday.clock_in_again') as set_by_seed
from cma.tenant t where t.status = 'active' order by 1;
select version, applied_by from cma.schema_migration where version = '0008zp';
reset role;
```
Expected: `pulse4all-subscriptions | true | true`, `pulse4all-invest | false | false` (and any other dev tenant `false | false`); then one row `0008zp` with your login.

## 5. Prod, just before the merge: `126`, `02`, `127`

**Terminal** (from the Chromebook; point-in-time recovery on, as before every prod migration)
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.backupConfiguration.transactionLogRetentionDays)"
```
Expected: `True	7`.

**Terminal** (from the Chromebook; `db/` scripts only). `127` is universal and safe in prod: its throwaway tenants are always rolled back.
```bash
cd ~/cma && rec=records/0008zp-prod-2026-11-04 && mkdir -p "$rec" && cma_db prod
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/126_workday_sessions.sql > "$rec/126.txt" 2>&1; echo "126: $(tail -3 "$rec/126.txt" | tr '\n' ' ')"
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/126_workday_sessions.sql > "$rec/126-rerun.txt" 2>&1; echo "126 again: $(tail -3 "$rec/126-rerun.txt" | tr '\n' ' ')"
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/02_seed_pulse4all.sql > "$rec/02-after-126.txt" 2>&1; echo "02 exit $?"; grep -E "ERROR|NOTICE" "$rec/02-after-126.txt"
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/127_verify_workday_sessions.sql > "$rec/127.txt" 2>&1; echo "127: $(grep -E ' verdict' "$rec/127.txt" | tr -s ' ')"
```
Expected: `connected to cma as martin@pulse4all.com`; `126: INSERT 0 1 COMMIT RESET`, `126 again: INSERT 0 0 COMMIT RESET`; `02 exit 0` and no line after it; `127:  verdict | PASS | 31 PASS, 0 FAIL`.

**Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select version, applied_at, applied_by from cma.schema_migration where version = '0008zp';
select t.slug, cma.setting_of(t.id, 'workday.clock_in_again') as clock_in_again from cma.tenant t where t.status = 'active' order by 1;
reset role;
```
Expected: one row with today's time and your login; `pulse4all-invest | false`, `pulse4all-subscriptions | true`.

## 6. Merge, watch the prod build

**Terminal** (from the Chromebook)
```bash
cd ~/cma && gh pr merge <number> --squash --delete-branch && git switch main -q && git pull -q && git log --oneline -1
gcloud builds list --project=p4a-cma-prod --region=europe-west4 --limit=1 --format="table(status,substitutions.SHORT_SHA,createTime.date('%H:%M'))"
```
Expected: the merge commit; then a build for its short SHA, `QUEUED` or `WORKING`, then `SUCCESS` (`docs/RUNBOOK.md` section 3; the build appears 2 to 4 minutes after the merge). No build for the short SHA 4 minutes after the merge: `gcloud builds triggers run cma-web-main --project=p4a-cma-prod --region=europe-west4 --sha=$(git rev-parse HEAD)`.

## 7. Dev on the merge's image: `verify:api`

**Terminal** (`docs/RUNBOOK.md` section 4, after step 6's build is green; inside 07:00 to 22:00 Amsterdam)
```bash
sha=<the merge's short SHA from step 6>
gcloud run services update cma-web --project=p4a-cma-dev --region=europe-west4 \
  --image=europe-west4-docker.pkg.dev/p4a-cma-prod/cma/web:$sha 2>&1 | tail -1
pkill -f "run services proxy"; gcloud run services proxy cma-web --project=p4a-cma-dev \
  --region=europe-west4 --port=8080 >/tmp/proxy.log 2>&1 & sleep 6
curl -s localhost:8080/api/health; echo
```
Expected: the new revision serving 100 percent of traffic; then the health answer with `version` the merge's short SHA, auth `mock`, data `api`.

**Terminal** (dev, through the proxy)
```bash
cd ~/cma/web && node verify/api.mjs | tee ../records/0008zp-dev-2026-11-04/verify-api.txt | grep -E "branch|FAIL|ALL|FAILED"; echo "exit ${PIPESTATUS[0]}"
node verify/api.mjs --provoke | tail -1; echo "exit ${PIPESTATUS[0]}"
```
Expected: `(branch: clock in again; workday.clock_in_again on, the window open until …Z)` (the test supervisor's day ends, clocks in again with its first start kept and ends again, two checks), then `ALL n PASS` with n two more than the last dev run's (local: 281), `exit 0`; provoked `ALL n PROVOKED CHECKS FAILED, as they must`, `exit 0`. Run it inside 07:00 to 22:00 Amsterdam (the workday window it needs). The other branch, `(branch: an ended day stays ended; …)`, runs where the setting is off; it passed locally with the same count. Each run adds a session to the test supervisor's dev day (no limit, N2): dev data.

## 8. Browser, dev hand check

**Browser** (dev, http://localhost:8080 through the proxy, `/?as=agent-two` once; inside 07:00 to 22:00 Amsterdam)
1. Welcome: Clock in (Enter). Expected: "Clocked in at HH:MM · 0m worked so far".
2. Top bar → Log out → Log out (Enter). Expected: the Log out page first says "This stops your clock and signs you out of the Workspace. You can clock in again today until 22:00." and the warning ends "The time until you clock in again is not counted."
3. Sign in again (dev: http://localhost:8080/?as=agent-two). Expected: Welcome shows "Your workday has ended" with the times, and below it a card "Clocked out", "You can clock in again today until 22:00. Your status will be set to …", the button **Clock in again** with the focus.
4. Press Enter. Expected: "Clocked in at" (the first start) and a second line "Back since HH:MM".
5. My day. Expected: "Started at" and below it "Back since"; the clock counts the first session plus the running one, nothing for the gap. End workday: the dialog says "Your clock stops now. You can clock in again today until 22:00."; End workday. Expected: "Your workday has ended", "Log out when you leave. To work another session today, clock in again below.", and the card again below it.
6. As the supervisor (`/?as=supervisor`): Team hours, today. Expected: one row for Agent Two with the first clock-in and the last clock-out and a neutral chip "2 sessions"; Worked excludes the gap. Download status changes: Agent Two's day has one row per stretch, none for the gap.

Write down what differs and send it to me.

## 9. Prod hand check, your own day only

**Browser** (prod, https://workspace.pulse4all.app, as yourself; Pulse4all Subscriptions; inside 07:00 to 22:00 Amsterdam; only if you keep your time today)
1. Clock in, Log out, Log in on the signed-out page. Expected: Welcome shows your ended day and the card "Clock in again"; the signed-out page said "You can sign in and clock in again today until 22:00."
2. Clock in again, then End workday on My day. Expected: My hours, today: one day with "2 sessions", the gap in neither Duration nor Pauses.

Nothing else: no other person's day, no correction.

## Rollback

**Studio (cma-prod-pg)** (the setting only, no deploy; days already of several sessions stay valid and counted)
```sql
set role cma_owner;
update cma.tenant_setting set value = 'false'
where key = 'workday.clock_in_again' and tenant_id = (select id from cma.tenant where slug = 'pulse4all-subscriptions');
select cma.setting_of(id, 'workday.clock_in_again') from cma.tenant where slug = 'pulse4all-subscriptions';
reset role;
```
Expected: `UPDATE 1`, then `false`. From the next Clock in an ended day stays ended again; the card no longer shows. A rerun of `02` keeps `false` (it adds only a value the tenant does not have). The web itself rolls back as `docs/RUNBOOK.md` section 10 says; it needs the database at 0008zp either way.
