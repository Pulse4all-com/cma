# Addition 0009k (#261) in dev, 11 November 2026

- Before the renumbering: this change's former 168 ran in dev with `INSERT 0 0` (0009j was already #262's) and replaced the two functions; its former 169 read 12 PASS, 0 FAIL, 1 skip, and provoked 12 FAIL.
- On the branch at d8aab87, before prod and before E4's change (0.5 ms or 3 % then):
  - 170 exit 0: `INSERT 0 1`, `COMMIT`.
  - 171: 12 PASS, 0 FAIL, 1 skip. Provoked: 0 PASS, 12 FAIL, 1 skip, "PROVOKED, NOT A PASS".
  - Reruns: 133 20 ok, 0 FAIL; 145 29 ok, 0 FAIL; 165 12 PASS, 0 FAIL.
  - 131 part a: PASS, 119 ok, 0 FAIL. The Live rows: inbound now (one statement) 7.3 ms, outbound now 2.4 ms, live board calls (one statement) 8.7 ms, inbound today by hour (the board chart) 1.8 ms.

Not in the report: the outputs themselves (no files in this folder), the times of the runs, 171's E4 timings in dev, a run of 171 with E4's new allowance, and 131 part a's other rows.

Written down from Martin's report of his own runs on 11 November 2026.
