# Local records of night N06 (5 to 6 November 2026)

Outputs of runs in the session's own container, not of prod or dev: PostgreSQL 16.15 (prod runs 18) with a local
`uuidv7()` shim, `db/00` to `133` replayed with the dev seeds, `web/verify/perf-volume-fixture.sql` at multiplier 3
(three times prod's volume as of 5 November 2026), Node 22, the standalone build in api mode with mock sign-in on
port 8080, the mock-mode build on 8081, `main` (`8643d17`) built in a worktree on 8082 for the web "before". Every
figure here is a local figure: the container shares its cores with the build and the web server, and prod runs
PostgreSQL 18 on its own vCPU, so the ratios carry over, the milliseconds do not. `records/` stays
for Martin's own runs (CLAUDE.md, Git and release).

| Folder | What | When |
|---|---|---|
| `before/` | `130_census.sql`, `131_time_all.sql` (one run, part all, which stopped starting reads at its 240 s budget after lead cohorts: the rows after it say so), `124_time_flash.sql`, `round-trips` observed and checked, all on the fixture before any change; `perf-observed.json` and `round-trips-observed-main.json` from `main`'s build on the same database | before `132` and before the web changes |
| `after/` | the same on `132` and the N06b web: `131` in its three parts (a: polls and pages, b: the reports' default period, c: 92 days), `124`, `130`, `round-trips`, `perf-observed.json` | after |
| `db/` | `132` run twice (`INSERT 0 1`, then `INSERT 0 0`), `133` normal and provoked, `130` and `131` provoked (tails), the earlier verifies of every function `132` touches, rerun after it (41, 53, 61, 63, 73, 75, 79, 81, 123, 129) | after `132` |
| `web/` | `build.txt`, `typecheck.txt`, `lint.txt`, one `verify-<name>.txt` per verifier (the pure ones; `api` in api mode against 8080, normal and provoked; `layout`, `theme`, `hints` and `api --sources` against the mock server; `screenshots/` from the layout verifier, the route skeletons among them) | the final build |

The first `verify:api` run of the night failed one Flash check (`1 of 318 FAILED`, the invest tenant's analyst had no access): `web/verify/reports-fixture.sql` had not been loaded; the record here is the run after it (every check passes). `123_verify_flash` fails one check locally (`uuidv7` is a shim here, prod has the real one); every other verify passes. `verify:datamap` fails with three expected problems (the two new tables are not in `schema.json`, `index.html` is older than the catalog) until Martin refreshes the snapshot from dev after `132` runs there and rebuilds the index (MORNING_RUNBOOK step 2).
