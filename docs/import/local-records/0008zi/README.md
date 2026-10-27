# Local records, addition 0008zi: asset register and Reports → Maintenance (27 October 2026)

Outputs of local runs in Claude Code's container, not release records (`records/` stays Martin's). No value here
comes from dev, prod, Airtable, NetSuite, HubSpot or GCP: every id, serial and count is the dev seed's, a verify
script's invented data, the synthetic fixture `tools/fixtures/devices-sample.csv` (fake serials and ids,
`example.invalid` addresses in ignored columns) or the web's mock data.

Setup: PostgreSQL 16 from the distribution with a local `uuidv7()` shim (PostgreSQL 16 has none; Cloud SQL's
PostgreSQL 18 has it); Node 22. One local database built from `main`'s `00` to `110` in README order with the dev
seeds, `02` and `03` again (0008zh: prod's path), copied fresh for this run, then this branch's `112`.

| File | What |
|---|---|
| `112_assets-first-run.txt`, `-rerun.txt` | `112` twice: the first run ends `INSERT 0 1`, `COMMIT`, `RESET`; the rerun ends `INSERT 0 0`. No error in either. |
| `113_verify_assets.txt`, `-provoked.txt` | 24 checks (A1 to A8, B1 to B15, C1), each `ok`, the verdict `0008zi verified`; provoked every row `FAIL`, the verdict `PROVOKED, NOT A PASS`. C1 reads the page of 24 months and the device list of every bucket over 5,000 devices in under 100 ms each. The verdict is the script's last row, after the helpers are dropped. |
| `113-mutations-of-112.txt` | Six mutations of `112` (overdue by day instead of by month, no replacement on a serial change, a full snapshot marking nothing missing, the bundling window 40 days short, the audit image of a staged row in full, a staged address kept as it is), each caught by `113`; `112` run again afterwards and `113` verified. |
| `seed-02-twice.txt` | Seed `02` twice after `112`, no error: Pulse4all Subscriptions holds 2 models, 2 component kinds, 4 rules, 5 device statuses and a bundling window of 90 days; Pulse4all Invest holds none. In this database the catalog holds no ES or IT market, so the aliases for Spain and Italy are not added. |
| `protected-verifies-after-112.txt` | `105`, `75` and `41` (the data-quality redefinition carries their checks), `107` (`cma.audit_row()`), `14` (the settings), `53` and `69` (the connection kinds), `73`, `79`, `101` and `109` after `112`: all pass, unchanged. |
| `fixture-load.txt` | docs/import/devices.md, "The fixture in dev", on this database with dev's twelve markets: the tool (`rows 30`, `mapped_columns 21`, `ignored_columns 31`, `date_parse_failures 0`, `values_with_at 1`), the copy (`COPY 30`), the full load (30 inserted; unmapped model 1, status 1, market 2; customer reference invalid 1; references dropped 0), the rerun (30 unchanged), no staged row left, Reports → Maintenance as of 27 October 2026 (27 tracked devices; Overdue 5 due items in 4 planned exchanges; the months 28 due items in 23 planned exchanges; 4 due items without a due date) and the eight data-quality checks' totals. Ids are not printed. |
| `web-checks.txt` | `web/` after review round 1: `npm ci`, build, typecheck and lint (0 errors; the two warnings of `main`), and the twenty-two pure verifiers, each exit 0 but `verify:datamap`, which fails as expected until Martin refreshes `schema.json` from dev (the seven new tables, the two computed views and `index.html`); with a schema snapshot of this local database the catalog describes all 96 tables and 144 views. Then `verify:layout`, `verify:hints` and `verify:theme` against the mock server (each PASS; provoked each FAIL). |
| `web-api-smoke.txt` | The three routes against the mock server: 200 for `reports.view` and `performance.team`, 403 for the agent (whose page shows the reports notice), each refused parameter its 400 code, the device list's fields (no link to the register) and the file's header in English. |
