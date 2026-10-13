# Local run of brief B10 (the Shopify adapter, the outbox worker, addition 0008g)

Claude Code's local runs on 13 October 2026, not a release record: `records/0008g-dev-*` and `records/0008g-prod-*` come from Martin's real runs (`../MORNING_RUNBOOK.md`).

**Server:** PostgreSQL 18.4 (the `@embedded-postgres/linux-x64` 18.4.0-beta.17 binaries from npm, as on 10 and 13 October). Fresh databases with the roles of `00_roles.sql`, every script as the login `martin@pulse4all.com` (not a superuser), `00` as `postgres`; the ingest service and jobs as `cma-ingest@local.iam`, a login with `grant cma_app`. Node 22.22.

**Order:** `00` to `57` in README order with the seed reruns (`db/order-of-the-fresh-database.txt`: the 0008f order with `56` and `57` appended). A second fresh database stopped at `55` gave the comparison and the copies for the mutations.

| File | What | Result |
|---|---|---|
| `db/56_commerce_phone_hash-first-run.txt`, `db/56_commerce_phone_hash-rerun.txt` | the addition in the fresh build, then again | both clean (`ON_ERROR_STOP=1`): `INSERT 0 1`, `COMMIT`; the rerun skips the columns and indexes (notices) and ends `INSERT 0 0`, `COMMIT` |
| `db/57_verify_commerce_phone_hash.txt` | blocks A (5 checks) and B (7 checks) | `12 PASS, 0 FAIL`, verdict `PASS` |
| `db/57_verify_commerce_phone_hash-provoked.txt` | the same with `verify.provoke` true | all 12 `FAIL`, verdict `PROVOKED, NOT A PASS`, `0 PASS, 12 FAIL` (13 lines containing FAIL: 12 checks and the verdict's count) |
| `db/57_verify_commerce_phone_hash-refused-not-dev.txt` | a copy with `agent.two@example.com` inactive | `REFUSED: the connected database is not dev`, verdict `REFUSED: not dev` |
| `db/earlier-verifies/` | every verify `04` to `55` on a copy at `55` and on a copy at `57`, outputs masked (ids, times, dates); `comparison.txt` | identical, except `07` and `10`, which list the migration table and now show the `0008g` row; every verdict PASS (`37` unchanged) |
| `db/mutations.txt` | fifteen deliberate breakages of `56`, each on a fresh copy at `55`, with `57` run against it | every one caught, each by the check named on its line |
| `ingest/ingest-checks.txt` | `npm ci`, `npm run lint`, ESLint (the ingest config) on `docs/ingest/*.mjs`, `node --check` on every `.mjs` of `src`, `jobs`, `tools`, `verify` and `docs/ingest`, `bash -n docs/ingest/deploy.sh` | clean; 71 files, 0 errors |
| `ingest/verifiers-summary.txt`, `ingest/verify-*.txt` | every verifier in `ingest/verify/`, normal and `--provoke`; the database ones against the fresh database at `57` | `signature` 18, `mapping` 37, `hash` 26, `forms` 41, `aircall-token` 20, `aircall-mapping` 49, `aircall-scripts` 27, `shopify-signature` 17, `shopify-mapping` 53, `shopify-client` 21, `shopify-scripts` 21, `outbox` 20, `flow` 79, `jobs-flow` 62, `aircall-flow` 88, `shopify-flow` 80: ALL PASS, and ALL PROVOKED CHECKS FAILED. `flow`, `jobs-flow` and `aircall-flow` have the same counts as before B10 (`docs/b9a-uncounted-lines/local-records/`); `hash` gained six commerce checks |
| (in `verify-shopify-flow.txt`) | the burst of 200 `orders/create` deliveries | every answer `200` in 584 to 914 ms (median 795), one token minted, no GraphQL call refused for cost; 18 read inline, 182 left `throttled` for the sweep, which read all 200 (all `renewal`, each once) |
| `ingest/mutations.txt` | twelve deliberate breakages of the adapter and the outbox writer, each run against the verifiers that should catch it, the file restored afterwards | every one caught |
| `ingest/image-smoke.txt` | what the Dockerfile copies (`package.json`, `package-lock.json`, `src`, `jobs`), `npm ci --omit=dev`, every module imported, the server started: `/health`, a malformed key and a GET on `/shopify` | `adapters: hubspot aircall shopify automation`, the five jobs, `{"ok":true,"version":"b10local"}`, `404`, `404` |
| `ingest/docker-build-refused.txt` | `docker build` of `ingest/` (a Docker daemon was started in the session) | refused by Docker Hub: `429 Too Many Requests` for `node:22-alpine`, so no image was built here; Cloud Build builds it at the deploy |
| `web/typecheck.txt`, `web/lint.txt`, `web/build.txt` | `npm run typecheck`, `npm run lint`, `npm run build` in `web/` (no change under `web/` in this brief) | all exit 0 |
| `web/verifiers-summary.txt`, `web/verify-<name>.txt`, `web/verify-<name>-provoked.txt` | the pure verifiers CLAUDE.md names, normal and `--provoke` | all PASS and all provoked checks failed; `copy` 1061 keys in en and nl (its provoked run exits 1 with 5 problems, as designed) |

Not run here: `verify:api`, `verify:theme`, `verify:layout`, `verify:iap`, `verify:scheduler` (CLAUDE.md: Martin's, against dev or a server; nothing under `web/` changed), every `db/` script in dev and prod, and anything against a real Shopify or HubSpot (the flow runs against fakes).
