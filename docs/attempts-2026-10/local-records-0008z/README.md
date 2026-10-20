# Local records, attempts per deal for sales and message withdrawal (0008z, 20 October 2026)

These are the outputs of local runs in Claude Code's container:
- PostgreSQL 16 from the distribution, with a local `uuidv7()` shim (PostgreSQL 16 has none; Cloud SQL's PostgreSQL 18 has it);
- Node 22;
- the build of `web/` with mock sign-in: `next start` in mock data mode, and the standalone server in api data mode on a local database through a local login role holding `cma_app`;
- Playwright with the container's own Chromium.

They are not release records; `records/` stays Martin's, and the records of 0008y in dev and prod are in `../records/`, written down from Martin's report. No value here comes from dev, prod or GCP: every id, name and count is the dev seed's, a verify script's invented data or the invented data of `web/verify/reports-fixture.sql` and `db/volume-timing.sql`.

## `db/`

A fresh database built from `00` to `92` in README order (the dev seeds included), `02` and `03` again, `web/verify/reports-fixture.sql`, then `94` twice, the verifies, `03` again, all by the final versions of the scripts on this branch.

| File | What |
|---|---|
| `fresh-build.txt` | One line per script of the build after `00`, `01` to `92` (the verify scripts left out): every one `exit=0 errors=0`, with its count of notices. |
| `02_seed_pulse4all-rerun.txt`, `03_seed_dev_test_data-rerun.txt`, `reports-fixture-load.txt` | The seeds again after the build, then the fixture (`fixture written`). |
| `lead-reads-before-94.txt`, `lead-reads-after-94.txt` | The runbook's lead-reads block (steps 1 and 7) as the dev seed's two admins, before and after `94`: per tenant the count and an md5 over every column of `cma.speed_to_lead_rows` and `cma.lead_to_order_rows` for the last 30 days, ordered by tenant and deal (7 and 7 rows for Pulse4all Subscriptions, 2 and 2 for Pulse4all Invest). Identical, `newest_change` included. |
| `94_attempts_for_sales-first-run.txt`, `-rerun.txt` | Addition 0008z: the first run ends `INSERT 0 1`, `COMMIT`, `RESET`; the rerun is the same except `INSERT 0 0` for the migration row. |
| `fingerprint-after-94.txt`, `fingerprint-after-94-rerun.txt` | The functions of `cma` and `cma_read` with an md5 of their definitions, the views with an md5 of theirs, the attempts settings, the `messages.withdraw` grants and the migration, after each run of `94`: identical (475 functions, 120 views, 2 grants), so the rerun adds nothing. A database at 0008y has 466 functions and 120 views, as dev's record of 19 October 2026. |
| `95_verify_attempts_for_sales.txt`, `-provoked.txt` | 36 PASS (A1 to A7, B1 to B22, C1 to C7), verdict PASS; provoked 0 PASS, 36 FAIL, `PROVOKED, NOT A PASS`. |
| `93_verify_attempts_per_deal-at-0008z.txt`, `-provoked.txt` | `93` as amended for 0008z: 25 PASS; provoked 25 FAIL. Its header names the changed checks (A2, A3, B1, B4, B6, B7, B8, B12, B13, B14, B18, B19). |
| `43_verify_messaging-at-0008z.txt`, `-provoked.txt`, `43_verify_messaging-a3-mutations.txt` | `43` as amended for 0008z (A3: a message changes only by its withdrawal, both columns together, once, never cleared; A5: `cma_read.message` ends with both columns): no FAIL, both tenant rows `PASS`, and the same on a database at 0008y; provoked, every block A to E stops with `FAIL` and the verdict reads `PROVOKED, NOT A PASS`. Unamended, `43` failed A3 at 0008z, and A5 once A3 held. Three breaks of the rule, each on a throwaway copy of the database (the application allowed to update a message's title; the both-or-neither check dropped; the trigger dropped), each stop at `FAIL A3`. |
| `41_…` to `91_…-at-0008z.txt` | The earlier verifies after 0008z, unchanged: `41` both tenant rows PASS, `61` 20, `69` 29, `73` 21, `75` 24, `77` 14, `81` 19, `83` 26, `85` 26, `89` 15 and `91` 13 PASS (`91` in 86 seconds on this machine; dev's shared core needs about seven minutes, so the runbook runs it from the Terminal). |
| `03_seed_dev_test_data-rerun-after-94.txt`, `per-person-after-03-rerun.txt` | `03` once more after `94`: `reports.per_person` stays `email,orders,attempts` for Pulse4all Subscriptions, empty for Invest. No seed changes in 0008z: `94` grants `messages.withdraw` itself. |
| `schema_migration.txt` | The additions 0008s to 0008z recorded. |
| `volume-timing.sql`, `volume-timing.txt` | Every page read of October and `cma.attempts_of_deal` as `cma_app`, best of three, on a throwaway tenant at about twice prod's lead volume of 20 October 2026, rolled back: 4,800 deals (3,000 lead, 1,500 order, 300 renewals), 9,598 CRM calls, 5,929 telephony calls (4,429 linked), talk times, calls without an outcome and store orders. The script refuses a Cloud SQL instance. By day 273.9 ms, by pipeline 268.3 ms, market NL with no attempt yet 251.6 ms, by week with the deals won 256.0 ms, per person 123.1 ms, one deal's attempts at most 44.0 ms of ten deals. |
| `volume-timing-0008y-same-machine.txt` | 0008y's own `volume-timing.sql` (`../local-records/db/`) on a database at 0008y, on the same machine: by day 266.8 ms, by pipeline with every counted deal 281.8 ms, market NL 237.2 ms, per person 115.3 ms. |

## `drift/`

| File | What |
|---|---|
| `diff-0008y-0008z.txt` | `tools/drift/functions.sql` on a database at 0008y (466 lines) and one at 0008z (475 lines), then `diff`: exactly the functions 0008z adds, drops or redefines. Two fresh databases at 0008z (the one above and a second built to `94` before the fixture) gave 475 lines each and no difference. |

## `web/`

| File | What |
|---|---|
| `checks.txt` | The last line of each check on this branch, in one pass from `npm ci`: build, typecheck, lint (0 errors; the one warning is in `web/verify/follow-up.mjs`, unchanged from `main`), the nineteen pure verifiers and `verify:reports` and `verify:signed-out` provoked; then, against the mock server, `layout`, `hints` and `theme`, each normal and provoked; then `verify:api` in full against the server in api data mode on a second fresh database (built to `94`, the seeds, `reports-fixture.sql` with its calls linked to Aircall's), normal and provoked: ALL 311 PASS and all 311 FAIL provoked (0008y's count on such a database was 297). Its first run in this pass failed one check, which read the agent's name as personal data; the check was fixed and both runs repeated, as the file says. |
| `build.txt` | The output of that `npm run build`. |
| `layout-provoked-new-checks.txt` | The lines of the provoked layout run that the new checks give: the Live board's last section, the deal list and an opened deal spilling out of their card, Esc swallowed, a fresh sign-in kept on the deep link. |
| `measurement.txt` | `/reports/attempts` outside the database, against `/reports/speed-to-lead`, on a committed copy of the volume tenant served in api data mode (medians of ten requests; below). |

### The measurement

Prod's request log of 20 October 2026 showed `/reports/attempts` at 519 to 933 ms in all for 203 to 244 ms in the database. Locally, at about twice prod's volume:
- `/reports/attempts`: 316 ms in all, 226 ms in the database, so about 90 ms outside it (rendering and serializing the page); its API route spends 4 ms outside the database on the same read.
- `/reports/speed-to-lead`: 526 ms in all; its reads run in parallel, so their summed 840 ms exceed the total, and the time outside the database cannot be split the same way; its API route spends 3 ms outside.
- The page was 692 KB of HTML against Speed to lead's 310 KB. Its RSC payload carried the whole copy dictionary of the reader's language, about 136 KB, twice: `AttemptFilters` and `AttemptDealList` (client components) received `copy` whole. They now receive only the words they use (`attemptClientCopy` in `src/lib/attempts.ts`, 15 lines): 556 KB of HTML, the payload from 340 KB to 203 KB. The rest of the payload is the deal list's rows (about 66 KB for 100 deals) and the server tree.
- The time outside the database stays about 86 ms locally. Prod's 300 to 700 ms outside it is not reproduced here: this machine has no network between the server and the database and a faster core. The bytes saved count in prod on every page view, and 0008y's page in prod carries the copy once.
