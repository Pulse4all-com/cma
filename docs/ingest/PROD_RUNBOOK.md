# Prod runbook: HubSpot into cma-ingest in prod

The prod phase for HubSpot (Pulse4all Subscriptions, the live portal `147946837`). It replaces step 3 of Phase 7 in `docs/night-2026-10-10/MORNING_RUNBOOK.md`; Aircall, Make and Shopify stay in that phase as they are. Order: the front and the service, the jobs, the connection, the app, the first events, the owners, the assignment rule, the backfill, day one. Every block says where it runs and ends with what you should see (the convention of `docs/night-2026-10-11/GO_LIVE_RUNBOOK.md`). SQL and shell never share a block.

Before you start:
- The gates of Phase 7 (the Yordi heads-up sent; NocoDB's visibility of the new views).
- The helpers of `MORNING_RUNBOOK.md` (Helpers: `put_secret`) defined in the Cloud Shell session that stores a secret.
- `~/cma` on a clean, current `main`, the same commit dev runs, so prod deploys the image dev tested (`no build`).
- The tenant is `pulse4all-subscriptions` (seed `db/02_seed_pulse4all.sql`).

**The Studio context block** (every Studio session below that calls a configuration function; prod uses you):

**Studio (cma-prod-pg)**
```sql
set role cma_owner;
select t.slug, t.id as tenant_id, u.id as user_id, u.email
from cma.tenant t join cma.app_user u on u.tenant_id = t.id
where t.slug = 'pulse4all-subscriptions' and u.email = 'martin@pulse4all.com';
reset role;
```
Then, with the two ids from that row:
```sql
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'studio:martin', false);
```
Expected: one row, then one row of three values. Every "after the context block" statement runs in that same tab; `reset role;` at the end.

---

## 7.1 The service and its public front

The two HubSpot secrets normally exist only after 7.4 (the client secret before the install, the token after it). Pass them anyway: for a secret that does not exist yet the script prints `secret … does not exist yet: create it (runbook put_secret), then rerun with --secret …` and carries on; 7.4 reruns this line.

**Terminal** (in `~/cma`, on main)
```bash
git switch -q main && git pull -q --ff-only && bash docs/ingest/deploy.sh prod --front ingest.pulse4all.app --tenant pulse4all-subscriptions --secret ingest-hubspot-subs-signing --secret ingest-hubspot-subs-token
```
Expected: the APIs, the service account `cma-ingest@p4a-cma-prod` and its database user (first time), `created ingest-hash-pepper-pulse4all-subscriptions (value generated, not shown)` the first time and `accessor on ingest-hash-pepper-pulse4all-subscriptions`, per HubSpot secret `accessor on …` or `does not exist yet`, `image … exists (sha256:…); no build`, the Cloud Run deploy, then the block with one Studio statement, `ingress: internal-and-cloud-load-balancing (front https://ingest.pulse4all.app: …)`, `public URLs (signed by HubSpot): https://ingest.pulse4all.app,https://cma-ingest-…run.app,…`, `health: no answer yet (…)` (the front does not exist yet) and `webhook address per connection: https://ingest.pulse4all.app/hubspot/<connection key>`.

**Studio (cma-prod-pg)**: paste the printed statement as is, once:
```sql
grant cma_app to "cma-ingest@p4a-cma-prod.iam";
```
Expected: `GRANT ROLE` (a notice that the role is already a member on a rerun).

**Terminal**
```bash
bash docs/ingest/front.sh prod --host ingest.pulse4all.app
```
Expected: `a. NEG cma-ingest-neg created`, `b. backend cma-ingest-backend created (EXTERNAL_MANAGED, HTTPS, logging off)` (the scheme is read from `cma-web-backend`), `b. cma-ingest-neg added to cma-ingest-backend`, `c. policy cma-ingest-armor created`, `c. rule 1000 (create): 600 requests per 60 s per IP, then 429`, `c. cma-ingest-armor attached to cma-ingest-backend`, `d. certificate cma-ingest-cert created for ingest.pulse4all.app`, `d. cma-web-proxy now holds cma-web-cert,cma-ingest-cert`, `e. path matcher cma-ingest added to cma-web-urlmap: ingest.pulse4all.app → cma-ingest-backend`, then the A record with the address of `cma-web-ip` (34.54.22.146), `certificate cma-ingest-cert: PROVISIONING …` and the two checks. On a rerun every line says `exists` or `holds`.

**Browser:** IONOS → pulse4all.app → DNS → Add record → type A, host `ingest`, points to the printed address. The `workspace` record and the mail records stay as they are.

Expected: the record listed next to `workspace`.

**Terminal** (repeat every ten minutes until `ACTIVE`; up to an hour after the record)
```bash
gcloud compute ssl-certificates describe cma-ingest-cert --project=p4a-cma-prod --global --format="value(managed.status,managed.domainStatus)"
```
Expected: `ACTIVE	ingest.pulse4all.app=ACTIVE` (before that `PROVISIONING` with `FAILED_NOT_VISIBLE` while the record propagates).

**Terminal**
```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://ingest.pulse4all.app/health
curl -sS -o /dev/null -w "%{http_code}\n" "$(gcloud run services describe cma-ingest --project=p4a-cma-prod --region=europe-west4 --format='value(status.url)')/health"
```
Expected: `200`, then `403` (the `run.app` address refused by the ingress setting). A `200` on the second line means the service was deployed without `--front`: rerun the first block.

## 7.2 The jobs

**Terminal** (same commit, so the image exists)
```bash
bash docs/ingest/deploy.sh prod --jobs
```
Expected: `image … exists (sha256:…); no build`, four `gcloud run jobs deploy` results, `schedule ingest-sweep: * * * * * (Europe/Amsterdam)`, `schedule ingest-poll-forms: * * * * * (Europe/Amsterdam)`, `schedule ingest-reconcile: 30 2 * * * (Europe/Amsterdam)`, the same Studio grant (already done in 7.1) and the backfill command. The first time it creates `cma-ingest-scheduler`.

**Terminal** (the four jobs, the three schedules, and who may start which job)
```bash
gcloud run jobs list --project=p4a-cma-prod --region=europe-west4 --format='value(metadata.name)'
gcloud scheduler jobs list --project=p4a-cma-prod --location=europe-west4 --format='table(name.basename(),schedule,timeZone,state)'
for j in ingest-sweep ingest-poll-forms ingest-reconcile ingest-backfill; do echo "$j: $(gcloud run jobs get-iam-policy "$j" --project=p4a-cma-prod --region=europe-west4 --flatten='bindings[].members' --filter='bindings.role:roles/run.invoker' --format='value(bindings.members)' | paste -sd' ')"; done
gcloud projects get-iam-policy p4a-cma-prod --flatten='bindings[].members' --filter='bindings.members:cma-ingest-scheduler@' --format='value(bindings.role)'
```
Expected: `ingest-backfill`, `ingest-poll-forms`, `ingest-reconcile`, `ingest-sweep`; three schedules (`* * * * *`, `* * * * *`, `30 2 * * *`, `Europe/Amsterdam`, `ENABLED`); `serviceAccount:cma-ingest-scheduler@p4a-cma-prod.iam.gserviceaccount.com` after the three scheduled jobs and nothing after `ingest-backfill:`; the last command prints nothing (no project role for the scheduler account). Until 7.3 the jobs find no connection and exit 0.

## 7.3 Configuration and the connection

**Studio (cma-prod-pg)** after the context block: the first block of `MORNING_RUNBOOK.md` 1.4 unchanged (twelve `cma.upsert_market`, the 26 aliases, the office hours, the language skill keys), then its second block per language (the market-to-skill links with the keys from the last result and the minimum level the team wants). Every statement is an upsert, so a rerun on a prod that already has them changes nothing.

Expected: as in 1.4: twelve empty results, 26 rows of `set_market_alias`, five of `set_business_hours`, the tenant's language skill keys; then one row per updated market per language.

**Studio (cma-prod-pg)** after the context block (the live portal):
```sql
select * from cma.upsert_connection('hubspot', 'HubSpot Subscriptions', '147946837',
                                    'ingest-hubspot-subs-signing', 'ingest-hubspot-subs-token');
```
Expected: one row with `connection_id` and `key`. Keep both in the tab: the key goes into the webhook URL (an identifier, not a secret: the signature is the proof), the id is `<conn>` below.

**Studio (cma-prod-pg)** (same tab):
```sql
select cma.set_connection_settings('<conn>', '{"app_host":"app-eu1.hubspot.com"}'::jsonb);
select cma.set_connection_field('<conn>', 'contact', 'country',  '', 'contact_country');
select cma.set_connection_field('<conn>', 'contact', 'language', '', 'contact_language');
select cma.set_connection_field('<conn>', 'contact', 'currency', '', 'contact_currency');
select cma.set_connection_field('<conn>', 'contact', 'store',    '', 'contact_shopify_store');
select cma.set_connection_field('<conn>', 'contact', 'ref', 'shopify', 'contact_shopify_id_1', 1::smallint);
select cma.set_connection_field('<conn>', 'contact', 'ref', 'shopify', 'contact_shopify_id_2', 2::smallint);
select cma.set_connection_field('<conn>', 'contact', 'ref', 'netsuite', 'contact_netsuite_id');
select cma.set_connection_field('<conn>', 'deal',   'market',         '', 'deal_country');
select cma.set_connection_field('<conn>', 'deal',   'amount',         '', 'amount');
select cma.set_connection_field('<conn>', 'deal',   'currency',       '', 'deal_currency_code');
select cma.set_connection_field('<conn>', 'deal',   'source_channel', '', 'hs_analytics_source');
select cma.set_connection_field('<conn>', 'ticket', 'category',       '', 'hs_ticket_category');
select cma.connection_config('<conn>');
reset role;
```
Expected: empty results, then the connection's configuration as JSON with the account `147946837`, `app_host` `app-eu1.hubspot.com` and twelve fields. That JSON is the proof for the records.

## 7.4 The prod app: render, upload, install, secrets

The click paths of `hubspot/README.md` (Render, upload, install) and `VENDOR_SETUP.md` §1.2 and §1.3, as corrected on 11 October 2026. The HubSpot CLI and its login (a personal access key of the live portal) are the ones of `MORNING_RUNBOOK.md` 2.3; in a new Cloud Shell the `PATH` line in `~/.bashrc` is enough.

**Terminal** (in `~/cma`; `<key>` from 7.3)
```bash
node hubspot/render.mjs prod --target-url "https://ingest.pulse4all.app/hubspot/<key>" && cd hubspot/build/prod && hs project upload && cd ~/cma
```
Expected: `rendered prod: hubspot/build/prod`; the upload names the live portal (`147946837`) and ends with a successful build and deploy of project **CMA ingest prod** with both components (the app and the webhooks). If the upload names a test account, answer `n`.

**Browser:** live portal → Development → Projects → CMA ingest prod → the app → **Auth** tab: copy the client secret. Then type this line on its own, not inside a pasted block:

**Terminal**
```bash
put_secret p4a-cma-prod ingest-hubspot-subs-signing
```
Expected: the hidden prompt; paste, Enter; `stored ingest-hubspot-subs-signing (version added)`.

**Browser:** the app → Distribution → **Standard install** → install into the live portal `147946837` itself (not a test install) → review the scopes on the consent screen (the read scopes, ticket read among them and no ticket write, and write on contacts) → install.

Expected: the install listed under Standard install. Webhooks start now: every deal, ticket, call and listed contact change in the live portal is delivered to `https://ingest.pulse4all.app/hubspot/<key>`, and until the token exists the read-backs finish `failed` with `token_unavailable` (the sweep reads them again after the token is in).

**Browser:** the app → **Distribution** tab → the install's row → **Show**: copy the static access token. Then on its own line:

**Terminal**
```bash
put_secret p4a-cma-prod ingest-hubspot-subs-token
```
Expected: `stored ingest-hubspot-subs-token (version added)`.

**Terminal** (the token checked without showing it)
```bash
gcloud secrets versions access latest --secret=ingest-hubspot-subs-token --project=p4a-cma-prod | sed 's/^/Authorization: Bearer /' \
  | curl -s -H @- https://api.hubapi.com/account-info/v3/details | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("portalId"), d.get("accountType"), d.get("dataHostingLocation"))'
```
Expected: `147946837`, the live portal's account type and `eu1`. A test account's id or `DEVELOPER_TEST` means the wrong install's token.

**Terminal** (the accessor grants, when the secrets were created after 7.1; always with `--front`, or the ingress goes back to `all`)
```bash
bash docs/ingest/deploy.sh prod --front ingest.pulse4all.app --tenant pulse4all-subscriptions --secret ingest-hubspot-subs-signing --secret ingest-hubspot-subs-token
```
Expected: `accessor on ingest-hubspot-subs-signing`, `accessor on ingest-hubspot-subs-token`, a new revision, `health: {"ok":true,"version":"<short sha>"}` through the host.

## 7.5 The first events

**Browser:** live portal → Contacts → Create contact: a clearly named test contact (first name `CMA`, last name `Test`, an `@example.com` email, Contact-Country `United Kingdom`). Then on it: Create deal, named `CMA test deal (delete)`, in a test pipeline if the portal has one, else any pipeline, with the deal's country set to the United Kingdom as the portal spells it. Note the deal id from the address bar (the digits after `/record/0-3/`).

**Terminal**
```bash
gcloud run services logs read cma-ingest --project=p4a-cma-prod --region=europe-west4 --limit=30 | grep -E "webhook|authentication" | tail -10
```
Expected: `webhook` lines with `new` above 0; no `authentication failed` (a 401 means the signing secret is not this app's client secret).

**Studio (cma-prod-pg)**
```sql
set role cma_owner;
select object_type, kind, status, error, count(*) from cma.ingest_event
where recorded_at > now() - interval '1 hour' group by 1, 2, 3, 4 order by 1, 2;
select r.record_type, r.source_id, r.pipeline_id, r.stage_id, r.owner_ref, r.contact_source_id,
       r.raw ->> 'deal_country' as deal_country_raw, r.market as market_stored,
       (cma.record_market_of(r.tenant_id, r.connection_id, r.market, r.contact_source_id)).*
from cma.crm_record r where r.record_type = 'deal' and r.source_id = '<deal id>';
reset role;
```
Expected: events `processed` (deal created, contact and association events; `ignored` for objects the CMA does not keep); one deal row with its pipeline and stage, the contact's id, `deal_country_raw` as the portal spells it, `code` `GB` and `source` `record` (the market from `deal_country` through the aliases; an NL test gives `NL`).

If `code` is not `GB` for a GB deal (`source` `contact` with the contact's country, or `unknown`), the portal's spelling is not an alias yet. Add it with the exact text of `deal_country_raw`:

**Studio (cma-prod-pg)** after the context block
```sql
select cma.set_market_alias('<spelling seen in deal_country_raw>', 'GB');
reset role;
```
Expected: an empty result. Rerun the query above: `code` `GB`, `source` `record`. `market_stored` keeps the old spelling until the deal's next read; the reports resolve the alias when they read, so nothing else needs to change.

**Studio (cma-prod-pg)** after the context block (speed to lead for today)
```sql
select deal_source_id, market, market_source, status, first_call_at, business_seconds
from cma.speed_to_lead_rows(current_date, current_date) where deal_source_id = '<deal id>';
reset role;
```
Expected: one row with market `GB`, `market_source` `record`, no call yet. Log an outbound call on the test contact (outcome Connected) and rerun: `first_call_at` filled.

**Browser:** delete the test deal and the test contact in the live portal. Expected: the deletion events `processed` and the rows' `source_deleted_at` set.

### 7.5b Pipelines, forms and call outcomes (carried over from Phase 7 step 3)

The first read-back loaded the pipeline and call outcome catalogs; the forms poll loads the form catalog within the hour.

**Studio (cma-prod-pg)** after the context block
```sql
select record_type, source_pipeline_id, label, is_counted, is_routed from cma.connection_pipeline where connection_id = '<conn>' order by 1, 3;
select outcome_ref, label, is_connected from cma.connection_call_outcome where connection_id = '<conn>' order by 2;
select source_form_id, name, is_counted, lead_source, market from cma.connection_form where connection_id = '<conn>' order by 2;
```
Then per pipeline, form and outcome (the values from those lists; the call outcomes as decided on 11 October 2026: Connected and Meeting booked count, Left live message, Left voicemail, Busy, No answer and Wrong number do not):
```sql
select cma.set_connection_pipeline('<conn>', 'deal', '<test pipeline id>', false, false, null);
select cma.set_pipeline_lead('<conn>', 'deal', '<lead pipeline id>', true);
select cma.set_form('<conn>', '<form guid>', true, '<lead source>', '<market code>', '{}'::text[]);
select cma.set_call_outcome('<conn>', '<outcome guid>', true);
reset role;
```
Expected: the three lists, then an empty result per statement.

## 7.6 People: HubSpot owners on CMA persons

**Terminal** (in `~/cma`; the token is read with your own login and never printed)
```bash
node docs/ingest/hubspot-owners.mjs --project p4a-cma-prod --token-secret ingest-hubspot-subs-token
```
Expected: one `select cma.set_user_external_id(u.id, 'hubspot_owner', '<owner id>') from cma.app_user u where u.email = '<owner email>';` per active owner, then `-- n statement(s) for m active owner(s)` on stderr. The output stays in the terminal.

**Studio (cma-prod-pg)** after the context block (you hold `users.manage_all`): paste the printed lines, then:
```sql
reset role;
```
Expected: one row per owner who is a CMA person; an owner without one matches no row (`GO_LIVE_RUNBOOK.md` 3b).

## 7.7 The assignment rule and the record links

Now that `cma-ingest` runs in prod, the parts of `GO_LIVE_RUNBOOK.md` step 2 that waited for it.

**Studio (cma-prod-pg)** after the context block (what exists already; step 2 may have written the rules on 12 October)
```sql
select name, trigger, record_type, urgency, enabled from cma.message_rule order by name;
```
Expected: `New deal` (`record_created`, `normal`) if step 2 ran; `Assigned deal` if its rule was written then too.

**Studio (cma-prod-pg)** (same tab; an upsert, so a rerun keeps one rule)
```sql
select cma.upsert_assignment_rule('Assigned deal', 'deal', '{}'::text[], 'urgent', null);
select c.id, c.name, c.settings from cma.integration_connection c where c.adapter = 'hubspot';
```
Expected: one uuid (urgent: the agent hears the chime and gets the pop-up), then the live connection with `{"app_host": "app-eu1.hubspot.com"}`.

**Studio (cma-prod-pg)** (same tab; `set_connection_settings` replaces all settings, so repeat every key the row already has)
```sql
select cma.set_connection_settings('<conn>', '{"app_host":"app-eu1.hubspot.com","record_url_deal":"https://{app_host}/contacts/{account}/record/0-3/{id}","record_url_ticket":"https://{app_host}/contacts/{account}/record/0-5/{id}"}'::jsonb);
reset role;
```
Expected: an empty result.

Optional: an automation connection for Make as in `GO_LIVE_RUNBOOK.md` 2b, with `<ingest host>` = `ingest.pulse4all.app`.

## 7.8 Backfill from 1 October

One object type at a time; the next only after the count of the previous. `<conn>` from 7.3 (or `select connection_id, adapter, name from cma.connections_all();` in Studio after the context block).

**Terminal**
```bash
gcloud run jobs execute ingest-backfill --project=p4a-cma-prod --region=europe-west4 --wait --args=--connection,<conn>,--object,deal,--from,2026-10-01
```
Expected: `Execution [ingest-backfill-…] has successfully completed.` A failed execution is run again with the same arguments: it continues where it stopped.

**Studio (cma-prod-pg)**
```sql
set role cma_owner;
select record_type, count(*), min(source_created_at), max(source_created_at) from cma.crm_record where connection_id = '<conn>' group by 1;
select job, stream, status, counts, error, started_at, finished_at from cma.sync_run where connection_id = '<conn>' and job = 'backfill' order by started_at desc limit 5;
reset role;
```
Expected: deals from 1 October onward; one `backfill` row `succeeded` for stream `deal`.

Then the same execution with `ticket` (count: the `ticket` row of the first query), `crm_call` and `form_submission`, with these counts:

**Studio (cma-prod-pg)**
```sql
set role cma_owner;
select count(*), min(occurred_at), max(occurred_at) from cma.crm_call where connection_id = '<conn>';
select count(*), min(submitted_at), max(submitted_at) from cma.form_submission where connection_id = '<conn>';
reset role;
```
Expected: calls and submissions from 1 October onward (submissions of counted forms only, so 7.5b first), and a `backfill` row `succeeded` per stream.

## 7.9 Day one

- **The first real new deal** with an owner who is a CMA person: that person gets the urgent "New deal assigned to you" pop-up with the record link. **Studio (cma-prod-pg)**, as `cma_owner`: `select title, ref_id, created_at from cma_read.message order by created_at desc limit 5;`
- **Browser:** live portal → Development → Projects → CMA ingest prod → the app → its monitoring page for webhooks: the delivery count rises and failures stay at zero.
- **Terminal**, the status codes of the public endpoint over the last day (the request log of Decision log 12 October 2026):
```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="cma-ingest" AND httpRequest.status>0' --project=p4a-cma-prod --freshness=1d --format='value(httpRequest.status)' | sort | uniq -c
```
Expected: mostly `200`; a few `401` or `404` are strangers; many `429` would come from Cloud Armor (then the rate-limit Open decision); `500` points at the database or a secret.
- **Records:** the outputs of 7.1 to 7.8 (the checks, the counts, `cma.connection_config`) into `records/intake-prod-<date>/`, committed as a records PR afterwards.
