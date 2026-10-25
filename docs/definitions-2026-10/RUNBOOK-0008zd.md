# Runbook, the tag meaning incorrect data (addition 0008zd, `102`, `103`)

Labels:
- **Browser**: a page or a click path.
- **Terminal**: Martin's own Linux terminal (Chromebook Linux or his Linux machine), in `~/cma` on the pull request's branch unless stated, with the helper `cma_db` (`docs/RUNBOOK.md`, section 1, step 8). A step against prod (`p4a-cma-prod`, `cma-prod-pg`) runs from the Chromebook only.
- **Studio**: Cloud SQL Studio, on the instance named. Check the instance in Studio's breadcrumb before every Run.
- **File**: a repository path.

SQL and shell never share a block. Every Studio block reads counts, codes, settings and tag names (configuration) only, never a customer row (README, Where a command runs); each starts with `set role cma_owner;` and ends with `reset role;`. Every step ends with what you should see. Claude Code's local outputs are in `local-records/0008zd/`, and its `README.md` lists them.

**What changes** (docs/definitions.md: Tag, Conversation):
- A tag can mean **Incorrect data** (Onjuiste gegevens): the contact data is wrong (a wrong number, incorrect data). Like Not reached, a call carrying a current tag of that meaning is never a conversation; Connected does not change. A tag keeps one meaning.
- `102` adds `incorrect_data` to the meaning's check and to `cma.set_telephony_tag_meaning`, and `cma.tag_meaning_excludes_conversation` names the two meanings that exclude a call, read by `cma.call_not_reached_of`. Nothing is renamed and no read changes its columns, so the web of `main` runs unchanged on the new database, and `102` can run in prod before the merge.
- The web offers Incorrect data in the Meaning select on Configuration → Sources, Tags; the Tags card, the Meaning hint and the Conversation hints name it. The notice "No tag means not reached yet…" still looks at Not reached only.
- Figures: none moves when `102` runs. Step 7 gives the "Wrong Number" and "Incorrect Data" tags the meaning Incorrect data. They have no meaning in prod today (`records/step1-dev-prod-2026-10-25.md` in this folder, step 11: they stayed None until 0008zd), so from step 7 on their calls of 30 seconds and more stop counting as conversations, in every period: Conversations on Reports → Calls and Calls per agent, the Attempts reports, First orders and Email's not-responding deals go down by those calls. Reporting them apart is definitions step 2 (gap D32).
- No `cloudbuild.yaml` change, no environment variable, no ingest change, no HubSpot or Aircall change.

| Step | What | Elapsed |
|---|---|---|
| 0 | Review the pull request, build it, check the additions | 10 min |
| 1 | Dev: `102` twice with the fingerprint | 5 min |
| 2 | Dev: `103` normal and provoked | 3 min |
| 3 | Dev: `101` again | 2 min |
| 4 | The data map: snapshot from dev, rebuild, push | 5 min |
| 5 | Prod: point-in-time recovery, `102` twice with the fingerprint | 5 min |
| 6 | Prod: merge, watch the build | 15 min |
| 7 | Prod: tell Kira and Arno; Configuration → Sources, the tags 1.4 and 1.5 to Incorrect data | 10 min |

---

## 0. Review the pull request, build it, check the additions

**Browser:** GitHub → Pulse4all-com/cma → Pull requests → "Definitions: the tag meaning incorrect data (0008zd)". Read the description and the diff.

Expected: in `db/`, the new `102_tag_meaning_incorrect_data.sql` and `103_verify_tag_meaning_incorrect_data.sql` and `101` amended (A2: seven keys); under `web/`, the copy, the meaning list, the mock's rule and the verifiers; the docs and `local-records/0008zd/`; nothing under `cloudbuild.yaml`, `ingest/`, `records/` or `hubspot/`.

