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
- the import status (Steam session) is seeded inactive and never offered; the load accepts it as long as
  no effective time in it lies on a day that no import batch wrote, so every later batch reuses it, and time
  clocked live never lands in it (addition 0008zh).

Rules for the files: the export, the map, the staging file and the person map statement stay in
`~/import` in Cloud Shell, never in `~/cma`, and are deleted after the load (step 11). Real files are
prod only; dev uses the synthetic fixture in `tools/fixtures/`.

Before you start: `48` (0008c), `50` (0008d), `51` and `02` have run in prod, in that order, with
`51` passing; `48` must be in before `50`, because 0008d needs 0008c. Point-in-time recovery of
cma-prod-pg is confirmed. The status is seeded inactive and never offered, so `02` may run any time
before step 1. Every person whose hours are imported exists in the tenant (People, below).

Studio does not keep `set_config` between runs: each run may get a new session, so `app.tenant_id`
and `app.user_id` set in one run are gone in the next. Every Studio block of steps 5 and 7 to 10 (and
the void) therefore starts with the context block, shown in each block; run the block as a whole.
The two ids come from the first query of step 5. The context block returns one row of three values;
each step's expected output follows it.

## People for the imported hours

Every included account of the map needs a person in the tenant (Team → People → Add a person): role
`agent` for agents, login system Google, and the account id at the provider. The account id is the
Google account's stable numeric id (README, Authentication), never the email address and not the key
in the Admin console's address. A Workspace admin reads the ids for many people at once with the
Directory API:

**Browser:** the Admin SDK Directory API reference for `users.list` (developers.google.com, Admin
SDK, Directory API, `users.list`), Try this API, signed in as a Workspace admin, with `customer`
`my_customer`, `maxResults` `500` and `fields` `users(primaryEmail,id,orgUnitPath,suspended)`.

Expected: one entry per account with `primaryEmail`, `id` (digits only), `orgUnitPath` and
`suspended`. Use `id` as the account id; leave out suspended accounts. The ids are pasted into the
People screen, never into a file in the repository or a chat. A person added for the import has
access as soon as the gate admits their account (README, Authentication).

---

## 1. A folder outside the repository

**Terminal**
```bash
mkdir -p ~/import && chmod 700 ~/import && ls -la ~/import
```
Upload the export into it (⋮ → Upload, then `mv ~/<file> ~/import/steam-export.csv`).

Expected: the folder lists `steam-export.csv`; `cd ~/cma && git status --short` prints nothing.

## 2. The map

Skip this step when the map is already filled (`~/import/steam-map.csv` from an earlier run); go to
step 3. The map may carry extra columns (the template's, or your own notes): only `steam_pid`,
`work_email` and `include` are read.

**Terminal**
```bash
cd ~/cma && node tools/legacy-sessions-to-staging.mjs ~/import/steam-export.csv --map-template ~/import/steam-map.csv
```
Expected: `accounts_in_export <n>` and the file path.

**File** `~/import/steam-map.csv` (Cloud Shell editor): fill in `work_email` (the person's email in
the CMA) and `include` (`yes` or `no`) on every row. The other columns are there to recognise the
account and are ignored. An account set to `no`, or a row you delete, is not imported. Accounts that
are not agent hours (management accounts, for Pulse4all five in the Steam export) are left out:
deleted from the map or set to `no`.

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
login of an included account), `accounts_absent_from_map` equal to the number of accounts you
deliberately deleted from the map in step 2 (`accounts_excluded` for those set to `no`), and the two
file paths. A refusal (`refused, nothing written`) names the line: fix the export or the map and
run again. The defaults are Steam's columns and `d-m-yyyy hh:mm:ss`; for another layout see the
options at the top of `tools/legacy-sessions-to-staging.mjs`.

A refusal `session id <id> appears twice`: Steam's export can hold one session twice, the same
session id and login on both rows, the second with a later logout that contains the first (the
Pulse4all export had 11). Check the pairs first: open `~/import/steam-export.csv` in the Cloud Shell
editor at the lines the refusal names (the later row of each pair; up to 20 are listed), search for
the earlier row with the same session id, and confirm that each pair has the same account and login. Then run the line above again with `--dedupe-sessions latest-logout` at the end:
per session id the row with the latest logout is kept (a row without a logout counts as latest).
This changes no hours, because the load merges overlapping sessions. Expected: the counts as above
plus `sessions_deduplicated` equal to the number of extra rows (11 for 11 pairs). A pair whose rows
differ in account or login is still refused (`appears twice with another account or login`): that
is not a duplicate; fix the export.

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
Europe/Amsterdam`. Use the period step 4 printed. Keep the two ids at hand for the context block
of steps 7 to 10.

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

**Studio (cma-prod-pg)**: the context block, then the statement of the file pasted below it; run
both together.
```sql
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'studio:martin', false);
-- paste the contents of ~/import/person-map.sql here
```

Expected: `accounts_in_map <a> | rows_written <a> | emails_without_person 0`, with `a` =
`accounts_written` of step 4. It is rerun-safe (a second run writes 0). An email without a person
means that account's sessions are skipped at the load: add the person (Team → People) and run the
statement again, or accept that the load counts them as `accounts_skipped`.

## 8. Before the load: what will be skipped

**Studio (cma-prod-pg)**
```sql
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'studio:martin', false);
select count(distinct s.external_person_id) filter (where m.user_id is null) as accounts_without_person,
       count(distinct (m.user_id, s.login_local::date)) filter (where w.id is not null) as days_the_cma_already_has
