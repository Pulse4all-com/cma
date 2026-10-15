# Local run of brief B17a (email activity data model, addition 0008m)

Claude Code's local runs on 15 October 2026, redone for the amendment of 0008m with brief B17b's database half (contacts' country slots and `country_source`, contacts held for emails and threads, the market chain with the form step, the check `contact_country_fallback`) after `main` was merged into the branch. This is not a release record: `records/0008m-dev-*` and `records/0008m-prod-*` will come from Martin's real runs (`../MORNING_RUNBOOK.md`). No value here comes from dev, prod or GCP.

**Server:** PostgreSQL 18.4, the `@embedded-postgres/linux-x64` 18.4.0-beta.17 binaries from npm, as for B10 to B16 and the night of 15 October. The database is built fresh with the roles of `00_roles.sql`. `00` runs as `postgres`; every other script runs as the login `martin@pulse4all.com`, which is not a superuser.

**Order:** `00` to `67` in the order of the night of 15 October (`db/order-of-the-fresh-database.txt`); that database was kept as the template at `67`. Every run below starts from a fresh copy of it. `main`'s merge into the branch (#136, #137) changed no `db/` script.

## Database

| File | What | Result |
|---|---|---|
| `db/68_email_activity-first-run.txt` | the addition on a copy at `67` | Clean (`ON_ERROR_STOP=1`); ends `INSERT 0 1`, `COMMIT`, `RESET`. |
| `db/68_email_activity-rerun.txt` | the same addition run again | Clean; ends `INSERT 0 0`, `COMMIT`, `RESET`. |
| `db/69_verify_email_activity.txt` | block A (7 checks on the objects) and block B (22 checks on three throwaway tenants) | `29 PASS, 0 FAIL`, verdict `PASS`. |
| `db/69_verify_email_activity-provoked.txt` | the same with `verify.provoke` true | All 29 checks `FAIL`, verdict `PROVOKED, NOT A PASS`, `0 PASS, 29 FAIL`. The file has 30 lines containing FAIL: the 29 checks and the verdict's count. |
| `db/69_verify_email_activity-refused-not-dev.txt` | a copy with `agent.two@example.com` inactive | `REFUSED: the connected database is not dev`, verdict `REFUSED: not dev`. |
| `db/33_verify_intake_core-at69.txt`, `db/35_…`, `db/41_…`, `db/53_…` | the earlier verifies that own `connection_field`, the contact upsert and data quality, after `68` and `69` | `33`, `35` and `41` 2 PASS rows each, `53` 16 PASS (17 PASS rows): as before `68`. `33`'s C2 still sees its slot 2 of the contacts' country refused (`CMA04`), now as a gap: no slot 1 is mapped there. `41`'s A4 and E1 still find 0007d's fifteen checks and their totals. |
| `db/68_backfill-on-stored-contacts.txt` | a copy at `67` with three contacts stored by 0007's upsert (a catalog country, one not in the catalog, none), then `68` | `country_source` 1 on the two with a country, none on the third; the consistency check holds; two audit rows by `cma_owner`. |
| `db/earlier-verifies/` | every verify from `04` to `67`, each on a fresh copy at `67` and at `68`, outputs masked (ids, times, dates); see `comparison.txt` | 27 identical. `04`, `07`, `10` and `14` differ only in their listings: `04` the six tables (owner, row-level security, policy, audit) and the views with `dq_contact_country_fallback`; `07` and `10` the `0008m` row, whose description is the longest, so psql widens the column and every row of the listing re-flows; `14` the four settings with `email.market_order = contact,form,record,inbox (default)`. Each diff is kept as is and ignoring white space (`*-ignoring-white-space.diff`: 39, 14, 5 and 6 lines). |
| `db/mutations.py`, `db/mutations.txt` | sixty-eight deliberate breakages of `68` (the forty-eight of the first push, two of them reworded for the amended text, and twenty for the amendment: slots, the country choice, held contacts, the form step, the setting, data quality, the views), each on a fresh copy at `67`, then `69` | All sixty-eight caught, each by the checks named on its line. "B" is `69`'s row for a block that did not run to the end. |
| `db/datamap-check-local-schema.txt` | `tools/datamap/build.mjs`'s check (the page left out) on `docs/datamap/catalog.json` against a schema snapshot of the local database at `68`, kept outside the repository | `72 tables, 89 views, all described`. `docs/datamap/schema.json` itself stays dev's: Martin refreshes it on the branch after 0008m ran in dev (`../MORNING_RUNBOOK.md` step 4). |

## Web

No file under `web/` changed; CLAUDE.md's session checks ran anyway.

| File | What | Result |
|---|---|---|
| `web/npm-ci.txt`, `web/build.txt`, `web/typecheck.txt`, `web/lint.txt` | `npm ci`, `npm run build`, `npm run typecheck`, `npm run lint` in `web/` | All exit 0. |
| `web/verifiers-summary.txt`, `web/verify-<name>.txt`, `web/verify-<name>-provoked.txt` | the pure verifiers CLAUDE.md names, normal and `--provoke` | All PASS and all provoked checks fail (`copy` 1372 keys after `main`'s merge, its provoked run exits 1 with 5 problems, as designed; `signed-out` 16 checks after `main`'s merge), except `verify:datamap`: FAIL with 7 problems, the six new tables missing from `schema.json` and `index.html` not rebuilt, which is expected until Martin refreshes the snapshot from dev (CLAUDE.md, Database). |

## HubSpot specs read

`HubSpot-public-api-spec-collection`, `main`, read on 15 October 2026 through `raw.githubusercontent.com`:

- `PublicApiSpecs/Conversations/Conversations/Rollouts/54902/v3/conversations.json` (title "Conversations Inbox & Messages", v3): `GET /conversations/v3/conversations/threads` needs `conversations.read`; `PublicThread` has `archived`, `assignedTo`, `associatedContactId`, `closedAt`, `createdAt`, `id`, `inboxId`, `latestMessageReceivedTimestamp`, `latestMessageSentTimestamp`, `latestMessageTimestamp`, `originalChannelAccountId`, `originalChannelId`, `spam`, `status`, `threadAssociations`; the actors are typed `AGENT`, `BOT`, `INTEGRATOR`, `SYSTEM`, `VISITOR`, `EMAIL` and `LLM` (`EmailActor` and `VisitorActor` carry an email; the id is a plain string, its prefixes are not documented); a message's status is `FAILED`, `READ`, `RECEIVED` or `SENT`; a message carries `text`, `richText`, `subject`, `senders`, `recipients` and `attachments`, which the ingest drops (B17b).
- `PublicApiSpecs/CRM/Emails/Rollouts/424/2026-09/emails.json` (Emails, 2026-09): the batch read and the search need both `crm.objects.contacts.read` and `sales-email-read`; no email property name (`hs_email_direction`, `hs_email_status`) occurs in it, so B17b reads them from the properties API in dev.

Not run here:
- Every `db/` script in dev and prod (Martin, `../MORNING_RUNBOOK.md`).
- The data map's snapshot from dev and the rebuild of `docs/datamap/index.html` (Martin, step 4); until then `verify:datamap` fails on this branch, naming the six tables as missing from `schema.json`.
- Anything against HubSpot: nothing fills the tables before B17b.
