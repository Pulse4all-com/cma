# Addition 0009k (#261) in prod, 11 November 2026

- 170 committed: `INSERT 0 1`, `COMMIT`.
- 171, first run, before E4's change: 11 PASS, 1 FAIL, 1 skip. The FAIL was E4: `cma.inbound_now()` 5.45 ms against 0009h's 4.50 ms, with 0.50 ms of slack. Martin accepted the cost of the inbound Talk time sum, about 1 ms in prod (Decision log, 11 Nov 2026); E4 now allows the new read 1.5 ms or 30 % above 0009h's, whichever is larger.
- 171, rerun on the branch at c8ab454: 12 PASS, 0 FAIL, 1 skip. E4: 5.03 ms against 0009h's 4.11 ms, allowed up to 5.61 ms.
- Reruns: 133 20 ok, 145 29 ok, 165 12 PASS, all 0 FAIL.
- 131 part a, the Live rows: inbound now (one statement) 14.9 ms, outbound now 2.6 ms, live board calls (one statement) 14.3 ms, inbound today by hour (the board chart) 4.0 ms, all under the poll's 20 ms. Its two FAILs are the known installed base and data quality rows.
- The combined Live read's 14.3 ms is a morning figure; the open decision on it stays until it is measured at a busy hour (Open decisions).

Not in the report: the outputs themselves (no files in this folder), the times of the runs, 131 part a's other rows, and the head of the first runs.

Written down from Martin's report of his own runs on 11 November 2026.
