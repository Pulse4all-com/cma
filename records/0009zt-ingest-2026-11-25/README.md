# The ingest jobs with the reconcile's purge, 25 November 2026

The ingest jobs of addition 0009zt (`Pulse4all-com/cma#321`, decision D13: the run rows' retention) were deployed by
Martin on 25 November 2026 from 20:29 to 20:38, after the merge (e48e2d2), with `tools/runners/n07f-ingest.sh` on main:
dev, one reconcile in dev, then prod.

This note was written down by Claude Code on 25 November 2026 at Martin's request, from his report, and the results are
his. His runner's log is not in this folder. Counts and verdicts only: no key, no secret, no personal data.

| Step | Result |
|---|---|
| The image | `ingest:e48e2d2f`, built in 32 s |
| Dev: the eleven jobs (read after the deploy) | all on the image |
| Dev: `ingest-source-figures` | created by the deploy, paused |
| Dev: the reconcile, run once | succeeded |
| Dev: its retention line | 1 tenant: deleted 0, batches 1, more false |
| Prod: the eleven jobs (read after the deploy) | all on the image |
| The reconcile's schedule, dev and prod | `30 3 * * *` |
| The runner's result | `RESULT n07f-ingest: OK` |

## The first purge in prod

The first purge was not run by hand (`n07f-first-purge.sh`). The scheduled reconcile at 03:30 on 26 November 2026 does it,
and its `reconcile: sync_run retention` line per tenant is its record. That night's result is not part of this note.
