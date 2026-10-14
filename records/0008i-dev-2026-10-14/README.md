# Addition 0008i in dev, 14 October 2026

Brief B15 (inbound service level and missed calls not called back), steps 2 and 5 of
`docs/b15-inbound-service/MORNING_RUNBOOK.md`, run by Martin on 14 October 2026 in p4a-cma-dev
(cma-dev-pg). Written down by Claude Code at Martin's request from his report of the run and the files
in this folder; the values below are his. Ids and counts only: no key, no secret and no personal data.

## Database (step 2)

| File | What | Verdict |
|---|---|---|
| `60.txt` | the addition, first run | Clean; ends `INSERT 0 1`, `COMMIT`, `RESET` |
| `61.txt` | the verify | `20 PASS, 0 FAIL`, verdict `PASS` |
| `61-provoked.txt` | the verify with `verify.provoke` true | All 20 checks `FAIL`, verdict `PROVOKED, NOT A PASS`, `0 PASS, 20 FAIL` |
| `35-rerun.txt` | `35_verify_telephony.sql` | 2 PASS rows |
| `41-rerun.txt` | `41_verify_lead_metrics.sql` | 2 PASS rows |
| `53-rerun.txt` | `53_verify_sources_configuration.sql` | `16 PASS, 0 FAIL`, verdict `PASS` (17 rows) |
| `55-rerun.txt` | `55_verify_uncounted_lines.sql` | `17 PASS, 0 FAIL`, verdict `PASS` (18 rows) |
| `60-rerun.txt` | the addition again | Clean; ends `INSERT 0 0`, `COMMIT`, `RESET` |
| `02-rerun.txt` | the Pulse4all seed after `60` | Clean; ends `DO` |

## The new image and the API verifier (step 5)

- `cma-web` in dev on `516b9e5`, the image prod's build made for the B15 merge.
- `verify-api.txt`: `ALL 228 PASS`, with three `note` lines for the 7 checks dev leaves out (the
  tenant-without-sources check from before B15, the 5 missed-reason catalog checks because dev's tenant
  has no telephony connection, and the tenant-without-telephony check; dev has no `invest-analyst`).
  The times in its answers put the run at about 14:55 UTC.
- `--provoke`: `ALL 228 PROVOKED CHECKS FAILED, as they must` (Martin's report; not in a file here).

## The browser verifiers (step 6)

Against a local mock server, from Martin's report (not in a file here):

| Verifier | Run | `--provoke` |
|---|---|---|
| `theme` | PASS | FAIL (6 problems) |
| `layout` | PASS | FAIL (17 problems) |
| `hints` | PASS | FAIL (1 problems) |

The layout verifier's screenshots of that run are in `records/layout/` (committed with this folder, PR #124).

## Not in the report

- The time `60` ran in dev, and the Studio read of step 2 (reasons and settings per tenant).
