# Local records, night of 12 to 13 October 2026

Outputs of the night's local runs (Claude Code's container: PostgreSQL 18.4 from the npm binaries, Node 22.22, the standalone build). Not release records: `records/` stays Martin's.

| File | What |
|---|---|
| `0008e/` | the migration and its verify, the earlier verifies after it, the refusal outside dev, the mutations (own README) |
| `typecheck.txt`, `lint.txt`, `build.txt` | `npm run typecheck`, `npm run lint`, `npm run build` in `web/`, all exit 0 |
| `verify-<name>.txt`, `verify-<name>-provoked.txt` | the pure verifiers CLAUDE.md names, normal and `--provoke` |
| `api.txt`, `api-provoked.txt` | `verify/api.mjs` against the standalone build in mock auth and api data on the local database at `53` with `verify/reports-fixture.sql`, run at 21:45 Amsterdam time on the final build (a first run at 21:17 gave the same counts), inside the seed's workday window: `ALL 218 PASS`, `ALL 218 PROVOKED CHECKS FAILED` (the call-outcome check is left out: the fixture has no call outcome, dev has) |
| `api-sources*.txt` | `verify/api.mjs --sources` on the same database (31 checks) and against the build in mock data (32 checks), normal and provoked |
| `theme*.txt`, `layout*.txt`, `hints*.txt` | the browser verifiers against the build in mock mode, normal and provoked |
| `screenshots/` | the new pages at 1280 px as the admin (from `verify/layout.mjs`), Edit person with linked accounts as the manager, the form rule with its preview |
