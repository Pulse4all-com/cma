# Local records, addition 0008zg: legacy call outcomes (25 October 2026)

Outputs of local runs in Claude Code's container, not release records (`records/` stays Martin's). No value here
comes from dev, prod, HubSpot, Aircall or GCP: every id, name and count is the dev seed's, a verify script's invented
data or the synthetic fixture `ingest/verify/fixtures/legacy-calls/legacy-calls.csv` (invented people,
`example.invalid` addresses).

Setup: PostgreSQL 16 from the distribution with a local `uuidv7()` shim (PostgreSQL 16 has none; Cloud SQL's
PostgreSQL 18 has it); Node 22. Three local databases: **migrated** (`main`'s `00` to `106` in README order with the
dev seeds, `02` and `03` again, then this branch's `108`: prod's path), **main** (`main`'s `00` to `106` the same way)
and **branch** (this branch's `00` to `108` the same way).

| File | What |
|---|---|
| `build-to-0008zf.txt` | The migrated database's build up to 0008zf: every script `exit=0 errors=0`. |
| `108_legacy_call_outcome-first-run.txt`, `-rerun.txt` | `108` on it twice: the first run ends `INSERT 0 1`, `COMMIT`, `RESET`; the rerun skips what exists and ends `INSERT 0 0`. No error in either. |
| `109_verify_legacy_call_outcome.txt`, `-provoked.txt` | 18 checks (A1 to A6, B1 to B12), each `PASS`, the verdict PASS; provoked every row `FAIL`, the verdict `PROVOKED, NOT A PASS`. |
| `109-mutations-of-108.txt` | Eight mutations of `108` (the privacy deletion's step removed, a set contact overwritten, the reader view without the withdrawn filter, a second withdrawal allowed, a removed tag counted, no batch reuse, any key in a finish, no cutover check), each caught by `109`; `108` run again afterwards and `109` PASS. |
| `protected-verifies-after-108.txt` | `33`, `35`, `69`, `71`, `75` (the verifies covering `cma.ingest_contact_forget`), `105` and `107` on the migrated database after `108`: all pass, unchanged. |
| `verifies-main-and-branch.txt` | Every `db/` verify script on the main and the branch database. They agree but for `109` (new) and `39`, which flips between runs on both (the outbox's claim order under the local `uuidv7()` shim, as in `docs/definitions-2026-10/local-records/`); `25` failed once on the branch while both ran at the same time and passed three times on each database alone. `04`, `07`, `12` and `27` err the same on both, as in earlier local records. |
| `ingest-checks.txt` | `npm test` in `ingest/`: the eighteen pure verifiers, each `ALL n PASS`, among them `verify/legacy-calls.mjs` (28) and `verify/deploy-script.mjs` (26, amended for the eighth job); `npx eslint .` clean; both provoked, every check failing. |
| `legacy-calls.txt` | `verify/legacy-calls.mjs` in full. |
| `web-checks.txt` | `web/`: `npm ci`, build, typecheck and lint (0 errors; the two warnings of `main`), and the twenty pure verifiers, each exit 0 (`verify:datamap` before `docs/datamap/catalog.json` names the two new tables; it fails on the branch until Martin refreshes `schema.json` from dev). |
