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
