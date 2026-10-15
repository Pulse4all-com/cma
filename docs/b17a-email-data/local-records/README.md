# Local run of brief B17a (email activity data model, addition 0008m)

Claude Code's local runs on 15 October 2026. This is not a release record: `records/0008m-dev-*` and `records/0008m-prod-*` will come from Martin's real runs (`../MORNING_RUNBOOK.md`). No value here comes from dev, prod or GCP.

**Server:** PostgreSQL 18.4, the `@embedded-postgres/linux-x64` 18.4.0-beta.17 binaries from npm, as for B10 to B16 and the night of 15 October. The database is built fresh with the roles of `00_roles.sql`. `00` runs as `postgres`; every other script runs as the login `martin@pulse4all.com`, which is not a superuser.

**Order:** `00` to `67` in the order of the night of 15 October (`db/order-of-the-fresh-database.txt`); that database was kept as the template at `67`. Every run below starts from a fresh copy of it.

## Database

| File | What | Result |
|---|---|---|
| `db/68_email_activity-first-run.txt` | the addition on a copy at `67` | Clean (`ON_ERROR_STOP=1`); ends `INSERT 0 1`, `COMMIT`, `RESET`. |
| `db/68_email_activity-rerun.txt` | the same addition run again | Clean; ends `INSERT 0 0`, `COMMIT`, `RESET`. |
| `db/69_verify_email_activity.txt` | block A (6 checks on the objects) and block B (16 checks on two throwaway tenants) | `22 PASS, 0 FAIL`, verdict `PASS`. |
| `db/69_verify_email_activity-provoked.txt` | the same with `verify.provoke` true | All 22 checks `FAIL`, verdict `PROVOKED, NOT A PASS`, `0 PASS, 22 FAIL`. The file has 23 lines containing FAIL: the 22 checks and the verdict's count. |
| `db/69_verify_email_activity-refused-not-dev.txt` | a copy with `agent.two@example.com` inactive | `REFUSED: the connected database is not dev`, verdict `REFUSED: not dev`. |
| `db/33_verify_intake_core-at69.txt`, `db/35_…`, `db/53_…` | the brief's earlier verifies after `68` and `69` | `33` and `35` 2 PASS rows each, `53` 16 PASS (17 PASS rows): as before `68`. |
| `db/earlier-verifies/` | every verify from `04` to `67`, each on a fresh copy at `67` and at `68`, outputs masked (ids, times, dates); see `comparison.txt` | 27 identical. `04`, `07`, `10` and `14` differ only in their listings (the six tables, their policies and audit triggers, the `0008m` row, the four settings); the four diffs are kept (`04`'s is long because psql widens its columns for the longer table names). |
| `db/mutations.py`, `db/mutations.txt` | forty-eight deliberate breakages of `68`, each on a fresh copy at `67`, then `69` | All forty-eight caught, each by the checks named on its line. "B" is `69`'s row for a block that did not run to the end. |
| `db/datamap-check-local-schema.txt` | `tools/datamap/build.mjs`'s check (the page left out) on `docs/datamap/catalog.json` against a schema snapshot of the local database at `68`, kept outside the repository | `72 tables, 88 views, all described`. `docs/datamap/schema.json` itself stays dev's: Martin refreshes it on the branch (`../MORNING_RUNBOOK.md` step 4). |

## Web

No file under `web/` changed; CLAUDE.md's session checks ran anyway.

| File | What | Result |
|---|---|---|
| `web/npm-ci.txt`, `web/build.txt`, `web/typecheck.txt`, `web/lint.txt` | `npm ci`, `npm run build`, `npm run typecheck`, `npm run lint` in `web/` | All exit 0. |
| `web/verifiers-summary.txt`, `web/verify-<name>.txt`, `web/verify-<name>-provoked.txt` | the pure verifiers CLAUDE.md names, normal and `--provoke` | All PASS and all provoked checks fail (`copy` 1371 keys, its provoked run exits 1 with 5 problems, as designed), except `verify:datamap`: FAIL with 7 problems, the six new tables missing from `schema.json` and `index.html` not rebuilt, which is expected until Martin refreshes the snapshot from dev (CLAUDE.md, Database). |

## HubSpot specs read

`HubSpot-public-api-spec-collection`, `main`, read on 15 October 2026 through `raw.githubusercontent.com`:

- `PublicApiSpecs/Conversations/Conversations/Rollouts/54902/v3/conversations.json` (title "Conversations Inbox & Messages", v3): `GET /conversations/v3/conversations/threads` needs `conversations.read`; `PublicThread` has `archived`, `assignedTo`, `associatedContactId`, `closedAt`, `createdAt`, `id`, `inboxId`, `latestMessageReceivedTimestamp`, `latestMessageSentTimestamp`, `latestMessageTimestamp`, `originalChannelAccountId`, `originalChannelId`, `spam`, `status`, `threadAssociations`; the actors are typed `AGENT`, `BOT`, `INTEGRATOR`, `SYSTEM`, `VISITOR`, `EMAIL` and `LLM` (`EmailActor` and `VisitorActor` carry an email; the id is a plain string, its prefixes are not documented); a message's status is `FAILED`, `READ`, `RECEIVED` or `SENT`; a message carries `text`, `richText`, `subject`, `senders`, `recipients` and `attachments`, which the ingest drops (B17b).
- `PublicApiSpecs/CRM/Emails/Rollouts/424/2026-09/emails.json` (Emails, 2026-09): the batch read and the search need both `crm.objects.contacts.read` and `sales-email-read`; no email property name (`hs_email_direction`, `hs_email_status`) occurs in it, so B17b reads them from the properties API in dev.

Not run here:
- Every `db/` script in dev and prod (Martin, `../MORNING_RUNBOOK.md`).
- The data map's snapshot from dev and the rebuild of `docs/datamap/index.html` (Martin, step 4); until then `verify:datamap` fails on this branch, naming the six tables as missing from `schema.json`.
- Anything against HubSpot: nothing fills the tables before B17b.