from cma.import_session s
join cma.import_batch b on b.id = s.batch_id and b.key = 'steam-2026'
left join cma.import_person_map m on m.batch_id = s.batch_id and m.external_person_id = s.external_person_id
left join cma.workday w on w.user_id = m.user_id and w.business_date = s.login_local::date;
```
Expected: `0` accounts without a person, and the number of person-days the CMA already holds (from 5
October 2026); those stay as they are. On a first import for people who are new in the CMA (added
for the import, never clocked in), `days_the_cma_already_has` is `0`.

## 9. Load

**Studio (cma-prod-pg)**
```sql
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'studio:martin', false);
select key, status, loaded_at, jsonb_pretty(counts) as counts from cma.load_import_batch('steam-2026');
```
Expected: `loaded` with the counts: `sessions_in` = step 6's `n`; `accounts_skipped` 0;
`days_skipped_existing` = step 8's second figure; `days_written`, `events_written`,
`days_closed_by_rule`, `days_clipped`, `days_dropped`, `sessions_merged`, `sessions_open_dropped`,
`sessions_outside_window`. A refusal (`CMA03`, `CMA04`) writes nothing and says why: a session in
the spring clock change gap of 29 March, a session outside the period, a status that is not ready.

## 10. Read the result

**Studio (cma-prod-pg)**
```sql
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'studio:martin', false);
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
`legacy_session | inactive`. Keep the counts of step 9, the batch key, the period and the times
(not the names, emails or Steam ids) as the record `records/0008d-import-prod-<date>/load.txt`.

**Browser:** Team hours for a week in the period: the days show as normal days; Correct a day shows
the history as "Imported from an earlier system, batch steam-2026"; Download status changes names
them "Import" under Entered by.

## 11. Delete the files

**Terminal**
```bash
rm -rf ~/import && ls ~/import
```
Expected: `ls: cannot access '/home/…/import': No such file or directory`. The whole folder goes, so a
cleaned or renamed copy of the export goes too.

**Browser:** on the laptop, delete every downloaded copy of the export, the map or the staging file
(Downloads, and empty the bin).

---

## A weekly batch

Each week's export is loaded as a batch of its own, into the status the first batch used, after the
tenant's people are in place (People, above). The steps are 1 to 11 above with the changes below; every
Studio block starts with the context block, as in steps 5 and 7 to 10. A weekly batch needs `110`
(0008zh) and `111` run in prod, `111` returning `PASS`: before it, the load refuses the status
`legacy_session` once it holds the first batch's days (`CMA04`).

- **Batch key** `steam-<yyyy>-w<ww>`: the ISO year and ISO week number of the week's first login, the
  number with two digits (`steam-2026-w43`). A batch that is voided and loaded again takes the key with
  `-2` (`steam-2026-w43-2`), as in the void section.
- **Status** `legacy_session` stays the work status of step 5 and `break` the gap status. The load
  refuses an inactive status only when it holds effective time on a workday that no import wrote. The
  days of earlier batches, with the corrections made to them since, do not count; a day clocked live in
  the status would, and the load then refuses with `inactive and has time recorded in it on days no
  import wrote`. `legacy_session_w42`, the one-off status of the week of 12 to 18 October 2026, is not
  used again.
- **Session ids** `--session-id-from person-login` on step 4: a weekly export has no session id column,
  so the tool derives `<person id>@<login as in the file>` for every row. If two rows of one account
  have the same login text, the ids collide and the tool refuses, writes nothing and names the lines
  (`lines 12, 40: one account and login give the same session id`). Open the export at those lines: if they
  are the same session twice, delete the shorter row in your copy (the load would merge them anyway),
  and run the line again; the check covers every row of the export, also those of accounts the map leaves out. The option is not combined with `--dedupe-sessions`.
- **Period** the week's first to last login: the `period_from` and `period_to` that step 4 prints (the
  first and last login of an included account), not the calendar week. Use them in step 5. The period
  must have ended: the last login day is before today.

