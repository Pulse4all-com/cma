# Runbook, B17a: email activity data model (0008m), amended with B17b's database half

Labels: **Browser**, **Terminal** (Cloud Shell, in `~/cma` unless stated), **Studio** (the instance named), **File** (a repository path). SQL and shell never share a block. Every step ends with what you should see. Claude Code's local outputs are in `local-records/` (its `README.md` lists them).

**What changes:** the database only. Addition 0008m (`68`, `69`) adds the data model under the email and inbox reports of brief B17: inboxes and source channels with their configuration, classification rules, the CRM's email engagements and the inbox conversations' messages (two source kinds, never added together), the conversations and their assignments, closes, reopens and moves, the four settings `email.start_date`, `email.reply_target_minutes`, `email.no_response_days` and `email.market_order`, the ingest writes, the market of an email by `email.market_order` (contact, form, record, inbox), and the privacy deletions. Amended in place before it ran (brief B17b's database half): a contact's country in ordered slots with `crm_contact.country_source`, contacts held for emails and inbox threads, and the data-quality check `contact_country_fallback`. Metadata only: no subject, body, address, name or raw actor id is stored (README, Data model: email activity; Decision log, 15 October 2026). Nothing fills the tables yet: the email poll comes with B17b, the reports with B17c.

**Order matters:**
- 0008l (`66`) must have run first; without it `68` stops with `addition 0008l (66_invitations.sql) must run before 0008m` and applies nothing. It runs in dev and prod (`records/0008l-*`).
- No web change: the merge builds nothing (`db/`, `docs/` and `README.md` do not build). B17c's web merge, later, needs 0008m in dev and prod first.
- The data map: `verify:datamap` fails on this branch until step 4 refreshes `docs/datamap/schema.json` from dev, after 0008m ran there; that is expected (CLAUDE.md, Database).
- `68` sets `country_source` to 1 on every stored contact with a country (an audit row each; in prod the contacts deals and tickets hold) and replaces the contact upsert, the field mapping and the data-quality reads. No country slot is configured: contacts stay as they are until B17b's ingest reads slot 2.
- No seed rerun: `02` is unchanged (Pulse4all runs on the defaults until Arno and Kira confirm them; README, Open decisions).
- No script that has run in prod changes in this pull request.
- The email poll in prod (B17b's `PROD_RUNBOOK.md` phase 10) waits for Yordi's answer on email metadata and the new scopes (README, Open decisions). The migration itself stores nothing and may run in prod before that.

| Step | What | Elapsed |
|---|---|---|
| 1 | Review the pull request | 10 min |
| 2 | 0008m in dev with its verify | 10 min |
| 3 | A read-only check in dev | 5 min |
| 4 | The data map: snapshot from dev, rebuild, push | 10 min |
| 5 | 0008m in prod, a read-only check | 10 min |
| 6 | Merge | 5 min |

---

## Helpers (define in every new Cloud Shell)

The helpers `cma_db` and `run_migration` of `docs/night-2026-10-13/MORNING_RUNBOOK.md`, section Helpers, unchanged: paste that block first.

Expected: `type cma_db run_migration` prints both functions.

## 1. Review the pull request

**Browser:** GitHub → Pulse4all-com/cma → Pull requests → "B17a: email activity data model (0008m)". Read the description and the diff.

Expected: in `db/` only the new `68_email_activity.sql` and `69_verify_email_activity.sql`; `README.md`, `docs/datamap/catalog.json` and `docs/b17a-email-data/`; no change to `web/`, `ingest/`, `hubspot/`, `cloudbuild.yaml` or `records/`; no script that has run in prod changes.

**Terminal** (the pull request's number from the page)
```bash
cd ~/cma && gh pr checkout <number> && git log --oneline -1 && ls db/68_email_activity.sql db/69_verify_email_activity.sql
```
Expected: the branch's last commit, then both file names. **Do not merge yet.**

## 2. Addition 0008m in dev

**Terminal** (still on the pull request's branch)
```bash
run_migration dev 68_email_activity.sql 69_verify_email_activity.sql 0008m-dev-$(date +%F) 33_verify_intake_core.sql 35_verify_telephony.sql 41_verify_lead_metrics.sql 53_verify_sources_configuration.sql
```
Expected: `connected to cma as martin@pulse4all.com`; the last lines of `68` are `INSERT 0 1`, `COMMIT`, `RESET` (no `ERROR`); `69` ends with `B22 tenant isolation for contacts, slots and the fallback check, also against the owner's view | PASS`, the verdict row `verdict | PASS | 29 PASS, 0 FAIL`, `(30 rows)`, `DROP FUNCTION`, `RESET`; `provoked FAIL lines: 30` (the 29 checks and the verdict's count) and the verdict `PROVOKED, NOT A PASS | 0 PASS, 29 FAIL`; `33_verify_intake_core.sql: 2 PASS rows`, `35_verify_telephony.sql: 2 PASS rows`, `41_verify_lead_metrics.sql: 2 PASS rows` (its fifteen data-quality checks unchanged), `53_verify_sources_configuration.sql: 17 PASS rows` (its 16 checks and the verdict). A `REFUSED` line means the session is not on dev: check `cma_db dev`. Any other `FAIL` row: send me its line.

Should you rerun `04`, `07`, `10` or `14` in dev, they list what 0008m adds and nothing else changes: `04` the six tables (owner, row-level security, the tenant policy, audit) and `cma_read.dq_contact_country_fallback` among the views; `07` and `10` the `0008m` row (its long description widens the column, so every row of that listing re-flows); `14` the four settings with `email.market_order = contact,form,record,inbox (default)` (`local-records/db/earlier-verifies/`).

**Terminal** (`68` again)
```bash
rec=records/0008m-dev-$(date +%F); psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/68_email_activity.sql > "$rec/68-rerun.txt" 2>&1; tail -3 "$rec/68-rerun.txt"
```
Expected: `INSERT 0 0`, `COMMIT`, `RESET`.

## 3. A read-only check in dev

**Studio (cma-dev-pg)** (the addition, the settings, the empty tables, the connections' kinds; ids, counts and keys only)
```sql
set role cma_owner;
select version, applied_by from cma.schema_migration where version = '0008m';
select key, value_type, default_value from cma.setting where key like 'email.%' order by key;
select (select count(*) from cma.connection_inbox) as inboxes, (select count(*) from cma.connection_inbox_channel) as channels,
       (select count(*) from cma.connection_email_rule) as rules, (select count(*) from cma.email_message) as emails,
       (select count(*) from cma.email_thread) as threads, (select count(*) from cma.email_thread_event) as events;
select t.slug, c.adapter, c.kind, c.status from cma.integration_connection c join cma.tenant t on t.id = c.tenant_id order by 1, 2;
select count(*) filter (where country is not null) as with_country, count(*) filter (where country_source = 1) as from_slot_1,
       count(*) filter (where country_source > 1) as from_fallback,
       (select count(*) from cma.connection_field where entity = 'contact' and field = 'country' and slot > 1) as fallback_slots
from cma.crm_contact;
reset role;
```
Expected:
- one `0008m` row with your login;
- four settings: `email.market_order | text | contact,form,record,inbox`, `email.no_response_days | integer | 5`, `email.reply_target_minutes | integer | 240`, `email.start_date | text |` (empty);
- `0 | 0 | 0 | 0 | 0 | 0`: nothing fills the tables before B17b (the verify's throwaway tenants were rolled back);
- the connections with the kinds they had before (0008m changes no kind);
- `with_country` equal to `from_slot_1`, then `0 | 0`: every stored country came from slot 1, and no fallback slot is configured.

## 4. The data map: snapshot from dev, rebuild, push

`docs/datamap/README.md`, Refreshing the snapshot, on this branch. **Terminal** (first tab; leave it running)
```bash
cloud-sql-proxy --auto-iam-authn --port 5433 p4a-cma-dev:europe-west4:cma-dev-pg
```
Expected: `The proxy has started successfully and is ready for new connections!` (when `cma_db dev` already runs a proxy on 5433, skip this block).

**Terminal** (second tab, in `~/cma`)
```bash
psql "host=127.0.0.1 port=5433 dbname=cma user=$(gcloud config get-value account) sslmode=disable" -v ON_ERROR_STOP=1 -qAt -f tools/datamap/schema.sql > docs/datamap/schema.json && grep -o '"latest_migration" : "[^"]*"' docs/datamap/schema.json
```
Expected: `"latest_migration" : "0008m"`.

**Terminal** (`~/cma`)
```bash
node tools/datamap/build.mjs && node tools/datamap/build.mjs --check
```
Expected: `datamap: wrote docs/datamap/index.html (72 tables, 89 views)`, then `datamap: 72 tables, 89 views, all described; index.html current` (Claude Code's check against its local schema at 0008m: `local-records/db/datamap-check-local-schema.txt`, 72 tables and 89 views: the six email tables and their six views, and `dq_contact_country_fallback`). Other counts mean dev differs from the scripts: send me the line. A problem list names what the catalog lacks: send it to me.

**Terminal** (`~/cma`)
```bash
git add docs/datamap && git commit -m "Data map: snapshot after 0008m" && git push
```
Expected: the push names this pull request's branch.

## 5. Addition 0008m in prod

**Terminal** (point-in-time recovery on, as before every prod migration)
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.backupConfiguration.transactionLogRetentionDays)"
```
Expected: `True	7`.

`69` and `53` refuse prod (they write throwaway tenants and run in dev only), so prod runs the migration twice and `33`, `35` and `41`, then a read-only check. `68` changes three checks (`crm_association` takes `crm_email`, `sync_run` takes `email_poll`, `connection_field` takes the country's slots), adds `crm_contact.country_source` (set to 1 on every stored contact with a country, an audit row each) and replaces nine functions in one transaction; the ingest's writes wait for it a moment and carry on.

**Terminal**
```bash
rec=records/0008m-prod-$(date +%F); mkdir -p "$rec" && cma_db prod && psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/68_email_activity.sql > "$rec/68.txt" 2>&1; tail -3 "$rec/68.txt"; psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/68_email_activity.sql > "$rec/68-rerun.txt" 2>&1; tail -3 "$rec/68-rerun.txt"
for f in 33_verify_intake_core.sql 35_verify_telephony.sql 41_verify_lead_metrics.sql; do psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$f" > "$rec/${f%%_*}-rerun.txt" 2>&1; echo "$f: $(grep -cE '\| PASS' "$rec/${f%%_*}-rerun.txt") PASS rows"; done
```
Expected: `connected to cma as martin@pulse4all.com`; `INSERT 0 1`, `COMMIT`, `RESET`; then `INSERT 0 0`, `COMMIT`, `RESET`; `33_verify_intake_core.sql: 2 PASS rows`, `35_verify_telephony.sql: 2 PASS rows`, `41_verify_lead_metrics.sql: 2 PASS rows`.

**Studio (cma-prod-pg)** (read only: the addition, the settings, the empty tables, the connections' kinds, and the market function on nothing)
```sql
set role cma_owner;
select version, applied_at, applied_by from cma.schema_migration where version = '0008m';
select key, value_type, default_value from cma.setting where key like 'email.%' order by key;
select (select count(*) from cma.email_message) as emails, (select count(*) from cma.email_thread) as threads,
       (select count(*) from cma.connection_inbox) as inboxes;
select t.slug, c.adapter, c.kind, c.status from cma.integration_connection c join cma.tenant t on t.id = c.tenant_id order by 1, 2;
select t.slug, cma.email_start_date_of(t.id) as email_start, cma.setting_of(t.id, 'intake.start_date') as intake_start from cma.tenant t order by 1;
select count(*) filter (where country is not null) as with_country, count(*) filter (where country_source = 1) as from_slot_1,
       count(*) filter (where country_source > 1) as from_fallback
from cma.crm_contact;
select t.slug, (select count(*) from cma.data_quality_of(t.id) q where q.check_key = 'contact_country_fallback') as fallback_findings
from cma.tenant t order by 1;
reset role;
```
Expected:
- one `0008m` row with today's time and your login;
- the same four settings as in dev;
- `0 | 0 | 0`;
- the connections with the kinds they had before;
- per tenant `email_start` equal to `intake_start` (`2026-10-01` unless a tenant's intake start was changed): the email start follows `intake.start_date` while `email.start_date` is empty;
- `with_country` equal to `from_slot_1`, and `from_fallback` 0 (counts only);
- `0` fallback findings for both tenants (no slot 2 yet, so the Data page does not list the check).

## 6. Merge

**Terminal**
```bash
cd ~/cma && gh pr merge <number> --squash --delete-branch && git switch main -q && git pull -q && git log --oneline -1
```
Expected: the merge commit. No build starts (nothing under `web/` or `cloudbuild.yaml` changed), so there is nothing to watch.

Send me the outputs of steps 2, 3 and 5 (ids, counts, dates and times only); records go in a separate pull request, written from your report.
