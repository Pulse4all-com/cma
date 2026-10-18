# verify:api against dev, 18 October 2026

`verify:api` (`web/verify/api.mjs`), normal and provoked, run by Martin on 18 October 2026 against dev's
`cma-web` (both files' first line: `verify/api.mjs against http://localhost:8080`). Written down by Claude Code
on 18 October 2026 at Martin's request from his report and the outputs he pushed to this folder; the values
are his. Ids, counts, dates and times only: no key, no secret and no personal data.

| Run | File | Result |
|---|---|---|
| `node verify/api.mjs` | `api-dev.txt` | 271 lines `PASS`, none `FAIL`; `ALL 271 PASS` |
| `node verify/api.mjs --provoke` | `api-dev-provoked.txt` | 271 lines `FAIL`, none `PASS`; `ALL 271 PROVOKED CHECKS FAILED, as they must` |

Both files carry the same six `note` lines, the checks left out: the reader's two (no reader identity in this
tenant; the reader has no access here), the invest-analyst's three (a tenant without sources; twice a tenant
without telephony) and the 5 checks of the missed-reason catalog (no telephony connection in this tenant).

The checks and notes are the same, in the same order, as 0008p's run in dev on 17 October 2026
(`records/0008p-dev-2026-10-17/verify-api.txt`, also 271 PASS); only dates in some checks' `got` values
differ. `api-dev.txt` and `api-dev-provoked.txt` are byte for byte the same files as
`records/speed-dev-2026-10-18/verify-api.txt` and `verify-api-provoke.txt`.

## Not in the report

- The times of the runs.
- The `cma-web` revision and image in dev at the time. Dev ran `f1cf4db` from 07:17:19 UTC that day
  (`records/deploys-2026-10-18`); the files do not show the version.
- Which audit item or step these runs belong to.
- Whether these files and the speed record's are one run filed in both folders or two runs with the same
  output.
