# Morning runbook, N05: every source live on Sources, Juo for every store (addition 0008zq)

Written in the night of 4 to 5 November 2026 by Claude Code. Labels: **Browser**, **Terminal** (Martin's own Linux terminal, Chromebook Linux or his Linux machine, in `~/cma` unless stated; a step against prod, `p4a-cma-prod` or `cma-prod-pg`, from the Chromebook only), **Studio** (the instance named), **File** (a repository path). SQL and shell never share a block. Through the Auth Proxy the terminal runs only `db/` scripts, whose output is schema, check rows, counts and ids; every query that reads rows runs in Studio (README, Where a command runs). Every step ends with what you should see. Claude Code's local outputs are in `local-records/` (its `README.md` lists them); `NIGHT_NOTES.md` has the design, the night defaults (to confirm) and every function and verifier checked; `TEAM_NOTE.md` is the paste-ready note of step 8.

**What changes** (Decision log, 4 November 2026; README, Data model: sources last read):
- **0008zq** (`128`, `129`): `cma.sources()` recreated with five columns after the catalog sizes: `last_read_at`, `last_read_job`, `reads_24h`, `reads_failed_24h`, `last_read_error`, read from the connection's own `cma.sync_run` rows; `cma.source_reads(connection_id)`, the connection's last 20 runs newest first (the follow-up of 4 November, evening). No table, view or column changes, so `docs/datamap/schema.json` needs no refresh and `docs/datamap/catalog.json` is unchanged.
- Web: Configuration → Sources shows a **Last read** column after Last event: the latest successful read with the job's name and the reads of 24 hours under it, a warning badge with the failed reads and the latest code in its title; a connection read on a schedule shows a dash under Last event, never "Never". A connection's page shows a **Reads** panel: its last 20 runs with job, started, duration, outcome, counts and the code of a failure.
- Ingest: `ingest-backfill --adapter <name>` walks every served connection of an adapter in one execution (in place of `--connection`, never both); a skipped or failed store is counted and the others still run; exit 1 when any failed.
- Runbook: `docs/ingest/PROD_RUNBOOK.md` 15.10 (the 11 live stores with Juo in one sitting; NO has no Juo yet, CH is not live, both join later with one handle), 15.11 (every store's customers from the store's start), 15.12 (Flash per market); the 13.9 line on the review channels' markets.

**The number.** 0008zq, `128` and `129`, as briefed: free on `main` at `cf35a8a` (`NIGHT_NOTES.md`, The number). The branch is on `main` at `cf35a8a`.

**Order matters:**
- The migration runs in dev and prod **before** the merge: the merge builds and deploys prod's web, and its Sources read maps the five new columns and its connection page calls `cma.source_reads`. Merged first, Configuration → Sources would show every connection without a last read and a connection's page would answer an error until `128` runs.
- The web of `main` runs unchanged on the migrated database: it reads `select * from cma.sources()` and maps the columns it knows by name; the five new ones come last. Locally, `main`'s build is not needed to prove it: the Postgres mapper of `main` and of this branch name their columns (`local-records/README.md`).
- The ingest deploy comes **after** the merge (15.10 (b)): `deploy.sh` tags the image with the last commit under `ingest/`, which is this pull request's squash commit, and `--adapter` is in that image only. Nothing in prod's ingest changes before step 4.
- Dev runs the web images prod's build makes (`docs/RUNBOOK.md` section 4), so this branch's web reaches dev only after the merge: `verify:api` against dev is step 4b.
- Scripts that have run in prod: none changes.

| Step | What | Elapsed |
|---|---|---|
| 0 | Studio (cma-prod-pg): the polled connections' last succeeded and last failed run in 24 hours | 3 min |
| 1 | Review the pull request, build it locally; do not merge yet | 15 min |
| 2 | Dev: `128` twice, `129` normal and provoked, `53` and `79` again | 8 min |
| 3 | Prod, just before the merge: point-in-time recovery, `128` twice, `129` | 8 min |
| 4 | Merge; watch the prod build; the ingest from `main` (15.10 (b)); `verify:api` against dev | 25 min |
| 5 | 15.10 (a) to (h), 15.11, 15.12 as written | 40 min hands-on, 2 to 5 h unattended |
| 6 | Browser: Sources with every last read; Flash, All markets | 5 min |
| 7 | The Gemini audit (does not block the run) | 10 min |
| 8 | Team onboarding: four invitations and the note | 15 min |
| | Rollback, if needed | 5 min |

The unattended parts run while you do the rest: 15.10 (f) (30 to 90 minutes, then 5 to 15) and 15.11 (1 to 4 hours) need the tab open or `nohup`; steps 6 to 8 fit in between.

---

## Helpers

The terminal is set up as `docs/RUNBOOK.md`, Setup (once per machine), step 8: the helpers `cma_db` and `run_migration` in `~/.cma_helpers.sh`. This runbook uses `cma_db` and adds none. Every new Cloud Shell or terminal session needs `put_secret` defined again before a secret is stored (`docs/ingest/PROD_RUNBOOK.md`, Before you start).

**Terminal**
```bash
cd ~/cma && node -v && bash -ic 'type -t cma_db run_migration put_secret'
```
Expected: `v22.…`, then `function` three times. A missing `put_secret`: paste its definition from PROD_RUNBOOK's Before you start.

## 0. Studio (cma-prod-pg): the polled sources are healthy

Before anything else: Trusted Shops, Juo GB and the asset register are read on schedule, whatever Sources says today (read only; runs only, no customer row).

**Studio (cma-prod-pg)**
```sql
set role cma_owner;
with t as (select id from cma.tenant where slug = 'pulse4all-subscriptions'),
c as (select c.id, c.name, c.adapter from cma.integration_connection c where c.tenant_id = (select id from t) and c.status = 'active'
      and c.kind in ('reviews', 'subscriptions', 'assets'))
select c.name, c.adapter, r.job,
       max(r.finished_at) filter (where r.status = 'succeeded') as last_succeeded,
       max(r.finished_at) filter (where r.status = 'failed') as last_failed,
       count(*) filter (where r.started_at > now() - interval '24 hours') as runs_24h,
       count(*) filter (where r.started_at > now() - interval '24 hours' and r.status = 'failed') as failed_24h,
       (array_agg(r.error order by r.finished_at desc) filter (where r.status = 'failed' and r.started_at > now() - interval '24 hours'))[1] as last_error
from c join cma.sync_run r on r.tenant_id = (select id from t) and r.connection_id = c.id
group by 1, 2, 3 order by 1, 3;
reset role;
```
Expected: **Trusted Shops Subscriptions** `reviews_poll` with `last_succeeded` within the last 2 hours and about 24 `runs_24h`; **Juo GB** `subscriptions_poll` with `last_succeeded` within the last 10 minutes and about 288 `runs_24h`, plus one `reconcile` of the night; the asset register's connection `assets_poll` within the last 30 minutes (Martin does Airtable himself tonight: its row is what it is). `failed_24h` 0 or a few `rate_limited`; `last_error` null or that code. A `last_succeeded` older than that: the source is not healthy; fix it first (PROD_RUNBOOK 13.11, 15.9 day one, 14.8) and tell me. These are exactly the figures the Sources page shows after step 4.

## 1. Review the pull request, build it; do not merge yet

**Browser:** GitHub → Pulse4all-com/cma → Pull requests → "N05: every source live on Sources, Juo for every store (addition 0008zq)". Read the description and the diff.

Expected: in `db/` the new `128_sources_last_read.sql` and `129_verify_sources_last_read.sql`, nothing else; under `web/` the Sources list and the connection page (`SourceConfig.tsx`, its Reads panel), their types and the two data layers, the copy, `sources.ts`, `verify/configuration.mjs` and `verify/api.mjs`; under `ingest/` `jobs/backfill.mjs`, `src/jobs/backfill.mjs`, `verify/juo-flow.mjs` and `verify/juo-fake.mjs`; `docs/` (decisions, definitions, features, api, data model 0008, open decisions, OPERATIONS, the ingest README and PROD_RUNBOOK, this folder), `README.md` (Architecture, the documentation map) and `CHANGELOG.md`; none under `cloudbuild.yaml`, `hubspot/`, `records/` or `docs/datamap/`.

**Terminal** (the pull request's number from the page)
```bash
cd ~/cma && gh pr checkout <number> && cd web && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run build 2>&1 | tail -2; echo "build exit: ${PIPESTATUS[0]}"; npm run --silent verify:configuration | tail -1; npm run --silent verify:copy; cd ../ingest && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm test 2>&1 | grep -c "^ALL"; cd ~/cma
```
Expected: `found 0 vulnerabilities` (or the known advisories of README, Open decisions), the build's last lines and `build exit: 0`, `ALL 121 PASS`, `copy: PASS (3419 keys, en and nl)`; then the ingest's install and `20` (every pure verifier of `npm test` printed its `ALL n PASS`). **Do not merge yet.**

**Studio (cma-dev-pg)** and **Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select version, applied_at from cma.schema_migration where version >= '0008zo' order by 1;
reset role;
```
Expected on both instances: `0008zo` and `0008zp` (4 November 2026). With `0008zq` already there, stop and tell me.

## 2. Dev: `128` twice, `129` normal and provoked, the earlier verifies

**Terminal** (dev, on the pull request's branch): the migration twice; the second run adds nothing.
```bash
cd ~/cma && rec=records/0008zq-dev-2026-11-05 && mkdir -p "$rec" && cma_db dev
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/128_sources_last_read.sql > "$rec/128.txt" 2>&1; echo "128: $(tail -3 "$rec/128.txt" | tr '\n' ' ')"
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/128_sources_last_read.sql > "$rec/128-rerun.txt" 2>&1; echo "128 again: $(tail -3 "$rec/128-rerun.txt" | tr '\n' ' ')"
```
Expected: `connected to cma as martin@pulse4all.com`; then `128: INSERT 0 1 COMMIT RESET`, `128 again: INSERT 0 0 COMMIT RESET`. An `ERROR` line: stop and send me `tail "$rec/128.txt"`. `addition 0008zp (126_workday_sessions.sql) must run before 0008zq`: dev is not at 0008zp; tell me.

**Terminal** (dev): the verify, normal and provoked (universal: throwaway tenants, always rolled back)
```bash
cd ~/cma && psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/129_verify_sources_last_read.sql > "$rec/129.txt" 2>&1; echo "129: $(grep -E ' verdict' "$rec/129.txt" | tr -s ' ')"
sed "s/select set_config('verify.provoke', 'false', false);/select set_config('verify.provoke', 'true', false);/" db/129_verify_sources_last_read.sql > /tmp/provoke.sql
psql "$PGCONN" -v ON_ERROR_STOP=0 -f /tmp/provoke.sql > "$rec/129-provoked.txt" 2>&1; echo "provoked: $(grep -c 'ERROR:  FAIL' "$rec/129-provoked.txt") blocks failed, $(grep -E ' verdict' "$rec/129-provoked.txt" | tr -s ' ')"
```
Expected: `129:  verdict | PASS | 14 PASS, 0 FAIL`; `provoked: 6 blocks failed,  verdict | PROVOKED, NOT A PASS | 0 PASS, 14 FAIL`. Any other `129` line: send me `grep -E 'FAIL|ERROR' "$rec/129.txt"`.

**Terminal** (dev): the earlier verifies of what `128` touches (unchanged, still passing)
```bash
cd ~/cma && for f in 53_verify_sources_configuration 79_verify_system_health; do
  psql "$PGCONN" -v ON_ERROR_STOP=0 -f "db/$f.sql" > "$rec/${f%%_*}-rerun.txt" 2>&1; echo "$f: $(grep -E ' verdict' "$rec/${f%%_*}-rerun.txt" | tr -s ' ')"
done
```
Expected: `53_verify_sources_configuration:  verdict | PASS | 16 PASS, 0 FAIL`, `79_verify_system_health:  verdict | PASS | 13 PASS, 0 FAIL`.

**Studio (cma-dev-pg)** (read only: the new columns on dev's own connections; names, counts and codes only)
```sql
set role cma_app;
select set_config('app.tenant_id', '<dev tenant_id>', false),
       set_config('app.user_id', '<dev user_id>', false),
       set_config('app.actor_label', 'studio:martin', false);
select name, kind, events_24h, last_event_at, last_read_at, last_read_job, reads_24h, reads_failed_24h, last_read_error from cma.sources() order by name;
select job, stream, started_at, finished_at, status, counts, error from cma.source_reads((select connection_id from cma.sources() order by reads_24h desc limit 1));
reset role;
```
Expected: one row per dev connection; the polled ones (reviews, assets, subscriptions, where dev has them) with `events_24h` 0 and a `last_read_at`; the HubSpot connection with events and its nightly `reconcile` as `last_read_job`; then at most 20 runs of the most-read connection, newest first, codes and counts only. (The context block's first part gives the two ids, as PROD_RUNBOOK's Studio context block does for prod.)

## 3. Prod, just before the merge: point-in-time recovery, `128` twice, `129`

**Terminal** (from the Chromebook; point-in-time recovery on, as before every prod migration)
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.backupConfiguration.transactionLogRetentionDays)"
```
Expected: `True	7`.

**Terminal** (prod)
```bash
cd ~/cma && rec=records/0008zq-prod-2026-11-05 && mkdir -p "$rec" && cma_db prod
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/128_sources_last_read.sql > "$rec/128.txt" 2>&1; echo "128: $(tail -3 "$rec/128.txt" | tr '\n' ' ')"
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/128_sources_last_read.sql > "$rec/128-rerun.txt" 2>&1; echo "128 again: $(tail -3 "$rec/128-rerun.txt" | tr '\n' ' ')"
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/129_verify_sources_last_read.sql > "$rec/129.txt" 2>&1; echo "129: $(grep -E ' verdict' "$rec/129.txt" | tr -s ' ')"
```
Expected: `connected to cma as martin@pulse4all.com`; `128: INSERT 0 1 COMMIT RESET`; `128 again: INSERT 0 0 COMMIT RESET`; `129:  verdict | PASS | 14 PASS, 0 FAIL`. `main`'s web keeps running on it (Order matters). **Browser:** Configuration → Sources in prod once: the page as before (no Last read column yet; the new columns are ignored by `main`'s web).

## 4. Merge, watch the prod build, the ingest from `main`, `verify:api` against dev

**Terminal** (from the Chromebook)
```bash
cd ~/cma && gh pr merge <number> --squash --delete-branch && git switch main -q && git pull -q && git log --oneline -1
gcloud builds list --project=p4a-cma-prod --region=europe-west4 --limit=1 --format="table(status,substitutions.SHORT_SHA,createTime.date('%H:%M'))"
```
Expected: the merge commit; then a build for its short SHA, `QUEUED` or `WORKING`, then `SUCCESS` (`docs/RUNBOOK.md` section 3; the build appears 2 to 4 minutes after the merge). No build 4 minutes after the merge: `gcloud builds triggers run cma-web-main --project=p4a-cma-prod --region=europe-west4 --sha=$(git rev-parse HEAD)`.

**4a. The ingest from `main`.** This is PROD_RUNBOOK 15.10 (b): the twelve secrets (the eleven stores' and CH's) exist since the evening of 4 November 2026 (15.10 (a) checks them), so (a) and (b) run right after the merge, then the rest of 15.10.

**4b. `verify:api` against dev on the merge's image** (`docs/RUNBOOK.md` section 4; inside 07:00 to 22:00 Amsterdam)
```bash
sha=<the merge's short SHA>
gcloud run services update cma-web --project=p4a-cma-dev --region=europe-west4 \
  --image=europe-west4-docker.pkg.dev/p4a-cma-prod/cma/web:$sha 2>&1 | tail -1
pkill -f "run services proxy"; gcloud run services proxy cma-web --project=p4a-cma-dev \
  --region=europe-west4 --port=8080 >/tmp/proxy.log 2>&1 & sleep 6
curl -s localhost:8080/api/health; echo
cd ~/cma/web && node verify/api.mjs | tee ../records/0008zq-dev-2026-11-05/verify-api.txt | grep -E "FAIL|ALL|FAILED"; echo "exit ${PIPESTATUS[0]}"
node verify/api.mjs --provoke | tail -1; echo "exit ${PIPESTATUS[0]}"; cd ~/cma
```
Expected: the new revision serving 100 percent of traffic; the health answer with `version` the merge's short SHA, auth `mock`, data `api`; `ALL n PASS` with n as the last dev run's on `main`'s image (the sources checks now accept every source kind and read the five new fields: locally 324 with the reports fixture, see `local-records/README.md`), `exit 0`; provoked `ALL n PROVOKED CHECKS FAILED, as they must`, `exit 0`.

## 5. PROD_RUNBOOK 15.10 to 15.12, as written

**File:** `docs/ingest/PROD_RUNBOOK.md`, sections 15.10 (a) to (h), 15.11 and 15.12. Every command is prefilled with the eleven handles (AT, BE, DE, DK, ES, FI, FR, IE, IT, NL, SE; NO has no Juo yet and CH is not live, both join later with one handle), and (a)'s versions list with CH's too; only `<tenant_id>`, `<user_id>` and the connection ids from the Studio output are placeholders. In short:
1. 15.10 (a), done in step 4a: the check that the twelve secrets exist, the eleven stores' and CH's, with one enabled version each and no accessor yet (stored on the evening of 4 November 2026): the secrets list (thirteen names with GB's, none for NO) and the versions list (twelve lines); the `put_secret` block stays for a store that joins later.
2. 15.10 (b), done in step 4a: the service deploy with eleven `--secret` flags and the jobs deploy; the accessor loop, one line per secret. Do not run them again here; go on with (c).
3. 15.10 (c): one Studio Run: eleven connections `Juo AT` to `Juo SE`, kind, settings, the read-back with `ok` true and the store resolved.
4. 15.10 (d): pause `ingest-poll-subscriptions`.
5. 15.10 (e): the dry run over every store, twelve `backfill dry run` lines (GB included) and the finished line's results.
6. 15.10 (f): the events backfill (unattended, 30 to 90 minutes), then the subscriptions (5 to 15 minutes).
7. 15.10 (g): the checks grouped by store, the two email counts 0.
8. 15.10 (h): resume the schedule; twelve `subscriptions_poll` rows; System health; Sources with every Juo row's last read; Juo NL's Reads panel.
9. 15.11: the customers per store before; one `--adapter shopify --object commerce_customer --from 2000-01-01` (unattended, 1 to 4 hours); the customers after; the `linked_contact` backfill; the subscriptions block again.
10. 15.12: the coverage queries; Reports → Flash with All markets and per market.

Expected: as each block says. Do (c) to (f) before 03:30 or after the reconcile has finished; the morning is fine.

## 6. Browser: Sources with every last read; Flash, All markets

**Browser** (prod, https://workspace.pulse4all.app, as yourself)
1. Configuration → Sources. Expected: every active connection with a Last read: HubSpot and Aircall their `Nightly reconcile` of 03:30 (and HubSpot's `Backfill` or `Link calls (sweep)` where that ran later), the thirteen live Shopify stores their `Nightly reconcile` (NO's among them: a Shopify store without Juo), Shopify CH its reconcile too (an empty store is still read), Trusted Shops Subscriptions `Reviews poll` within the hour, the asset register `Asset register poll` within 15 minutes, every Juo row (twelve) `Subscriptions poll` within 5 minutes; a caption `n reads in 24 hours` under each; no warning badge, or a badge whose title names a `rate_limited` of the night (hover it). Last event: HubSpot, Aircall and the live Shopify stores with their latest events (a store without sales yet may show an older one); the polled rows a dash; Shopify CH a dash (it has a read, no events ever: correct until it sells). Open Juo NL: the Reads panel with the poll's runs, the two backfills and the reconcile, newest first, counts and codes only; open Shopify CH: its nightly reconciles, each with `fetched 0`.
2. Configuration → System health. Expected: unchanged: every source Working, the job rows without Failed.
3. Reports → Flash, All markets. Expected: 15.12's on-screen check; the sources line with Subscriptions read a few minutes ago.

## 7. The Gemini audit (does not block the run)

**Browser:** the Gemini chat of the audits (the pattern of 28 and 29 October 2026). Paste:

```
Audit p4a-cma-prod on 5 November 2026 against the previous audits of 28 and 29 October 2026 (FIND-01 and FIND-02 of 29 October: one accessor binding per Juo secret, the ingest-backfill job unchanged). Since then: twelve secrets stored on the evening of 4 November 2026, one enabled version each, the earlier version of nine of them disabled, no expiry on the secrets or their versions: eleven new secrets ingest-juo-pulse4all-at-key, ingest-juo-pulse4all-be-key, ingest-juo-pulse4all-de-key, ingest-juo-pulse4all-dk-key, ingest-juo-pulse4all-esp-key, ingest-juo-pulse4all-fi-key, ingest-juo-pulse4all-fr-key, ingest-juo-pulse4all-ie-key, ingest-juo-pulse4all-ita-key, ingest-juo-pulse4all-nl-key, ingest-juo-pulse4all-se-key, each with exactly one IAM binding, roles/secretmanager.secretAccessor for serviceAccount:cma-ingest@p4a-cma-prod.iam.gserviceaccount.com, no other member; and the twelfth, ingest-juo-pulse4all-ch-key, with no binding at all (the CH store is not live); no secret for the NO store (it has no Juo yet); nothing else changed in IAM; the ingest-backfill job redeployed from the same image as the other nine jobs with the same service account, pool and schedule (none) as before; four more pulse4all.com accounts gain access to the Workspace behind IAP the same morning, two with the analytics role and two with the admin or analytics role, through the Workspace's own invitation (cma.invitation), not through an IAM change. Check: (1) every ingest-juo-* secret but the CH one has exactly that one binding, the CH one none, and no other principal can read any of them; (2) no new key, role or binding exists on cma-ingest, cma-web, cma-ingest-scheduler or the IAP client; (3) the IAP policy of the Workspace still grants the Google Workspace domain only; (4) Secret Manager data access logging still on; (5) anything else that changed in IAM, Cloud Run or Secret Manager in p4a-cma-prod since 29 October 2026. Report findings as FIND-nn with severity, evidence (the gcloud command and its output), and the fix; do not run any fix.
```

Expected: a report with findings or none; every finding checked as README, How we work, says, and the result in the record. The audit does not block steps 5, 6 or 8.

## 8. Team onboarding: four invitations and the note

**Browser** (prod, People → Invite by email, as an admin): one invitation each, with the role:
- Joshua: `admin` (Decision log, 7 October 2026).
- Kira: `analytics`.
- Bas: `analytics`.
- Mark: `analytics` unless you decide `admin` (your call, this morning); an admin changes a role on People at any time, so either choice is reversible in a minute.

Expected: each invitation listed as sent with its expiry; the invitation link opens behind IAP, so the person signs in with their pulse4all.com Google account first and then accepts (the link works only for that account's address). What each role lands on: Welcome, then the Dashboard and Reports in the rail; the Cockpit handles (Live board, Follow-up, Roster, Team) only for `manager`; `admin` sees Configuration too. The open grant question whether `analytics` holds `monitoring.live` is left as it is (Open decisions); the per-person reports setting `reports.per_person` stands as it is. Then send `TEAM_NOTE.md` (File) to the four, as it is or with your changes.

**Studio (cma-prod-pg)** (read only, after they accepted)
```sql
set role cma_owner;
select u.display_name, u.status, string_agg(r.key, ', ' order by r.key) as roles
from cma.app_user u join cma.tenant t on t.id = u.tenant_id and t.slug = 'pulse4all-subscriptions'
left join cma.user_role ur on ur.tenant_id = u.tenant_id and ur.user_id = u.id
left join cma.app_role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
where u.kind <> 'system' and u.created_at > now() - interval '1 day'
group by 1, 2 order by 1;
reset role;
```
Expected: four rows, `active`, with the roles above. (Names only, as People shows them; nothing else.)

## Rollback

- **The migration** (OPERATIONS 3.5): forward-only; `cma.sources()` of 0008zq is a superset of 52's and `cma.source_reads` a new read, so `main`'s web reads the database unchanged and there is nothing to roll back in it. The web itself rolls back as `docs/RUNBOOK.md` section 10 says; it runs on 0008zq either way.
- **The connections** (OPERATIONS 6): a store whose reads must stop is switched off on Configuration → Sources (`cma.set_connection_status(id, 'inactive')`); the jobs skip it, its rows stay, switching on resumes from its cursors.
- **The schedule** (OPERATIONS 5): `gcloud scheduler jobs pause ingest-poll-subscriptions --location=europe-west4 --project=p4a-cma-prod` stops every store's poll; the nightly reconcile still reads the stores. A key that must stop working: revoke it in Juo's admin of that store and disable the secret's version (OPERATIONS 7); the store's reads fail `key_rejected` until a new key is stored.
- **The ingest image** (OPERATIONS 3.3): the previous image for the ten jobs; `--adapter` is then gone, `--connection` works as before.
