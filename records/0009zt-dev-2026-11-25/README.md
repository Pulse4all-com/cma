# Addition 0009zt in dev, 25 November 2026

Addition 0009zt, the ingest's source writes out of the audit log (D12, narrowed) and the run rows' retention (D13)
(`Pulse4all-com/cma#321`, brief N07, N07f), run in dev (cma-dev-pg) by Martin on 25 November 2026 at 20:21, before the
merge, with `tools/runners/n07f-dev.sh` from the N07f branch.
- **What ran:** 240 (it had not run in dev); 241 normal and provoked; the verifies that read what 240 re-creates (77,
  107, 113, 169 and 195: `cma.audit_row`; 197: `cma.sync_run_hour_count`); then the records check.

This note was written down by Claude Code on 25 November 2026 at Martin's request, from his report, and the results are
his. His runner's log is not in this folder. Verdicts only: no key, no secret, no personal data.

| Step | Result |
|---|---|
| `240_audit_and_retention.sql` | applied |
| `241_verify_audit_and_retention.sql` | `PASS 0009zt`, 3 OK |
| 241, provoked | `PROVOKED, NOT A PASS`, 0 OK, 3 FAIL |
| 77 | 13 PASS, 1 FAIL (A5, below) |
| 107, 113, 169, 195, 197 | PASS or verified |
| The runner's result | `RESULT n07f-dev: FAIL`, on 77's line only |

## 77's A5

A5 names `cma.workday_stretches_reader_of` and `cma.workday_summary_reader_of`: SECURITY DEFINER functions whose search
path does not end with `pg_temp`. They come from 134 and are not touched by 240. Backlogged as CMA-155.
