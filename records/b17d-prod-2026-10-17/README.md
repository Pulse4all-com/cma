# B17d in prod, 17 October 2026

Brief B17d (forms reporting, addition 0008p; `Pulse4all-com/cma#145`, squash-merged as `964a347`), the prod
steps of `docs/b17d-forms/MORNING_RUNBOOK.md` (5, 6 and 9 to 13; step 12 runs the browser verifiers against a
local mock server), run by Martin on 17 October 2026 in p4a-cma-prod (cma-prod-pg) and the live portal,
after dev (`records/b17d-dev-2026-10-17`). The HubSpot connection `01a12f17-4fcb-7406-b0ff-b335c54f828a`,
tenant `pulse4all-subscriptions`. Written down by Claude Code at Martin's request from his report of the
run, as `records/b17b-*` were (`Pulse4all-com/cma#144`); the values below are his. Ids, counts, dates and
times, form and field names and option values only: no key, no secret, no personal data and no free-text
answer. The terminal and psql outputs of the run are not in this folder.

## Step 5: 0008p in prod, Intake A

- 0008p applied in prod at 09:58 UTC, before the merge.
- Intake A: Intake's form submissions from 1 October to 17 October 00:00 (Europe/Amsterdam), per market,
  in the table under 10h.

## Step 6: the merge

`Pulse4all-com/cma#145` squash-merged as `964a347` (git: 10:02:18 UTC), after step 5.

## Step 9: the ingest jobs, the forms' fields

- The ingest jobs deployed on `964a347`; the service `cma-ingest` was not redeployed.
- The first catalog refresh with fields ran at 14:32 UTC, about an hour after the deploy: the forms poll
  refreshes the catalog only when the cursor `forms:catalog` is an hour old.
- 50 active forms, 50 described.

| Choice field | Kind | Forms |
|---|---|---|
| `are_you_already_a_customer` | radio | 9 |
| `call_me_back` | single_checkbox | 1 |
| `cancellation_reason` | dropdown | 10 |
| `country_dropdown` | dropdown | 35 |
| `customer_sector` | dropdown | 2 |
| `deployment_outcome` | dropdown | 1 |
| `exchange_reason` | not in the report | 10 |
| `exchange_type` | not in the report | 10 |
| `hs_ticket_category` | multiple_checkboxes | 1 |
| `request_channel` | not in the report | 10 |
| `source_type` | not in the report | 10 |
| `ticket_country` | not in the report | 9 |
| `use_case` | not in the report | 9 |

`call_me_back` is not in brief B17d's data: listed, never kept. `deployment_outcome` is listed and never kept
(README, Decision log, 16 October 2026).

## Step 10: the configuration, the backfill, Intake before and after the lead rule

**10a.** The seven categories.

**10b.** The 28 counted forms got their category from their lead source:

| Category | Forms | With a market |
|---|---|---|
| `contact` | 9 | 9 |
| `info` | 9 | 9 |
| `quote` | 10 | 9 |

Deviation: the generic "Quote Form" (`8358d560-d791-4bbc-8d33-bef2764b784a`) has no market and has had
0 submissions ever. It stays counted, without a market (README, Decision log, 17 October 2026).

**10c.** The 22 support forms set polled, not counted, with category and market:

| Category | Forms |
|---|---|
| `cancellation` | 10 |
| `replacement` | 10 |
| `iban_change` | 1 (DE) |
| `support` | 1 |

The general cancellation and replacement forms and the General support form have no market.

**10d.** The kept fields as brief B17d gives them. Deviation: `with_market_field` is 0 on every category.
The four forms without a market (Cancellation Form Helpdesk, Request a Replacement Device Form, General
support form Helpdesk, Quote Form) have no country field in HubSpot, so none of them has a market field;
their submissions take the contact's country, else unknown (README, Decision log, 17 October 2026).
`deployment_outcome` is kept nowhere.

**10e.** The backfill from 1 October, execution `ingest-backfill-7kflr`: succeeded.

| fetched | upserted | skipped | dropped |
|---|---|---|---|
| 478 | 262 | 216 | 0 |

