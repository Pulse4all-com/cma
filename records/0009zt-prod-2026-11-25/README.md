# Addition 0009zt in prod, 25 November 2026

Addition 0009zt, the ingest's source writes out of the audit log (D12, narrowed, agreed by Yordi on 25 November 2026) and
the run rows' retention (D13) (`Pulse4all-com/cma#321`, brief N07, N07f), run in prod (cma-prod-pg) by Martin on
25 November 2026 at 20:23, after 244 (0009zv) and before the merge, with `tools/runners/n07f-prod.sh` from the N07f
branch.
- **What ran:** the check that 0009zs, 0009zu and 0009zv were in prod; 240; 241 normal and provoked; the verifies that
  read what 240 re-creates (77 and 107 refuse prod, being dev only; 113, 169, 195 and 197); the additions after; the
  records check.

This note was written down by Claude Code on 25 November 2026 at Martin's request, from his report, and the results are
his. His runner's log is not in this folder. Verdicts only: no key, no secret, no personal data.

| Step | Result |
|---|---|
| `240_audit_and_retention.sql` | applied |
| `241_verify_audit_and_retention.sql` | `PASS 0009zt` |
| 241, provoked | as expected (`PROVOKED, NOT A PASS`) |
| 77, 107 | refused: dev only |
| 113, 169, 195, 197 | PASS or verified |
| The additions after, in the order applied | 0009zs, 0009zu, 0009zv, 0009zt |
| The runner's result | `RESULT n07f-prod: OK` |

241's R1 (0009zt recorded after 0009zs) held with 0009zu and 0009zv applied in between, as the PR expected.
