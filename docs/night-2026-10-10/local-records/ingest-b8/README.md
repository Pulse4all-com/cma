# Local run of the ingest jobs (brief B8), 11 October 2026

This is Claude Code's local run, not a release record. Nothing here touched dev, prod or a vendor.

**Database:** PostgreSQL 18.4 (the `@embedded-postgres/linux-x64` 18.4.0 binaries; the PostgreSQL apt repository is not reachable from the session), a fresh database `cma` with the roles of `00_roles.sql` and `db/01` to `43` in README order (`00` as `postgres`, the rest as `martin@pulse4all.com`). The jobs logged in as `cma-ingest@local.iam`, a login with `grant cma_app` (inheriting, like the service account's IAM user).

| File | Command (in `ingest/`, after `npm ci`) | Result |
|---|---|---|
| `lint.txt` | `npm ci && npm run lint` | clean |
| `npm-test.txt` | `npm test` (signature, mapping, hash, forms) | `ALL 18 PASS`, `ALL 37 PASS`, `ALL 20 PASS`, `ALL 41 PASS` |
| `*-provoked.txt` (signature, mapping, hash, forms) | `node verify/<name>.mjs --provoke` | `ALL 18 / 37 / 20 / 41 PROVOKED CHECKS FAILED, as they must` |
| `jobs-flow.txt`, `jobs-flow-provoked.txt` | `CMA_DB_HOST=/opt/pgsock CMA_DB_PORT=5432 CMA_DB_NAME=cma CMA_DB_USER=cma-ingest@local.iam node verify/jobs-flow.mjs [--provoke]` | `ALL 62 PASS`; `ALL 62 PROVOKED CHECKS FAILED, as they must` |
| `flow.txt`, `flow-provoked.txt` | the B7 flow verifier, unchanged, against the same database | `ALL 61 PASS`; `ALL 61 PROVOKED CHECKS FAILED, as they must` |
| `db-verifies.txt` | `31`, `33`, `35`, `37`, `43` after the verifier runs (verdict lines) | `PASS` for every tenant, the throwaway ones included |
| `deploy-syntax.txt` | `bash -n docs/ingest/deploy.sh` | syntax ok |
| `deploy-dryrun.txt` | `deploy.sh dev --jobs`, `prod --jobs`, the D3 fallback options, `dev` (the service, a first deploy) and two refused argument sets, against a stub `gcloud` that records each call's arguments; a parser reads every `--set-env-vars` and `--update-env-vars` the way gcloud does (`^X^` delimiter, each item split on its first `=`) | every job's `--set-env-vars` parses into six keys with `CMA_DB_USER=cma-ingest@p4a-cma-dev.iam` (and `…@p4a-cma-prod.iam`) intact; the service's into nine and the URL update into one; the four jobs on `europe-west4-docker.pkg.dev/p4a-cma-prod/cma/ingest:<sha>`, `run.invoker` for `cma-ingest-scheduler` on the three scheduled jobs, the three Cloud Scheduler entries in Europe/Amsterdam; refusals exit 2; the jobs' old `^@^` list gives `Bad syntax for dict arg: [p4a-cma-dev.iam]` |
| `docker.txt` | `docker build`, `GET /health` on the container, the job entry points in the image, a sweep from the image against the local database | `{"ok":true,"version":"local"}` as user `app`; `jobs/` in the image; usage errors exit 2; the sweep exits 0 |

**Mutation check (not kept as a file):** with `INGEST_PACE_FACTOR` set to 0 in a copy of `jobs-flow.mjs`, the pacing check failed (`1 of 62 FAILED`), so it measures the pacing and not the fake's latency.

**Docker note:** as in B7, the image was built from a session-only copy of `ingest/Dockerfile` with the proxy's CA before `npm ci`, `node:22-alpine` pulled through `mirror.gcr.io` and `--network host`. The committed Dockerfile has one change (it copies `jobs/`). Cloud Build needs neither workaround.

**Leftovers in the sweep from the image:** the local database also holds the throwaway tenants of earlier `flow.mjs` runs, whose secret files are gone; the sweep served their connections and their due events failed with `token_unavailable` (`eventsFailed` in `docker.txt`), which is the expected behaviour. `jobs-flow.mjs` sets its own connections inactive at the end, so later runs leave them alone.

Each `jobs-flow.mjs` run creates two throwaway tenants (`jobs-<run>-one`, `jobs-<run>-two`) with invented portals, ids, secrets and `example.com` emails.
