# Local run of the ingest service (brief B7), 10 October 2026

This is Claude Code's local run, not a release record. Nothing here touched dev, prod or a vendor.

**Database:** PostgreSQL 18.4 (the `@embedded-postgres/linux-x64` 18.4.0 binaries; the PostgreSQL apt repository was not reachable from the session). It ran in a fresh database `cma` with `db/00` to `33` in README order: `31` and `33` gave PASS for both tenants. The service logged in as `cma-ingest@local.iam`, a login with `grant cma_app` (inheriting, like the service account's IAM user). The setup ran as `martin@pulse4all.com` (cma_owner and cma_app by SET ROLE, as `00_roles.sql` grants).

| File | Command (in `ingest/`, after `npm ci`) | Result |
|---|---|---|
| `lint.txt` | `npm run lint` | clean |
| `npm-test.txt` | `npm test` (signature, mapping, hash) | `ALL 18 PASS`, `ALL 37 PASS`, `ALL 20 PASS` |
| `signature-provoked.txt`, `mapping-provoked.txt`, `hash-provoked.txt` | `node verify/<name>.mjs --provoke` | `ALL 18 / 37 / 20 PROVOKED CHECKS FAILED, as they must` |
| `flow.txt`, `flow-provoked.txt` | `CMA_DB_HOST=/tmp CMA_DB_PORT=5432 CMA_DB_NAME=cma CMA_DB_USER=cma-ingest@local.iam node verify/flow.mjs [--provoke]` | `ALL 61 PASS`; `ALL 61 PROVOKED CHECKS FAILED, as they must` |
| `docker-health.txt` | `docker build` and `GET /health` on the container | `{"ok":true,"version":"local"}`, running as user `app` |

**Docker note:** the session's proxy stops `npm ci` inside a build, and Docker Hub rate-limited the base image. So the image was built from a session-only copy of `ingest/Dockerfile` with two changes: the proxy's CA added before `npm ci`, and the same `node:22-alpine` pulled through `mirror.gcr.io`. The committed Dockerfile is unchanged. Cloud Build does not need either change.

Each flow run creates two throwaway tenants (`flow-<run>-one`, `flow-<run>-two`) in the local database, with invented portals, ids, secrets and numbers.
