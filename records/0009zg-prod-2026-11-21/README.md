# Addition 0009zg in prod, 21 November 2026

Addition 0009zg, Juo's own figures beside the CMA's (`Pulse4all-com/cma#307`, brief B39 continued, Part B39b):
`db/214_source_figures.sql` and `db/215_verify_source_figures.sql`, run by Martin on cma-prod-pg with `run_migration` from
the Terminal on 21 November 2026, after the dev run of the same day (`records/0009zg-dev-2026-11-21`); then the merge, the
ingest's deploy and the first runs of the job (`docs/ingest/PROD_RUNBOOK.md` Phase 19). The eight output files in this
folder are his run (`node tools/check-records.mjs` clean); everything from 19.5 on comes from his report. This note was
written down by Claude Code on 22 November 2026 at Martin's request, from his report and those files, and the values are
his. Verdicts, counts, ratios, times and dates only: no key, no secret, no personal data and no commercial volume (no
amount: 19.7's unit check shows ratios alone).

## 19.4 The migration and its verifies

| Step | File | Result |
|---|---|---|
| `214_source_figures.sql` | `214.txt` | `INSERT 0 1`: addition 0009zg recorded; `COMMIT` |
| `215_verify_source_figures.sql` | `215.txt` | `REFUSED`: 5 PASS, 1 FAIL. A1 to A5 PASS (A5 lists the seven figures with `exits`, and `source_figure_gap` at 400, fixed in subscriptions); block B FAIL because prod has no dev seed, as expected |
| `215_verify_source_figures.sql`, provoked | `215-provoked.txt` | `REFUSED`: 0 PASS, 6 FAIL |
| `123_verify_flash.sql` again (edited by 0009zg) | `123-rerun.txt` | `0008zn verified`: 40 ok, 0 FAIL, 4 skip |
| `137_verify_flash_insights.sql` again (edited by 0009zg) | `137-rerun.txt` | `0008zt verified`: 24 ok, 0 FAIL, 1 skip |
| `139_verify_flash_totals.sql` again | `139-rerun.txt` | `0008zu verified`: 16 ok, 0 FAIL, 1 skip |
| `159_verify_flash_current_take.sql` again | `159-rerun.txt` | `0009e verified`: 12 ok, 0 FAIL, 0 skip |
| `179_verify_job_reads.sql` again | `179-rerun.txt` | `FAIL`: 27 ok, 1 FAIL, 0 skip |

179's one FAIL is E5 for pulse4all-subscriptions: `7178 rows now against 7097 before: 81 only now, 0 only before`. The 81
are all `subscription_device_units_mismatch` (Martin counted them). 179 keeps a copy of 160's `cma.data_quality_of`,
which has none of the checks added since, so the gap is the old copy's, not a changed answer; `Pulse4all-com/cma#309`
edits E5 to compare only the check keys the old copy knows (PROD_RUNBOOK 19.12 reruns 179 after it). Dev's E5 read ok
because dev holds no finding of those checks.

## 19.5 The merge and the deploys

`#307` merged as `fc958670`. The ingest deployed from `main` as `cma-ingest-00028-b8j`; the job `ingest-source-figures`
created with its schedule paused.

## 19.6 The first run

One manual run: `read` 9, `failed` 0.

## 19.7 The first stored figures and the amount's unit

Of the 108 stored figures read, 106 equal the CMA's value. The other two are `exits` with status `canceled`, where the
CMA's value is double the app's (Martin's report). Open: the cause and its fix are not in `Pulse4all-com/cma#309` as of
its head `4bf8008`.

The unit check of `recurring_amount_active` against Customers → Active's Monthly recurring amount: `ok` for every store
and currency, the ratios from 0.95 to 1.00. So Juo's `current-mrr` is in the currency's own unit, as stored.

## 19.8 The schedule

`ingest-source-figures` resumed.

## 19.9 The months before

The month backfill of the flow figures for every store: `failed` 0, about 4.5 minutes.

## 19.10 Data quality

The check `source_figure_gap` is present, with 0 gaps. It reads the latest date per store, figure and status only, and
19.7's two doubled `exits` did not show there (Martin's report). Open: the check is not changed in `Pulse4all-com/cma#309`
as of `4bf8008`.

## 19.11 The data-quality refresh

The refresh after the merge: 15,752 ms.
