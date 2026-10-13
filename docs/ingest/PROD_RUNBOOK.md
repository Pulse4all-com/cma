# Prod runbook: HubSpot, Aircall and Shopify into cma-ingest in prod

The prod phase for HubSpot (Pulse4all Subscriptions, the live portal `147946837`), then Aircall (phase 8) and Shopify (phase 9). Sections 7.1 to 7.9 replace step 3 of Phase 7 in `docs/night-2026-10-10/MORNING_RUNBOOK.md` (12 October 2026); phases 8 and 9 replace its steps 4 (the Aircall half), 5, 6 and 7 (13 October 2026). Order for HubSpot: the front and the service, the jobs, the connection, the app, the first events, the owners, the assignment rule, the backfill, day one. Every block says where it runs and ends with what you should see (the convention of `docs/night-2026-10-11/GO_LIVE_RUNBOOK.md`). SQL and shell never share a block.

Before you start:
- The gates of Phase 7 (the Yordi heads-up sent; NocoDB's visibility of the new views).
- Every command below runs from `~/cma`. Every new Cloud Shell session (a reconnect starts one) needs `put_secret` defined again before a secret is stored; it is the function of `MORNING_RUNBOOK.md` (Helpers), unchanged:

**Terminal** (paste once per Cloud Shell session)
```bash
cd ~/cma
put_secret () {  # usage: put_secret <project> <name>   → hidden prompt, never echoed, never in history
  gcloud secrets describe "$2" --project="$1" >/dev/null 2>&1 || \
    gcloud secrets create "$2" --project="$1" --replication-policy=user-managed --locations=europe-west4 >/dev/null
  read -rsp "Paste value for $2 (hidden), then Enter: " v; echo
  printf %s "$v" | gcloud secrets versions add "$2" --project="$1" --data-file=- >/dev/null && echo "stored $2 (version added)"; unset v
}
```
Expected: no output. `type put_secret` prints the function.
- `~/cma` on a clean, current `main`. `deploy.sh` tags the image with the last commit that touched `ingest/` (`git log -1 --format=%h -- ingest/`), not HEAD, so a `main` that moved on with docs or README only deploys the image dev tested (`no build`); when the two differ the script prints `image tag <sha>: the last commit under ingest/; HEAD is <sha>`.
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
Expected: `== cma-ingest <sha> → p4a-cma-prod` with the image tag (and the `image tag … HEAD is …` line when `main` moved on outside `ingest/`), the APIs, the service account `cma-ingest@p4a-cma-prod` and its database user (first time), `created ingest-hash-pepper-pulse4all-subscriptions (value generated, not shown)` the first time and `accessor on ingest-hash-pepper-pulse4all-subscriptions`, per HubSpot secret `accessor on …` or `does not exist yet`, `image … exists (sha256:…); no build`, the Cloud Run deploy, then the block with one Studio statement, `ingress: internal-and-cloud-load-balancing (front https://ingest.pulse4all.app: …)`, `public URLs (signed by HubSpot): https://ingest.pulse4all.app,https://cma-ingest-…run.app,…`, `health: no answer yet (…)` (the front does not exist yet) and `webhook address per connection: https://ingest.pulse4all.app/hubspot/<connection key>`.

**Studio (cma-prod-pg)**: paste the printed statement as is, once:
```sql
grant cma_app to "cma-ingest@p4a-cma-prod.iam";
```
Expected: `GRANT ROLE` (a notice that the role is already a member on a rerun).

**Terminal**
```bash
bash docs/ingest/front.sh prod --host ingest.pulse4all.app
```
Expected: `a. NEG cma-ingest-neg created`, `b. backend cma-ingest-backend created (EXTERNAL_MANAGED, logging off)` (the scheme is read from `cma-web-backend`; no `--protocol`, so gcloud sets HTTP with port name `http`, which the serverless NEG accepts: with `--protocol=HTTPS` the next step was refused on 12 October with "Port name is not supported for a backend service with Serverless network endpoint groups"), `b. cma-ingest-neg added to cma-ingest-backend`, `c. policy cma-ingest-armor created`, `c. rule 1000 (create): 600 requests per 60 s per IP, then 429`, `c. cma-ingest-armor attached to cma-ingest-backend`, `d. certificate cma-ingest-cert created for ingest.pulse4all.app`, `d. cma-web-proxy now holds cma-web-cert,cma-ingest-cert`, `e. path matcher cma-ingest added to cma-web-urlmap: ingest.pulse4all.app → cma-ingest-backend`, then the A record with the address of `cma-web-ip` (34.54.22.146), `certificate cma-ingest-cert: PROVISIONING …` and the two checks. On a rerun every line says `exists` or `holds`.

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
Expected: `200`, then `404` (the `run.app` address refused by the ingress setting; seen in prod on 12 October, `deploy.sh` prints `run.app: 404 (refused)`). A `200` on the second line means the service was deployed without `--front` (`deploy.sh` prints a `FAIL run.app: 200` line): rerun the first block.

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

**Studio (cma-prod-pg)** after the context block: the first block of `MORNING_RUNBOOK.md` 1.4 unchanged (twelve `cma.upsert_market`, the 26 aliases, the office hours, the language skill keys). Every statement is an upsert, so a rerun on a prod that already has them changes nothing.

Expected: as in 1.4: twelve empty results, 26 rows of `set_market_alias`, five of `set_business_hours`, the tenant's language skill keys.

The language skill keys of the Pulse4all seed equal the language codes (`en`, `nl`, …), so the market-to-skill links are one statement instead of 1.4's block per language (minimum level 3, Fluent):

**Studio (cma-prod-pg)** (same tab)
```sql
select cma.upsert_market(code, name, time_zone, language_code, currency, language_code, 3::smallint, sort_order)
from cma.market where language_code in (select key from cma.skill where dimension = 'language');
reset role;
```
Expected: one row per market whose language has a skill. A market whose language has no skill keeps no link: market ES (Spain, Europe/Madrid, EUR), added in prod on 12 October because the live portal has ES forms, has none until a Spanish skill exists (Open decisions).

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
node hubspot/render.mjs prod --target-url "https://ingest.pulse4all.app/hubspot/<key>" && cd hubspot/build/prod && hs project upload --force && cd ~/cma
```
Expected: `rendered prod: hubspot/build/prod`; the upload names the live portal (`147946837`) and ends with a successful build and deploy of project **CMA ingest prod** with both components (the app and the webhooks). On the first upload the project does not exist yet: `--force` creates it without the prompt (`--forceCreate` is deprecated). If the upload names a test account, stop it (Ctrl+C) and switch the CLI's account first.

**Browser:** live portal → Development → Projects → CMA ingest prod → the app → **Auth** tab: copy the client secret. Then type this line on its own, not inside a pasted block:

**Terminal**
```bash
put_secret p4a-cma-prod ingest-hubspot-subs-signing
```
Expected: the hidden prompt; paste, Enter; `stored ingest-hubspot-subs-signing (version added)`.

**Browser:** the app → Distribution → **Standard install** → install into the live portal `147946837` itself (not a test install) → review the scopes on the consent screen (the read scopes, ticket read among them and no ticket write, and write on contacts) → install.

Expected: the install listed under Standard install. Webhooks start now: every deal, ticket, call and listed contact change in the live portal is delivered to `https://ingest.pulse4all.app/hubspot/<key>`, and until the token exists the read-backs finish `failed` with `token_unavailable` (the sweep reads them again after the token is in).

**Browser:** the app → **Distribution** tab → the Standard install's row → **Show**: copy the static access token (it is on the install row, not on the Auth tab). Then on its own line:

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

In the live portal on 12 October `deal_country` was filled: `United Kingdom` resolved to `GB` with `source` `record`, so no alias was needed.

**Browser:** delete the test deal and the test contact in the live portal. Expected: within seconds the deletion events (`deal` `deleted`, `processed`) and the rows' `source_deleted_at` set.

### 7.5b Pipelines, forms and call outcomes (carried over from Phase 7 step 3)

The first read-back loaded the pipeline and call outcome catalogs; the forms poll loads the form catalog within the hour. A form is counted by default, so set the form rule below before the forms poll has run for long: until then every form's submissions, cancellations included, are read as leads.

**Studio (cma-prod-pg)** after the context block
```sql
select record_type, source_pipeline_id, label, is_counted, is_routed from cma.connection_pipeline where connection_id = '<conn>' order by 1, 3;
select outcome_ref, label, is_connected from cma.connection_call_outcome where connection_id = '<conn>' order by 2;
select source_form_id, name, is_counted, lead_source, market from cma.connection_form where connection_id = '<conn>' order by 2;
```
Then per pipeline (the values from the first list):
```sql
select cma.set_connection_pipeline('<conn>', 'deal', '<test pipeline id>', false, false, null);
select cma.set_pipeline_lead('<conn>', 'deal', '<lead pipeline id>', true);
```
Expected: an empty result per statement.

**The call outcome rule** (Martin, 12 October 2026; Decision log): an outcome is connected unless its label matches not reached, voicemail, no answer, busy, wrong number, incorrect data or email only; `Left live message` is not connected either (the customer was not reached), `Do Not Call Or Email` is (they were). One statement over the catalog:

**Studio (cma-prod-pg)** (same tab)
```sql
select o.label, cma.set_call_outcome(o.connection_id, o.outcome_ref,
         o.label !~* '(not reached|voicemail|no answer|busy|wrong number|incorrect data|email only|left live message)')
from cma.connection_call_outcome o where o.connection_id = '<conn>' order by o.label;
select label, is_connected from cma.connection_call_outcome where connection_id = '<conn>' order by is_connected desc, label;
```
Expected: one row per outcome, then the list with `is_connected` as the rule says.

**The form rule** (Martin, 12 October 2026; Decision log): a form is counted when its name matches quote, contact or info and not cancellation, replacement or support; its `lead_source` is `quote`, `contact` or `info`, whichever of the three comes first in the name; its market is the name's two-letter prefix, `UK` read as `GB`, when that is a market of the tenant. `set_form` replaces `kept_fields`, so the statement passes the form's current ones:

**Studio (cma-prod-pg)** (same tab)
```sql
select f.name, cma.set_form(f.connection_id, f.source_form_id, x.counted,
         case when x.counted then substring(lower(f.name) from '(quote|contact|info)') end,
         (select m.code from cma.market m where m.code = x.prefix), f.kept_fields)
from cma.connection_form f
cross join lateral (select f.name ~* '(quote|contact|info)' and f.name !~* '(cancellation|replacement|support)' as counted,
                           case upper(substring(f.name from '^\s*([A-Za-z]{2})\M')) when 'UK' then 'GB'
                                else upper(substring(f.name from '^\s*([A-Za-z]{2})\M')) end as prefix) x
where f.connection_id = '<conn>' order by f.name;
select name, is_counted, lead_source, market from cma.connection_form where connection_id = '<conn>' order by is_counted desc, name;
reset role;
```
Expected: one row per form, then the list: the Quote, Contact and Info forms counted with their lead source and market, the cancellation, replacement and support forms not counted. A counted form without a market (a prefix that is no market, ES before the market existed) reads its market from the contact; add the market and rerun.

## 7.6 People: HubSpot owners on CMA persons

**Terminal** (in `~/cma`; the token is read with your own login and never printed)
```bash
node docs/ingest/hubspot-owners.mjs --project p4a-cma-prod --token-secret ingest-hubspot-subs-token --also-domain newcogroup.com=pulse4all.com
```
Expected: one `select cma.set_user_external_id(…)` per active owner, then `-- n statement(s) for m active owner(s)` on stderr; a `@newcogroup.com` owner's line matches `u.email in ('<local>@newcogroup.com', '<local>@pulse4all.com')` (Newco agents sign in to the CMA as `@pulse4all.com`). The output stays in the terminal. An agent whose local part differs between the two addresses is mapped by hand (`GO_LIVE_RUNBOOK.md` 3b gives the line).

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

One object type at a time; the next only after the count of the previous. `<conn>` from 7.3 (or `select connection_id, adapter, name from cma.connections_all();` in Studio after the context block). The backfill selects by last modification since `--from`, so records created before 1 October but touched since then come along: the earliest `source_created_at` below can lie before 1 October. The reports count a record by its `source_created_at`, so such a record counts on the day it was created, not on the day of the backfill.

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
Expected: deals modified since 1 October (the earliest created before it); one `backfill` row `succeeded` for stream `deal`.

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

---

# Phase 8. Aircall in prod

Written on 13 October 2026 from `VENDOR_SETUP.md` §2 (`docs/night-2026-10-10/`), step 5 of Phase 7 in `docs/night-2026-10-10/MORNING_RUNBOOK.md` and what 12 October taught for HubSpot. The Aircall click paths of VENDOR_SETUP were written from Aircall's documentation and have not been walked through in Pulse4all's Aircall account; a step that depends on one says so. The connection's lines, tags and kind are set on **Configuration → Sources** (addition 0008e), each agent's Aircall user id on **Team → People → Linked accounts**; the SQL next to them is the fallback.

**The gate.** The Aircall adapter (brief B9, `Pulse4all-com/cma#111`) brings `ingest/src/adapters/aircall/`, the scripts this phase calls (`docs/ingest/aircall-webhook.mjs`, `docs/ingest/aircall-users.mjs`) and the backfill object `telephony_call`; how they work is `docs/ingest/README.md`, section Aircall. B9 is on `main` once that pull request is merged. Until it is merged and its image deployed (the service in 8.4 and the jobs with `deploy.sh prod --jobs`), run 8.1 and 8.2 only (they touch nothing the CMA reads) and stop there.

**Terminal** (in `~/cma`, on a current `main`)
```bash
git switch -q main && git pull -q --ff-only && ls ingest/src/adapters docs/ingest/aircall-webhook.mjs docs/ingest/aircall-users.mjs
```
Expected after B9: `aircall automation hubspot` and the two script paths. `No such file or directory` for a script means B9 is not merged: 8.1 and 8.2 only.

Also before 8.3: addition 0008e run in prod (`docs/night-2026-10-13/MORNING_RUNBOOK.md`), so the Sources page and the Linked accounts exist; the HubSpot phase done (7.1 to 7.8), because speed to lead pairs Aircall calls with the HubSpot call engagements the Aircall–HubSpot integration logs.

**Data prerequisites** (Aircall side; the counts mean nothing without them):
- Tagging on for every line, and agents tagging every call. The CMA counts tags as Aircall reports them; an untagged line counts as untagged calls, not as a gap.
- Every agent who calls has their own Aircall user (a shared user cannot be linked to one person).
- Each line's market known (the line's country is not read as its market; you set it in 8.6).
- The Aircall–HubSpot integration on and logging every call on the contact (`VENDOR_SETUP.md` §2, last paragraph). It is not changed by this phase.
- The Open decision "Aircall tags as a refinement of connected" stays open: this phase counts tags as tags, not as outcomes.

