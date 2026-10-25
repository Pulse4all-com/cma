# Local records, the tag meaning incorrect data (addition 0008zd, 25 October 2026)

These are the outputs of local runs in Claude Code's container:
- PostgreSQL 16 from the distribution, with a local `uuidv7()` shim (PostgreSQL 16 has none; Cloud SQL's PostgreSQL 18 has it);
- Node 22;
- the build of `web/` and its pure verifiers.

They are not release records; `records/` stays Martin's. No value here comes from dev, prod, HubSpot, Aircall or GCP: every id, name and count is the dev seed's, a verify script's invented data or the invented data of `web/verify/reports-fixture.sql`.

## `db/`

Three local databases: **at 0008zc** (`main`'s `01` to `100` in numeric order with the dev seeds, the verify scripts left out, `02` and `03` again, `reports-fixture.sql`); **migrated** (built the same way to `100`, then this branch's `102` twice: prod's path); **fresh** (this branch, `01` to `102` the same way).

| File | What |
|---|---|
| `fresh-build.txt` | One line per script of the fresh build after `00`: every one `exit=0 errors=0`, `102` included; the seeds again and the fixture (`fixture written`). |
| `fingerprint-at-0008zc.txt` | The runbook's fingerprint (step 1) on the migrated database before `102`: 519 functions, 126 views, 85 tables, 6 meaning keys, additions `0008zc`; the functions' md5 equals 0008zc's local record (`../db/fingerprint-after-100.txt`). |
| `102_tag_meaning_incorrect_data-first-run.txt`, `-rerun.txt` | Addition 0008zd: the first run ends `INSERT 0 1`, `COMMIT`, `RESET`; the rerun ends `INSERT 0 0`. No error in either. |
| `fingerprint-after-102.txt`, `fingerprint-after-102-rerun.txt` | Identical: 520 functions (`cma.tag_meaning_excludes_conversation` new; `cma.set_telephony_tag_meaning` and `cma.call_not_reached_of` replaced), 126 views, 85 tables, 7 meaning keys, additions `0008zc 0008zd`, the same md5. |
| `fingerprint-fresh.txt` | The fresh database: the same row as the migrated one, md5 included. |
| `103_verify_tag_meaning_incorrect_data.txt`, `-provoked.txt`, `-fresh.txt` | 12 checks (A1 to A4, B1 to B8), each `PASS`, the verdict PASS, on the migrated and on the fresh database; provoked every row `FAIL`, the verdict `PROVOKED`. |
| `103_verify_tag_meaning_incorrect_data-at-0008zc.txt` | On the database at 0008zc: the verdict FAIL (block A stops at `cma.tag_meaning_excludes_conversation`, which does not exist; block B at the setter refusing `incorrect_data`), as it must. |
| `101_verify_definitions_calls.txt`, `-provoked.txt`, `-fresh.txt` | `101` with A2 amended (seven keys): 18 PASS on the migrated and the fresh database; provoked 18 FAIL. |
| `101_verify_definitions_calls-at-0008zc.txt` | The amended `101` on the database at 0008zc: 17 PASS, A2 FAIL (six keys), as it must. |
| `verifies-0008zc-and-0008zd.txt` | Every `db/` verify script at 0008zc and at 0008zd. They agree except `101` and `103` (above), and `25` and `39`, which flip between runs on both databases (`25`: its roster dates near today's; `39`: the outbox's claim order under the local `uuidv7()` shim), as 0008zc's records found. `53` fails the same two checks on both, locally only, as before this branch (0008zc's records: `07`, `12`, `27` and `53` err or fail the same on both). `91` passed 13 of 13 at 0008zd. An earlier run, on a template copy of the database and not kept here, failed `91`'s A4 (tables never analyzed: a copy carries no statistics) and passed after `analyze`. |
| `drift.txt` | `tools/drift/functions.sql` on the three databases: fresh and migrated 520 lines each, no line differs; against 0008zc exactly three lines: `cma.call_not_reached_of` and `cma.set_telephony_tag_meaning` changed, `cma.tag_meaning_excludes_conversation` added. |
| `helper-inlined.txt` | The plan of a call's flag through `cma.call_not_reached_of`: the helper is inlined, its expression `COALESCE((tg.meaning = ANY ('{not_reached,incorrect_data}'::text[])), false)` sits in the filter, no function call left. |
| `catalog-verify-sql.txt` | The `verify_sql` of the 79 catalog entries whose tag condition now names `incorrect_data`, each run on the migrated database: 79 ran, none erred. |

## `web/`

| File | What |
|---|---|
| `checks.txt` | The last line of each check on this branch: build, typecheck, lint (0 errors; the two warnings are in `web/verify/follow-up.mjs` and `web/scripts/metrics-doc.mjs`, unchanged from `main`), the twenty pure verifiers (`verify:reports` 186, three more than `main`: 103's B1, B2 and B5 on the web's own rule; `verify:configuration` 107, one more: the seven meanings and the notice that looks at not reached only), and `reports`, `configuration` and `metrics` provoked. |
| `build.txt` | The output of `npm run build`. |

The verifiers that need a server or a database (`verify:api`, `verify:theme`, `verify:layout`, `verify:hints` and the others CLAUDE.md names) were not run: no route, page layout or API field changes; the Meaning select gains one option.

## `ingest/`

No ingest file changes: ingest never writes a tag's meaning.
