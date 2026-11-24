# Addition 0009zq in dev, 24 November 2026

Addition 0009zq, speed to lead in one function (`Pulse4all-com/cma#316`, brief B40a), renumbered from 232/233 and 0009zp
after `Pulse4all-com/cma#317` took them. Dev already held this PR's functions under the 0009zp it took before #317, so
Martin ran `db/234_speed_to_lead_one.sql` again in dev (cma-dev-pg), recording 0009zq, then the verify, the readers, the
time script, the server verifiers and the data map's snapshot, on 24 November 2026.

This note was written down by Claude Code on 24 November 2026 at Martin's request, from his report, and the values are
his. No output file of his is in this folder. Counts and versions only: no key, no secret, no personal data.

| Step | Result |
|---|---|
| `234_speed_to_lead_one.sql` | rerun, records 0009zq |
| `235_verify_speed_to_lead_one.sql` | PASS |
| The readers of what 234 re-creates (the PR's list) | run again; Martin listed them with the passing results, without counts |
| `131_time_all.sql` | PASS: 342 ok, 0 FAIL |
| `npm run verify:api` | 366 of 368: the two Flash checks that expect definition version 0008zu (dev returns 0009ze; main expects the same, out of scope) |
| The data map | snapshot from dev at 0009zq, commit `b19c09f` on the branch |
