# Local run of brief B9 (the Aircall adapter)

Claude Code's local runs on 13 October 2026, not a release record: `records/` stays Martin's. No migration: `db/` is not changed.

**Server:** PostgreSQL 18.4 (the `@embedded-postgres/linux-x64` 18.4.0-beta.17 binaries from npm; the PostgreSQL apt repository was not reachable from the session, as on 10 and 13 October). Roles of `00_roles.sql`; scripts as the login `martin@pulse4all.com` (not a superuser), `00` as `postgres`; the service and the jobs as `cma-ingest@local.iam`, a login with `grant cma_app` (inheriting, like the service account's IAM user). Node 22.22.

| File | What | Result |
|---|---|---|
| `ingest-checks.txt` | `npm ci`, `npm run lint`, ESLint (the ingest config) on the docs scripts, `node --check` on every `.mjs` of `src`, `jobs`, `tools`, `verify` and the two new scripts, `bash -n docs/ingest/deploy.sh` | clean; 52 files, 0 errors |
| `image-smoke.txt` | what the Dockerfile copies (`package.json`, `package-lock.json`, `src`, `jobs`), `npm ci --omit=dev`, every module imported, the server started: `/health` and a malformed key on `/aircall` | `adapters: hubspot aircall automation`, `{"ok":true,"version":"b9local"}`, `404`. No Docker daemon in the session, so no `docker build` |
| `verifiers-summary.txt`, `verify-*.txt` | every verifier in `ingest/verify/`, normal and `--provoke`; the DB ones against the database `cma` built to `53` | `signature` 18, `mapping` 37, `hash` 20, `forms` 41, `aircall-token` 20, `aircall-mapping` 49, `aircall-scripts` 27, `flow` 79, `jobs-flow` 62, `aircall-flow` 85: ALL PASS, and ALL PROVOKED CHECKS FAILED |
| (in the PR) | `signature`, `mapping`, `hash`, `forms`, `flow`, `jobs-flow` on a checkout of `main` (`b62af44`) | the same check names and verdicts as on the branch: the HubSpot and automation verifiers are unchanged |
| `mutations.txt` | fourteen deliberate breakages of the adapter and the webhook script, each run against the verifiers that should catch it, the file restored afterwards | every one caught |
| `db-verifies.txt` | a fresh database `cma_b9`: `00` to `53` in README order with the seed reruns, every verify, compared with the same verify on the session's first fresh build | 65 scripts clean; 28 of 28 verify outputs identical (ids, times and dates masked); every verdict PASS |
