# Addition 0009g (#254) in dev, 9 November 2026

- Head c1dfd51 (the branch of #254). 162 committed (162.txt: INSERT 0 1, COMMIT); 163 verified: 21 PASS, 0 FAIL; provoked: 0 PASS, 21 FAIL (163-provoked.txt).
- Reruns of the verifies that read cma.open_workday: 14, 16, 18, 20, 43, 45 and 47 each their two PASS rows; 111 its verdict PASS, no FAIL; 127 32 PASS rows (its one FAIL/ERROR match is its own verdict text, as before 0009g).
- 07 run with ON_ERROR_STOP=0 (it provokes expected errors; with stop-on-error it halts at the first): its seven error lines are identical to records/0008zp-dev-2026-11-04/07-rerun.txt apart from ids.
- 27 stops at A4 ("2 scheduler role(s) with other permissions than workday.close_forgotten"): the scheduler holds data_quality.refresh, flash.snapshot and follow_up.refresh besides workday.close_forgotten. The check has been stale since those job permissions were added, not caused by 162; fixed in the PR of these records (A4 allows the jobs' permissions).
- verify:api against dev on image f11d434 (verify-api.txt): 335 of 338 PASS, the 8 Remove day checks all PASS. The 3 FAILs are Flash checks (the Model filter's first paint order, the customers file 409, Invest's shop not set up), unrelated to 0009g, to be handled separately.
- Browser acceptance in dev as supervisor: Remove day on Agent Two's 4 Nov removed the row, and the total dropped from 7h 03m to 6h 59m (5 min removed, 1 min of the open day added). Correct stays disabled on the supervisor's own days.
- The operator's login is masked as `<operator>` in 07-rerun.txt (the additions list), as in #231.

Written down from Martin's report of his own runs on 9 November 2026.
