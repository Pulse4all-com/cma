# Local run of the ingest jobs (brief B8) at b361d2f, 11 October 2026

This is Claude Code's local run, not a release record. Nothing here touched dev, prod or a vendor.

**Commit:** `b361d2f` (the merge of main `e1035fe` into the B8 branch). Every file below except `docker.txt` and `db-verifies.txt` comes from runs at this commit.

**Database:** PostgreSQL 18.4 (the `@embedded-postgres/linux-x64` 18.4.0 binaries; the PostgreSQL apt repository is not reachable from the session), database `cma` with the roles of `00_roles.sql` and `db/01` to `43` in README order (`00` as `postgres`, the rest as `martin@pulse4all.com`), `38` and `40` included. The jobs logged in as `cma-ingest@local.iam`, a login with `grant cma_app` (inheriting, like the service account's IAM user).

| File | Command (in `ingest/`, after `npm ci`) | Result |
|---|---|---|
| `lint.txt` | `npm ci && npm run lint` | clean, exit 0 |
| `npm-test.txt` | `npm test` (signature, mapping, hash, forms) | `ALL 18 PASS`, `ALL 37 PASS`, `ALL 20 PASS`, `ALL 41 PASS` |
| `forms.txt` | `node verify/forms.mjs` | `ALL 41 PASS` |
| `*-provoked.txt` (signature, mapping, hash, forms) | `node verify/<name>.mjs --provoke` | `ALL 18 / 37 / 20 / 41 PROVOKED CHECKS FAILED, as they must` |
| `jobs-flow.txt`, `jobs-flow-provoked.txt` | `CMA_DB_HOST=/opt/pgsock CMA_DB_PORT=5432 CMA_DB_NAME=cma CMA_DB_USER=cma-ingest@local.iam node verify/jobs-flow.mjs [--provoke]` | `ALL 62 PASS`; `ALL 62 PROVOKED CHECKS FAILED, as they must` |
| `flow.txt`, `flow-provoked.txt` | the B7 flow verifier, unchanged, against the same database | `ALL 61 PASS`; `ALL 61 PROVOKED CHECKS FAILED, as they must` |
| `deploy-dryrun.txt` | `deploy.sh dev --jobs` and `deploy.sh prod --jobs` against a stub `gcloud` that records each call's arguments; a parser (source in the file) reads every `--set-env-vars` the way gcloud parses a dict argument (`^X^` delimiter, each item split on its first `=`) | both exit 0; every job's env list parses into six keys with `CMA_DB_USER=cma-ingest@p4a-cma-dev.iam` (prod: `cma-ingest@p4a-cma-prod.iam`) intact; the four jobs on `europe-west4-docker.pkg.dev/p4a-cma-prod/cma/ingest:b361d2f` |
| `deploy-syntax.txt` | `bash -n docs/ingest/deploy.sh` | syntax ok |
| `shellcheck.txt` | `shellcheck docs/ingest/deploy.sh` (ShellCheck 0.11.0, from `shellcheck-py`) | no findings, exit 0 |
| `docker.txt` | not rerun at `b361d2f`: from the earlier run of this branch (`docker build`, `GET /health` on the container, the job entry points in the image, a sweep from the image against the local database). `ingest/` is unchanged since | `{"ok":true,"version":"local"}` as user `app`; `jobs/` in the image; usage errors exit 2; the sweep exits 0 |
| `db-verifies.txt` | not rerun into this file at `b361d2f`: verdict lines of `31` to `43` from the earlier run. At `b361d2f`, `31`, `33`, `35`, `37`, `39`, `41` and `43` were run again and gave `PASS` for all 30 tenants (counted, not kept) | `PASS` for every tenant |

**Docker note:** as in B7, the image was built from a session-only copy of `ingest/Dockerfile` with the proxy's CA before `npm ci`, `node:22-alpine` pulled through `mirror.gcr.io` and `--network host`. The committed Dockerfile has one change (it copies `jobs/`). Cloud Build needs neither workaround.

Each `jobs-flow.mjs` run creates two throwaway tenants (`jobs-<run>-one`, `jobs-<run>-two`) with invented portals, ids, secrets and `example.com` emails, and sets their connections inactive at the end; each `flow.mjs` run creates two (`flow-<run>-one`, `flow-<run>-two`).
