# Local records, night of 3 to 4 November 2026 (N04)

These are the outputs of the night's local runs in Claude Code's container: PostgreSQL 16.15 from the distribution (with a local `uuidv7()` shim, since PostgreSQL 16 has none; Cloud SQL's PostgreSQL 18 has it), Node 22.23, the standalone build of `web/` in mock mode and in api mode against the local database. They are not release records; `records/` stays Martin's. No value here comes from dev, prod or Google Cloud: every id, name and count is the dev seed's, a verify script's or the mock's invented data. Paths of the container's scratch folder read `<scratch>`.

The database: `db/00` to `124` replayed in number order, the seeds `02` and `03` rerun after every migration, `06` and `24` in their place; a copy of it at 0008zn is the baseline (`*-at-0008zn.txt`), the database after `126` and `02` the result (`*-at-0008zp.txt`). The container restarted several times in the night; every run below was repeated on the final scripts of the branch.

## `db/`

| File | What |
|---|---|
| `126_workday_sessions-first-run.txt`, `-rerun.txt` | Addition 0008zp: the first run ends `INSERT 0 1`, `COMMIT`, `RESET`; the rerun `INSERT 0 0` (the setting's catalog row is an upsert and says `INSERT 0 1` both times). |
| `02_seed_pulse4all-after-126.txt`, `-rerun.txt` | The Pulse4all seed after `126` and again: no error, no notice. |
| `settings-and-additions.txt` | Then: `pulse4all-subscriptions true`, `pulse4all-invest false`; the additions 0008zn and 0008zp recorded. |
| `127_verify_workday_sessions.txt` | 31 checks, `PASS | 31 PASS, 0 FAIL`. |
| `127_verify_workday_sessions-provoked.txt` | Provoked: every one of the nine blocks raises `FAIL`, `PROVOKED, NOT A PASS | 0 PASS, 31 FAIL`. |
| `127_verify_workday_sessions-at-0008zn.txt` | The verify on the database before `126`: `FAIL | 0 PASS, 31 FAIL` (S1 not recorded, then "Unknown setting workday.clock_in_again"). |
| `127-against-mutations.txt` | Nine mutations of `126`, each on a fresh copy at 0008zn: eight caught (the setting not read, any end's source, no window end, the end's own instant allowed, time kept not read, a status after an end, a clock-in at the end's instant, two ends in a row); the ninth, the business-date clause dropped, passes by design (the window lies within the date). |
| `concurrency-two-connections.txt` | Two real connections press Clock in on a resumable day: tab A clocks in again and holds its transaction three seconds; tab B, pressing a second later, waits for the lock and answers with the open day, one new start in all. Then the same with `open_workday`'s re-check under the lock taken out (a scratch copy): B's second start is refused by `refresh_workday` (`CMA04`, "has a clock-in while a session is open"). |
| `<nn>_…-at-0008zn.txt`, `-at-0008zp.txt` | The earlier verifies before and after: `07` (block C still reads ended: the open after the end in one transaction is not later, N3; its other expected errors as before), `10` (10 PASS notices), `14`, `16`, `18`, `20`, `47`, `51` (both tenants PASS) and `111` (PASS) unchanged. `27` fails its A4 in both ("2 scheduler role(s) with other permissions than workday.close_forgotten"): pre-existing since 0008s, not this change (`../NIGHT_NOTES.md`). |

## `web/`

The final build of this branch (`build.txt`, exit 0), then every check on it:

| File | What |
|---|---|
| `typecheck.txt`, `lint.txt` | Exit 0; lint's two warnings are in `scripts/metrics-doc.mjs` and `verify/follow-up.mjs`, unchanged from `main`. |
| `verify-<name>.txt` | The pure verifiers CLAUDE.md names, each with its exit code: copy 3181 keys (en and nl), corrections 44, csv 22, dashboard 17, live 43, team 26, configuration 116, messages 24, import 29, devices-import 13, datamap PASS, signed-out 20, invitations 27, preview 18, follow-up 34, reports 215, period 16, health 39, boundaries 334 files, jobs 28, metrics ok. `roster` fails one of 36 ("12 – 18 October 2026" against "12–18 October 2026"): this container's ICU spaces a date range; `main` fails it alike here. |
| `verify-api-local.txt` | `verify/api.mjs` against this build in api mode (`CMA_DB_HOST`) on the local database after `126` and `02`: `ALL 281 PASS`, the branch "clock in again" (the test supervisor's day ended, clocked in again with its first start kept, ended again). |
| `verify-api-local-setting-off.txt` | The same with `workday.clock_in_again` false for the tenant: `ALL 281 PASS`, the branch "an ended day stays ended". |
| `verify-api-local-provoked.txt` | Provoked: `ALL 281 PROVOKED CHECKS FAILED, as they must`. |
| `main-web-verify-api-setting-on.txt` | `main`'s build and `main`'s `verify/api.mjs` on a database at 0008zp with the setting on: `3 of 279 FAILED`, exactly the three checks that assume an ended day stays ended ("start on an ended day changes nothing" and the two that follow from it). The web of `main` runs on the migrated database; only Clock in on an ended day behaves as decided. |
| `handrun.txt`, `screenshots/` | A hand run of the flow in mock mode (Playwright, 1280 px): Clock in on Welcome; End workday's confirmation ("You can clock in again today until 22:00"); My day ended with the Clock in card below it; Welcome's ended day with "Clock in again"; clocked in again with "Back since"; My day with "Started at" and "Back since"; the Log out page; My hours today with "2 sessions"; Team hours as the supervisor with the fixture's split shift ("2 sessions"). |

Not recorded as a file: the browser verifiers, which CLAUDE.md leaves to Martin, ran here against this branch's build and against `main`'s, both in mock mode, and report the same problems on both, all on pages this change does not touch: `theme` 1 (Attempts by pipeline with an outcome filter has no table), `hints` 14 (header counts on Inbound, Calls, Attempts and Funnel), `layout` 11 (Funnel's tables without a scroll container, the Reports accordion). Pre-existing, not this change.

## After the rebase on `main` at `ca16bba` (4 November 2026)

The same checks on the rebased branch, on a fresh database: `db/00` to `125` replayed in number order with the seeds rerun after every migration (the same six known errors of earlier verifies as on the night run), then `126` and `127` run by hand so that `126`'s first run shows `INSERT 0 1`.

| File | What |
|---|---|
| `../../../records/0008zp-precheck-2026-11-04/README.md` | Martin's pre-check in dev and prod (his values): no stored day refused, dev 98 days, prod 1,633. |
| `db/replay-00-to-125-after-rebase.txt` | The replay's log: `replayed to 125`; the known errors of `04`, `07`, `12` (their expected-error blocks) and of `91`, `93`, `95` (earlier verifies against later functions), as before. |
| `db/precheck-query-local-after-rebase.txt` | The record's query on this database before `126`: Result 1 no rows, Result 2 `pulse4all-subscriptions` 5 (the dev seed's days). |
| `db/126_workday_sessions-first-run-after-rebase.txt`, `-rerun-after-rebase.txt` | `INSERT 0 1 COMMIT RESET`, then `INSERT 0 0 COMMIT RESET`. |
| `db/02_seed_pulse4all-after-126-after-rebase.txt` | No error, no notice. |
| `db/127_verify_workday_sessions-after-rebase.txt` | `PASS | 31 PASS, 0 FAIL`. |
| `db/127_verify_workday_sessions-provoked-after-rebase.txt` | Nine blocks failed, `PROVOKED, NOT A PASS | 0 PASS, 31 FAIL`. |
| `db/07_verify_time_model-after-rebase.txt` | Block C still `ended ended`. |
| `db/settings-and-additions-after-rebase.txt` | `pulse4all-subscriptions true`, `pulse4all-invest false`; 0008zn, 0008zo, 0008zp recorded. |
| `web/npm-ci-after-rebase.txt`, `build-after-rebase.txt`, `typecheck-after-rebase.txt`, `lint-after-rebase.txt` | `npm ci` exit 0; build exit 0; typecheck exit 0, 0 errors; lint exit 0, 0 errors (`main`'s two warnings). |
| `web/verify-<name>-after-rebase.txt` | Every pure verifier: copy 3397 keys (en and nl), corrections 44, csv 22, dashboard 17, live 43, team 26, configuration 116, messages 24, import 29, devices-import 13, datamap PASS, signed-out 20, invitations 27, preview 18, follow-up 34, reports 215, flash 64, period 16, health 39, boundaries 345 files, jobs 28, metrics ok; roster 1 of 36, the same date-range failure as `main` (its code is identical to `main`'s). |
| `web/reports-fixture-load-after-rebase.txt` | `web/verify/reports-fixture.sql` loaded into the local database (local only; a CRM, a telephony and a shop connection with invented data), as the API verifier's note asks. |
| `web/verify-api-setting-on-after-rebase.txt` | `ALL 324 PASS`, branch "clock in again". Before the fixture, four of `main`'s Flash checks answered 409 `not_set_up` (no shop or CRM set up in the tenant); dev has both. |
| `web/verify-api-setting-off-after-rebase.txt` | `workday.clock_in_again` false: `ALL 324 PASS`, branch "an ended day stays ended". |
| `web/verify-api-provoked-after-rebase.txt` | `ALL 324 PROVOKED CHECKS FAILED, as they must`. |
| `git-after-rebase.txt` | The merge base `ca16bba`, the branch's commits on it, and the one file under `cloudbuild.yaml`, `ingest/`, `hubspot/` or `records/`: the new pre-check record. |

