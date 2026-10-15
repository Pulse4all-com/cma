# Night notes, 15 to 16 October 2026: Workspace quick wins (N16-A), the CRM tasks and the follow-up layer (N16-B)

Written by Claude Code while Martin and Joshua were away. Everything was built and verified in the session's own container: PostgreSQL 16 from the distribution with `db/00` to `69` in README order and then `70` to `73`, Node 22, the standalone build of `web/` in mock mode and in api mode against that database. Nothing touched dev, prod, GCP, Secret Manager, Google Workspace, HubSpot or any vendor; no secrets, no real personal or customer data, the dev seed only. `records/` is untouched; the night's local outputs are in `local-records/` next to this file.

**Two branches, two pull requests.** `night-2026-10-16-a` from `main` (1146ee3, B17b): [N16-A: Workspace quick wins](https://github.com/Pulse4all-com/cma/pull/141), web only, no migration. `night-2026-10-16-b` from `night-2026-10-16-a`: N16-B, the CRM tasks (0008n) and the follow-up layer (0008o), merged after N16-A; it shows N16-A's commits until then, and is rebased on `main` by me in the morning if you ask.

**Migration numbers:** README Planned migrations and `db/` ended at 0008m and `69`, so 0008n is `70` and `71`, 0008o is `72` and `73`, as the brief said.

**Local only, not a decision:** PostgreSQL 16 in the container has no `uuidv7()`, so the database was built with a shim `public.uuidv7()` (a version-7 id from the clock and random bits) before `00`; nothing in `db/` changed for it. Cloud SQL (PostgreSQL 18) has the function. The local application login `cma_web` (a member of `cma_app` with `set role`) exists only in the container, to run the API verifier in api mode.

## What was built

### Part A (N16-A, in PR #141)

1. **The 80th percentile left Speed to lead and Inbound.** Types, SQL and the JSON API keep it (README API: "returned, not shown"); `verify/reports.mjs` and `verify/hints.mjs` no longer expect the column.
2. **The rail folds to icons.** Cookie `cma-rail`, `data-rail` on the frame, 64 px, labels and keycaps hidden, `title` and `aria-label` with the key, the toggle at the foot on W (a page's own W wins). Digit keys, C and L work folded.
3. **Breadcrumbs** from the navigation model (`breadcrumbs()` in `src/lib/nav.ts`), a page's own trail through `Shell`'s `trail` prop.
4. **Keyboard hints hide** with the cookie `cma-hints`, the top-bar icon and `?`; `aria-keyshortcuts` on the rail's links and the top-bar controls.
5. **Preview as role**, admin only: `src/lib/auth/preview.ts` narrows the permissions to the intersection in `getAccess()`; `POST /api/v1/me/preview`; the cookie `cma-preview-role` is httpOnly, 12 hours, cleared by Log out. The database still runs with the real permissions; data is the admin's own.
6. **What your role allows** on My account from the copy map `allow.<key>`.
7. **Roster copy:** the week as one range, the cell placeholder and the keyword list from the tenant's absence types, Previous / This week / Next no longer wrap at 1280.
8. A8 (the line switch-off dialog showing the calls removed) was not started.

### Part B1, addition 0008n: CRM tasks (`db/70`, `db/71`)

- `cma.crm_task` through `setup_tenant_table`; the task's text never enters the database: `cma.task_raw()` strips body, subject, note, text, description, html, the connection's own property names (`task_body_property`, `task_subject_property`), strings with an `@` and strings over 200 characters; `cma.task_raw_ok()` is a check on the column, so not even the owner can store such a key.
- The catalogs `connection_task_status` (`is_done`) and `connection_task_type` (`is_callback`, `is_counted`) fill from the rows and are set with `cma.set_task_status()` and `cma.set_task_type()` (tenant.configure); `cma.connection_task_catalogs()` feeds Sources.
- `cma.ingest_upsert_tasks()` as `ingest_upsert_records` (500 at most, stale guard, outcomes inserted, updated, stale, deleted, unknown); the contact, deal and ticket are columns on the row, taken as the read gives them (a decision, in the README's Decision log).
- Contacts held for tasks (0008m's rule extended), the privacy deletion clears a task's contact and answers how many; task rows make a connection `crm`.
- Ingest: the HubSpot adapter reads tasks (eight properties, three associations) from webhooks, the reconcile and the backfill (`--object task`); the store writes tasks after records. The project template gained nine task subscriptions (46 in all), no new scope. **A new app version has to be uploaded and the install's update accepted in both portals** (morning runbook steps 6 and 11; `PROD_RUNBOOK.md` 11.2).
- `71`: 20 PASS, provoked 20 FAIL; `70` run twice (`INSERT 0 1`, then `INSERT 0 0`). `ingest/verify/mapping.mjs` 48 PASS, `hubspot/verify/render.mjs` 33 PASS, each provoked all fail.

### Part B2, addition 0008o: the follow-up layer (`db/72`, `db/73`)

- Settings `tickets.sla_minutes` 240, `tickets.sla_warning_pct` 75, `leads.age_buckets_business_days` `1,2,5`, `tasks.callback_window_minutes` 240, checked by `cma.check_tenant_setting()` and seeded for both Pulse4all tenants in `02`; `connection_pipeline.sla_minutes` with `cma.set_pipeline_sla()`; the lead target stays `speed_to_lead.target_minutes`.
- `cma.open_leads_of`, `open_tickets_of`, `open_tasks_of`, `follow_up_summary_of`, `follow_up_by_owner_of`, `my_follow_up_of` and their wrappers; the permissions as the brief gave them (per person for `performance.team` only).
- Data quality: the skip rule `dq_unlinked_skip` (default on for kind `telephony`, `none` off), `ticket_no_owner` and `ticket_no_market` once a response time is configured, `crm_task_owner_unlinked`.
- **One change from the brief's letter:** 0008m's `cma.data_quality_added_checks()` is pinned by `69` to its one row, and a verify script that has run in prod is never edited, so the three new checks live in a new `cma.data_quality_follow_up_checks()`; `cma.data_quality()` reads both. `69` passes unchanged.
- `73`: 21 PASS, provoked 21 FAIL; `72` run twice; `41`, `69` and `71` unchanged after it. The first run of `73` failed three checks on my expectation, not on the code: a lead two days old is also past the hour's target, so `leads_past_target` is 2 and the not-mapped row carries one; the expectations were corrected.

### Part B3: the Workspace

- **Reports → Follow-up** (`/reports/follow-up`, after Speed to lead; `reports.view`, `performance.team` or `monitoring.live`): eight tiles, the three tables, Per person for `performance.team`, the filters market (K), person (O) and state (S) in the address, `LiveRefresh` every 10 seconds, every header and tile with a hint.
- **Waiting for you** (`/me/follow-up`, `leads.accept` or `workday.own`; breadcrumbs Welcome › Waiting for you) and its Welcome card; **Needs attention** on Welcome in place of Before today's shift; **Follow-up now** on the Live board.
- **Sources:** task statuses and types of a CRM connection, a response time per ticket pipeline, the Unlinked calls check select on a telephony connection, the `record_url_task` hint. **Exports:** the Follow-up section with the four settings.
- API: `GET /api/v1/reports/follow-up/{leads,tickets,tasks,summary,by-owner}`, `GET /api/v1/me/follow-up`, `PUT …/sources/{id}/pipeline-sla`, `…/task-statuses`, `…/task-types`; both data layers (Postgres through the new functions; the mock with a fixture relative to the clock).
- `src/lib/follow-up.ts` (pure) with `verify:follow-up` (25 checks); copy 1601 keys EN and NL.
- B4 (callbacks kept) did not land: the catalogs and the window setting are in place, the figure is not computed (Open decisions).

## How it was verified (local, see `local-records/`)

- `web/`: `npm ci`, `npm run build`, `npm run typecheck`, `npm run lint`, all exit 0 (on both branches).
- Pure verifiers on N16-B: copy PASS (1601 keys), corrections 31, csv 16, dashboard 17, live 39, team 26, roster 36, configuration 92 (one expectation updated: a CRM connection has six sections), messages 24, import 23, signed-out 16, invitations 27, preview 18, **follow-up 25**, reports 75. `verify:datamap` fails on N16-B as expected (the three 0008n tables and the six 0008o views are not in `schema.json` until you refresh it from dev; the index is rebuilt then).
- Browser verifiers against the build in mock mode: theme PASS (49 pages), hints PASS (315 headers and 81 tiles on 24 pages), layout PASS; each provoked FAIL.
- `verify/api.mjs --follow-up`: 16 PASS against mock data (provoked all fail); 9 PASS against the local database in api mode (the reader identity and a CRM connection are not in the dev seed, so two parts print a note and are left out). `--sources` 32 PASS, `--preview` 11 PASS.
- Database: the fresh build `00` to `69`, then `70` twice, `71` normal and provoked, `72` twice, `02` again, `73` normal and provoked, then `41`, `69` and `71` again.

## What was left and why

- **A8** (the line switch-off dialog with the calls removed) and **B4** (callbacks kept): time went to the three slices and their verifiers; both are in the backlog rows below.
- **`verify:api` in full** was not run (it needs the workday window and the reports fixture); the groups `--follow-up`, `--sources` and `--preview` were.
- **The data map index** (`docs/datamap/index.html`) is not rebuilt: the build refuses while the catalog and the snapshot disagree, by design; it is rebuilt after your `schema.json` refresh (morning runbook step 5).

## Questions for the morning

1. HubSpot's task statuses and types in the live portal: which status means done (`COMPLETED` alone, or `DEFERRED` too), which type is the callback. Set on Sources after the backfill (`PROD_RUNBOOK.md` 11.4).
2. The task's address in HubSpot for `record_url_task`: whether a task opens on its own page or on its record's; the morning runbook step 9 checks it in dev.
3. The response time per ticket pipeline: the default 240 business minutes and the warning at 75 % are the brief's; Arno and Kira confirm them on Exports.
4. The Unlinked calls check: the default skips outbound calls never connected and never tagged; Arno decides whether every call should be checked.

## Open ends (README Open decisions, not solved tonight)

- Alert rules on tasks and on tickets against their response time.
- Hiding the hints after a person's first week; a shortcut letter for the Preview as select (fewer letters are free now that Follow-up takes K, O and S).
- Dropping the 80th percentile from the SQL functions and the JSON API.
- HubSpot's SLA properties feeding `connection_pipeline.sla_minutes`.
- The exact HubSpot task URL for `record_url_task`.
- Task types as a catalog scoped across connections.

## Backlog rows

| Row | State |
|---|---|
| CMA-004 Hide keyboard hints | Done (N16-A): cookie `cma-hints`, the top-bar icon and `?`; by default after the first week stays open |
| CMA-007 Tasks in the Workspace | Done except task alerts (0008n): the rows without their text, the catalogs, the ingest; alerts are an open end |
| CMA-015 Follow-up overview | Done, reshaped (0008o, Reports → Follow-up): a "now" page with filters, not a period report |
| CMA-019 What my role allows | Done (N16-A) |
| CMA-036 Tickets against their SLA | Done (0008o): settings, per-pipeline override, states, the lists and tiles |
| CMA-045 Leads not called with their age | Partly: the list, the age groups and the last call (0008o); the age groups as a chart and a per-period figure follow |
| CMA-046 Per person what is waiting | Done (0008o, `performance.team` only) |
| CMA-050 Data quality: unlinked outbound calls | Partly: the skip rule for calls never connected and untagged (0008o); a per-line rule did not land |
| CMA-052 Tickets without owner or market | Partly: the two checks run once a response time is configured (0008o); no alert on them |
| CMA-061 Roster copy | Done (N16-A) |
| CMA-020 Line switch-off shows the calls removed | Not started (A8) |
| CMA-017 | Stays Later |
| New: the 80th percentile removed from the reports | Done on screen (N16-A); dropping it from SQL and API is an open end |
| New: the collapsible rail and breadcrumbs | Done (N16-A) |
| New: preview as role | Done (N16-A) |
| New: ticket response-time configuration (tenant default, per pipeline, warning share) | Done (0008o, Sources and Exports) |
| New: callbacks kept (KPI 5) | Not done (B4): the catalogs and the window are in place, the figure is not computed |
