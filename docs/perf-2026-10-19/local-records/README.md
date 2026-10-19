# Local records, report speed (19 October 2026)

These are the outputs of local runs in Claude Code's container: PostgreSQL 16.15 from the distribution (with a local `uuidv7()` shim, since PostgreSQL 16 has none; Cloud SQL's PostgreSQL 18 has it; `work_mem` 4 MB as in prod), Node 22, and the standalone build of `web/` in mock sign-in. They are not release records; `records/` stays Martin's. No value here comes from dev, prod or GCP: every id, name and count is the dev seed's, a verify script's invented data or the invented report data of Part 1. Prod's own numbers are in `../prod-output.txt`.

## `db/`

A fresh database built from `00` to `89` in README order (the dev seeds included), then `90` twice and the verifies, by the final versions of the scripts on this branch.

| File | What |
|---|---|
| `90_report_speed-first-run.txt`, `-rerun.txt` | Addition 0008x: the first run ends `ANALYZE` three times, `INSERT 0 1`, `COMMIT`, `RESET`; the rerun is the same except `INSERT 0 0` for the migration row. |
| `91_verify_report_speed.txt`, `-provoked.txt` | 13 PASS, verdict PASS, in 1 min 45 s; provoked 0 PASS, 13 FAIL, `PROVOKED, NOT A PASS`. B1 builds the tenant at prod's counts; B2 to B7 show 0 rows apart, old against new, both ways; B8 times every report read of October as `cma_app` (the slowest 229 ms, `email_report_page`; `first_orders_page` 98 ms); B9 compares with the old definitions on the same data (`first_orders_of` 66 ms against 39.4 s, `email_report_of` 250 ms against 2.4 s, `email_per_person_of` 159 ms against 2.1 s). |
| `83_…`, `85_…`, `87_…`, `89_…-at-0008x.txt` | Unchanged and passing after 0008x: 26, 26, 16 and 15 PASS. |
| `41_…`, `69_…`, `73_…`, `75_…`, `81_…-at-0008x.txt` | The earlier verifies after 0008x: `41` both tenant rows PASS, `69` 29, `73` 21, `75` 24, `81` 19 PASS; unchanged. |
| `schema_migration.txt` | The additions 0008s to 0008x recorded. |

## `web/`

| File | What |
|---|---|
| `checks.txt` | The last line of each check on this branch after `main` of 19 October 2026 (`509ec43`) was merged in: typecheck, lint (0 errors; the one warning is in `web/verify/follow-up.mjs`, unchanged from `main`), build, and the nineteen pure verifiers, all passing. |
| `old-vs-new.txt` | The First orders, Email and Email per agent API answers of the web before and after this branch, against the same database: identical (Email apart from the waiting time, which counts up to now). |
