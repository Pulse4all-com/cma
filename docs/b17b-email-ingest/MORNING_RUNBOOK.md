# Runbook, B17b: the email poll (HubSpot email engagements and inbox conversations)

Labels: **Browser**, **Terminal** (Cloud Shell, in `~/cma` unless stated), **Studio** (the instance named), **File** (a repository path). SQL and shell never share a block. Every step ends with what you should see. Claude Code's local outputs are in `local-records/` (its `README.md` lists them).

**What changes:** the ingest service's jobs and the HubSpot app; no migration. A new Cloud Run job `ingest-poll-email` (every minute) fills the tables of addition 0008m (B17a, `Pulse4all-com/cma#135`, run in dev and prod on 15 October 2026): the CRM's email engagements (`crm_email`) and the inbox conversations' messages (`inbox_message`), kept apart, the threads and their assignments, closes, reopens and inbox moves, the inbox and channel catalogs, and the contacts the emails and threads point to, read with every country slot. Metadata only: no subject, body, address, name or raw actor id is stored or logged (README, Data model: email activity; `docs/ingest/README.md`, section Email). The HubSpot app gains two read scopes (`sales-email-read`, `conversations.read`) and one subscription (`object.propertyChange` on the contact property `country_dropdown`). The nightly reconcile and the backfill learn `crm_email` and `inbox_thread`; `--object contact` reads every country slot.

**Order matters:**
- The poll serves a connection only while its settings hold `email_poll` true (step 3). Deploying the job before that polls nothing and writes no run row.
- The app's new scopes must be accepted in the account before the poll is switched on, or every run fails with `http_403` (step 2).
- `country_dropdown` is a property of the live portal that the CMA does not create; in the developer test account `CMA dev` it does not exist until step 2 creates it, with the live portal's option values.
- Merging deploys nothing (`web/**` and `cloudbuild.yaml` are untouched): the ingest image is built and deployed by hand with `docs/ingest/deploy.sh` from the merged `main` (step 4), as for B9 and B10, so prod later runs the image dev ran.
- No `db/` script changes; `docs/datamap/schema.json` needs no refresh (no schema change), only `catalog.json`'s "how" texts changed.
- Prod is `docs/ingest/PROD_RUNBOOK.md` phase 10, after dev passes. Yordi agreed to the email metadata, the two scopes and the held contacts on 15 October 2026 (README Decision log), so dev is the only gate.

| Step | What | Elapsed |
|---|---|---|
| 1 | Review the pull request, run the ingest and HubSpot checks | 20 min |
| 2 | The dev app: `country_dropdown` in `CMA dev`, render, upload, accept the new scopes | 20 min |
| 3 | Configure dev: the email properties and settings, country slot 2 with its aliases, inboxes and channels | 25 min |
| 4 | Merge, then the ingest image and the jobs in dev | 15 min |
| 5 | Backfill: contacts, then emails and threads | 15 min |
| 6 | The overlap test with a connected test inbox | 20 min |
| 7 | `verify:email-flow` against dev | 5 min |
| 8 | Read-only counts | 5 min |
| 9 | Prod: `docs/ingest/PROD_RUNBOOK.md` phase 10 | per phase 10 |

---

## Helpers (define in every new Cloud Shell)

The helpers `cma_db` and `run_migration` of `docs/night-2026-10-13/MORNING_RUNBOOK.md`, section Helpers, unchanged: paste that block first (only `cma_db` is used here). The Studio context block is the one at the top of `docs/ingest/PROD_RUNBOOK.md`, with `cma-dev-pg` and the dev tenant `pulse4all-subscriptions`.

Expected: `type cma_db` prints the function; `node -v` prints `v22.…`.

## 1. Review the pull request and run the checks

**Browser:** GitHub → Pulse4all-com/cma → Pull requests → "B17b: email ingest". Read the description and the diff.

Expected: changes under `ingest/`, `hubspot/`, `docs/` and `README.md`; none under `web/`, `db/`, `cloudbuild.yaml` or `records/`.

