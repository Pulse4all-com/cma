# Addition 0009zu in dev, 25 November 2026

Addition 0009zu, Sales → Speed to lead as a cockpit (`Pulse4all-com/cma#318`, brief B40b), renumbered from 0009zr and
236/237 after N07a took them. Martin ran it in dev (cma-dev-pg) on 25 November 2026 at about 07:30 CET.
- **Before:** dev was at 0009zs (N07a's 236 and N07c's 238), with none of #318's objects since last night's repair
  (`records/n07a-dev-repair-2026-11-24/`).
- **What ran:** 242 twice, then 243 and N07a's 237 (edited by 242), each normal and provoked, then the readers of what 242
  re-creates. After a two-minute wait, 99 and `131_time_all.sql` parts a and b.
- **How:** the Terminal runner in the PR's step 1, every file from #318's branch.

This note was written down by Claude Code on 25 November 2026 at Martin's request, from his report, and the results are
his. His output files (`dev-run.txt`, `dev-logs/`, on his machine) are not in this folder. Counts and times only: no key,
no secret, no personal data.

| Step | Result |
|---|---|
| `242_speed_to_lead_cockpit.sql` | applied, exit 0 |
| 242 again | applied, exit 0 |
| `243_verify_speed_to_lead_cockpit.sql` | `PASS 0009zu`, 17 OK |
| 243, provoked | 0 OK, 17 FAIL |
| `237_verify_jobs_off_the_vcpu.sql` (edited by 242) | `PASS 0009zr`, 11 OK |
| 237, provoked | 0 OK, 11 FAIL |
| Readers 235, 41, 95, 179, 191, 73, 75, 81, 93, 101, 103, 121, 151, 155, 113, 123, 137, 161, 233, 225, 14, 33 | PASS, OK or verified, 0 FAIL |
| `99_verify_funnel.sql`, after the two-minute wait | PASS, 33 |
| `131_time_all.sql` part a | PASS, 169 ok; worst 145.8 ms (current takes refresh) |
| `131_time_all.sql` part b | PASS, 107 ok; worst 662 ms (active customers refresh) |
| `node tools/check-records.mjs` on the run's folder | records clean, 32 files |

Every line exited 0.

## Steps 2 and 3 (Martin, 25 November 2026, from his report)

| Step | Result |
|---|---|
| 2. The data map's schema snapshot from dev after 0009zu | committed as `8da180a` on #318's branch; `verify:datamap` PASS |
| 3. Main's `verify:api` against dev's web (`b489fe3`) on the 0009zu database | 366 of 368. The two failures are the known Flash definition versions (0008zu and 0008zt expected, dev returns 0009ze), not this addition. His output, `verify-api-main.txt`, is on his machine. |

## Step 4: round-trips and perf (Claude Code, local, 25 November 2026, at Martin's request)

This is not a dev run. Claude Code ran it in its own session and Martin asked for it here; the numbers are the session's.
- **The app:** the branch's production build (standalone, `CMA_AUTH_MODE=mock CMA_DATA_MODE=api CMA_DB_TRACE=1`).
- **The database:** a local PostgreSQL 16 copy of `web/verify/perf-volume-fixture.sql` (three times prod's volume) at
  0009zu, held to one CPU.
- **Main's baseline:** main's build (`eb7bad4`; its Speed to lead page is unchanged up to `9b634e0`) on the same fixture
  at 0009zs.

| Verifier | Branch | Main |
|---|---|---|
| `verify:round-trips` | PASS: 89 requests within budget, 4 not measured (pledges, no permission); provoked FAIL, 212 problems | not run |
| Speed to lead page, round trips | 2 transactions, 9 statements (budget 2 and 11) | not run |
| Figures route, round trips | 2 transactions, 9 statements (budget 2 and 9) | not run |
| Deals route, round trips | 2 transactions, 9 statements (budget 2 and 9) | not run |
| `verify:perf` | FAIL, 55 problems (second run 56); provoked FAIL, 296 problems | FAIL, 52 problems |
| `/reports/speed-to-lead`, first byte p50 / p95 | 6.9 / 12.7 ms | 7.7 / 17.6 ms |
| `/reports/speed-to-lead`, last byte p50 / p95 | 240.7 / 274.5 ms (second run 258.7 / 286.3); budget 200 / 500 ms (report 400 / 1,000 × the container factor 0.5) | 40.3 / 84.9 ms |
| `/reports/speed-to-lead`, HTML gzip | 15.4 kB (budget 17) | 12.1 kB |
| `/reports/speed-to-lead`, JavaScript gzip | 154.6 kB (budget 167) | read from the branch's build on disk, so not a comparison |

**What perf's failures mean.** In this session's machine `verify:perf` fails on main too, with 52 routes over the
halved budgets: Calls, Flash, Funnel, Follow-up, Installed base and others.
- **Over budget on the branch only:** `/reports/speed-to-lead`'s last-byte p50, 240.7 to 258.7 ms against 200. The page
  now reads the cockpit, with the previous period, the markets, the trend, the groups and 50 deals with their attempts,
  where main read the summary and the rows.
- **Not this change:** the inbound poll's p95 was over in one branch run only.
- **Still within budget:** the page's p95, its HTML and its JavaScript.
- **Accepted:** this is the page-read budget Martin accepted on 24 November 2026; the stored take is decided after 131
  runs in prod (docs/open-decisions.md).
