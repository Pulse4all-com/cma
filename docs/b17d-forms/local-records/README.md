# Local run of brief B17d (forms reporting, addition 0008p)

Claude Code's local runs on 16 October 2026, on this branch after `main` of that day (N16-A, `Pulse4all-com/cma#141`; seed `02` for invitations, `#140`; B17b.1, `#143`) was brought in, and again after the rebase on `#146` (the ingest's front guard; no `web/` or `db/` change): the ingest's `npm test`, its provoked runs and `jobs-flow`, and the web checks of CLAUDE.md were rerun then; the browser verifiers and the api-mode run are from the build before that rebase, whose `web/` is identical. This is not a release record: `records/0008p-dev-*` and `records/0008p-prod-*` will come from Martin's real runs (`../MORNING_RUNBOOK.md`). No value here comes from dev, prod, GCP or HubSpot.

**Server:** PostgreSQL 18.4, the `@embedded-postgres/linux-x64` 18.4.0-beta.17 binaries from npm, as for B10 to B17b. `00` runs as `postgres`; every other script runs as the login `martin@pulse4all.com`, which is not a superuser.

**Order:** `00` to `69` in the order of B17a's fresh database (`../../b17a-email-data/local-records/db/order-of-the-fresh-database.txt`), then `Pulse4all-com/cma#142`'s `70_crm_tasks.sql` to `73_verify_follow_up.sql` as that pull request held them on 16 October 2026 (0008n and 0008o; #142 merges before B17d), kept as the template at `73`. Every run below starts from a fresh copy of it. That template predates `#140`'s change to `02` (the invitation domain): `db/75-after-main-02.txt` runs `main`'s `02` on a copy at 0008p and then `75` again.

## Database

| File | What | Result |
|---|---|---|
| `db/74.txt` | the addition on a copy at `73` | Clean (`ON_ERROR_STOP=1`); ends `INSERT 0 1`, `COMMIT`, `RESET`. |
| `db/74-rerun.txt` | the same addition run again | Clean; ends `INSERT 0 0`, `COMMIT`, `RESET`. |
| `db/75.txt` | block A (5 checks on the objects) and block B (19 checks on two throwaway tenants, rolled back) | `24 PASS, 0 FAIL`, verdict `PASS`. |
| `db/75-provoked.txt` | the same with `verify.provoke` true | All 24 checks `FAIL`, verdict `PROVOKED, NOT A PASS`, `0 PASS, 24 FAIL`; 25 lines contain FAIL (the 24 checks and the verdict's count). |
| `db/75-after-main-02.txt` | `main`'s `02` rerun on a copy at 0008p, then `75` | `02` clean (`DO` twice); `75` `24 PASS, 0 FAIL`. |
| `db/earlier-verifies/` | after `74`: `33`, `35`, `41` (they have run in prod), `53`, `69`, and #142's `71` and `73` | `33`, `35` and `41` 2 PASS rows each, `53` 17, `69` 30, `71` 21, `73` 22 PASS rows; no FAIL row. |
| `db/datamap-check-local-schema.txt` | `tools/datamap/build.mjs`'s check (the page left out) on this branch's `docs/datamap/catalog.json` against a schema snapshot of the local database at 0008p, kept outside the repository | Every problem it lists is an object of #142 (its tables and views), whose catalog entries come with #142; none names an object of 0008p. `docs/datamap/schema.json` itself stays dev's: Martin refreshes it on the branch after 0008p ran in dev (`../MORNING_RUNBOOK.md` step 4). |
| `db/runbook-step10-rehearsal.txt` | the runbook's steps 10 and 11, every statement as written, on a throwaway database at 0008p with an invented catalog shaped like brief B17d's prod data (50 forms, the form rule of 12 October applied first) | The seven categories; the 28 counted forms' categories; 22 printed statements for the support forms, run; 50 printed kept-field lines, run (the three general forms with their market field, `deployment_outcome` kept nowhere); Intake B, the lead condition on the nine Contact forms, Intake C lower by the NL Contact submissions answered "Yes" or not at all; step 11's counts with `answers_not_in_options` 0. The submissions come from the ingest write directly (steps 9 and 10e are the ingest jobs). |

## Ingest

| File | What | Result |
|---|---|---|
| `ingest/lint.txt`, `ingest/npm-test.txt` | `npx eslint`, `npm test` in `ingest/` | exit 0; fourteen lines `ALL n PASS` (18, 37, 26, 48, 20, 49, 27, 17, 51, 21, 21, 20, 76, 10; the fourth is `verify/forms.mjs`, the last `verify/deploy-script.mjs` of `#146`). |
| `ingest/provoked-<name>.txt` | every pure verifier with `--provoke` | Each `ALL n PROVOKED CHECKS FAILED, as they must`. |
| `ingest/jobs-flow.txt`, `ingest/jobs-flow-provoked.txt` | `verify/jobs-flow.mjs` against a fresh copy at 0008p (with B17b.1's guard from `main`) | `ALL 75 PASS`; provoked `ALL 75 PROVOKED CHECKS FAILED, as they must`. Among them the support form polled and not counted: its answers within the options, one dropped and counted, never counted in Intake; the backfill's second read filling an empty answer. |
| `ingest/flow.txt`, `email-flow.txt`, `aircall-flow.txt`, `shopify-flow.txt`, `outbox-flow.txt` | the other flow verifiers, unchanged by B17d, on the same copy | `ALL 80 PASS`, `ALL 33 PASS`, `ALL 88 PASS`, `ALL 86 PASS`, `ALL 11 PASS`. |

## Web

| File | What | Result |
|---|---|---|
| `web/npm-ci.txt`, `web/build.txt`, `web/typecheck.txt`, `web/lint.txt` | `npm ci`, `npm run build`, `npm run typecheck`, `npm run lint` in `web/` | All exit 0. The build lists `/reports/forms`, `/api/v1/reports/forms`, `/api/v1/reports/forms/answers`, `/api/v1/reports/forms/export` and `/api/v1/configuration/form-categories`. |
| `web/verifiers-summary.txt`, `web/verify-<name>.txt`, `web/verify-<name>-provoked.txt` | the pure verifiers CLAUDE.md names, `reports` and `main`'s new `preview`, normal and `--provoke` | All PASS and all provoked checks fail (`copy` 1523 keys, its provoked run exits 1 with 5 problems, as designed; `reports` 91 checks, the Forms checks on 75's own dataset; `configuration` 99; `csv` 17), except `verify:datamap`: FAIL with 3 problems, the two new tables missing from `schema.json` and `index.html` not rebuilt, which is expected until Martin refreshes the snapshot from dev (CLAUDE.md, Database). |
| `web/verify-theme*.txt`, `web/verify-hints*.txt`, `web/verify-layout*.txt` | the browser verifiers against the build of this branch in mock mode | `theme: PASS (50 pages, …, 28 tables per 7.6 and 3.3, a header hint open on 14 report pages)`, provoked `FAIL (6 problems)`; `hints: PASS (267 headers and 67 tiles on 22 pages, …)`, provoked `FAIL (3 problems)`; `layout: PASS (…, Forms for 7 identities (…), Sources with its form categories (…), …)`, provoked `FAIL (43 problems)`, among them the forms table spilling out of its card. This container's Chromium is an older build than the installed Playwright expects, so the runs launched it by path (a Node `--import` that sets `executablePath`; no verifier changed for it); the layout screenshots went to a local folder, not `records/layout/`. |
| `web/api-mode-local-db.txt` | the same build in api mode (`CMA_DATA_MODE=api`, mock identities) against a throwaway database at 0008p with three invented forms and 120 submissions in the dev seed's tenant | The report's totals, previous period and lists, the filters, the answers, the refusals (400) and an agent's 403, the file in the tenant's format, the categories (read, add, a code `none` refused, an analyst's write 403), a connection's forms with polled, category, market field, lead condition and fields, a switched-off category and a counted form not polled refused. `verify:api` has no Forms checks; this run and `75` cover the routes and the reads. |
| `web/screenshots/` | Reports → Forms (this week, the manager), Configuration → Sources with the form categories, a CRM connection's forms (the admin), mock mode at 1280 px | For the review. |

Not run here:
- Every `db/` script in dev and prod, the ingest image in dev and prod, the configuration and the backfill (Martin, `../MORNING_RUNBOOK.md`).
- The data map's snapshot from dev and the rebuild of `docs/datamap/index.html` (Martin, step 4); until then `verify:datamap` fails on this branch.
- `verify:api`, `verify:iap`, `verify:scheduler` against a server with a database (Martin).
- Anything against HubSpot: the fields of real forms, the single checkbox's submitted value (the runbook checks it in dev, step 8d).