**Terminal** (the pull request's number from the page)
```bash
cd ~/cma && gh pr checkout <number> && cd ingest && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run lint && npm test 2>&1 | grep -E "^ALL|FAILED"; cd ~/cma && node hubspot/verify/render.mjs | tail -1
```
Expected: `found 0 vulnerabilities`, no lint output after the `eslint` line, thirteen lines `ALL n PASS` (18, 37, 26, 41, 20, 49, 27, 17, 51, 21, 21, 20, 76; the last is `verify/email-mapping.mjs`), no `FAILED`, then `ALL 32 PASS`. **Do not merge yet.**

## 2. The dev app

**2a. `country_dropdown` in `CMA dev`.** Its option values must be the live portal's, so the aliases of step 3 hold in both. Read them with the prod token (metadata, no contact data):

**Terminal**
```bash
gcloud secrets versions access latest --secret=ingest-hubspot-subs-token --project=p4a-cma-prod | sed 's/^/Authorization: Bearer /' \
  | curl -s -H @- https://api.hubapi.com/crm/v3/properties/contacts/country_dropdown \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("name"), d.get("type"), d.get("fieldType"), len(d.get("options",[])), "options"); print(", ".join(o["value"] for o in d.get("options",[])[:8]), "…")'
```
Expected: `country_dropdown enumeration select <n> options`, then the first eight values (country names such as `United Kingdom`).

**Browser:** `CMA dev` → Settings → Data Management → Properties → Contact → Create property: label `Country (dropdown)`, internal name `country_dropdown`, field type Dropdown select, and at least the options `United Kingdom`, `Netherlands`, `Germany` and `Atlantis Test` with the values exactly as the live portal writes them (the last one deliberately no market). Then fill it on the test contacts of VENDOR_SETUP §1.2, leaving Contact-Country as it is: `United Kingdom` on test1 (which holds the first deal, so the CMA holds it) and on one contact whose Contact-Country is empty, `Netherlands` on one whose Contact-Country is filled, `Atlantis Test` on another whose Contact-Country is empty.

Expected: the property listed with four options; the contacts show their value. Each change also sends a webhook (`country_dropdown` is subscribed): a contact the CMA holds is read again, the others are recorded as ignored.

**2b. Render and upload.**

**Terminal** (in `~/cma`, still on the pull request's branch; `<URL>` and `<key>` as in `hubspot/README.md` step 2)
```bash
node hubspot/render.mjs dev --target-url "<URL>/hubspot/<key>" && cd hubspot/build/dev && hs project upload && cd ~/cma
```
Expected: `rendered dev: hubspot/build/dev`, then the upload naming the live portal, and build and deploy of **CMA ingest dev** succeeding with both components. If HubSpot refuses a scope, stop and send me its message (`crm.objects.emails.read` is not available to this app: `hubspot/README.md`, Scopes).

**2c. Accept the new scopes.** **Browser:** live portal → Development → Projects → CMA ingest dev → the app → Distribution → Test installs → the row of `CMA dev` → update or reinstall when HubSpot asks; on the consent screen check that the new scopes are `sales-email-read` and `conversations.read` (read only).

Expected: the test install's row active; the app's Auth tab lists the two scopes. The static token stays the same; if HubSpot shows a new one, store it with `put_secret p4a-cma-dev ingest-hubspot-dev-token` (`hubspot/README.md`).

**2d. Both endpoints answer.** **Terminal** (the HTTP status only; a body is never printed, it can hold email data)
```bash
for p in "/crm/v3/objects/emails?limit=1" "/conversations/v3/conversations/inboxes?limit=1"; do gcloud secrets versions access latest --secret=ingest-hubspot-dev-token --project=p4a-cma-dev | sed 's/^/Authorization: Bearer /' | curl -s -o /dev/null -w "%{http_code}  ${p%%\?*}\n" -H @- "https://api.hubapi.com$p"; done
```
Expected: `200  /crm/v3/objects/emails` and `200  /conversations/v3/conversations/inboxes`. A `403` means the install does not hold the scope yet (HubSpot answers `MISSING_SCOPES`): update or reinstall the test install (2c) and run it again.

## 3. Configure dev

**3a. What the account holds.** **Terminal** (in `~/cma`, the branch still checked out)
```bash
node docs/ingest/hubspot-email-check.mjs --project p4a-cma-dev --token-secret ingest-hubspot-dev-token --days 30
```
Expected, four blocks (metadata and counts only):
- `== 1.` eight properties, each `present`, `hs_email_direction` with `options: EMAIL, INCOMING_EMAIL, FORWARDED_EMAIL` and `hs_email_status` with its options. Send me the `hs_email_status` options and any `MISSING` line: the ingest maps `sent`, `bounced`, `failed` and `scheduled` (any case) and everything else to `other`.
- `== 2.` the candidates. Pick the property that holds HubSpot's thread id (a string whose label speaks of the thread) as `<thread property>`, and the one that tells whether a sequence or an automation sent the email as `<origin property>`, with the option values that mean "an automation sent it" as `<automated values>` (comma-separated). Send me the names you picked and why; none fitting means leaving that setting out.
- `== 3.` the actor id prefixes: expected `A AGENT`, `E EMAIL`, `V VISITOR`, `S SYSTEM`, maybe `B BOT`, `I INTEGRATOR`, and any `LLM` line. Send me the block: it confirms the table in `docs/ingest/README.md`, section Email (another prefix maps to `unknown` until it is added).
- `== 4.` the inboxes and channels with their ids (`(no actors …)` in block 3 and no inbox in block 4 mean no inbox is connected yet: step 6 connects one; come back to 3d then).

**3b. The connection.** **Studio (cma-dev-pg)** (read; note the HubSpot connection's id as `<conn>`)
```sql
set role cma_owner;
select c.id, c.adapter, c.name, c.kind, c.settings from cma.integration_connection c join cma.tenant t on t.id = c.tenant_id
where t.slug = 'pulse4all-subscriptions' and c.adapter = 'hubspot';
reset role;
```
Expected: one row, kind `crm`, its current settings.

**Studio (cma-dev-pg)** after the context block (the settings are replaced whole, so the current ones are merged in; leave out a property you did not pick in 3a)
```sql
select cma.set_connection_settings('<conn>', (select c.settings from cma.integration_connection c where c.id = '<conn>')
  || '{"email_poll": true, "email_thread_property": "<thread property>", "email_origin_property": "<origin property>", "email_automated_origins": "<automated values>"}'::jsonb);
select cma.set_connection_field('<conn>', 'contact', 'country', '', 'country_dropdown', 2::smallint);
select f ->> 'field' as field, f ->> 'slot' as slot, f ->> 'property' as property from jsonb_array_elements(cma.connection_config('<conn>') -> 'fields') f
where f ->> 'entity' = 'contact' and f ->> 'field' = 'country';
select cma.connection_config('<conn>') -> 'settings';
reset role;
```
Expected: two empty results, then `country | 1 | contact_country` and `country | 2 | country_dropdown`, then the settings with `email_poll: true` and your properties next to the earlier keys. (`country_dropdown` twice, or a slot 3 without 2, is refused with `CMA03` or `CMA04`.)

**3c. Aliases for `country_dropdown`.** A value that names no market through an alias stays as written and lands in data quality (`market_not_in_catalog`). First the values as one SQL list:

**Terminal**
```bash
gcloud secrets versions access latest --secret=ingest-hubspot-dev-token --project=p4a-cma-dev | sed 's/^/Authorization: Bearer /' \
  | curl -s -H @- https://api.hubapi.com/crm/v3/properties/contacts/country_dropdown \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('array[' + ', '.join(\"'\" + o['value'].replace(\"'\", \"''\") + \"'\" for o in d.get('options', [])) + ']')"
```
Expected: one line `array['United Kingdom', 'Netherlands', …]`.

**Studio (cma-dev-pg)** (read; paste the line in place of `<array>`)
```sql
set role cma_owner;
select v as option_value, cma.market_code_of(t.id, v) as market
from cma.tenant t cross join unnest(<array>) v
where t.slug = 'pulse4all-subscriptions' order by market nulls first, v;
reset role;
```
Expected: one row per option; `market` filled for every value the 26 aliases of 10 October already name (`United Kingdom` → `GB`, `Netherlands` → `NL`, …), empty for the rest.

For every empty row whose value is a country of a catalog market, add the alias on **Browser:** Workspace (dev) → Configuration → Markets → the market → Aliases, or in **Studio (cma-dev-pg)** after the context block:
```sql
select cma.set_market_alias('<option value>', '<market code>');
reset role;
```
Expected: an empty result per alias; the read above now shows the market. Values of countries that are no market (and `Atlantis Test`) stay empty on purpose.

**3d. Inboxes and channels.** New inboxes count and take the channel `email`; new channels count only when their kind is `email`. Set what differs, with the ids of block 4. **Studio (cma-dev-pg)** after the context block (one line per inbox or channel; `null` for no market, work type or channel)
```sql
select cma.set_inbox('<conn>', '<inbox id>', true, 'GB', null, 'email');
select cma.set_inbox_channel('<conn>', '<channel id>', 'email', true);
select b ->> 'inboxId' as inbox, b ->> 'name' as name, b ->> 'isCounted' as counted, b ->> 'market' as market, b ->> 'channel' as channel
from jsonb_array_elements(cma.connection_config('<conn>') -> 'inboxes') b;
reset role;
```
Expected: empty results, then the inboxes as configured (an inbox not yet in the catalog shows its id as its name until the first poll brings the name).

## 4. Merge, then the ingest image and the jobs in dev

**Browser:** the pull request → **Squash and merge** → Confirm.

**Terminal**
```bash
cd ~/cma && git switch -q main && git pull -q --ff-only && git log --oneline -1 && git log -1 --format=%h -- ingest/
```
Expected: the merge commit twice (the image tag `deploy.sh` uses). No Cloud Build runs.

**Terminal** (on the merged `main`)
```bash
bash docs/ingest/deploy.sh dev && bash docs/ingest/deploy.sh dev --jobs
```
Expected: the build in `p4a-cma-prod` ending `SUCCESS` (or `image … exists …; no build`), the service's `health: {"ok":true,"version":"<sha>"}`; then six `gcloud run jobs deploy` results, `schedule ingest-sweep: * * * * *`, `schedule ingest-poll-forms: * * * * *`, `schedule ingest-poll-email: * * * * * (Europe/Amsterdam)`, `schedule ingest-reconcile: 30 2 * * *` and `schedule ingest-outbox: none …`.

After two minutes, **Studio (cma-dev-pg)**
```sql
set role cma_owner;
select status, counts, error, started_at from cma.sync_run where job = 'email_poll' order by started_at desc limit 3;
select stream, cursor ? 'at' as has_at, updated_at from cma.sync_cursor where stream like 'email:%' order by stream;
reset role;
```
Expected: `succeeded` rows, a minute apart, with counts; streams `email:accounts`, `email:catalogs`, `email:engagements`, `email:open-check`, `email:owners` and their parts (`email:owners:0`, …) and `email:threads`. A `failed` row with `http_403` means a scope is not accepted (step 2c); `token_unavailable` the token secret's accessor. Send me the first three rows.

**Terminal** (the job's log: counts and codes only)
```bash
gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=ingest-poll-email AND jsonPayload.message="poll-email: connection"' --project=p4a-cma-dev --limit=3 --format='value(jsonPayload.fetched,jsonPayload.upserted,jsonPayload.error,jsonPayload.outcomes)'
```
Expected: counts and outcome counts per kind; no id, address or subject.

## 5. Backfill: contacts, then emails and threads

Contacts first, so the held ones are read again with slot 2 before the emails add more. The connection id `<conn>` as in step 3.

**Terminal**
```bash
for o in contact crm_email inbox_thread; do gcloud run jobs execute ingest-backfill --project=p4a-cma-dev --region=europe-west4 --wait --args=--connection,<conn>,--object,$o; done
```
Expected: three times `Execution [ingest-backfill-…] has successfully completed.` `crm_email` and `inbox_thread` start at `cma.email_start_date_of` (`email.start_date`, empty in dev, so `intake.start_date`). A failed execution is run again with the same arguments: it continues where it stopped.

**Studio (cma-dev-pg)**
```sql
set role cma_owner;
select stream, status, counts, error, from_at from cma.sync_run where job = 'backfill' and stream in ('contact', 'crm_email', 'inbox_thread') order by started_at desc limit 3;
select country_source, count(*) from cma.crm_contact group by 1 order by 1;
reset role;
```
Expected: three `succeeded` rows; contacts by `country_source`: 1 for those whose Contact-Country names a market, 2 for a held contact whose Contact-Country is empty and whose `country_dropdown` is set (`United Kingdom` → `GB` through its alias, `Atlantis Test` as written), none without either.

## 6. The overlap test

**Data prerequisite:** a test mailbox you control, connected in `CMA dev` as a team email inbox (Browser: `CMA dev` → Inbox → Inbox settings → Channels → Connect a channel → Team email). Without it, inbox conversations stay empty in dev and the overlap cannot be measured; say so in your report.

1. **Browser:** from another mailbox of your own, send an email to the connected test mailbox with the subject `Overlap test <date>`.
2. **Browser:** in `CMA dev` → Inbox, open the conversation, assign it to yourself and reply; then close it.
3. Wait two minutes (two poll runs).

**Studio (cma-dev-pg)** (ids, kinds and times only)
```sql
set role cma_owner;
select source_kind, source_id, thread_source_id, direction, actor_kind, owner_ref is not null as has_owner, occurred_at
from cma.email_message where occurred_at > now() - interval '30 minutes' order by occurred_at;
select source_id, status, owner_ref is not null as has_owner, contact_source_id is not null as has_contact from cma.email_thread
where source_created_at > now() - interval '30 minutes';
select kind, actor_kind, to_actor_kind from cma.email_thread_event where occurred_at > now() - interval '30 minutes' order by occurred_at;
reset role;
```
Expected: an `inbox_message` `in` (customer), an `inbox_message` `out` (agent, with an owner), the thread closed with an owner, the events `assigned` and `closed`. Report: whether the reply (and the incoming email) also appear as `crm_email` rows; if so, whether their `thread_source_id` (the configured thread property) equals anything of the inbox thread's ids; and whether the thread closed without a new message showed in the first run after the close or only after the ten-minute open check. Those answers settle the Open decision on the overlap (README).

## 7. `verify:email-flow` against dev

It creates two throwaway tenants (`email-<run>-one`, `email-<run>-two`), polls a fake HubSpot on localhost into them, checks, and sets their connections inactive; their invented rows stay. It refuses a database without the dev seed.

**Terminal** (in `~/cma/ingest`, after `npm ci`; `cma_db dev` runs the proxy on 5433)
```bash
cma_db dev && cd ~/cma/ingest && CMA_DB_HOST=127.0.0.1 CMA_DB_PORT=5433 CMA_DB_NAME=cma CMA_DB_USER=$(gcloud config get-value account) CMA_DB_SET_ROLE=cma_app INGEST_FLOW_ADMIN_USER=$(gcloud config get-value account) node verify/email-flow.mjs | tail -3; cd ~/cma
```
Expected: `connected to cma as martin@pulse4all.com`, then the last checks and `ALL 32 PASS`. With `--provoke` at the end of the `node` command: `ALL 32 PROVOKED CHECKS FAILED, as they must`. A `FAIL` on F1 or F2 means the database's words logic differs from the ingest's on a shared fixture (its line names the case): send it to me.

## 8. Read-only counts

**Studio (cma-dev-pg)** (counts only)
```sql
set role cma_owner;
select source_kind, direction, actor_kind, count(*) from cma.email_message m join cma.tenant t on t.id = m.tenant_id
where t.slug = 'pulse4all-subscriptions' group by 1, 2, 3 order by 1, 2, 3;
select status, is_spam, is_archived, forgotten_at is not null as forgotten, count(*) from cma.email_thread e join cma.tenant t on t.id = e.tenant_id
where t.slug = 'pulse4all-subscriptions' group by 1, 2, 3, 4 order by 1, 2, 3, 4;
select kind, count(*) from cma.email_thread_event e join cma.tenant t on t.id = e.tenant_id where t.slug = 'pulse4all-subscriptions' group by 1 order by 1;
select (select count(*) from cma.connection_inbox) as inboxes, (select count(*) from cma.connection_inbox_channel) as channels,
       (select count(*) from cma.crm_contact where country_source > 1) as contacts_from_fallback;
select status, count(*) from cma.sync_run where job = 'email_poll' and started_at > now() - interval '1 hour' group by 1;
reset role;
```
Expected: counts per source kind, direction and actor kind (no `crm_email` row is added to an `inbox_message` row anywhere); threads by status; events by kind; the catalogs' sizes; runs of the last hour, all `succeeded` (about 60). Send me the outputs of steps 3a, 4, 5, 6 and 8 (ids, counts, dates and times only); records go in a separate pull request, written from your report.

## 9. Prod

`docs/ingest/PROD_RUNBOOK.md` phase 10, after steps 1 to 8 passed in dev.
