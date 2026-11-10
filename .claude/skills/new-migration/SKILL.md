---
name: new-migration
description: Prepare a new db/ migration and its verify script for the CMA: the next number and addition version, the script frame, the function base, the impact list, the datamap and docs edits, and the steps for Martin. Use when a brief adds or changes a table, view, column, function or setting in the database.
---

# New migration

Follow CLAUDE.md (Database, Performance) and docs/RUNBOOK.md, section 7. Nothing here runs a db/ script: Martin runs them in Studio or his terminal. Never edit a script that has run in prod.

## 1. Number and version
- Next script number: `ls db | sort -n | tail -4`; take the next two numbers: `<n>_<name>.sql` and `<n+1>_verify_<name>.sql`.
- Next addition version: the highest `version` inserted into `cma.schema_migration` in `db/*.sql`, then the series of docs/decisions.md (0008za after 0008z; after 0008zz the additions continue as 0009a, 0009b, …). Search with `grep -h "insert into cma.schema_migration" -A1 db/*.sql | tail`.
- The brief gives the migration number when it has one; use it as given and say so.

## 2. Impact (delegate when a function or object is re-created)
- A function that is re-created: delegate to `cma-migration-impact` with the function name and the migration number. It returns the base script, the verifies to rerun, and the budget files affected.
- Do it yourself for a plain new table or column: `grep -rlw '<name>' db web/src docs/datamap`.

## 3. Script frame (copy the shape of the latest numbered script, for example `db/162_remove_day.sql`)
- Header comment: what and why (Martin, date, brief; Decision log row), what it adds, the order to run (dev, the verify, the verifies that read what changed, merge, prod), rerunnable and forward-only, one transaction.
- `begin; set local lock_timeout = '5s'; set role cma_owner;` … `commit; reset role;`
- A function that is redefined: start from its latest earlier definition (the base script), and put `-- based on: <file>.sql` on the line directly above the `create` (from 152 on; `npm run verify:function-bases` in web/ enforces it). A `create or replace` drops settings such as `set jit = off`: repeat them. A set-returning function says its `rows`.
- A new tenant table: `select cma.setup_tenant_table('<table>');`
- A new index on a busy table (`ingest_event`, `sync_run`, `subscription_event`, `crm_record`, `telephony_call`, `commerce_order`, `crm_call`, `commerce_customer`) never goes in the migration: give Martin a Terminal block with `create index concurrently if not exists`, one statement each, with `lock_timeout` and `statement_timeout`, and a check of `pg_index.indisvalid`. A constraint or other ACCESS EXCLUSIVE change on such a table goes last, directly before the `schema_migration` insert.
- Last: `insert into cma.schema_migration (version, description) values ('<version>', '<what it does>') on conflict (version) do nothing;`
- Performance traps (CLAUDE.md, Performance; night N06): scalar subqueries `(select s.x from s)` instead of `cross join s`; `min(<indexed column>) is not null` instead of `exists()` over a big table; no ordered aggregate over a long history; no grouped or windowed view that must take a caller's bound.

## 4. Verify script (the shape of `db/163_verify_remove_day.sql`)
- Refuses `postgres` as session user; `set role cma_owner;` `select set_config('verify.provoke', 'false', false);` a temp results table; synthetic data only (example.invalid), fixed dates; blocks inside subtransactions that always roll back.
- Check S1: the version is recorded after the previous one; grants and ownership as designed.
- A rewrite meant to keep the answers keeps the previous definition inside the verify and compares both row for row; a change that restores a rule compares with the definition that held it.
- Provoke switch: with `verify.provoke` true every block fails and the verdict says "PROVOKED, NOT A PASS". The last row is "PASS | n PASS, 0 FAIL".
- Error codes and permissions follow docs/architecture/data-model/ and docs/architecture/api.md.

## 5. Budgets and docs in the same PR
- A new read: its row in `db/131_time_all.sql` and its budget in `web/verify/round-trips.json`; client JavaScript or payload checked against `web/verify/perf.json`.
- `docs/datamap/catalog.json`: a `what` and `how` per new table, an entry per new computed view; `how` updated when a source's fill changed. The PR says Martin refreshes `docs/datamap/schema.json` from dev on this branch after running the migration there, before merging; until then `verify:datamap` fails, which is expected.
- docs/decisions.md row, one dated CHANGELOG.md line, docs/definitions.md for a new term (with a `Definitions:` row). Delegate these to `cma-docs-keeper` after the reviewers.

## 6. Review and hand-off
- In web/: `npm ci`, `npm run build`, `npm run typecheck`, `npm run lint`, and the pure verifiers listed in CLAUDE.md (`verify:function-bases` and `verify:datamap` included).
- Delegate in one message to `cma-reviewer`, `cma-db-reviewer`, `cma-security-reviewer` and `cma-performance`; fix every Critical.
- The PR's steps for Martin, one at a time with the expected output, each block labelled: **Studio** (SQL, naming `cma-dev-pg` or `cma-prod-pg`) or **Terminal**; SQL and shell never in one block. Order: dev migration, its verify (and the provoked run), the verifies named in the migration header, the datamap refresh, then prod after the merge: the migration and the same verifies without the new verify when the brief says so.
