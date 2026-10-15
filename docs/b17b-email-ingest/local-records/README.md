# Local run of brief B17b (the email poll)

Claude Code's local runs on 15 October 2026. This is not a release record: `records/` gets Martin's real runs of `../MORNING_RUNBOOK.md` and `docs/ingest/PROD_RUNBOOK.md` phase 10, written from his report. No value here comes from dev, prod, GCP or HubSpot: every HubSpot answer is the fake of `ingest/verify/email-fake.mjs` with the invented fixtures `ingest/verify/fixtures/hubspot/email-source.json` and `email-rules.json`.

**Database:** PostgreSQL 18.4, the `@embedded-postgres/linux-x64` 18.4.0-beta.17 binaries from npm (as for B17a), initialised with the ICU locale `en-US`; built fresh with the roles of `00_roles.sql` (as `postgres`), then `01` to `69` in the order of `docs/b17a-email-data/local-records/db/order-of-the-fresh-database.txt` as the login `martin@pulse4all.com` (not a superuser): `67` 23 PASS, `69` 29 PASS before any run here. The flow verifiers' job login is `cma-ingest@local.iam`, a member of `cma_app`, as in earlier briefs; `email-flow-own-login-as-in-dev.txt` runs it the way the runbook does in dev, with the admin login as the job's (`CMA_DB_SET_ROLE=cma_app`). No `db/` script changed.

## ingest

| File | What | Result |
|---|---|---|
| `ingest/lint.txt` | `npx eslint` in `ingest/` | exit 0, no findings |
| `ingest/npm-test.txt` | `npm test`: the twelve earlier pure verifiers and `verify/email-mapping.mjs` | thirteen `ALL n PASS` (18, 37, 26, 41, 20, 49, 27, 17, 51, 21, 21, 20, 76), exit 0 |
| `ingest/provoked-<name>.txt` | each of the thirteen with `--provoke` | every one `ALL n PROVOKED CHECKS FAILED, as they must` |
| `ingest/email-flow.txt`, `ingest/email-flow-provoked.txt` | `verify/email-flow.mjs` against the local database, normal and `--provoke` | `ALL 32 PASS`; `ALL 32 PROVOKED CHECKS FAILED, as they must` |
| `ingest/email-flow-own-login-as-in-dev.txt` | the same with `CMA_DB_USER=martin@pulse4all.com CMA_DB_SET_ROLE=cma_app`, the dev runbook's way | `ALL 32 PASS` |
| `ingest/email-flow-refused-not-dev.txt` | the same with `agent.two@example.com` set inactive for the run (restored after) | `REFUSED: the connected database is not dev …`, exit 2, nothing created |
| `ingest/flow.txt`, `jobs-flow.txt`, `aircall-flow.txt`, `shopify-flow.txt`, `outbox-flow.txt` | the earlier flow verifiers on the same database after the changes to the store, the reconcile and the backfill | 79, 71, 88, 86 and 11 PASS. `jobs-flow` first failed three checks while the reconcile listed the email objects for every HubSpot connection (two extra runs each); since then a connection gets them only with `email_poll` on, and it passes unchanged |

## db

| File | What | Result |
|---|---|---|
| `db/69_verify_email_activity-after-email-flow.txt` | `69` again on the database after every flow run above (their throwaway tenants and rows in place) | `29 PASS, 0 FAIL`, verdict `PASS` |

## hubspot

| File | What | Result |
|---|---|---|
| `hubspot/render.txt`, `hubspot/render-provoked.txt` | `node hubspot/verify/render.mjs`, normal and `--provoke` | `ALL 32 PASS` (31 before: one check added for the email poll's read scopes; the documented scope set, the subscription count of 37 with `country_dropdown` and §1.3's named properties changed in their existing checks); `ALL 32 PROVOKED CHECKS FAILED, as they must` |

## web

No file under `web/` changed; CLAUDE.md's session checks ran anyway.

| File | What | Result |
|---|---|---|
| `web/npm-ci.txt`, `web/build.txt`, `web/typecheck.txt`, `web/lint.txt` | `npm ci`, `npm run build`, `npm run typecheck`, `npm run lint` in `web/` | all exit 0 |
| `web/verify-<name>.txt`, `web/verify-<name>-provoked.txt` | the thirteen pure verifiers CLAUDE.md names, normal and `--provoke` | all PASS (`copy` 1372 keys, `datamap` 72 tables and 89 views, all described, `index.html` current); every provoked run fails its checks, `copy` and `datamap` with exit 1 and 5 problems each, as designed |
| `web/datamap-check.txt` | `node tools/datamap/build.mjs --check` after the catalog's new "how" texts and the rebuilt `index.html` | `72 tables, 89 views, all described; index.html current` |

## HubSpot specs read

`HubSpot-public-api-spec-collection`, `main` at `1c9c50f` (15 October 2026), cloned sparsely:

- `PublicApiSpecs/CRM/Emails/Rollouts/424/2026-09/emails.json`: the search and the batch read name `crm.objects.contacts.read` and `sales-email-read` in one security requirement (both needed). The newer rollout `PublicApiSpecs/CRM/Emails/Rollouts/321895/2026-09/emails.json` lists 80 alternatives for the same calls, among them `crm.objects.emails.read` (the fallback in `hubspot/README.md`). Neither names an email property such as `hs_email_status` or a thread id: those are read in dev (`docs/ingest/hubspot-email-check.mjs`).
- `PublicApiSpecs/Conversations/Conversations/Rollouts/54902/v3/conversations.json` and its 2026-09 rollout: every read (inboxes, channels, channel accounts, threads, a thread, its messages, actors) names `conversations.read`. `PublicApiSpecs/Conversations/Conversations Inbox & Messages/Rollouts/54902/v3/conversationsInboxMessages.json`, the `sort` parameter of `GET threads`: "Valid options are `id` (default) and `latestMessageTimestamp` (which requires the `latestMessageTimestampAfter` field to also be set) … Otherwise, results are always returned in ascending order." The message types `MESSAGE` (with `text`, `richText`, `subject`, `senders`, `recipients`, `attachments`), `ASSIGNMENT` (`assignedTo`, `assignedFrom`), `THREAD_STATUS_CHANGE` (`newStatus`), `THREAD_INBOX_CHANGE` (`fromInboxId`, `toInboxId`), `COMMENT`, `WELCOME_MESSAGE`; the actors `AGENT`, `BOT`, `INTEGRATOR`, `SYSTEM`, `VISITOR`, `EMAIL`, `LLM`, without documented id prefixes.

`developers.hubspot.com` was not reachable from the session (the proxy refused it), as in earlier briefs.

## Not run here

Anything against dev, prod, HubSpot or Google Cloud: the app's upload and its consent screen, `hubspot-email-check.mjs` on a real account (the property names, the status values, the actor prefixes), the deploy and the job, the backfills, the overlap test, `verify/email-flow.mjs` against dev. They are `../MORNING_RUNBOOK.md` steps 2 to 8 and `docs/ingest/PROD_RUNBOOK.md` phase 10.
