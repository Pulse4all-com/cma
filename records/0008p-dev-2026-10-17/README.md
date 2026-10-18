# Addition 0008p in dev, 17 October 2026

Brief B17d (forms reporting, addition 0008p; `Pulse4all-com/cma#145`, squash-merged as `964a347`), steps 2
and 7 of `docs/b17d-forms/MORNING_RUNBOOK.md`, run by Martin on 17 October 2026 in p4a-cma-dev (cma-dev-pg),
after 0008o (`records/0008o-dev-2026-10-16`). Written down by Claude Code on 18 October 2026 at Martin's
request from his report and the outputs he pushed to this folder; the values are his. Ids, counts, dates
and times only: no key, no secret and no personal data. The outputs were committed on 18 October 2026 with
`Pulse4all-com/cma#167`.

The file names are the ones the runbook's commands write: step 2's `run_migration` (the migration, its
verify, the provoked verify and the earlier verifies again), step 2's `74` again, and step 7's `verify:api`.
The rest of B17d's dev run is in `records/b17d-dev-2026-10-17`, whose "Not in the report" listed `75`'s
counts, its provoked run, `74`'s rerun and the earlier verifies' counts: they are the files below.

## Database (step 2)

| Script | File | Result |
|---|---|---|
| `74_forms_reporting.sql` | `74.txt` | ends `INSERT 0 1`, `COMMIT`, `RESET`; `UPDATE 1` (the existing forms' `is_polled` set as they count); notices only for the checks, the foreign key, the policies and the audit triggers that did not exist yet |
| `74_forms_reporting.sql` again | `74-rerun.txt` | ends `INSERT 0 0`, `COMMIT`, `RESET`; `UPDATE 0`; notices only for the tables and columns that already exist and the policy `tenant_readonly` that does not |
| `75_verify_forms_reporting.sql` | `75.txt` | `is_dev` true; 24 rows `PASS` (A1 to A5, B1 to B19); verdict `PASS`, `24 PASS, 0 FAIL`, `(25 rows)` |
| `75_verify_forms_reporting.sql` with `verify.provoke` true | `75-provoked.txt` | every row `FAIL`; verdict `PROVOKED, NOT A PASS`, `0 PASS, 24 FAIL` |
| `41_verify_lead_metrics.sql` again | `41-rerun.txt` | two tenant rows, each `PASS`: `pulse4all-invest` (0 lead deals, 0 called, 0 data-quality findings) and `pulse4all-subscriptions` (2, 1, 5) |
| `53_verify_sources_configuration.sql` again | `53-rerun.txt` | 16 rows `PASS`, A4 `0 connection(s) without the kind their rows imply`; verdict `PASS`, `16 PASS, 0 FAIL` |
| `69_verify_email_activity.sql` again | `69-rerun.txt` | 29 rows `PASS`; verdict `PASS`, `29 PASS, 0 FAIL` |
| `71_verify_crm_tasks.sql` again | `71-rerun.txt` | 20 rows `PASS`; verdict `PASS`, `20 PASS, 0 FAIL` |
| `73_verify_follow_up.sql` again | `73-rerun.txt` | 21 rows `PASS`; verdict `PASS`, `21 PASS, 0 FAIL` |

`41` and `53` differ from `records/0008o-dev-2026-10-16`: `41` lists the two Pulse4all tenants only, not the
four leftover `email-…` tenants, and `53`'s A4 passes. That record's note gives a one-off removal of those
tenants with these two results as its expected outcome; when it ran is not in the report.

`75`, `53`, `69`, `71` and `73` are dev only by their headers: each refuses a database that does not hold the
dev seed's active test person, which prod never holds. Prod ran `74` twice and `33`, `35` and `41`
(`records/0008p-prod-2026-10-17`).

## The API verifier (step 7)

| Run | File | Result |
|---|---|---|
| `node verify/api.mjs` against `http://localhost:8080` (step 7: dev's `cma-web` through the service proxy) | `verify-api.txt` | 271 lines `PASS`, none `FAIL`; `ALL 271 PASS` |

Six `note` lines name the checks left out: the reader's two (no reader identity in this tenant; the reader
has no access here), the invest-analyst's three (a tenant without sources; twice a tenant without telephony)
and the 5 checks of the missed-reason catalog (no telephony connection in this tenant). The count is the one
`records/b17d-dev-2026-10-17` gives for step 7 (271 PASS).

## Not in the report

- The times of the runs.
- `33` and `35` again in dev: step 2's `run_migration` names them, and this folder holds no output of them.
- The provoked run of `verify:api` (step 7).
- When the one-off removal of the four `email-…` tenants (`records/0008o-dev-2026-10-16`, Note) ran.