## 8.1 The plan check

**Browser:** Aircall Dashboard → **Integrations & API** → **API Keys** (`VENDOR_SETUP.md` §2.1; not walked through).

Expected: the API Keys page with a button to generate a key. If the menu is missing, the plan has no API access: stop phase 8 and write down the plan's name (Open decisions).

## 8.2 The API key into Secret Manager

**Browser:** API Keys → **Generate an API key**, description `CMA ingest (prod)`. Aircall shows the API ID and the API token once. Keep the page open until the next step is done.

**Terminal** (type it on its own line; the value is one line of JSON, `{"api_id":"<API ID>","api_token":"<API token>"}`)
```bash
put_secret p4a-cma-prod ingest-aircall-subs-token
```
Expected: the hidden prompt; paste, Enter; `stored ingest-aircall-subs-token (version added)`. Then close the Aircall page.

**Terminal** (the key checked without showing it; Aircall's API takes the pair as basic authentication)
```bash
gcloud secrets versions access latest --secret=ingest-aircall-subs-token --project=p4a-cma-prod \
  | python3 -c 'import json,sys,base64; d=json.load(sys.stdin); print("Authorization: Basic " + base64.b64encode((d["api_id"]+":"+d["api_token"]).encode()).decode())' \
  | curl -s -o /dev/null -w "%{http_code}\n" -H @- https://api.aircall.io/v1/company
```
Expected: `200`. `401` means the pair is wrong or pasted with spaces; a Python error means the value is not the JSON line: run `put_secret` again (it adds a version).

Done on 13 October 2026: `ingest-aircall-subs-token` version 1 exists in `p4a-cma-prod` and `GET /v1/ping` answered `200` with it (Martin). Rerun 8.2 only to rotate the key.

## 8.3 The connection

**The account id is the company's name: `Pulse4all`.** `upsert_connection` takes the account the connection pins (the live portal's `147946837` for HubSpot). An Aircall event names no company and `GET /v1/company` exposes no company id: on 13 October 2026 Pulse4all's account answered `company.name` `Pulse4all` and `company.id` null. So the account id is the company's `name` exactly as `GET /v1/company` gives it (`docs/ingest/README.md`, section Aircall): `aircall-webhook.mjs` (8.4) refuses to run when the API key answers for another name, and the reconcile and the backfill check it before they list anything. To see the name yourself:

