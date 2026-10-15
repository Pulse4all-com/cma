# Local records, night of 15 to 16 October 2026

These are the outputs of the night's local runs in Claude Code's container: PostgreSQL 16 from the distribution (with a local `public.uuidv7()` shim, since PostgreSQL 16 has no `uuidv7()`; Cloud SQL's PostgreSQL 18 has it), Node 22, and the standalone build of `web/` in mock mode and in api mode against that database. They are not release records; `records/` stays Martin's. No value here comes from dev, prod or GCP.

## `db/` (N16-B)

| File | What |
|---|---|
| `70_crm_tasks-first-run.txt`, `70_crm_tasks-rerun.txt` | Addition 0008n, first run (`INSERT 0 1`, `COMMIT`) and rerun (`INSERT 0 0`, nothing new), on the database built from `00` to `69` in README order. |
| `71_verify_crm_tasks.txt`, `71_verify_crm_tasks-provoked.txt` | The verify: 20 PASS, verdict PASS; with `verify.provoke`: 0 PASS, 20 FAIL, verdict `PROVOKED, NOT A PASS`. |
| `72_follow_up-first-run.txt`, `72_follow_up-rerun.txt`, `02_seed_pulse4all-after-72.txt` | Addition 0008o, first run and rerun; the Pulse4all seed again after it (the four follow-up settings for both tenants). |
| `73_verify_follow_up.txt`, `73_verify_follow_up-provoked.txt` | The verify: 21 PASS, verdict PASS; provoked 0 PASS, 21 FAIL. |
| `41_verify_lead_metrics-at73.txt`, `69_verify_email_activity-at73.txt`, `71_verify_crm_tasks-at73.txt` | The three rerun after `72` and `73`: `41` both tenant rows PASS, `69` 29 PASS, `71` 20 PASS; unchanged. |

## `ingest/` (N16-B)

| File | What |
|---|---|
| `lint.txt` | `npm run lint` in `ingest/`, exit 0. |
| `mapping.txt`, `mapping-provoked.txt` | `ingest/verify/mapping.mjs` with the eleven task checks: 48 PASS; provoked all 48 failed. |
| `render.txt`, `render-provoked.txt` | `hubspot/verify/render.mjs` with the task subscriptions (46 in all) and the check that no subscription names `hs_task_body` or `hs_task_subject`: 33 PASS; provoked all 33 failed. |

## `web/`

### N16-A (the first branch)

| File | What |
|---|---|
| `npm-ci.txt`, `typecheck.txt`, `lint.txt` | `npm ci`, `npm run typecheck` and `npm run lint` in `web/`, all exit 0. `npm run build` ran before the browser verifiers (exit 0, the build those runs used). |
| `verify-<name>.txt` | The pure verifiers CLAUDE.md names, each with its exit code: copy (1402 keys), corrections 31, csv 16, dashboard 17, live 39, team 26, roster 36, configuration 92, messages 24, import 23, datamap (72 tables, 89 views), signed-out 16, invitations 27, preview 18 (new), reports 75. |
| `layout.log`, `theme.log`, `hints.log` | The browser verifiers against the build in mock mode on a freshly started server: PASS. `layout` covers the folded rail (cookie and W), the hidden hints (cookie and ?), `aria-keyshortcuts`, breadcrumbs on six pages, preview as role for the admin and ignored for the manager and the agent, and the roster's week bar; `theme` 46 pages; `hints` 233 headers and 59 tiles. |
| `*-provoked.log` | The same three with `--provoke`: FAIL with 41, 6 and 3 problems, as they must. |
| `verify-api-preview-mock*.txt` | `verify/api.mjs --preview` against the build in mock auth and mock data: 11 PASS, and provoked all failed. |
| `screenshots/` | From `verify/layout.mjs` at 1280 px: the folded rail on Welcome and Inbound, the admin previewing as the agent, the Sources detail with its breadcrumbs, the roster's week bar, My account with "What your role allows", and Speed to lead without the 80th percentile. |

### N16-B (the second branch, on top of N16-A)

| File | What |
|---|---|
| `typecheck-n16b.txt`, `lint-n16b.txt`, `build-n16b.txt` | In `web/`, all exit 0; the build the browser and API runs below used. |
| `verify-copy-n16b.txt`, `verify-follow-up-n16b.txt`, `verify-follow-up-n16b-provoked.txt`, `verify-configuration-n16b.txt`, `verify-reports-n16b.txt` | copy PASS (1601 keys); follow-up PASS (25 checks, new, pure) and provoked all failed; configuration 92 (one expectation updated: a CRM connection has six sections); reports 75. The other pure verifiers passed unchanged (corrections 31, csv 16, dashboard 17, live 39, team 26, roster 36, messages 24, import 23, signed-out 16, invitations 27, preview 18). |
| `verify-datamap-n16b.txt` | `datamap: FAIL` naming the three 0008n tables and the six 0008o views as not in `schema.json`, and the index as not rebuilt: expected until Martin refreshes the snapshot from dev (morning runbook step 5). |
| `layout-n16b.log`, `theme-n16b.log`, `hints-n16b.log` | The browser verifiers against the N16-B build in mock mode: PASS. `layout` adds Follow-up to every identity's rail, the three filters' keycaps, the right-most header hints of the tickets and tasks tables, the reader without the per-person table, no table for an agent, the breadcrumbs of Follow-up and Waiting for you, the manager's 17 rail pages while previewing; `theme` 49 pages (three new: Follow-up for the manager and with the attention filter for the supervisor, Waiting for you); `hints` 315 headers and 81 tiles on 24 pages (Follow-up's tiles and tables, Waiting for you, the Live board's follow-up strip). |
| `*-n16b-provoked.log` | The same three with `--provoke`: FAIL, as they must. |
| `verify-api-follow-up-mock*.txt` | `verify/api.mjs --follow-up` against the build in mock data: 16 PASS (the five report routes and the person's own, their permissions, shapes, order and filters; the Sources writes of a pipeline's response time and a task status); provoked all failed. |
| `verify-api-follow-up-local-db.txt` | The same group against the build in api mode on the local database at `73` (as the application login `cma_web`, a container-only member of `cma_app`): 9 PASS; the reader identity and a CRM connection are not in the dev seed, so two parts print a note and are left out. |
| `verify-api-sources-mock.txt`, `verify-api-preview-mock-n16b.txt` | `--sources` 32 PASS and `--preview` 11 PASS on the N16-B build. |
| `screenshots/` | Also from the N16-B layout run: Follow-up for the manager, Waiting for you for the agent, Welcome with Needs attention and Waiting for you, the Live board's follow-up strip, Sources with the task catalogs. |
