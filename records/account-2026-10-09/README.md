# My account (addition 0005b), 9 October 2026

`local/`: built and verified on a local PostgreSQL 18.6 on top of `00` to `27` and the seeds, before
dev: `29_verify_my_profile.sql` normal (PASS) and provoked (FAIL A3, FAIL B1, PROVOKED), the API
verifier against the local database through `CMA_DB_HOST` (ALL 143 PASS; ALL 143 PROVOKED CHECKS
FAILED). Theme 20 pages and layout with My account for five identities passed against the local
mock server; the screenshots are in `records/layout`.

`dev.txt` and `prod.txt`: the verdict of `29` in Cloud SQL Studio on cma-dev-pg and cma-prod-pg,
added in the records PR. `api-dev.txt`: the API verifier against dev.