**Terminal** (the key read without showing it)
```bash
gcloud secrets versions access latest --secret=ingest-aircall-subs-token --project=p4a-cma-prod \
  | python3 -c 'import json,sys,base64; d=json.load(sys.stdin); print("Authorization: Basic " + base64.b64encode((d["api_id"]+":"+d["api_token"]).encode()).decode())' \
  | curl -s -H @- https://api.aircall.io/v1/company
```
Expected: `{"company":{"name":"Pulse4all",…,"id":null,…}}` (with the user and line counts).

**Studio (cma-prod-pg)** after the context block
```sql
select * from cma.upsert_connection('aircall', 'Aircall Subscriptions', 'Pulse4all',
                                    'ingest-aircall-subs-signing', 'ingest-aircall-subs-token');
```
Expected: one row with `connection_id` and `key`. Keep both in the tab: the key goes into the webhook address, the id is `<aircall conn>` below.

**Studio (cma-prod-pg)** (same tab; the kind decides the Sources page's sections and that People offers an Aircall user id)
```sql
select cma.set_connection_kind('<aircall conn>', 'telephony');
select name, adapter, external_account_id, kind, status, signing_secret_name, token_secret_name
from cma.sources() where connection_id = '<aircall conn>';
reset role;
```
Expected: an empty result, then one row: `Aircall Subscriptions`, `aircall`, `Pulse4all`, `telephony`, `active`, `ingest-aircall-subs-signing`, `ingest-aircall-subs-token`.

**Browser:** `https://workspace.pulse4all.app/configuration/sources` → **Aircall Subscriptions**.

Expected: the connection with kind Telephony, the two secret names (names only), and the Lines and Tags sections, both empty (`No tags received yet`). The kind can also be set here (Choose the kind → Telephony → Set kind) instead of the Studio statement; the page never creates a connection, because a connection names its secrets.

## 8.4 The webhook and the service's access to it

The webhook's token is the signing secret: Aircall puts it in every event, and only the API response that creates the webhook shows it (`VENDOR_SETUP.md` §2.3), which is why the script creates the webhook and stores the token. The secret is created empty first, so the service can read it from the first event on.

**Terminal**
```bash
gcloud secrets create ingest-aircall-subs-signing --project=p4a-cma-prod --replication-policy=user-managed --locations=europe-west4
```
Expected: `Created secret [ingest-aircall-subs-signing].` (on a rerun: `already exists`, which is fine).

**Terminal** (the accessor grants; always with `--front`, or the ingress goes back to `all`)
```bash
bash docs/ingest/deploy.sh prod --front ingest.pulse4all.app --tenant pulse4all-subscriptions --secret ingest-aircall-subs-token --secret ingest-aircall-subs-signing
```
Expected: `accessor on ingest-aircall-subs-token`, `accessor on ingest-aircall-subs-signing`, `image … exists (sha256:…); no build` when B9's image was deployed already (else the build), a new revision, `health: {"ok":true,"version":"<short sha>"}` through the host, and `webhook address per connection: https://ingest.pulse4all.app/<adapter>/<connection key>`.

**Terminal** (`<key>` from 8.3)
```bash
node docs/ingest/aircall-webhook.mjs --project p4a-cma-prod --url "https://ingest.pulse4all.app/aircall/<key>" --api-secret ingest-aircall-subs-token --token-secret ingest-aircall-subs-signing --account Pulse4all
```
Expected: `webhook <webhook id>` and `events  call.created, call.answered, call.ended, call.tagged, call.untagged, call.archived`, then on stderr `-- token stored as a new version of ingest-aircall-subs-signing (not shown). Next: the connection setting webhook_id = <webhook id> …`. The token is never printed. Keep the webhook id for the next step.

The script refuses, and creates nothing, when:
- `--account` is not the name the key answers for: `refused: the API key in ingest-aircall-subs-token belongs to the Aircall company "<name>", not "Pulse4all"` (check 8.2 and 8.3);
- `ingest-aircall-subs-signing` does not exist yet: `refused: the secret … does not exist yet` (the first block of this step);
- a webhook for this URL exists already: it prints that webhook (`<id>  active true  events …  <url>`) and `refused: a webhook for this URL exists already`, so a second run never makes a second webhook (both would deliver every event). To start again on purpose: `--delete <id>`, then run it again. `--list` shows every webhook of the company (ids, active, events, URLs; never a token).

If it prints `the webhook <id> exists, but its token could not be stored`, run it with `--delete <id>` and then again.

**Browser:** `https://workspace.pulse4all.app/configuration/sources` → **Aircall Subscriptions** → **Settings** → Add setting: key `webhook_id`, value the webhook id from the script → Save settings.

Expected: the setting listed after a reload. The nightly reconcile (02:30) checks this webhook: its `reconcile` run for stream `telephony_call` fails with `webhook_id_not_set` without the setting, `webhook_missing` when Aircall has no webhook with that id, `webhook_token_mismatch` when its token is not the one in `ingest-aircall-subs-signing`, and `webhook_reactivated` when Aircall had disabled it after failed deliveries and the job switched it on again (look at why the deliveries failed). The same page takes `aircall_max_per_minute` (default 60, the adapter's own limit on Aircall's API, shared with nothing else of the CMA): lower it if the other integrations on Pulse4all's Aircall account meet Aircall's limit of 120 per minute.

The fallback in **Studio (cma-prod-pg)** after the context block (keeps the settings already there):
```sql
select cma.set_connection_settings('<aircall conn>',
  coalesce((select settings from cma.integration_connection where id = '<aircall conn>'), '{}'::jsonb) || '{"webhook_id": "<webhook id>"}'::jsonb);
reset role;
```
Expected: an empty result.

## 8.5 The first events

**Browser / phone:** from the Aircall app, call your own mobile on a Pulse4all line, answer, talk ten seconds, hang up; tag the call with any tag. Your own number is staff data; it is stored only as a keyed hash.

**Terminal**
```bash
gcloud run services logs read cma-ingest --project=p4a-cma-prod --region=europe-west4 --limit=30 | grep -E "webhook|authentication" | tail -10
```
Expected: `webhook` lines for the Aircall route with `new` above 0; no `authentication failed` (that means the token in `ingest-aircall-subs-signing` is not this webhook's: the script's run did not store it, or a second webhook exists).

**Studio (cma-prod-pg)**
```sql
set role cma_owner;
select object_type, kind, status, error, count(*) from cma.ingest_event
where connection_id = '<aircall conn>' and recorded_at > now() - interval '1 hour' group by 1, 2, 3, 4 order by 1, 2;
select source_id, direction, status, started_at, answered_at, ended_at, talk_seconds, user_ref, number_ref,
       counterpart_hash is not null as hashed
from cma.telephony_call where connection_id = '<aircall conn>' order by started_at desc limit 3;
select call_source_id, tag_ref, tagged_at, untagged_at from cma.telephony_call_tag
where connection_id = '<aircall conn>' order by tagged_at desc limit 3;
reset role;
```
Expected: events `processed`; one call `outbound` with its times, about ten seconds of talk, your Aircall user id in `user_ref`, the line in `number_ref`, `hashed` true; one tag row with `untagged_at` empty. `failed` with `pepper_unavailable` means the deploy in 8.4 ran without `--tenant`.

## 8.6 Lines and tags

The adapter reads Aircall's lines and tags with the first event of the connection (its line catalog is empty) and then from the sweep at most hourly (`VENDOR_SETUP.md` §2.4; `docs/ingest/README.md`, section Aircall). Calls count only on counted lines, for the line's market; a line's market is also the default region of the call hash for numbers in national format. Pulse4all's account has 54 lines on 13 October 2026, each to be set by hand: there is no rule for lines yet.

**Browser:** Configuration → Sources → Aircall Subscriptions → **Lines**: per line choose its market and switch **Counted** off for internal and test lines, and for every line of another business line (on Pulse4all's account: the Invest lines). **Tags**: every tag counts until switched off; switch off tags that are not about the customer conversation, if any.

**Before the backfill (8.8), mark every other business line's line not counted** (addition 0008f, `db/54_uncounted_lines.sql`; Decision log, 13 October 2026). A connection stores calls on its counted lines only: a call on a line that does not count is not stored, and switching a line off removes the calls already stored on it, with their tags and links (the CRM calls stay), after a confirmation. A line still counted when the backfill runs fills this tenant with that business line's calls until it is switched off. Switching a line off by mistake is undone by switching it back on, but its earlier calls do not come back with a later backfill: the backfill does not take a call it listed before as new (README, Open decisions). So check the list before 8.8. A line added later in Aircall arrives counted: switch it off as soon as it appears if it is another business line's.

Expected: each change saved without a message and still there after a reload; switching **Counted** off asks first (`Stop counting this line`) and saves on confirmation. Intake (Reports → Intake) no longer shows `No telephony connected` from the first call or line on (the CMA counts telephony as connected once an active telephony connection holds a line or a call).

The fallback in **Studio (cma-prod-pg)** after the context block, one line per statement (a line not yet read is added with its id as name; `false` as the last value switches it off and removes its stored calls):
```sql
select number_ref, name, market, is_counted from cma.telephony_number where connection_id = '<aircall conn>' order by name;
select cma.set_telephony_number('<aircall conn>', '<number_ref>', '<market code>', true);
reset role;
```
Expected: the lines, then an empty result per statement.

The check before 8.8 in **Studio (cma-prod-pg)**: the lines not counted, and no stored call on any of them.
```sql
set role cma_owner;
select n.number_ref, n.name, (select count(*) from cma.telephony_call t where t.tenant_id = n.tenant_id and t.connection_id = n.connection_id and t.number_ref = n.number_ref) as stored_calls
from cma.telephony_number n where n.connection_id = '<aircall conn>' and not n.is_counted order by n.name;
reset role;
```
Expected: one row per line that does not count (the other business line's, internal and test lines), each with `stored_calls` 0.

## 8.7 People: each agent's Aircall user id

**Terminal** (the Aircall key and the HubSpot token read with your own login and never printed; after 7.6, which put the HubSpot owner ids on the persons)
```bash
node docs/ingest/aircall-users.mjs --project p4a-cma-prod --api-secret ingest-aircall-subs-token --via-owners ingest-hubspot-subs-token
```
Expected: per Aircall user whose email is a HubSpot owner's email, one line `select cma.set_user_external_id(x.user_id, 'aircall_user', '<Aircall user id>') from cma.app_user_external_id x where x.system = 'hubspot_owner' and x.external_id = '<owner id>';` (no email in the output), then on stderr `-- <n> Aircall user(s) matched to a HubSpot owner, of <m>` and `-- not matched (link by hand on Team → People → Linked accounts): <ids>`. Paste the lines in **Studio (cma-prod-pg)** after the context block, then `reset role;`. Expected: one row per statement; a statement whose owner id is on no person returns no row and changes nothing. `--also-domain newcogroup.com=pulse4all.com` also matches an address on the other domain, as in 7.6. Without `--via-owners` the script prints one statement per user by email instead.

Or by hand, one person at a time: **Browser:** Aircall Dashboard → Users → the user: the id is the number in the page's address (`VENDOR_SETUP.md` §2.5; not walked through). Then `https://workspace.pulse4all.app/team/people` → the person → **Linked accounts** → `User id in Aircall Subscriptions` → the id → Save.

Expected: the People list's **Linked** column shows `2 of 2` for a person with their HubSpot owner id and their Aircall user id. An id already linked to someone else is refused with `This id is already linked to someone else`; nothing changes until it is unlinked there. A manager links the agents they may edit; an admin links everyone; nobody links their own ids on this page.

**Browser:** Reports → **Data quality**. Expected: `Telephony users without a person` at 0 after the calls of every linked agent; a count above 0 lists Aircall users who called without a CMA person (a new agent, or an id typed wrong), with the link to People.

## 8.8 Backfill from 1 October

**Terminal** (`<aircall conn>` from 8.3)
```bash
gcloud run jobs execute ingest-backfill --project=p4a-cma-prod --region=europe-west4 --wait --args=--connection,<aircall conn>,--object,telephony_call,--from,2026-10-01
```
Expected: `Execution [ingest-backfill-…] has successfully completed.` It lists the calls a day at a time, 50 per request, at `aircall_max_per_minute` (default 60) and takes each call from the listing (no second read), so two weeks of calls take minutes. A failed execution is run again with the same arguments: it continues at the last finished day. It fails at once with `account_mismatch` when the connection's account id is not the key's company name (8.3).

The sweep links calls of the last two hours only (`link_calls(now() − 2 h)`), so the backfilled calls are linked once, by hand:

**Studio (cma-prod-pg)** after the context block
```sql
select cma.link_calls('2026-10-01 00:00 Europe/Amsterdam'::timestamptz);
reset role;
```
Expected: the number of links made.

**Studio (cma-prod-pg)**
```sql
set role cma_owner;
select count(*), min(started_at), max(started_at), count(*) filter (where user_ref is null) as without_user
from cma.telephony_call where connection_id = '<aircall conn>';
select count(*) from cma.call_link l join cma.telephony_call t on t.tenant_id = l.tenant_id and t.id = l.telephony_call_id
where t.connection_id = '<aircall conn>' and l.unlinked_at is null;
select job, stream, status, counts, error, started_at, finished_at from cma.sync_run
where connection_id = '<aircall conn>' order by started_at desc limit 5;
reset role;
```
Expected: calls from 1 October onward; links for most calls agents logged in HubSpot; a `backfill` row `succeeded` for stream `telephony_call`. Few links next to many calls means the Aircall–HubSpot integration does not log every call (data prerequisite) or the HubSpot calls carry no number (the `counterpart_hash` on `cma.crm_call` is empty).

## 8.9 Day one

- **The end-to-end check** of Phase 7 step 7 on the first real new deal: the Aircall call, its HubSpot call engagement, the `call_link` within two hours, the deal in `speed_to_lead_rows`. Compare the engagement's `occurred_at` with the Aircall call's `started_at` for the same call: equal within seconds means HubSpot's time is the start; minutes apart means the effective start comes from the link (DESIGN §4.4 does that already).
- **Browser:** Reports → Intake: the calls column per day and market; Reports → Data quality: `Telephony calls without a logged call` after 24 hours.
- **The first reconcile** (02:30): `select job, stream, status, error, counts from cma.sync_run where connection_id = '<aircall conn>' order by started_at desc limit 3;` as `cma_owner` in Studio. Expected: `reconcile`, `telephony_call`, `succeeded` with the calls of the last 26 hours fetched; an `error` is one of the webhook codes of 8.4 or `account_mismatch`.
- **Records:** the outputs of 8.2 to 8.8 into `records/intake-prod-<date>/`, with the HubSpot ones.

---

# Phase 9. Shopify in prod

Written on 13 October 2026 from `VENDOR_SETUP.md` §3 and §4 and step 6 of Phase 7; brought in line with the Shopify adapter (brief B10) the same day, and with B10.1 after it: the CMA writes nothing back to HubSpot for Shopify and keeps each customer's matched contact in its own database (addition 0008h; README Decision log, 13 October 2026). Shopify's Dev Dashboard click paths follow Shopify's documentation as of 13 October and have not been walked through in Pulse4all's organisation. Per store: one connection, one store row with its renewal settings, one set of subscriptions, one backfill, two read-only checks. What each step relies on is in `docs/ingest/README.md`, section Shopify.

**The gate.** Briefs B10 and B10.1 bring `ingest/src/adapters/shopify`, `docs/ingest/shopify-subscribe.mjs` and the backfill objects `commerce_customer` and `commerce_order`, and need additions 0008g (`db/56_commerce_phone_hash.sql`) and 0008h (`db/58_commerce_contact_link.sql`) in the database first: the adapter sends the phone hash, which the 0007b functions would drop, and keeps each customer's contact link with the function of 0008h. Until B10.1 is merged, 0008g and 0008h have run in prod (their morning runbooks) and the service and jobs are deployed from it, run 9.1 to 9.3 only (Shopify-side setup and the secret) and stop there. The outbox worker job `ingest-outbox` of B10 stays deployed but has no schedule: nothing enqueues a write-back since 0008h.

**Terminal** (in `~/cma`, on a current `main`)
```bash
git switch -q main && git pull -q --ff-only && ls ingest/src/adapters docs/ingest/shopify-subscribe.mjs ingest/jobs
```
Expected after B10.1: `aircall automation hubspot shopify`, the script path, and `outbox.mjs` among the jobs (generic and unscheduled).

**Studio (cma-prod-pg)**
```sql
set role cma_owner;
select version from cma.schema_migration where version in ('0008f', '0008g', '0008h') order by 1;
reset role;
```
Expected: `0008f`, `0008g` and `0008h`.

**Data prerequisites:**
- Every Pulse4all store installed (9.3) and subscribed (9.7). A store left out is missing from first orders and lead to order without any error.
- Shopify grants the protected fields **Email** and **Phone** (9.2). Without Email the CMA cannot find a new customer's HubSpot contact by email; it then matches by the customer id in the contacts' Contact-Shopify ID properties (`VENDOR_SETUP.md` §4), which the HubSpot–Shopify app fills and the HubSpot connection names as its `shopify` contact refs (7.3). Without Phone orders carry no phone hash, so an order cannot be matched to an earlier call (indirect sales, Open decisions); nothing fails.
- The HubSpot connection's contact ref fields for `shopify` (7.3: Contact-Shopify ID-1 and ID-2) name the properties in which the HubSpot–Shopify app writes the Shopify customer id; if the app writes it elsewhere, point the refs there. Without them the match has no fallback when the email is withheld, and Reports → Data quality and lead to order find no customer of a contact.
- The renewal source names or app ids of each store's subscription app (9.6), or every renewal counts as a repeat order.
- Nothing on the HubSpot side is the CMA's: the HubSpot–Shopify app writes the Shopify contact properties of `VENDOR_SETUP.md` §1.1 and creates a Self Serve deal per new order, and the CMA writes none of them (one writer per property).

## 9.1 The organisation check

**Browser:** Shopify admin of any Pulse4all store → Settings → Apps → Develop apps → **Build apps in Dev Dashboard** → **Stores** (`VENDOR_SETUP.md` §3.1).

Expected: the list of the organisation's stores. Every Pulse4all store in it → one app (9.2 once). A store in another organisation → one app per organisation, each with its own client secret: repeat 9.2 and 9.3 per organisation with the secret name `ingest-shopify-<organisation>-signing` instead of `ingest-shopify-app-signing`. Write the store handles down (the part before `.myshopify.com`).

## 9.2 The app and its version

**Browser:** Dev Dashboard → Apps → Create app → name **CMA ingest** → Versions → Create a version (`VENDOR_SETUP.md` §3.2):
- Scopes `read_customers`, `read_orders`, and `read_all_orders` if offered (without it Shopify serves 60 days of orders; first versus repeat then comes from the customer's lifetime order count).
- No app address, no extensions, no webhooks in the version (the CMA subscribes per store in 9.7).
- Distribution **Custom**.
- The app → API access requests → Protected customer data access → customer data with the fields **Email** and **Phone** (not Name, not Address); reason "match the customer to our CRM contact and to earlier calls; neither stored, the phone only as a keyed hash".
- Release the version.

Expected: version 1 released with the three scopes; the protected data request listed as granted for Email and Phone (for a custom-distribution app Shopify lists both levels as always available: a selection, not a review). If the Dashboard asks for a review or refuses, stop here and decide §4's fallback; the rest of the phase works either way (without Email the match searches the contacts' Shopify id properties instead; without Phone the hash is empty).

## 9.3 Install per store and the client secret

**Browser:** the app → Home → **Install app** → each Pulse4all store from 9.1, one by one. Then Settings → Credentials: note the **Client ID** (not a secret; it goes into each store connection's settings) and copy the **Client secret**.

**Terminal** (on its own line)
```bash
put_secret p4a-cma-prod ingest-shopify-app-signing
```
Expected: `stored ingest-shopify-app-signing (version added)`. Every store connection of this app names this one secret: Shopify signs each store's webhooks with the app's client secret.

Rotation (README Decision log, 13 October 2026, sixth Gemini audit FIND-02): the client secret is rotated in the Dev Dashboard (the app → Settings → Credentials), then the new value is added as a new version of `ingest-shopify-app-signing` with the `put_secret` line above; no Secret Manager rotation schedule (the service reads the latest version within five minutes, and Shopify retries a delivery refused meanwhile).

**Terminal** (after B10 is deployed; always with `--front`)
```bash
bash docs/ingest/deploy.sh prod --front ingest.pulse4all.app --tenant pulse4all-subscriptions --secret ingest-shopify-app-signing
```
Expected: `accessor on ingest-shopify-app-signing`, a new revision, `health: {"ok":true,…}`.

**Terminal** (the jobs on the same image)
```bash
bash docs/ingest/deploy.sh prod --jobs
```
Expected: the four jobs of 7.2 plus `ingest-outbox`, and `schedule ingest-outbox: none (the job runs only when executed)`, or `schedule ingest-outbox: paused (nothing to deliver since 0008h)` where an earlier deploy had scheduled it; `no build`. The service deploy above also sets `INGEST_SHOPIFY_READBACK_BUDGET_MS=1500` (the Shopify route answers within 1.5 seconds of read-back and leaves the rest to the sweep; Shopify waits five seconds in all).

## 9.4 Removed: Make switched off for the nine properties

Removed on 13 October 2026 (B10.1; README Decision log, 13 October 2026). The CMA writes nothing back to HubSpot for Shopify, so it takes no contact property over from Make: the HubSpot–Shopify app writes the Shopify contact fields and creates a Self Serve deal per new order (Martin, 13 October 2026), and every property has one writer. Which of Make and the app writes a property is outside the CMA. The number stays so the references to 9.5 to 9.9 hold.

## 9.5 Removed: the write-back fields

Removed on 13 October 2026 with 9.4: no `cma.writeback_field` rows in any step. The CMA keeps each customer's matched contact in its own database (`cma.commerce_customer.crm_contact_source_id`, 0008h) and enqueues no outbox action; the outbox (0007c) and the job `ingest-outbox` stay, generic and unscheduled. The renewal lists are set per store in 9.6.

A read-only check that nothing was configured before this change:

**Studio (cma-prod-pg)**
```sql
set role cma_owner;
select connection_id, field, slot, target_property, mode, enabled from cma.writeback_field order by 1, 2, 3;
reset role;
```
Expected: no rows. A row means the earlier 9.5 ran: harmless (nothing enqueues), but disable each row so Configuration → Sources does not list a write-back that does not happen, in Studio after the context block: `select cma.set_writeback_field('<hubspot conn>', '<field>', '<target_property>', '<mode>', false, <slot>::smallint);` per row, then `reset role;`.

## 9.6 Per store: the connection, its settings and the store

Repeat 9.6 to 9.8 per store. **Do the three in one sitting**: the store row makes Intake count the shop as connected (the `No shop connected` text disappears), so a store row without subscriptions and backfill shows zero orders as if the shop sold nothing. The store row, its settings and its renewal settings come first, so the first order read is already classified.

**Studio (cma-prod-pg)** after the context block (`<handle>` from 9.1)
```sql
select * from cma.upsert_connection('shopify', 'Shopify <store name>', '<handle>.myshopify.com',
                                    'ingest-shopify-app-signing', null);
```
Expected: one row with `connection_id` (`<shop conn>`) and `key`.

**Studio (cma-prod-pg)** (same tab)
```sql
select cma.set_connection_kind('<shop conn>', 'commerce');
select cma.set_connection_settings('<shop conn>', '{"client_id":"<client id from 9.3>","api_version":"2026-10","shop_handle":"<handle>","crm_connection_id":"<hubspot conn>"}'::jsonb);
reset role;
```
Expected: two empty results. `crm_connection_id` names the HubSpot connection whose contacts the store's customers are matched to; the match stays in the CMA (nothing is written to HubSpot). The settings can also be typed on the Sources page (Settings → Add setting, one key per row → Save settings); the page refuses a key that names a secret.

**Browser:** Configuration → Sources → Shopify <store name> → **Store** → **Add store**: the handle, the name, the store's market, its currency (three capital letters) and its time zone (for example `Europe/Amsterdam`) → Save.

Expected: the store listed with its market. The fallback in Studio after the context block: `select cma.upsert_commerce_store('<shop conn>', '<handle>', '<store name>', '<market>', '<currency>', '<time zone>');` (answers the store's id). A handle another store holds is refused (`Another store already has this handle`).

**The store's renewal settings.** Which of the store's orders are renewals is named by the subscription app's sales channel (`source_name`) or app id (`app_ref`). Look them up before the backfill (read-only; no customer data):

**Terminal** (in `~/cma`)
```bash
node docs/ingest/shopify-subscribe.mjs --project p4a-cma-prod --shop <handle>.myshopify.com --client-id <client id from 9.3> --secret-name ingest-shopify-app-signing --source-names --days 60
```
Expected: one line per sales channel and app with its order count, the most frequent first, for example `412	web	580111	Online Store`, `236	subscription_contract	<app id>	<subscription app name>`, `9	pos	…`. The subscription app's renewals are the line with its name (Juo for Pulse4all); Shopify's own checkout is `web`, the point of sale `pos`. Write the line into the records.

**Studio (cma-prod-pg)** after the context block. The lists are the tenant's, comma-separated, and hold every store's values: first read what is there, then set the list with this store's value added (leave a list as it is when the other names the renewals)
```sql
select key, value, is_default from cma.tenant_settings() where key in ('commerce.renewal_source_names', 'commerce.renewal_app_ids');
select cma.set_tenant_setting('commerce.renewal_source_names', '<the values already there>,<this store''s source name>');
select cma.set_tenant_setting('commerce.renewal_app_ids', '<the values already there>,<this store''s app id>');
reset role;
```
Expected: the two rows as they were, then one row per setting with the new value and `is_default` false. A change reclassifies the tenant's orders in the same transaction (0007b), so a second store's value never undoes the first's.

## 9.7 Per store: the subscriptions and the first events

**Terminal** (`<key>` of this store's connection)
```bash
node docs/ingest/shopify-subscribe.mjs --project p4a-cma-prod --shop <handle>.myshopify.com --client-id <client id from 9.3> --secret-name ingest-shopify-app-signing --url "https://ingest.pulse4all.app/shopify/<key>"
```
Expected (`VENDOR_SETUP.md` §3.4): seven subscriptions created (`CUSTOMERS_CREATE`, `CUSTOMERS_UPDATE`, `CUSTOMERS_DELETE`, `ORDERS_CREATE`, `ORDERS_UPDATED`, `ORDERS_CANCELLED`, `ORDERS_DELETE`) or listed as existing on a rerun. The nightly reconcile recreates a subscription Shopify removed after failed deliveries.

The first real order or customer change of the store arrives within a minute; a store with few orders may take hours. No test order in a live store: it would be a real order in Shopify's books.

**Studio (cma-prod-pg)**
```sql
set role cma_owner;
select object_type, kind, status, error, count(*) from cma.ingest_event
where connection_id = '<shop conn>' and recorded_at > now() - interval '1 day' group by 1, 2, 3, 4 order by 1, 2;
select count(*) as customers, count(crm_contact_source_id) as with_contact, max(matched_at) as last_match
from cma.commerce_customer where connection_id = '<shop conn>';
reset role;
```
Expected: events `processed`; `with_contact` grows as customers match exactly one HubSpot contact (the link is the CMA's own; nothing is written to HubSpot). A `401` in the service log for the Shopify route means the secret is not this app's client secret (or the store belongs to another organisation's app). Events `failed` with `throttled` or `paced` are read by the sweep within minutes (a burst of renewals is answered at once and read by the sweep within Shopify's cost limit); `crm_paced` or another `crm_` code means the HubSpot lookup was paced or failed and the sweep tries again; `store_not_configured` means the store row of 9.6 is missing; `client_id_not_set` the setting; `token_http_400` a client id or secret of another app, or a store outside the app's organisation.

## 9.8 Per store: backfill from 1 October

**Terminal** (customers first, then orders)
```bash
gcloud run jobs execute ingest-backfill --project=p4a-cma-prod --region=europe-west4 --wait --args=--connection,<shop conn>,--object,commerce_customer,--from,2026-10-01
gcloud run jobs execute ingest-backfill --project=p4a-cma-prod --region=europe-west4 --wait --args=--connection,<shop conn>,--object,commerce_order,--from,2026-10-01
```
Expected: two `has successfully completed` lines. A failed execution is run again with the same arguments.

**Studio (cma-prod-pg)**
```sql
set role cma_owner;
select count(*), min(source_created_at), max(source_created_at) from cma.commerce_customer where connection_id = '<shop conn>';
select order_kind, count(*), min(source_created_at), max(source_created_at) from cma.commerce_order
where connection_id = '<shop conn>' group by 1 order by 1;
select source_name, app_ref, count(*) from cma.commerce_order where connection_id = '<shop conn>' group by 1, 2 order by 3 desc;
select job, stream, status, counts, error, started_at, finished_at from cma.sync_run
where connection_id = '<shop conn>' order by started_at desc limit 5;
reset role;
```
Expected: customers and orders since 1 October; `order_kind` mostly `first` and `repeat` (`renewal` stays 0 until the lists are set); the source names and app ids with their counts (no customer data); two `backfill` rows `succeeded`.

The source names and app ids should match what 9.6 found: the subscription app's line with many orders and `renewal` filled. A `source_name` or `app_ref` with many orders that the lists do not name is a renewal channel 9.6 missed: add it as in 9.6 (the settings change reclassifies the orders).

**The orders per kind per day (read-only, per store)**

**Studio (cma-prod-pg)**
```sql
set role cma_owner;
select (o.source_created_at at time zone s.time_zone)::date as day, o.order_kind, count(*) as orders
from cma.commerce_order o
join cma.commerce_store s on s.tenant_id = o.tenant_id and s.connection_id = o.connection_id
where o.connection_id = '<shop conn>' and not o.is_test and o.source_deleted_at is null
  and o.source_created_at >= now() - interval '14 days'
group by 1, 2 order by 1, 2;
reset role;
```
Expected: per day `first` and `repeat` orders spread over the days, and `renewal` orders clustered on the subscription app's billing days (many on a few days, few or none on the others); `unknown` only for orders without a customer (guest checkout) and for a new order whose count Shopify's search did not hold yet (it turns `first` or `repeat` at its next read, at the latest after the nightly reconcile). Renewals spread like web orders, or none at all, mean the renewal settings do not name the subscription app: back to 9.6. Write the result into the records.

**The bridge check (read-only, per store):** the share of the store's customers whose HubSpot contact the CMA holds, read from the local link (0008h): a customer is bridged when its last read found exactly one contact, by email, by a contact the CMA holds with the customer id among its refs, or by the Contact-Shopify ID properties.

**Studio (cma-prod-pg)**
```sql
set role cma_owner;
select s.handle, count(*) as customers,
       count(cu.crm_contact_source_id) as with_contact,
       round(100.0 * count(cu.crm_contact_source_id) / nullif(count(*), 0), 1) as with_contact_pct,
       min(cu.matched_at) as first_match, max(cu.matched_at) as last_match
from cma.commerce_customer cu
join cma.commerce_store s on s.tenant_id = cu.tenant_id and s.connection_id = cu.connection_id
where cu.source_deleted_at is null
group by s.handle order by s.handle;
select count(*) as outbox_actions from cma.outbox_action;
reset role;
```
Expected: one row per store with `customers` the store's customers since the backfill's start and `with_contact` at most that, filled by the backfill's own reads (one HubSpot search per customer not yet linked, one per 400 ms: about seven minutes per thousand customers); `outbox_actions` 0. The share is the customers whose email found exactly one HubSpot contact; a share far below what you expect from how many buyers have a HubSpot contact means the email match is not happening (Email not granted, 9.2). Customers with no contact or with several are counted in the service's `processed` log lines (`match_none`, `match_several`, no ids), not stored. Write both results into the records.

**Browser:** Reports → Intake (and Dashboard, the intake row): the `No shop connected` text is gone; first orders appear per day for the store's market.

## 9.9 Day one

- **Lead to order**: Studio after the context block, `select * from cma.lead_to_order_rows(current_date - 7, current_date) limit 20;` shows deals followed by a first order of the same contact within the window.
- **Browser:** Reports → Data quality: `Shop customers without a contact` and the ambiguous count. These still read the contacts' Contact-Shopify ID refs, not the link of 0008h (README Open decisions): customers without a deal count as unmatched (the CMA holds a contact only while a record points to it), so a high number on day one is expected; a number that does not fall as deals come in means the HubSpot–Shopify app is not filling the ID properties or 7.3's ref fields are not set.
- **One real match, by hand:** Shopify admin → Customers → a customer with a recent order → the customer id (the number at the end of the address); live portal → the contact with that customer's email → its record id (in the address bar). In Studio, `set role cma_owner; select crm_contact_source_id, matched_at from cma.commerce_customer where connection_id = '<shop conn>' and source_id = '<customer id>'; reset role;`. Expected: the contact's record id. Ids only: nothing else of the customer goes into the records.
- **Records:** the outputs of 9.2 to 9.8 per store (the source names of 9.6, the orders per kind and the bridge check of 9.8), the check of 9.5 and the renewal values into `records/intake-prod-<date>/`.
