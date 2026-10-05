# Record: prod on the database, 5 October 2026

Increment: the API (Roadmap step 2). Environment: `p4a-cma-prod`. Recorded by Martin.

## Configuration
- Trigger `cma-web-main` substitutions: `_DATA_MODE=api`, `_DB_INSTANCE=p4a-cma-prod:europe-west4:cma-prod-pg`, `_DB_USER=cma-web@p4a-cma-prod.iam`, `_IAP_AUDIENCE` unchanged; changed through `gcloud beta builds triggers export` / `import` (diff: three lines added, nothing removed)
- Build `063b0a7f-7530-411e-a215-e7ab15cc39e8` (commit `cd70368`, run by hand): SUCCESS, `check-config` passed
- Service env after deploy: `CMA_AUTH_MODE=iap`, `CMA_DATA_MODE=api`, `CMA_DB_INSTANCE` and `CMA_DB_USER` as above, `CMA_DB_NAME=cma`, `CMA_DB_POOL_MAX=5`; `maxScale` 4
- Database user `cma-web@p4a-cma-prod.iam` (`CLOUD_IAM_SERVICE_ACCOUNT`): member of `cma_app` with inherit true, set false, admin false; plus Cloud SQL's own `cloudsqliamserviceaccount`
- Service account roles in `p4a-cma-prod`: Cloud SQL Client, Cloud SQL Instance User

## People
- `db/09_seed_people_prod.sql` run with only Martin's id filled in: `pulse4all-subscriptions | martin@pulse4all.com | Martin Bartels | active | manager | 1 google id`. Joshua and Finn skipped (placeholders). The id itself is not recorded here.

## Behaviour
- workspace.pulse4all.app at 17:52 Amsterdam: "Signed in as Martin Bartels · Pulse4all B.V.", no test-data banner, My day "Working since 17:52", version `cd70368`
- Cloud SQL Studio as `cma_owner`: `2026-10-05 | open | Europe/Amsterdam | started 17:52:22 | 76 s`; `max_connections` 50; `app_connections` 0 at the time of the query (the pool closes idle connections after 30 s)

## Dev, same day
- API verifier against dev: `records/api-dev-2026-10-05` (15 PASS; `--provoke` 15 FAIL)
