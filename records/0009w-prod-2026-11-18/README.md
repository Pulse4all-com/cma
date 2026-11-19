# Addition 0009w in prod, 18 and 19 November 2026

Addition 0009w, prod's slowdown part 1 (`Pulse4all-com/cma#291`): `db/194_audit_bookkeeping.sql` and
`db/195_verify_audit_bookkeeping.sql`, run by Martin on cma-prod-pg. Written down by Claude Code on 19 November
2026 at Martin's request, from his report and the screenshots of his Studio runs (Studio keeps no files); the
values are his. The one output file in this folder, `179-rerun-2026-11-19.txt`, is his Terminal run. Counts,
verdicts, dates and times only: no key, no secret and no personal data.

## The migration and its verify

| Step | Where | Result |
|---|---|---|
| `194_audit_bookkeeping.sql` | Studio, Martin's own IAM login | addition 0009w recorded at 07:09:51 UTC on 18 November 2026: inside office hours, where the pull request said after 18:00. The locks lasted seconds; no incident. Studio shows no NOTICE, so section 1's outcome was read from 195's P1 |
| `195_verify_audit_bookkeeping.sql` | Studio, Martin's own IAM login | 8 PASS, P1 FAIL: the extension was not installed, and `cma_owner` held `pg_read_all_stats`: f. The login may not create the extension or grant the role, as the migration's section 1 allows for |
| `create extension if not exists pg_stat_statements with schema public;` `grant pg_read_all_stats to cma_owner;` | Studio, as the built-in user `postgres` | done: the pull request's step for this case |
| `195_verify_audit_bookkeeping.sql` again | Studio, Martin's own IAM login | `PASS`: 9 PASS, 0 FAIL, 1 info. P2 read `all`: `pg_stat_statements.track` was already `all` |
| `195_verify_audit_bookkeeping.sql`, provoked | Studio, Martin's own IAM login | `PROVOKED, NOT A PASS`: 0 PASS, 10 FAIL |

## The verifies the change edits or touches

| Verify | Where | Result |
|---|---|---|
| `31_verify_ingest_crm_records.sql` | Studio | PASS per tenant |
| `33_verify_intake_core.sql` | Studio | PASS per tenant |
| `75_verify_forms_reporting.sql` | Studio | refused: "runs in dev only". The pull request had called 75 and 77 universal; they are dev only |
| `77_verify_audit_hardening.sql` | Studio | refused: "runs in dev only", as 75 |
| `179_verify_job_reads.sql` | Studio, 18 November | lost its connection ("database currently unavailable") while it ran; the instance stayed RUNNABLE and did not restart. Its block E runs for minutes, longer than Studio holds a connection |
| `179_verify_job_reads.sql` again | Terminal (`psql -f`), 19 November | `0009o verified`: 28 ok, 0 FAIL, 0 skip, in 3 min 56 s (`179-rerun-2026-11-19.txt`) |

No other record of 0009w's prod run exists.
