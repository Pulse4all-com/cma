# Legacy time import (addition 0008d)

How the login and logout sessions of an earlier system become workdays in the CMA, in one batch
that can be withdrawn as a unit. For Pulse4all: Steam Connect, 2 January to 9 October 2026, into
Pulse4all Subscriptions (README, Data model: legacy time import; Decision log, 12 October 2026).

What the database does with the file (`cma.load_import_batch`), per person and local login date:

- a session without a logout ends at the tenant's close time (`workday.auto_close_at`, 17:00); one
  that starts at or after it without a logout is dropped;
- every session is clipped to the workday window (`workday.window_start` to `workday.window_end`,
  07:00 to 22:00);
- overlapping sessions are merged; the gaps between sessions are the gap status (Break);
- a date that already has a CMA day is skipped (the CMA's own days win); a day under one minute is
  dropped;
- a day closed by the 17:00 rule or clipped is flagged for review (Team hours, needs correction);
- the import status (Steam session) is seeded inactive and never offered; the load accepts it because
  nothing was ever booked on it.

Rules for the files: the export, the map, the staging file and the person map statement stay in
`~/import` in Cloud Shell, never in `~/cma`, and are deleted after the load (step 11). Real files are
prod only; dev uses the synthetic fixture in `tools/fixtures/`.

Before you start: `50`, `51` and `02` have run in prod (in that order, with `51` passing), and
point-in-time recovery of cma-prod-pg is confirmed. The status is seeded inactive and never offered,
so `02` may run any time before step 1.

---

## 1. A folder outside the repository

**Terminal**
```bash
mkdir -p ~/import && chmod 700 ~/import && ls -la ~/import
```
Upload the export into it (⋮ → Upload, then `mv ~/<file> ~/import/steam-export.csv`).

Expected: the folder lists `steam-export.csv`; `cd ~/cma && git status --short` prints nothing.

## 2. The map

**Terminal**
```bash
cd ~/cma && node tools/legacy-sessions-to-staging.mjs ~/import/steam-export.csv --map-template ~/import/steam-map.csv
```
Expected: `accounts_in_export <n>` and the file path.

**File** `~/import/steam-map.csv` (Cloud Shell editor): fill in `work_email` (the person's email in
the CMA) and `include` (`yes` or `no`) on every row. The other columns are there to recognise the
account and are ignored. An account set to `no`, or a row you delete, is not imported.

## 3. The tenant is ready

**Studio (cma-prod-pg)**
```sql
set role cma_owner;
select s.key, s.name, s.status, s.is_working, s.is_paid,
       cma.setting_of(t.id, 'workday.window_start') as window_start,
       cma.setting_of(t.id, 'workday.window_end') as window_end,
       cma.setting_of(t.id, 'workday.auto_close_at') as close_at
from cma.tenant t join cma.work_status s on s.tenant_id = t.id
where t.slug = 'pulse4all-subscriptions' and s.key in ('legacy_session', 'break')
order by s.key;
reset role;
```
Expected: two rows, `break` (active, not working, not paid) and `legacy_session` (Steam session,
inactive, working, paid), both with 07:00, 22:00 and 17:00.

## 4. The staging file

**Terminal**
```bash
cd ~/cma && node tools/legacy-sessions-to-staging.mjs ~/import/steam-export.csv --map ~/import/steam-map.csv --zone Europe/Amsterdam --batch steam-2026 --out ~/import/staging.csv --map-sql ~/import/person-map.sql
```
Expected: the counts, with `period_from 2026-01-02` and `period_to 2026-10-09` (the first and last
login of an included account), `accounts_absent_from_map 0`, and the two file paths. A refusal
(`refused, nothing written`) names the line: fix the export or the map and run again. The defaults
are Steam's columns and `d-m-yyyy hh:mm:ss`; for another layout see the options at the top of
`tools/legacy-sessions-to-staging.mjs`.

## 5. Stage the batch

**Studio (cma-prod-pg)**
```sql
set role cma_owner;
select t.id as tenant_id, u.id as user_id
from cma.tenant t join cma.app_user u on u.tenant_id = t.id
where t.slug = 'pulse4all-subscriptions' and u.email = 'martin@pulse4all.com';
reset role;
```
Expected: one row. Keep both ids for this step and step 6. Then, with the two ids:

**Studio (cma-prod-pg)**
```sql
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'studio:martin', false);
select key, status, period_from, period_to, timezone
from cma.stage_import_batch('steam-2026', 'steam_connect', 'steam-export.csv',
                            '2026-01-02', '2026-10-09', 'Europe/Amsterdam', 'legacy_session', 'break');
```
Expected: one row of three values, then `steam-2026 | staged | 2026-01-02 | 2026-10-09 |
Europe/Amsterdam`. Use the period step 4 printed. Keep this Studio tab open for steps 7 to 9.

## 6. Copy the sessions in

**Terminal** (the `cma_db` helper from `docs/night-2026-10-10/MORNING_RUNBOOK.md`, Helpers)
```bash
cma_db prod && psql "$PGCONN" -v tenant_id=<tenant_id> -v user_id=<user_id> -f ~/cma/docs/import/copy-staging.psql < ~/import/staging.csv
```
Expected: `connected to cma as martin@pulse4all.com`, `COPY <n>` with `n` = `sessions_written` of
step 4, one row `steam-2026 | <n> | <accounts_written> | 2026-01-02 | 2026-10-09`, `COMMIT`. On an
error nothing is kept (one transaction); fix it and run the line again.

## 7. Write the person map

**File** `~/import/person-map.sql`: open it in the Cloud Shell editor and copy all of it.

**Studio (cma-prod-pg)**, in the tab of step 5: paste and run it.

Expected: `accounts_in_map <a> | rows_written <a> | emails_without_person 0`, with `a` =
`accounts_written` of step 4. It is rerun-safe (a second run writes 0). An email without a person
means that account's sessions are skipped at the load: add the person (Team → People) and run the
statement again, or accept that the load counts them as `accounts_skipped`.

## 8. Before the load: what will be skipped

**Studio (cma-prod-pg)**, in the same tab:
```sql
select count(distinct s.external_person_id) filter (where m.user_id is null) as accounts_without_person,
       count(distinct (m.user_id, s.login_local::date)) filter (where w.id is not null) as days_the_cma_already_has
from cma.import_session s
join cma.import_batch b on b.id = s.batch_id and b.key = 'steam-2026'
left join cma.import_person_map m on m.batch_id = s.batch_id and m.external_person_id = s.external_person_id
left join cma.workday w on w.user_id = m.user_id and w.business_date = s.login_local::date;
```
Expected: `0` accounts without a person, and the number of person-days the CMA already holds (from 5
October 2026); those stay as they are.

## 9. Load

**Studio (cma-prod-pg)**, in the same tab:
```sql
select key, status, loaded_at, jsonb_pretty(counts) as counts from cma.load_import_batch('steam-2026');
```
Expected: `loaded` with the counts: `sessions_in` = step 6's `n`; `accounts_skipped` 0;
`days_skipped_existing` = step 8's second figure; `days_written`, `events_written`,
`days_closed_by_rule`, `days_clipped`, `days_dropped`, `sessions_merged`, `sessions_open_dropped`,
`sessions_outside_window`. A refusal (`CMA03`, `CMA04`) writes nothing and says why: a session in
the spring clock change gap of 29 March, a session outside the period, a status that is not ready.

## 10. Read the result

**Studio (cma-prod-pg)**, in the same tab:
```sql
select u.display_name, count(*) as days, round(sum(s.working_seconds) / 3600.0, 1) as hours,
       count(*) filter (where s.needs_correction) as to_review
from cma.import_day d
join cma.import_batch b on b.id = d.batch_id and b.key = 'steam-2026'
join cma.workday_summary s on s.workday_id = d.workday_id
join cma.app_user u on u.id = d.user_id
group by u.display_name
order by u.display_name;
select key, status from cma.work_status where key = 'legacy_session';
reset role;
```
Expected: one row per imported person with days, hours and days to review; then
`legacy_session | inactive`. Keep the counts of step 9 (not the names) as the record
`records/0008d-import-prod-<date>/load.txt`.

**Browser:** Team hours for a week in the period: the days show as normal days; Correct a day shows
the history as "Imported from an earlier system, batch steam-2026"; Download status changes names
them "Import" under Entered by.

## 11. Delete the files

**Terminal**
```bash
rm -f ~/import/steam-export.csv ~/import/steam-map.csv ~/import/staging.csv ~/import/person-map.sql && rmdir ~/import && ls ~/import
```
Expected: `ls: cannot access '/home/…/import': No such file or directory`.

---

## Withdraw a batch (the void)

The void adds one void correction per effective event of every day the batch wrote (your name as
approver, the reason with the batch key), so nothing is deleted and the history stays. The days then
count nowhere, and the same person-days can be loaded by a new batch.

**Studio (cma-prod-pg)**, after the context block of step 5:
```sql
select key, status, voided_at, counts ->> 'events_voided' as events_voided
from cma.void_import_batch('steam-2026', '<why, 3 to 500 characters>');
reset role;
```
Expected: `steam-2026 | voided | <now> | <events_written of step 9>`. A second void is refused
(`CMA03`).

To load again: steps 1 to 11 with a new key (`--batch steam-2026-2` in step 4, `'steam-2026-2'` in
steps 5 and 7 to 10). The import status stays inactive; the load accepts it because the void left no
effective event in it.