The 216 skipped: 208 Quote submissions (Quote forms keep no field) and 8 Info submissions without a
`use_case` answer. Submissions since 1 October per category:

| Category | Submissions | With answers |
|---|---|---|
| `cancellation` | 13 | 13 |
| `contact` | 43 | 43 |
| `info` | 212 | 204 |
| `quote` | 208 | 0 |
| `replacement` | 2 | 2 |

**10f.** Intake B equals Intake A, market by market (448).

**10g.** The lead condition is set on the nine Contact forms: `are_you_already_a_customer` in
"No, I'm not a customer yet", the value taken from each form's options in the catalog. Kira was informed
beforehand with the figures and agreed.

**10h.** Intake C. Of the 43 Contact submissions, 24 came from existing customers.

| Market | Intake A (step 5) | Intake B (10f) | Intake C (10h) | A − C |
|---|---|---|---|---|
| AT | 3 | 3 | 3 | 0 |
| BE | 27 | 27 | 27 | 0 |
| DE | 63 | 63 | 60 | 3 |
| DK | 1 | 1 | 1 | 0 |
| FR | 63 | 63 | 58 | 5 |
| GB | 206 | 206 | 198 | 8 |
| IE | 0 | 0 | 0 | 0 |
| NL | 27 | 27 | 23 | 4 |
| SE | 58 | 58 | 54 | 4 |
| unknown | 0 | 0 | 0 | 0 |
| **Total** | **448** | **448** | **424** | **24** |

Intake B is written as Martin reported it, equal to Intake A market by market; A − C is the difference of
the reported columns.

## Step 11: read-only counts

| Read | Value |
|---|---|
| `forms_report` from 1 October | 478 submissions: 477 `resolved`, 1 `not_found` (an Info submission, GB) |
| Kept fields with answers (`forms_answers`) | seven |
| `forms_history_start` | 2026-10-01 |
| `answers_not_in_options` | 0 for both tenants |
| `forms_poll` runs in the last hour | 60 `succeeded`, 0 `dropped` |

## Step 12: the browser verifiers against a local mock server

| Verifier | Run | Provoked |
|---|---|---|
| `theme` | PASS | FAIL, 6 problems |
| `layout` | PASS | FAIL, 46 problems |
| `hints` | FAIL, 1 problem: the known date-dependent Speed to lead line (runbook step 12) | FAIL, 4 problems |

Playwright needed `npx playwright install chromium` first (browser build 1243); `docs/RUNBOOK.md`, Setup,
has the step since this record's pull request.

## Step 13: a hand check in prod

The page matches step 11. Reports → Forms, This month: 478 submissions, "No history to compare yet",
Contact found 477 of 478, 0 without a market. This week: the changes against the previous week shown.

## Where the run went otherwise than the runbook

The runbook is corrected in the pull request of this record (`docs/b17d-forms/MORNING_RUNBOOK.md`, and the
prefix pattern also in `docs/ingest/PROD_RUNBOOK.md` 7.5b):

- The name prefix pattern `'^\s*([A-Za-z]{2})\M'` needs single backslashes: with doubled ones it matches a
  literal backslash under `standard_conforming_strings` and finds no prefix.
- The context block as one Run: `set_config` through subselects as `cma_owner`, then `set role cma_app`.
- 10c and 10d: a read-only review query, then the same query calling the function after the context
  block, instead of statements generated to paste.
- 10g: the option value taken from `connection_form_field.options` (the one starting with "No,").
- Step 9: the first refresh with fields came about an hour after the deploy (the catalog cursor).
- 10d: `with_market_field` depends on the forms having a country field.

## Not in the report

- Step 5: the point-in-time recovery check, `74`'s and its rerun's last lines, the counts of `33`, `35` and
  `41`, and the forms per counted and polled state.
- Step 6: the prod build's status and time.
- Step 9: the jobs' deploy lines, the deploy's time and the `forms_poll` runs.
- 10a to 10d: the rows of the read-only checks beyond the counts above.
- 10e: the backfill's duration.
- Step 11: the counts per category and market, and which seven fields.
- Step 13: the narrowing by category and market, the download, and the Sources pages.
- The times of the steps other than 5 and 9.
