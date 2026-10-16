# Local run of brief B17b.1 (the flow verifiers serve only their own connections)

Claude Code's local runs on 16 October 2026. This is not a release record: no value here comes from dev, prod, GCP or HubSpot. Every HubSpot answer is a fake on localhost with invented fixtures; the connection that stands for dev's real one is invented too (below).

**Database:** PostgreSQL 18.4, the `@embedded-postgres/linux-x64` 18.4.0-beta.17 binaries from npm (as for B17a and B17b), initialised with the ICU locale `en-US`; built fresh with the roles of `00_roles.sql` (as `postgres`), then `01` to `69` in the order of `db/order-of-the-fresh-database.txt` (B17a's) as the login `martin@pulse4all.com` (not a superuser): `69` `29 PASS, 0 FAIL` (`db/69_verify_email_activity.txt`). The flow verifiers' job login is `cma-ingest@local.iam`, a member of `cma_app`. No `db/` script changed.

**The bystander.** To reproduce Martin's finding, the seed tenant `pulse4all-subscriptions` was given an invented HubSpot connection (portal `9009999`, token secret `ingest-hubspot-bystander-token`, which no verifier's secrets folder holds) with `email_poll` true, as dev's real connection has. Every run below ran with it active. A second login, `scheduled-stand-in@local.iam` (a member of `cma_app`), stands for the Cloud Run jobs' own login in dev.

Each run's file ends with the audit rows it left in tenants that existed before it started (its own two are created after), by login and table.

## ingest

| File | What | Result |
|---|---|---|
| `ingest/email-flow-main-unchanged.txt` | `main`'s `verify/email-flow.mjs`, unchanged | `ALL 32 PASS`, and the finding reproduced: a failed `email_poll` run (`token_unavailable`) for `pulse4all-subscriptions`, inserted and updated by the job's login |
| `ingest/jobs-flow-main-unchanged.txt` | `main`'s `verify/jobs-flow.mjs`, unchanged | `ALL 71 PASS`, while its unfiltered sweep served every active connection: it took three failed events of a leftover `flow.mjs` tenant through another attempt (attempts 1 to 2, their errors replaced by `token_unavailable`), added two reread events there that failed the same way, and wrote a `link_calls` run into three tenants that are not its own, `pulse4all-subscriptions` among them |
| `ingest/email-flow.txt`, `ingest/email-flow-provoked.txt` | the fixed `verify/email-flow.mjs` | `ALL 33 PASS`, nothing in another tenant; `ALL 33 PROVOKED CHECKS FAILED, as they must` |
| `ingest/jobs-flow.txt`, `ingest/jobs-flow-provoked.txt` | the fixed `verify/jobs-flow.mjs` | `ALL 72 PASS`, nothing in another tenant; `ALL 72 PROVOKED CHECKS FAILED, as they must` |
| `ingest/guard-unfiltered-variants.diff`, `ingest/email-flow-guard-unfiltered-poll.txt`, `ingest/jobs-flow-guard-unfiltered-sweep.txt` | the fixed verifiers with only the old call put back (the poll or the sweep without a connection), in temporary copies deleted afterwards | the guard fails as it must: `email-flow` `2 of 33 FAILED` (G1 `[2,0,0,1]`, I1 `["sync_run:2"]`), `jobs-flow` `1 of 72 FAILED` (`["sync_run:6"]`) |
| `ingest/email-flow-with-a-scheduled-stand-in.txt` | the fixed `verify/email-flow.mjs` while the stand-in login runs `node jobs/poll-email.mjs --connection <the bystander>` every half second, as dev's scheduled poll writes meanwhile | `ALL 33 PASS`: the stand-in's six audit rows in `pulse4all-subscriptions` (three failed runs) are another login's, so I1 leaves them out |
| `ingest/flow.txt`, `aircall-flow.txt`, `shopify-flow.txt`, `outbox-flow.txt` | the four other flow verifiers, unchanged (every job they run names its connection) | 79, 88, 86 and 11 PASS, nothing in another tenant |
| `ingest/lint.txt` | `npx eslint` in `ingest/` | exit 0, no findings |
| `ingest/npm-test.txt` | `npm test` (the thirteen pure verifiers; `verify/lib.mjs` gained an export) | thirteen `ALL n PASS` (18, 37, 26, 41, 20, 49, 27, 17, 51, 21, 21, 20, 76), exit 0 |
| `ingest/provoked-<name>.txt` | each of the thirteen with `--provoke` | every one `ALL n PROVOKED CHECKS FAILED, as they must` |

## docs

| File | What | Result |
|---|---|---|
| `docs/step8-main-queries.txt` | `main`'s `../../b17b-email-ingest/MORNING_RUNBOOK.md` step 8 | the thread query stops at `column reference "status" is ambiguous`; the catalogs (20 inboxes, 30 channels, 10 contacts from a fallback) and the runs of the last hour count every tenant: here only verifiers' throwaway tenants |
| `docs/step8-fixed-queries.txt` | the fixed step 8 | every query runs (exit 0); `pulse4all-subscriptions` alone: no email row, catalogs 0, the bystander's failed runs |
| `docs/step8-fixed-queries-on-a-throwaway-tenant.txt` | the fixed step 8 with the slug of the last `email-flow` run's tenant one | the tenant's own counts: nine message groups, four thread groups, four event kinds, 2 inboxes, 3 channels, 1 contact from a fallback, 6 runs succeeded and 1 failed (the 429) |

## web

No file under `web/` changed; CLAUDE.md's session checks ran anyway.

| File | What | Result |
|---|---|---|
| `web/npm-ci.txt`, `web/build.txt`, `web/typecheck.txt`, `web/lint.txt` | `npm ci`, `npm run build`, `npm run typecheck`, `npm run lint` in `web/` | all exit 0 |
| `web/verify-<name>.txt`, `web/verify-<name>-provoked.txt` | the thirteen pure verifiers CLAUDE.md names, normal and `--provoke` | all PASS (`copy` 1372 keys, `datamap` 72 tables and 89 views, all described, `index.html` current); every provoked run fails its checks, `copy` and `datamap` with exit 1 and 5 problems each, as designed |

## Not run here

`verify/email-flow.mjs` against dev (`../../b17b-email-ingest/MORNING_RUNBOOK.md` step 7) and step 8 in Studio: Martin's.
