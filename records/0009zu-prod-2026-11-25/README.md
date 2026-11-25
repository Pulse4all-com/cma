# Addition 0009zu in prod, 25 November 2026

Addition 0009zu, Sales → Speed to lead as a cockpit (`Pulse4all-com/cma#318`, brief B40b), run in prod (cma-prod-pg) by
Martin on 25 November 2026 from 18:05 to 18:26, outside office hours and before the merge.
- **What ran:** 242 twice; 243 and N07a's 237 (edited by 242), each normal and provoked; the readers that run in prod;
  then the records check with his login.
- **How:** the step 5 runner of the PR, reworked by him to show progress. The scripts, their order and the expectations
  are the same.
- **What was left out:** the dev-only readers (73, 75, 81, 93, 95, 101, 103, 121, 151 and 155), and 99 and 131, which
  would time the busy minutes. 131 runs in prod a day later.

This note was written down by Claude Code on 25 November 2026 at Martin's request, from his report, and the results are
his. His output files (`prod-run.txt`, `prod-logs/`) are not in this folder. Counts, verdicts and durations only: no key,
no secret, no personal data.

| Step | Result | Duration |
|---|---|---|
| `242_speed_to_lead_cockpit.sql` | applied, exit 0 | 1 s |
| 242 again | applied, exit 0 | 1 s |
| `243_verify_speed_to_lead_cockpit.sql` | `PASS 0009zu`, 17 OK, 0 FAIL | 82 s |
| 243, provoked | `PROVOKED, NOT A PASS`, 0 OK, 17 FAIL | 148 s |
| `237_verify_jobs_off_the_vcpu.sql` (edited by 242), first run | `FAIL`, 9 OK, 2 FAIL (F1, F2; see below) | 121 s |
| 237, provoked | `PROVOKED, NOT A PASS`, 0 OK, 11 FAIL | 119 s |
| 235 | `PASS 0009zq`, 15 OK, 0 FAIL | 8 s |
| 41 | its pass row (pulse4all-subscriptions: 1396, 1259, 8330, PASS) | 34 s |
| 179 | `0009o verified`, 26 ok, 0 FAIL, 2 skip | 261 s |
| 191 | `0009u verified`, 20 ok, 0 FAIL, 2 skip | 138 s |
| 113 | `0008zi verified`, 25 ok, 0 FAIL | 57 s |
| 123 | `0008zn verified`, 40 ok, 0 FAIL, 4 skip | 60 s |
| 137 | `0008zt verified`, 24 ok, 0 FAIL, 1 skip | 30 s |
| 161 | `0009f verified`, 10 ok, 0 FAIL, 0 skip | 88 s |
| 233 | `PASS`, 11 PASS, 0 FAIL, 0 skip | 59 s |
| 225 | `PASS, A ONLY`, 5 PASS, 0 FAIL | 4 s |
| 14 | its settings row, no error | 2 s |
| 33 | its pass row (pulse4all-subscriptions, PASS) | 21 s |
| 237, rerun at 18:26 | `PASS 0009zr`, 11 OK, 0 FAIL | — |
| `node tools/check-records.mjs --login …` on the run's folder | records clean, 19 files | — |

Every line exited 0.

## 237's first run and its rerun

The first run read 9 OK, 2 FAIL:
- **F1:** "912 rows differ", with no outcome row count. The forced facts refresh computed nothing.
- **F2:** "0 rows differ, whole true, scope 0 subscriptions (3 written)".

The provoked run straight after it showed:
- **F1:** 61,995 outcome rows, 1 differing (the provoked one).
- **F2:** incremental (whole false, scope 3).

The rerun at 18:26 passed, `PASS 0009zr`, 11 OK, 0 FAIL:
- S1 and G1 to G4 OK.
- F1: 0 rows differ, 61,995 outcome rows.
- F2: 0 rows differ, whole false, scope 3 subscriptions (3 written).
- F3: 0 rows differ, whole false, scope 1.
- F4: 0 rows differ, whole true.
- L1: 0 rows differ over 1,396 lead deals.
- L2: 0 rows differ over 31 open leads.

**Martin's reading:** the first run collided with prod's `refresh_active_customers`, which has run every minute again
since that morning's deploy of the jobs (N07a, step P6).

**What supports it:** when another refresh holds the tenant's facts lock, the forced refresh in
`cma.subscription_facts_refresh_of` (236) answers `refreshed false, reason running` and computes nothing. F1 then
compares the stored outcomes, written earlier, with 210's computation of now. This matches an F1 with no outcome row
count. The run was a collision of the verify with the job, not a difference in the answers.

**The rerun's output:** its log file was not saved (a slip in his command). Its rows above are from his report, and its
line was added to `prod-run.txt` by hand.
