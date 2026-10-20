# Local records, attempts per deal (19 October 2026)

These are the outputs of local runs in Claude Code's container:
- PostgreSQL 16 from the distribution, with a local `uuidv7()` shim (PostgreSQL 16 has none; Cloud SQL's PostgreSQL 18 has it);
- Node 22;
- the standalone build of `web/` with mock sign-in.

They are not release records; `records/` stays Martin's. No value here comes from dev, prod or GCP: every id, name and count is the dev seed's, a verify script's invented data or the invented data of `web/verify/reports-fixture.sql` and `db/volume-timing.sql`.

## `db/`

A fresh database built from `00` to `90` in README order (the dev seeds included, `02` and `03` before `13`), then `92` twice, the verifies, the seeds again and the timings, all by the final versions of the scripts on this branch.

| File | What |
|---|---|
| `fresh-build.txt` | One line per script of the build after `00`, `01` to `90` (the verify scripts left out): every one `exit=0 errors=0`, with its count of notices. |
| `02_seed_pulse4all-before-13.txt`, `03_seed_dev_test_data-before-13.txt`, `13_tenant_settings.txt` | `02` and `03` run before `13` with their guards split: notices such as "the settings catalog does not exist yet (migration 0003b): rerun this seed after 62_calls_overview.sql" and "the per-person setting does not exist yet (addition 0008t): rerun this seed after 82_email_reports.sql", and no error. |
| `92_attempts_per_deal-first-run.txt`, `-rerun.txt` | Addition 0008y: the first run ends `INSERT 0 1`, `COMMIT`, `RESET`; the rerun is the same except `INSERT 0 0` for the migration row. |
| `fingerprint-after-92.txt`, `fingerprint-after-92-rerun.txt` | The functions of `cma` and `cma_read` with an md5 of their definitions, the views with an md5 of theirs, the settings and the migrations, after each run of `92`: identical, so the rerun adds nothing. |
| `93_verify_attempts_per_deal.txt`, `-provoked.txt` | 25 PASS (A1 to A5, B1 to B20), verdict PASS, in a second; provoked 0 PASS, 25 FAIL, `PROVOKED, NOT A PASS`. |
| `41_…` to `91_…-at-0008y.txt` | The earlier verifies after 0008y, unchanged: `41` both tenant rows PASS, `61` 20, `69` 29, `73` 21, `75` 24, `77` 14, `81` 19, `83` 26, `85` 26, `89` 15 and `91` 13 PASS (`91` in 1 min 46 s). |
| `per-person-after-92.txt`, `02_seed_pulse4all-rerun-after-92.txt`, `per-person-after-02-rerun.txt`, `03_seed_dev_test_data-rerun-after-92.txt`, `per-person-after-03-rerun.txt` | `reports.per_person` per tenant. After the build it is empty (no seed reran after `82`). After `02` again it is `email` for Pulse4all Subscriptions. After `03` again it is `email,orders,attempts`. Pulse4all Invest stays empty throughout. |
| `volume-timing.sql`, `volume-timing.txt` | Both page reads of October as `cma_app`, best of three, on a throwaway tenant at about twice prod's lead volume of 19 October 2026, rolled back. The tenant holds 3,000 lead deals, 1,500 order deals, 300 renewals, 9,598 CRM calls and 5,929 telephony calls (4,429 linked). The script refuses a Cloud SQL instance. Results: by day 286 ms, by pipeline with every counted deal 325 ms, one market 296 ms, per person 146 ms. |
| `reports-fixture-load.txt`, `timing-on-reports-fixture.txt` | `web/verify/reports-fixture.sql` loaded on a copy of the database (`fixture written`), then the runbook's step 7 block as the dev seed's admin: 6.9 ms, 6.3 ms and 6.2 ms on the fixture's handful of deals. |
| `schema_migration.txt` | The additions 0008s to 0008y recorded. |
| `lead-reads-before-92.txt`, `lead-reads-after-92.txt` | The runbook's lead-reads block (steps 1 and 6). It ran on a second fresh database at 0008x (`00` to `90`, `02` and `03` again, `reports-fixture.sql`) as the dev seed's two admins, before and after `92`. It gives, per tenant, the count and an md5 over every column of `cma.speed_to_lead_rows` and `cma.lead_to_order_rows` for 1 to 19 October 2026, ordered by tenant and deal: 6 and 6 rows for Pulse4all Subscriptions, 2 and 2 for Pulse4all Invest. Before and after are identical. |

## `web/`

| File | What |
|---|---|
| `checks.txt` | The last line of each check on this branch, in one pass from `npm ci`. That pass covers `npm ci`, build, typecheck, lint (0 errors; the one warning is in `web/verify/follow-up.mjs`, unchanged from `main`) and the nineteen pure verifiers. Every verifier passes except `verify:datamap`, which fails as expected until `schema.json` is refreshed from dev (the runbook's step 5). The pass also holds `verify:reports` provoked, and, against the mock server, `verify:api --attempts`, theme, hints and layout, each normal and provoked. This pass ran after the Attempts pages moved to directly after Speed to lead (19 October 2026). The pass script reads each exit code straight after its command; the first pass had logged the provoked layout line with its own `echo`'s exit 0. |
| `build.txt` | The output of that `npm run build`. |
| `layout-provoked-new-checks.txt` | The lines of the provoked layout run that the new checks give: the breadcrumbs of the two Attempts pages, the accordion, the wrapped marks, the attempts list spilling out of its card, the switch-off count. |
| `api-local-database.txt`, `-provoked.txt` | The full `verify/api.mjs` against a server in api data mode on the database above with `reports-fixture.sql`: ALL 297 PASS, the 16 new attempts checks among them; provoked, all 297 FAIL. On the same database before this branch's checks the count was 281. In dev, which has neither the `reader` nor the `invest-analyst` identity, the attempts part counts 12, or 14 with a telephony line. |