**Terminal** (the pull request's number from the page)
```bash
cd ~/cma && gh pr checkout <number> && cd web && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run build > /tmp/build.txt 2>&1; echo "build exit: $?"; npm run typecheck 2>&1 | tail -1; npm run verify:reports 2>&1 | tail -1; npm run verify:metrics 2>&1 | tail -1; cd ~/cma
```
Expected: `found 0 vulnerabilities` (or the known advisories of Open decisions), `build exit: 0`, `✓ Types generated successfully`, `ALL 186 PASS`, `ok`.

**Do not merge yet.**

**Studio (cma-dev-pg)** and **Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select version, applied_at from cma.schema_migration where version >= '0008zc' order by 1;
reset role;
```
Expected on both instances: `0008zc` only. Without it, run `docs/definitions-2026-10/RUNBOOK.md` first. With `0008zd` already there, stop and tell me.

## 1. Dev: `102` twice with the fingerprint

**Studio (cma-dev-pg)** (read only: the fingerprint of the functions, views, tables, the meaning's keys and the additions)
```sql
set role cma_owner;
select (select count(*) from pg_proc p where p.pronamespace in ('cma'::regnamespace, 'cma_read'::regnamespace)) as functions,
       (select md5(string_agg(p.oid::regprocedure::text || pg_get_functiondef(p.oid), '' order by p.oid::regprocedure::text))
          from pg_proc p where p.pronamespace in ('cma'::regnamespace, 'cma_read'::regnamespace) and p.prokind = 'f') as functions_md5,
       (select count(*) from pg_class c where c.relkind = 'v' and c.relnamespace in ('cma'::regnamespace, 'cma_read'::regnamespace)) as views,
       (select count(*) from pg_class c where c.relkind = 'r' and c.relnamespace = 'cma'::regnamespace) as tables,
       (select count(*) from pg_constraint c
          cross join lateral regexp_matches(pg_get_constraintdef(c.oid), '''[a-z_]+''', 'g') m
         where c.conrelid = 'cma.telephony_tag'::regclass and c.conname = 'telephony_tag_meaning_check') as meaning_keys,
       (select string_agg(m.version, ' ' order by m.version) from cma.schema_migration m where m.version >= '0008zc') as additions;
reset role;
```
Expected: one row, `meaning_keys` 6, `additions` `0008zc`. Write down `functions`, `views` and `tables` (locally 519, 126 and 85).

**Terminal**
```bash
cma_db dev && psql "$PGCONN" -X -v ON_ERROR_STOP=1 -f db/102_tag_meaning_incorrect_data.sql > /tmp/102.txt 2>&1; tail -4 /tmp/102.txt
```
Expected: `connected to cma as martin@pulse4all.com`, then `INSERT 0 1`, `COMMIT`, `RESET`. `addition 0008zc (100_definitions_calls.sql) must run before 0008zd` means step 0 found no `0008zc`.

**Studio (cma-dev-pg):** the fingerprint block again.

Expected: `functions` 1 more (`cma.tag_meaning_excludes_conversation`), `views` and `tables` the same, `meaning_keys` 7, `additions` `0008zc 0008zd` (locally 520, 126 and 85). Write down `functions_md5`.

**Terminal:** the block above again. Expected: `INSERT 0 0`, `COMMIT`, `RESET`.

**Studio (cma-dev-pg):** the fingerprint block again.

Expected: the same row, `functions_md5` included: the second run adds nothing (locally `local-records/0008zd/db/fingerprint-after-102.txt` and `-rerun.txt`).

## 2. Dev: `103` normal and provoked

**Terminal**
```bash
cma_db dev && psql "$PGCONN" -X -v ON_ERROR_STOP=1 -f db/103_verify_tag_meaning_incorrect_data.sql > /tmp/103.txt 2>&1; tail -20 /tmp/103.txt
```
Expected: rows `A1` to `A4` and `B1` to `B8`, each `PASS`, and the verdict `PASS`, 12 PASS. `REFUSED: the connected database is not dev` means `PGCONN` points at prod. Any `FAIL`: send me the row.

**Terminal** (the same script with the provoke switch on, written to `/tmp`)
```bash
sed "s/'verify.provoke', 'false'/'verify.provoke', 'true'/" db/103_verify_tag_meaning_incorrect_data.sql > /tmp/103-provoked.sql && cma_db dev && psql "$PGCONN" -X -f /tmp/103-provoked.sql > /tmp/103-provoked.txt 2>&1; tail -20 /tmp/103-provoked.txt
```
Expected: every row `FAIL`, the verdict `PROVOKED, NOT A PASS`, 0 PASS, 12 FAIL. Block B rolls back.

## 3. Dev: `101` again

**Terminal**
```bash
cma_db dev && psql "$PGCONN" -X -v ON_ERROR_STOP=1 -f db/101_verify_definitions_calls.sql > /tmp/101.txt 2>&1; tail -26 /tmp/101.txt
```
Expected: rows `A1` to `A6` and `B1` to `B12`, each `PASS`, the verdict `PASS`, 18 PASS. A2 is amended for 0008zd (its header says so): it checks the seven keys, and on a database without `102` it fails.

## 4. The data map: snapshot from dev, rebuild, push

**Terminal** (on this branch)
```bash
cd ~/cma && cma_db dev && psql "$PGCONN" -X -qAt -v ON_ERROR_STOP=1 -f tools/datamap/schema.sql > docs/datamap/schema.json && node tools/datamap/build.mjs && node tools/datamap/build.mjs --check
```
Expected: `connected to cma as martin@pulse4all.com`, then `datamap: wrote docs/datamap/index.html (85 tables, 117 views)` and `datamap: 85 tables, 117 views, all described; index.html current` (dev's counts when dev holds no table of its own). The snapshot's `latest_migration` reads `0008zd`; no column changes, so only its stamp and `latest_migration` move.

**Terminal**
```bash
git add docs/datamap && git commit -m "Data map: snapshot from dev at 0008zd, rebuilt" && git push
```
Expected: the push names this branch.

## 5. Prod: point-in-time recovery, `102` twice with the fingerprint

`102` renames nothing, so it can run during office hours and before the merge; the web of `main` runs unchanged on it.

**Terminal**
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format='value(settings.backupConfiguration.pointInTimeRecoveryEnabled)'
```
Expected: `True`. Otherwise stop. Write down the time: it is the point to recover to if `102` must be undone.

**Studio (cma-prod-pg):** the block of step 0 again. Expected: `0008zc` only.

**Studio (cma-prod-pg):** the fingerprint block of step 1. Write down the row.

**Terminal**
```bash
cma_db prod && psql "$PGCONN" -X -v ON_ERROR_STOP=1 -f db/102_tag_meaning_incorrect_data.sql > /tmp/102-prod.txt 2>&1; tail -4 /tmp/102-prod.txt
```
Expected: `connected to cma as martin@pulse4all.com`, then `INSERT 0 1`, `COMMIT`, `RESET`.

**Studio (cma-prod-pg):** the fingerprint; **Terminal:** the block above again (`INSERT 0 0`); **Studio (cma-prod-pg):** the fingerprint again.

Expected: `functions` 1 more than before, `meaning_keys` 7, `additions` `0008zc 0008zd`, the same counts and `functions_md5` as dev's in step 1, and the same row after the second run. A `functions_md5` that differs from dev's with the same counts: `tools/drift/functions.sql` names the functions that differ (`docs/RUNBOOK.md`, 7b).

No verify runs in prod: `103` and `101` refuse a database without the dev seed.

## 6. Prod: merge, watch the build

**Browser:** the pull request → Squash and merge. Then Cloud Build (`p4a-cma-prod`) → History: the `cma-web-main` build of the merge.

Expected: `SUCCESS`, the new `cma-web` revision serving (`docs/RUNBOOK.md`, section 3). Then put the merge's image on dev as `docs/RUNBOOK.md`, section 4.

After merge: in the Claude project, say "republish the data map".

## 7. Prod: Configuration → Sources, the tags 1.4 and 1.5 to Incorrect data

**Studio (cma-prod-pg)** (read only: the tags that have a meaning, by name; the same block again after the change)
```sql
set role cma_owner;
select tg.name as tag, tg.meaning, tg.is_counted
from cma.telephony_tag tg
join cma.tenant t on t.id = tg.tenant_id
where t.slug = 'pulse4all-subscriptions' and tg.meaning is not null
order by tg.meaning, tg.name;
reset role;
```
Expected before the change: the "Not Reached" tags at `not_reached`, and no 1.4 or 1.5 tag in the list: they have no meaning yet (the 0008zc record, step 11), so their calls of 30 seconds and more count as conversations today. A 1.4 or 1.5 tag already at `not_reached`: the change below moves no figure. Either way, go on.

Before the change, tell Kira and Arno (Slack or email, your words): from this change on, calls tagged "Wrong Number" or "Incorrect Data" are no conversation, whatever their talk time, as calls tagged "Not Reached" already are; the conversation figures of every period drop by those calls; nobody's calls changed.

**Browser:** Reports → Calls, This month: write down Conversations. Then Configuration → Sources → the Aircall connection → Tags. Set **Meaning** to **Incorrect data** on every tag whose name starts with `1.4 Sales - Wrong Number` or `1.5 Sales - Incorrect Data` (each saves on its own). `1.1 Sales - Not Reached` and the other "Not Reached" tags stay at Not reached (docs/definitions.md, Tag, Pulse4all Subscriptions mapping).

Expected: each select reads Incorrect data after a reload; the notice "No tag means not reached yet…" stays away (the Not Reached tags keep their meaning). Reports → Calls for this month: Conversations lower than before the change by the calls tagged 1.4 or 1.5 with 30 seconds of talk or more (the same if this month has none).

**Studio (cma-prod-pg):** the block above again.

Expected: the 1.4 and 1.5 tags at `incorrect_data`, the "Not Reached" tags at `not_reached`, and any other meaning you set yourself. Send me the rows if one is not where you expect it.
