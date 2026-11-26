# Addition 0009zr (N07a) in dev, 25 November 2026

Addition 0009zr, the minute jobs off the vCPU (`Pulse4all-com/cma#319`, brief N07a), run again in dev (cma-dev-pg) at
its commits `24db2e7` and `ded817d`.
- `24db2e7`: 237's F2 to F4 move the outcomes' read mark before their own writes.
- `ded817d`: the facts refresh's whole decision is never null, and 237's F checks run without the tenant's chargebacks.

Martin ran it on 25 November 2026 at about 05:40 CET, after last night's repair (`records/n07a-dev-repair-2026-11-24/`).

This note was written down by Claude Code on 25 November 2026 at Martin's request, from his report, and the results are
his. His output files (kept on his machine as `records/0009zr-n07a-dev-2026-11-25/`) are not in this folder. Counts and
times only: no key, no secret, no personal data.

| Step | Result |
|---|---|
| `236_jobs_off_the_vcpu.sql` | applied |
| `237_verify_jobs_off_the_vcpu.sql` | `PASS 0009zr`, 11 OK |
| 237, provoked | 0 OK, 11 FAIL |
| The readers 211, 213, 217, 219, 221, 223, 225, 41, 73, 75, 81, 95, 151, 155, 179, 191 and 235 | PASS or verified |
| `99_verify_funnel.sql`, right after 236 | C2 FAIL: the funnel and lost reasons reads at 1.22 to 1.50 s |
| 99, a minute later | PASS, 157 to 251 ms |

**F2 and F3 now pass.** They failed in last night's runs (9 OK, scope 0); `ded817d` is the fix.

**99's C2 failed right after a 236 run on both nights.** Last night the funnel took 1.0 to 1.24 s; this morning 1.22 to
1.50 s. Both times it passed on a quiet rerun a minute later. C2 times reads that 236 does not change (the funnel, lost
reasons, cancellations and deals per person, on 99's own volume tenant). So the first minutes after the migration are
busy on the instance's CPU, not slow in those reads.
