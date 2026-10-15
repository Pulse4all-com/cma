# The signed-out page in prod, 15 October 2026

`docs/signed-out/deploy.sh prod` and the prod test plan of `docs/signed-out/README.md` (a to e), then the flag
`_LOGOUT_TARGET=signed-out`: steps 8 to 10 of `docs/night-2026-10-15/MORNING_RUNBOOK.md`, run by Martin on
15 October 2026 in p4a-cma-prod. Written down by Claude Code at Martin's request from his report of the runs
and the three files in this folder, which are his terminal output as he pasted it; the values below are his.
Ids, names, times and outcomes only: no key and no secret.

## Files

| File | What |
|---|---|
| `signed-out-dry-run.txt` | The dry run at 04:39 UTC (before `Pulse4all-com/cma#134`, so its bucket create still shows `--public-access-prevention=inherited`): the plan, every change printed with `+`, nothing changed |
| `signed-out-apply.txt` | The first apply that went through, at 06:01 UTC |
| `signed-out-apply-2.txt` | The second apply, at 07:43 UTC, after `Pulse4all-com/cma#136` |

## Earlier stop (between 05:30 and 05:40 UTC)

The first `--apply` stopped at step b, at the bucket's create: gcloud refused `--public-access-prevention=inherited`
(the flag is a boolean). Nothing was created. Fixed in `Pulse4all-com/cma#134` (the create passes
`--no-public-access-prevention`). That run's output is not in this folder.

## First apply (06:01 UTC)

- Bucket `gs://p4a-cma-prod-signed-out` created; `allUsers` holds `roles/storage.legacyObjectReader` on it (the
  policy gcloud printed after the binding is in the file).
- The page (script `sha256-IIap4NjjF1VG9XUHUPd4Z7MShSvgGvN4hgQrksZXbSM=`), the logo and the font uploaded; the
  bucket holds exactly those three objects.
- Backend bucket `cma-signed-out-backend` created, Cloud CDN off, with the page's CSP header.
- `cma-web-urlmap`: `workspace.pulse4all.app` had no host rule (the map's default service served it), so the
  path matcher `cma-web` with the three route rules and a host rule for the Workspace were added; validate passed
  with 9 tests; imported.
- Rollback export (the map before the signed-out routes): `/home/martin/cma-web-urlmap-20261015T060142Z.yaml`.

## Second apply (07:43 UTC)

After `Pulse4all-com/cma#136` (Add another account opens plain `AddSession` in a new tab): the new page (script
`sha256-6F80Vq39wf2ptdVZ5QOJTX/frFepDKBjLK33tf7T+8g=`) uploaded and the backend bucket's CSP header updated to
its hash. The plan said "the three route rules are in place; nothing to change", yet `deploy.sh` still imported
the map, unchanged (gcloud's fingerprint warning again). Since the pull request that filed this record,
`deploy.sh` validates an unchanged map but does not import it (README, Decision log, 15 October 2026).

## The flag

After a to e: trigger `cma-web-main` got `_LOGOUT_TARGET=signed-out`; the build of `dbd3c79` ended `SUCCESS`.

## Test plan outcome

| Step | Outcome |
|---|---|
| a | Pass |
| b | Pass after `Pulse4all-com/cma#136`: Add another account opens Google's add-account form in a new tab; Log in shows Google's chooser; a second pulse4all.com account without a person ends on No access yet; a gmail.com account gets IAP's own "You don't have access" |
| c | Pass: several accounts give Google's chooser |
| d | Pass, run in an Incognito window |
| e | Pass, ingest checked with GET |

## Seen along the way

- The URL map took several minutes to take effect after the import.
- Cloud Shell's credentials expired after the account testing in the same browser; `gcloud auth login` fixed it.
- gcloud warned at both imports about the URL map's fingerprint and a 412 in future versions ("An up-to-date
  fingerprint must be provided to update the Url Map. Future versions of gcloud will fail with an error '412
  conditionNotMet'").

## Final check after the flag

Log out ends on `/signed-out` (with `?__gcp_iap_oauth_prompt=1`), and No access yet offers Use another account.