**2. The map, rebuilt.** The accounts are the same people from week to week, so the map is not made
from scratch: it is read from the person map of the latest loaded batch.

**Studio (cma-prod-pg)**
```sql
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'studio:martin', false);
select m.external_person_id as steam_pid, u.email as work_email, 'yes' as include
from cma.import_person_map m
join cma.app_user u on u.tenant_id = m.tenant_id and u.id = m.user_id
where m.batch_id = (select b.id from cma.import_batch b
                    where b.source_system = 'steam_connect' and b.status = 'loaded'
                    order by b.loaded_at desc limit 1)
order by m.external_person_id;
reset role;
```
Expected: after the context block's row of three values, one row per person of the last batch with
`steam_pid`, `work_email` and `include` = `yes`. Download the result as CSV, upload it to Cloud Shell as
`~/import/steam-map.csv` and check that its header reads `steam_pid,work_email,include`. An account in
this week's export that is not in the map is dropped and counted (`accounts_absent_from_map`): add its
row by hand, with the person added first (People), if it belongs in the import. The file holds emails and
goes in step 11 with the rest.

**4. The staging file**

**Terminal**
```bash
cd ~/cma && node tools/legacy-sessions-to-staging.mjs ~/import/steam-export.csv --map ~/import/steam-map.csv --zone Europe/Amsterdam --batch steam-<yyyy>-w<ww> --session-id-from person-login --out ~/import/staging.csv --map-sql ~/import/person-map.sql
```
Expected: the counts, with `sessions_written` above 0, `sessions_deduplicated 0`, `period_from` and
`period_to` the week's first and last login, `accounts_written` the number of people with sessions
that week (at most the rows of the map), and the two file paths.

**5. Stage the batch**: the block of step 5 with `'steam-<yyyy>-w<ww>'`, `'legacy_session'`, `'break'`
and the two dates step 4 printed. Expected: `steam-<yyyy>-w<ww> | staged | <period_from> | <period_to> |
Europe/Amsterdam`.

**6. Copy the sessions in**: as step 6. Expected: `COPY <n>` with `n` = `sessions_written`, one row
`steam-<yyyy>-w<ww> | <n> | <accounts_written> | <period_from> | <period_to>`, `COMMIT`.

**7. The person map**: as step 7. Expected: `accounts_in_map <a> | rows_written <a> | emails_without_person 0`,
`a` = `accounts_written` of step 4.

**8. Before the load**: the query of step 8 with `b.key = 'steam-<yyyy>-w<ww>'`. Expected: `0` accounts
without a person, and in `days_the_cma_already_has` the person-days of this week that agents clocked in
themselves in the CMA (the periods of weekly batches do not overlap, so no earlier batch's day is in
it). Those days stay as they are: the load skips them (the CMA's own days win) and counts them in
`days_skipped_existing`, which equals this figure. A figure above 0 is normal when agents already
use the CMA.

**9. Load**: the block of step 9 with the batch key. Expected: `loaded` with the counts as in step 9:
`sessions_in` = step 6's `n`, `accounts_skipped` 0, `days_skipped_existing` = step 8's second figure,
and the other counts. `CMA04` naming `legacy_session` means time was booked in that status outside an
import: stop and report it, do not move the batch to another status.

**10. Read the result**: the block of step 10 with the batch key. Expected: one row per person with days,
hours and days to review (days closed at 17:00 or clipped to 22:00), then `legacy_session | inactive`.
Write the counts, the batch key, the period and the times (no names, emails or Steam ids) down as
`records/0008d-import-prod-w<ww>/load.txt`, as for the first batches.

**11. Delete the files**: as step 11, so the map file with its emails goes too. Expected:
`ls: cannot access '/home/…/import': No such file or directory`.

---

## Withdraw a batch (the void)

The void adds one void correction per effective event of every day the batch wrote (your name as
approver, the reason with the batch key), so nothing is deleted and the history stays. The days then
count nowhere, and the same person-days can be loaded by a new batch.

**Studio (cma-prod-pg)**
```sql
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'studio:martin', false);
select key, status, voided_at, counts ->> 'events_voided' as events_voided
from cma.void_import_batch('steam-2026', '<why, 3 to 500 characters>');
reset role;
```
Expected: `steam-2026 | voided | <now> | <events_written of step 9>`. A second void is refused
(`CMA03`).

To load again: steps 1 to 11 with a new key (`--batch steam-2026-2` in step 4, `'steam-2026-2'` in
steps 5 and 7 to 10). The import status stays inactive; the load accepts it because the void left no
effective event in it, and because no effective time in it lies on a day no import wrote.
