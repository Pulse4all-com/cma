# Night notes: the build of 8 to 9 October 2026

Written at the end of the night chat for Martin. README.md (sixteenth pass, in `g-04-readme.patch`) is the source of truth; this file says what the night decided on its own, what it left out, what it could not prove here, what it found, and the scheduler's fact check with its sources. The runbook for the morning is `MORNING_RUNBOOK.md`.

## 1. Read this first

- **`main` was at `ff93b8e` as the handover said**; the night built on it without a token, so the handover is four patches (`g-01-0005a`, `g-02-configuration`, `g-03-scheduler`, `g-04-readme`), one PR each. All four apply in sequence on a fresh clone of `ff93b8e` (section 7).
- **The optional slice 4 (My account, shift templates, the supervisor's read-only planner) was not built.** The three mandatory slices and the documents took the night; the README's Roadmap step 5 and Open decisions say so.
- **Migration 0005a creates a system user in every tenant, prod included** ("Scheduler", login `scheduler`/`scheduler`, no clock, never on People). It is the actor the audit names for every forgotten day the scheduler ends. Yordi should know, together with the roster point of the first night.
- **The scheduler sweeps hourly, not at 03:00 per tenant** (section 3, default 6). Once `docs/scheduler/deploy.sh prod` has run, every day never clocked out before yesterday is ended at its business day's end on the next full hour and shows on Team hours as Not clocked out until someone corrects or confirms it. Prod holds the team's own time only, so the first run should close nothing or a test day.

## 2. What the night built, per slice

| Slice | Branch and commit | Patch | What |
|---|---|---|---|
| 1 | `g-01-0005a` (`274eb44`) | `g-01-0005a.patch` | migration 0005a (`db/26_configuration.sql`), verify `27`, verify `18` adjusted (A5 and B11 accept the app's insert and update on `app_link` once 0005a is recorded, passing before and after), `records/0005a-dev-2026-10-08/` placeholder |
| 2 | `g-02-configuration` (`8919d12`) | `g-02-configuration.patch` | the Configuration group with five screens, 14 routes under `/api/v1/configuration/…`, 17 `CmaData` methods on Postgres and mock, `src/lib/configuration.ts` with `verify/configuration.mjs` (30), `src/lib/api/configuration.ts`, copy in both locales (500 keys), theme 18 pages, layout with the group per identity, API verifier 138, the planner and the absence-types route leaving retired absence types out, `records/configuration-2026-10-09/` placeholder |
| 3 | `g-03-scheduler` | `g-03-scheduler.patch` | `web/jobs/close-forgotten-workdays.mjs`, the connector as a server-external package and `jobs/` in the Dockerfile, `verify/scheduler.mjs` (10), `docs/scheduler/deploy.sh`, `records/scheduler-2026-10-09/` placeholder |
| 4 | `g-04-readme` | `g-04-readme.patch` | README sixteenth pass, this file and the runbook under `docs/night-2026-10-09/`, the night's local verify output under `docs/night-2026-10-09/local-records/` |

Every slice was gated as the handover's section 5 asks: every `db/` script on a local PostgreSQL **18.6** on top of `00` to `25` in the README's order with the seed reruns, the verify passing and failing when provoked, `14`, `16`, `18`, `20`, `22`, `25` passing afterwards; every web slice through `npm run typecheck`, `npm run lint`, `npm run build`, the pure verifiers normal and provoked, theme and layout against the local mock server, the API verifier and the scheduler verifier normal and provoked against the local database through `CMA_DB_HOST`.

## 3. Defaults the night took (each also in the README's Decision log, marked "to confirm")

From the handover's section 4, applied as given: the scheduler as Cloud Scheduler → a Cloud Run job on the web image as `cma-web@…` with `app.user_id` the tenant's scheduler user; no digit keys on the configuration pages and the group's `C`; statuses and links retired, never deleted, reactivable; the default must be working and the last working status cannot be retired; coverage targets per team, work type and ISO weekday, 0 clears; the five export settings unchanged; everything tenant rows; nothing hardcodes Pulse4all.

Taken beyond section 4:

1. **Frozen flags.** `upsert_work_status` refuses a flag change on a status that has any time event (`CMA03`); name and order stay editable. This settles the Open decision "flag changes with history behind them" in the conservative direction; flags with a validity stay the alternative.
2. **The scheduler user is created by the migration** for every tenant and by `create_tenant`, like roles and absence types; the dev fixture `03` needed nothing.
3. **`app_user.kind` and `app_role.is_assignable`** with one protection trigger on `app_user`, `user_role`, `team_member`, `user_skill`, instead of redefining `add_person`, `set_person_role` and friends; `roles()` and `directory()` redefined to hide the role and the user. `kind` is where the README's worker kind for AI agents lands later.
4. **A system end keeps the day flagged**: `workday_summary_all.needs_correction` is "open past its end or ended by a system event" (same columns). Team hours, Welcome's to-do line and the exports follow without a web change; a manager confirms with a correction at the same instant.
5. **The end sits at the business day's end, or at the day's last event when that is later**, so `refresh_workday`'s order check always holds.
6. **Hourly sweep, the grace as the one knob**, instead of a tenant-local 03:00. The function is idempotent and the rule lives in the database; an hourly Cloud Scheduler job is free (three jobs are) and a Cloud Run job execution of a few seconds costs nothing noticeable. A London day's end plus 120 minutes would have landed exactly on 03:00 Amsterdam.
7. **`pg_cron` rejected** on the facts of section 6.
8. **Page shortcuts beat the rail's `C`**: controls inside `main` are looked up before the rail, one line in `useKeyboardShortcuts`. The planner's Copy previous week and the period bar's Custom range keep `C`; everywhere else `C` opens Configuration and focuses its first page.
9. **Routes at `/api/v1/configuration/…`**, every write answering the full list; `GET /api/v1/settings` stays the read, the write is `PUT /api/v1/configuration/settings`.
10. **The Exports page carries the two minute settings** (adherence tolerance, the forgotten clock-out grace) under "Other settings", because the settings have no page of their own and this page already edits settings.
11. **Retired absence types leave the planner's parser and `GET /api/v1/roster/absence-types`** (a latent gap: nothing could retire one before 0005a).
12. **The copy file stays two levels deep** (`satisfies Record<string, Record<string, string>>`), so the configuration copy is six sections: `configuration`, `configStatuses`, `configTeams`, `configAbsences`, `configExports`, `configAppLinks`.
13. **The mock keeps a configuration copy** of the fixture catalogs on `globalThis`; `listSettings` and `listAbsenceTypes` read it once seeded, so the screens can be tried in mock mode without touching the time fixtures.
14. **The connector is a server-external package** (`serverExternalPackages` in `next.config.ts`), so the image carries `@google-cloud/cloud-sql-connector` next to `pg` and the job imports both from `/app/node_modules`. The service's bundle is unchanged in behaviour.
15. **`CMA_DB_SET_ROLE=cma_app`** is a verifier aid in the job for a personal login that holds `cma_app` without inheritance (Cloud Shell); Cloud Run never sets it.
16. **Numbering**: `26` migration 0005a, `27` its verify; the job under `web/jobs/`, the deploy script under `docs/scheduler/`.

## 4. Left out, and why

- Slice 4 entirely: My account (`/account`), shift templates (`cma.shift_template`, presets `1` to `5`), the supervisor's read-only planner (`roster.view_team`). Not started; nothing half delivered. The README's Open decisions name them as next.
- A tenant-local close time of day (the grace is the knob), a notice to the agent whose day was closed, the agent's own end-time proposal (Open decisions).
- Dissolved teams on the Teams page: the page lists current teams (`cma.teams()`); a dissolved team keeps its history in the database and can be revived by writing its key again, but is not listed. A `teams_all()` read would be a small follow-up if Arno wants to see them.
- A skill's level scale is edited as one comma-separated line of names (level 1 first); renaming a level renames it, removing one is refused by the database while someone holds it (the message says so).

## 5. What could not be tested in the night

- **Nothing in dev or prod.** No Google identity: no Cloud SQL, Cloud Run, Cloud Build or Cloud Scheduler. Every script ran on PostgreSQL 18.6 locally; every verifier ran against the local mock server and the local database. The `records/*-2026-10-09` folders are placeholders until the morning.
- **The Cloud Run job itself** (`gcloud run jobs deploy`, the connector path with the service account, Cloud Scheduler's OAuth call). The job script ran locally through the plain path with the dev seeds and closed a forgotten day end to end (`verify/scheduler.mjs`); the `gcloud` commands in `docs/scheduler/deploy.sh` were written against the current `gcloud run jobs deploy` and `gcloud scheduler jobs create http` references (section 6) and not executed. The runbook's step 3.2 executes the job once by hand and reads its log before the schedule is trusted.
- **The real Docker build.** `npm run build` ran locally with the repository's settings; the Dockerfile's new `COPY … /app/jobs ./jobs` line was checked by reading, not by building the image. If the build fails on it, the line is the one to look at.
- **IAP mode** for the five screens: the night ran in mock auth; the screens use the same shell, routes and guards as People.
- **`npm ci` ran with `--ignore-scripts`** in the night's container (the README notes two blocked install scripts); `typecheck`, `lint`, `build` and every verifier ran on that install.

## 6. The scheduler's fact check (with sources)

- **`pg_cron` on Cloud SQL for PostgreSQL**: enabled with the database flag `cloudsql.enable_pg_cron` plus `cron.database_name`, and setting the flag restarts the instance; the extension is installed in one database per instance and the jobs run as the role that scheduled them (sources read: the pg_cron set-up pages of TensorZero and freeCodeCamp quoting Cloud SQL's flag, the AlloyDB flags reference for the restart semantics of `*.enable_pg_cron`, the Citus pg_cron README's one-database-per-instance rule; Google's own Cloud SQL flags page was not reachable from the night's search tool, so the morning may confirm the restart on that page in one look). Consequence for the CMA: a restart of `cma-prod-pg` (high availability, real time) for a scheduler, and an audit actor that is a database login rather than the tenant's scheduler user. Not chosen.
- **Cloud Run jobs**: `gcloud run jobs deploy` (create or update) with `--image`, `--command`, `--args`, `--service-account`, `--set-cloudsql-instances`, `--set-env-vars`, `--tasks`, `--max-retries`, `--task-timeout`; `gcloud run jobs execute … --wait` runs it by hand (the `gcloud run jobs create/deploy` references on cloud.google.com, October 2026).
- **Cloud Scheduler → a job**: `gcloud scheduler jobs create http` with `--uri=https://<region>-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/<project>/jobs/<job>:run`, `--http-method=POST`, `--oauth-service-account-email=<sa>`, `--schedule`, `--time-zone`; the service account needs `roles/run.invoker` on the job (`gcloud run jobs add-iam-policy-binding`). Three jobs per billing account are free; the API `cloudscheduler.googleapis.com` must be enabled (the deploy script does).
- **Plan dependencies**: none; Cloud Run jobs and Cloud Scheduler are in every project. The EU-only folder policy is honoured: the job and the schedule live in `europe-west4`.

## 7. The night's verify output (local)

`27_verify_configuration.sql` verdict: `pulse4all-invest | 1 | scheduler | 120 (default) | 5 | 2 | PASS`, `pulse4all-subscriptions | 1 | scheduler | 120 (default) | 7 | 3 | PASS`; provoked: `FAIL A2`, `FAIL B1`, verdict `PROVOKED, NOT A PASS` (`local-records/verify-0005a-local*.txt`). `18` after the adjustment: PASS, provoked `FAIL A4`, `FAIL B2`. `14`, `16`, `20`, `22`, `25`: PASS after 0005a. `26` rerun: no change.

Pure verifiers: copy 500 keys PASS; corrections 26, csv 15, dashboard 17, live 26, team 18, roster 31, configuration 30: all PASS and all fail provoked. Theme: PASS, 18 pages; provoked FAIL (4 problems). Layout: PASS, five identities with the Configuration group; provoked FAIL (3 problems).

API verifier against the local database: `ALL 138 PASS`; `ALL 138 PROVOKED CHECKS FAILED, as they must` (`local-records/api-verify-138*.txt`). Scheduler verifier: `ALL 10 PASS`; `ALL 10 PROVOKED CHECKS FAILED, as they must` (`local-records/scheduler-verify-local*.txt`), also with `CMA_DB_SET_ROLE=cma_app` under a non-inheriting login.

`git apply --check` of the four patches in sequence on a fresh clone of `main` (`ff93b8e`): clean; the tree equals the branches.

## 8. Known risks

- **The frozen-flags rule meets Invest at step 10**: Invest keeps the universal ladder, so its statuses have no time yet and their flags are free; once agents clock in there, the rule applies. Fine, but worth knowing.
- **The scheduler and a shift that ends after midnight**: none at Pulse4all (Decision log, 7 October); a tenant with night shifts needs the `business_day_end` setting before the scheduler is fair to them.
- **The hourly job and a long outage**: the job retries nothing (`--max-retries=0`); the next hour's run closes everything that is due, so a missed hour costs an hour, not a day.
- **The verifier's days 400 days back** (API and scheduler) keep accumulating in dev, one each per run; dev data.
- **`npm audit`**: unchanged, 5 high in `eslint-config-next` (devDependency); the night added no dependency.
- **`records/layout/` screenshots**: the night's runs wrote them and the night restored the committed ones; the morning's run writes the real ones for the commit.

## 9. For the sixteenth pass's successor

With Arno: the grace (120 minutes), whether Team hours should tell him the scheduler closed a day (it shows Not clocked out and the system row in the editor; a chip of its own is a small web follow-up), and the coverage targets per team now that the grid exists. With Yordi: the scheduler as a system actor in the audit. Next build: slice 4 of this handover (My account, shift templates, the supervisor's read-only planner), then Sync.
