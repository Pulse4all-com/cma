# Prod runbook: HubSpot, Aircall and Shopify into cma-ingest in prod

The prod phase for HubSpot (Pulse4all Subscriptions, the live portal `147946837`), then Aircall (phase 8), Shopify (phase 9), the email poll (phase 10, brief B17b, 15 October 2026), the Trusted Shops reviews (phase 13, brief B18, 25 October 2026) and the asset register's API sync (phase 14, addition 0008zj, 27 October 2026). Sections 7.1 to 7.9 replace step 3 of Phase 7 in `docs/night-2026-10-10/MORNING_RUNBOOK.md` (12 October 2026); phases 8 and 9 replace its steps 4 (the Aircall half), 5, 6 and 7 (13 October 2026). Order for HubSpot: the front and the service, the jobs, the connection, the app, the first events, the owners, the assignment rule, the backfill, day one. Every block says where it runs and ends with what you should see (the convention of `docs/night-2026-10-11/GO_LIVE_RUNBOOK.md`). SQL and shell never share a block.

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
- Every prod service deploy carries `--front ingest.pulse4all.app` (7.1, 7.4, 8.4, 9.3; `--jobs` takes none): `deploy.sh` refuses a prod service deploy without it since 16 October 2026 (`prod service deploy needs --front <host> …`, exit 2, before any gcloud call), because without it the ingress goes to `all` and every HubSpot signature fails (`records/ingest-front-incident-2026-10-16`). A change to `cma-ingest` in the Console is an emergency fix only, and sets exactly what `deploy.sh` sets (README, Decision log, 16 October 2026).
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
Expected: one row, then one row of three values. **Each Run in Studio is a fresh session** (found in the walk-through of phase 9, 14 October 2026): the role and the `set_config` values of an earlier Run are gone, so the second part (from `set role cma_app;`) goes into the same Run as the statement it serves. "After the context block" and "(same tab)" below mean exactly that: paste the second part above the statement, run both together, with `reset role;` at the end. A block written as `set role cma_owner; … reset role;` stands alone.

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
Expected: `200`, then `404` (the `run.app` address refused by the ingress setting; seen in prod on 12 October, `deploy.sh` prints `run.app: 404 (refused)`). A `200` on the second line means the ingress is `all`, from a Console change or a deploy without `--front` before 16 October 2026 (`deploy.sh` refuses one since then, and prints a `FAIL run.app: 200` line when it finds the address open): rerun the first block.

## 7.2 The jobs

**Terminal** (same commit, so the image exists)
```bash
bash docs/ingest/deploy.sh prod --jobs
```
Expected: `image … exists (sha256:…); no build`, four `gcloud run jobs deploy` results, `schedule ingest-sweep: * * * * * (Europe/Amsterdam)`, `schedule ingest-poll-forms: * * * * * (Europe/Amsterdam)`, `schedule ingest-reconcile: 30 3 * * * (Europe/Amsterdam)`, the same Studio grant (already done in 7.1) and the backfill command. The first time it creates `cma-ingest-scheduler`.

**Terminal** (the four jobs, the three schedules, and who may start which job)
```bash
gcloud run jobs list --project=p4a-cma-prod --region=europe-west4 --format='value(metadata.name)'
gcloud scheduler jobs list --project=p4a-cma-prod --location=europe-west4 --format='table(name.basename(),schedule,timeZone,state)'
for j in ingest-sweep ingest-poll-forms ingest-reconcile ingest-backfill; do echo "$j: $(gcloud run jobs get-iam-policy "$j" --project=p4a-cma-prod --region=europe-west4 --flatten='bindings[].members' --filter='bindings.role:roles/run.invoker' --format='value(bindings.members)' | paste -sd' ')"; done
gcloud projects get-iam-policy p4a-cma-prod --flatten='bindings[].members' --filter='bindings.members:cma-ingest-scheduler@' --format='value(bindings.role)'
```
Expected: `ingest-backfill`, `ingest-poll-forms`, `ingest-reconcile`, `ingest-sweep`; three schedules (`* * * * *`, `* * * * *`, `30 3 * * *`, `Europe/Amsterdam`, `ENABLED`); `serviceAccount:cma-ingest-scheduler@p4a-cma-prod.iam.gserviceaccount.com` after the three scheduled jobs and nothing after `ingest-backfill:`; the last command prints nothing (no project role for the scheduler account). Until 7.3 the jobs find no connection and exit 0.

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

**Terminal** (the accessor grants, when the secrets were created after 7.1; always with `--front`, without which `deploy.sh` refuses)
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

**The form rule** (Martin, 12 October 2026; Decision log): a form is counted when its name matches quote, contact or info and not cancellation, replacement or support; its `lead_source` is `quote`, `contact` or `info`, whichever of the three comes first in the name; its market is the name's two-letter prefix, `UK` read as `GB`, when that is a market of the tenant. `set_form` replaces `kept_fields`, so the statement passes the form's current ones. The prefix pattern `'^\s*([A-Za-z]{2})\M'` is written with single backslashes: Studio's `standard_conforming_strings` is on, so a backslash in a plain string literal stays one character, and a doubled backslash matches a literal backslash, which no form name has, so no form would get a market (B17d's prod run, 17 October 2026, `records/b17d-prod-2026-10-17`):

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

**Terminal** (the accessor grants; always with `--front`, without which `deploy.sh` refuses)
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

Expected: the setting listed after a reload. The nightly reconcile (03:30) checks this webhook: its `reconcile` run for stream `telephony_call` fails with `webhook_id_not_set` without the setting, `webhook_missing` when Aircall has no webhook with that id, `webhook_token_mismatch` when its token is not the one in `ingest-aircall-subs-signing`, and `webhook_reactivated` when Aircall had disabled it after failed deliveries and the job switched it on again (look at why the deliveries failed). The same page takes `aircall_max_per_minute` (default 60, the adapter's own limit on Aircall's API, shared with nothing else of the CMA): lower it if the other integrations on Pulse4all's Aircall account meet Aircall's limit of 120 per minute.

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

**Note: the start moved back to 1 September 2026 (prod, 25 October 2026, Pulse4all Subscriptions).** So the courtesy figures can read the Aircall calls from September (the legacy call import of addition 0008zg covers what came before, `docs/import/legacy-calls.md`), the same three steps ran again with `2026-09-01`: the HubSpot calls, the Aircall calls, then the links by hand. The outcome is in CHANGELOG.md (25 October 2026).

**Terminal** (`<hubspot conn>` the HubSpot connection, `<aircall conn>` from 8.3)
```bash
gcloud run jobs execute ingest-backfill --project=p4a-cma-prod --region=europe-west4 --wait --args=--connection,<hubspot conn>,--object,crm_call,--from,2026-09-01
gcloud run jobs execute ingest-backfill --project=p4a-cma-prod --region=europe-west4 --wait --args=--connection,<aircall conn>,--object,telephony_call,--from,2026-09-01
```

**Studio (cma-prod-pg)** after the context block
```sql
select cma.link_calls('2026-09-01 00:00 Europe/Amsterdam'::timestamptz);
reset role;
```
Expected: each execution `has successfully completed`, then the number of links made.

## 8.9 Day one

- **The end-to-end check** of Phase 7 step 7 on the first real new deal: the Aircall call, its HubSpot call engagement, the `call_link` within two hours, the deal in `speed_to_lead_rows`. Compare the engagement's `occurred_at` with the Aircall call's `started_at` for the same call: equal within seconds means HubSpot's time is the start; minutes apart means the effective start comes from the link (DESIGN §4.4 does that already).
- **Browser:** Reports → Intake: the calls column per day and market; Reports → Data quality: `Telephony calls without a logged call` after 24 hours.
- **The first reconcile** (03:30): `select job, stream, status, error, counts from cma.sync_run where connection_id = '<aircall conn>' order by started_at desc limit 3;` as `cma_owner` in Studio. Expected: `reconcile`, `telephony_call`, `succeeded` with the calls of the last 26 hours fetched; an `error` is one of the webhook codes of 8.4 or `account_mismatch`.
- **Records:** the outputs of 8.2 to 8.8 into `records/intake-prod-<date>/`, with the HubSpot ones.

---

# Phase 9. Shopify in prod

Written on 13 October 2026 from `VENDOR_SETUP.md` §3 and §4 and step 6 of Phase 7; brought in line with the Shopify adapter (brief B10) the same day, and with B10.1 after it: the CMA writes nothing back to HubSpot for Shopify and keeps each customer's matched contact in its own database (addition 0008h; README Decision log, 13 October 2026). Walked through for the NL store on 14 October 2026 (`records/intake-prod-2026-10-14`); 9.2, 9.3 and 9.6 to 9.9 were corrected the same day where the walk-through differed (the Dev Dashboard's click paths had followed Shopify's documentation as of 13 October). The other 13 stores followed the same day, all at once (9.6, Several stores at once; same record), and Juo's renewal source names were corrected then (9.6). Per store: one connection, one store row with its renewal settings, one set of subscriptions, one backfill, two read-only checks. What each step relies on is in `docs/ingest/README.md`, section Shopify.

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
- Email and Phone: a custom-distribution app gets every customer field automatically (9.2; README Decision log, 14 October 2026), so the email match and the phone hash need no request. Shopify still withholds the order's own phone (9.7), so an order's hash is its customer's phone's; an order whose phone sits only in the shipping address carries no hash, because the adapter never reads addresses (about a third of the NL store's orders on 14 October 2026; README Open decisions, Indirect sales). Nothing fails either way.
- The HubSpot connection's contact ref fields for `shopify` (7.3: Contact-Shopify ID-1 and ID-2) name the properties in which the HubSpot–Shopify app writes the Shopify customer id; if the app writes it elsewhere, point the refs there. Without them the match has no fallback for a customer without an email, and Reports → Data quality and lead to order find no customer of a contact: on 14 October 2026 the NL store's 1,874 customers all counted as without a contact and lead to order found no order (9.9), because the app does not fill them yet.
- The renewal source names or app ids of each store's subscription app (9.6), or every renewal counts as a repeat order.
- Nothing on the HubSpot side is the CMA's: the HubSpot–Shopify app writes the Shopify contact properties of `VENDOR_SETUP.md` §1.1 and creates a Self Serve deal per new order, and the CMA writes none of them (one writer per property).

## 9.1 The organisation check

**Browser:** Shopify admin of any Pulse4all store → Settings → Apps → Develop apps → **Build apps in Dev Dashboard** → **Stores** (`VENDOR_SETUP.md` §3.1).

Expected: the list of the organisation's stores. Every Pulse4all store in it → one app (9.2 once). A store in another organisation → one app per organisation, each with its own client secret: repeat 9.2 and 9.3 per organisation with the secret name `ingest-shopify-<organisation>-signing` instead of `ingest-shopify-app-signing`. Write the store handles down (the part before `.myshopify.com`).

## 9.2 The app and its version

Walked through on 14 October 2026; `VENDOR_SETUP.md` §3.2 still holds the earlier, documentation-based path.

**Browser:** Dev Dashboard → Apps → Create app → **Create app manually** → name **CMA ingest** → Versions → Create a version:
- Scopes, one comma-separated line: `read_customers,read_orders` (not the `customer_read_*` scopes). `read_all_orders` was not offered: Shopify serves the last 60 days of orders, and first versus repeat comes from the customer's lifetime order count (README Open decisions).
- Embedded in Shopify admin: off. The form still needs an app URL: type the placeholder `https://example.com` (the CMA has no app page).
- No extensions, no webhooks in the version (the CMA subscribes per store in 9.7).
- There is no API access requests step and no distribution picker: a custom-distribution app gets every customer field (name, email, phone, address, device data) and the store owner's staff data automatically (README Decision log, 14 October 2026). Minimisation rests on the adapter, which reads email and phone only, in memory, and stores the keyed phone hash and nothing personal, and on guarding the client secret (9.3).
- Release the version.

Expected: version 1 released with `read_customers` and `read_orders`.

## 9.3 Install per store and the client secret

**Browser:** the app → Home → **Install app** → each Pulse4all store from 9.1, one by one. Then Settings → Credentials: note the **Client ID** (not a secret; it goes into each store connection's settings) and copy the **Client secret**.

**Terminal** (on its own line)
```bash
put_secret p4a-cma-prod ingest-shopify-app-signing
```
Expected: `stored ingest-shopify-app-signing (version added)`. Every store connection of this app names this one secret: Shopify signs each store's webhooks with the app's client secret.

The secret may also be created in the console instead (Security → Secret Manager → Create secret, name `ingest-shopify-app-signing`, replication user-managed in `europe-west4` as `put_secret` does, the client secret as its value). Either way `deploy.sh` below grants the service's accessor on it.

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

Repeat 9.6 to 9.8 per store, or for several stores at once (the end of 9.6). **Do the three in one sitting**: the store row makes Intake count the shop as connected (the `No shop connected` text disappears), so a store row without subscriptions and backfill shows zero orders as if the shop sold nothing. The store row, its settings and its renewal settings come first, so the first order read is already classified.

The Studio blocks of 9.6 and 9.9 that call a function carry the context block's second part themselves (each Run is a fresh session; `<tenant_id>` and `<user_id>` from its first part).

**Studio (cma-prod-pg)** in one Run (`<handle>` from 9.1)
```sql
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'studio:martin', false);
select * from cma.upsert_connection('shopify', 'Shopify <store name>', '<handle>.myshopify.com',
                                    'ingest-shopify-app-signing', null);
reset role;
```
Expected: one row of three values, then one row with `connection_id` (`<shop conn>`) and `key`.

**Studio (cma-prod-pg)** in one Run
```sql
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'studio:martin', false);
select cma.set_connection_kind('<shop conn>', 'commerce');
select cma.set_connection_settings('<shop conn>', '{"client_id":"<client id from 9.3>","api_version":"2026-10","shop_handle":"<handle>","crm_connection_id":"<hubspot conn>"}'::jsonb);
reset role;
```
Expected: one row of three values, then two empty results. `crm_connection_id` names the HubSpot connection whose contacts the store's customers are matched to; the match stays in the CMA (nothing is written to HubSpot). The settings can also be typed on the Sources page (Settings → Add setting, one key per row → Save settings); the page refuses a key that names a secret.

**Browser:** Configuration → Sources → Shopify <store name> → **Store** → **Add store**: the handle, the name, the store's market, its currency (three capital letters) and its time zone (for example `Europe/Amsterdam`) → Save.

Expected: the store listed with its market. The fallback in Studio, in one Run below the context block's second part: `select cma.upsert_commerce_store('<shop conn>', '<handle>', '<store name>', '<market>', '<currency>', '<time zone>');` (answers the store's id). A handle another store holds is refused (`Another store already has this handle`).

**The store's renewal settings.** Which of the store's orders are renewals is named by the subscription app's sales channel (`source_name`) or app id (`app_ref`). Look them up before the backfill (read-only; no customer data):

**Terminal** (in `~/cma`)
```bash
node docs/ingest/shopify-subscribe.mjs --project p4a-cma-prod --shop <handle>.myshopify.com --client-id <client id from 9.3> --secret-name ingest-shopify-app-signing --source-names --days 60
```
Expected: a header `orders	source name	app id	app name`, then one line per sales channel and app with its order count, the most frequent first; Shopify's own checkout is `web`, the point of sale `pos`. Juo shows two lines with its app id, both renewals (README Decision log, 14 October 2026): the line whose source name is the app id, `9548333057` (in the NL store `876	9548333057	9548333057	Juo Subscriptions`), Juo's draft-order renewals paid through Mollie; and the line `…	subscription_contract_checkout_one	9548333057	…`, Juo's renewals paid through Shopify (card or PayPal billing attempts). New Juo subscriptions come in as `web`. **Name the sources, not the app id**: an app id in `commerce.renewal_app_ids` makes every order of that app a renewal, whatever its source name. Write the lines into the records.

**Studio (cma-prod-pg)** in one Run. The lists are the tenant's, comma-separated (empty entries are ignored), and hold every store's values: first read what is there, then set the source names with this store's renewal sources added. Leave `commerce.renewal_app_ids` as it is (Pulse4all keeps it empty: Juo's two source names name its renewals)
```sql
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'studio:martin', false);
select key, value, is_default from cma.tenant_settings() where key in ('commerce.renewal_source_names', 'commerce.renewal_app_ids');
select cma.set_tenant_setting('commerce.renewal_source_names', '<the values already there>,<this store''s renewal source names>');
reset role;
```
Expected: one row of three values, the two rows as they were, then one row with the new value and `is_default` false. Since 14 October 2026, for every Pulse4all store: `commerce.renewal_source_names` = `9548333057,subscription_contract_checkout_one`, `commerce.renewal_app_ids` empty (the NL pilot had set `9548333057` alone; corrected the same day). A store whose lines show only these two Juo sources adds nothing. A change reclassifies the tenant's orders in the same transaction (0007b), so a second store's value never undoes the first's.

**Several stores at once** (the other 13 stores, 14 October 2026). The same steps in two runs: one Studio Run for every store's connection, settings and store row, then one Cloud Shell script for the subscriptions (9.7) and backfills (9.8). Look up each store's source names first, as above; the renewal lists are the tenant's, so they are set once.

**Studio (cma-prod-pg)** in one Run (the temporary table lives only in this Run; one `values` row per store)
```sql
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'studio:martin', false);
create temp table new_store as
select v.handle, v.name, v.market, v.currency, v.time_zone, c.connection_id, c.key
from (values ('<handle>', '<store name>', '<market>', '<currency>', '<time zone>'),
             ('<handle>', '<store name>', '<market>', '<currency>', '<time zone>')) v(handle, name, market, currency, time_zone)
cross join lateral cma.upsert_connection('shopify', 'Shopify ' || v.name, v.handle || '.myshopify.com',
                                         'ingest-shopify-app-signing', null) c;
select cma.set_connection_kind(connection_id, 'commerce') from new_store;
select cma.set_connection_settings(connection_id, jsonb_build_object('client_id', '<client id from 9.3>',
         'api_version', '2026-10', 'shop_handle', handle, 'crm_connection_id', '<hubspot conn>')) from new_store;
select cma.upsert_commerce_store(connection_id, handle, name, market, currency, time_zone) from new_store;
select n.handle, n.market,
       c.kind = 'commerce' and c.settings->>'shop_handle' = n.handle and c.store_handle = n.handle as ok,
       concat_ws(' ', n.handle, n.connection_id, n.key) as line,
       c::text as read_back
from new_store n
left join cma.sources() c on c.connection_id = n.connection_id and c.key = n.key
order by n.handle;
reset role;
```
Expected: one row of three values; one empty result per store from `set_connection_kind` and from `set_connection_settings`, then the stores' ids; then one row per store with `ok` true, `line` (the handle, `<shop conn>` and `<key>`) and `read_back`, the connection as the Sources page reads it, matched on its id and key (`c::text`: id and key first, `commerce`, the settings, the handle last). An empty `ok` means no connection matched that id and key. A rerun is safe: the same ids and keys come back. The table keeps `c.connection_id` and `c.key`, not the row `c`, which a table cannot hold (`column "c" has pseudo-type record`).

**Terminal** (in `~/cma`): paste the `line` column, one store per line, then Ctrl-D
```bash
cat > ~/shopify-stores.txt
```
Expected: no output.

**Terminal** (in `~/cma`; the client id of 9.3 in place of its placeholder before pasting)
```bash
cat > ~/shopify-rollout.sh <<'EOF'
# One line per store in ~/shopify-stores.txt: <handle> <shop conn> <key>
client_id='<client id from 9.3>'
cd ~/cma || exit 1
while read -r handle conn key <&3; do
  [ -n "$key" ] || continue
  echo "== $handle $(date -u +%T)"
  node docs/ingest/shopify-subscribe.mjs --project p4a-cma-prod --shop "$handle.myshopify.com" --client-id "$client_id" --secret-name ingest-shopify-app-signing --url "https://ingest.pulse4all.app/shopify/$key"
  for object in commerce_customer commerce_order; do
    gcloud run jobs execute ingest-backfill --project=p4a-cma-prod --region=europe-west4 --wait --args=--connection,"$conn",--object,"$object",--from,2026-10-01
  done
done 3< ~/shopify-stores.txt
echo "== done $(date -u +%T)"
EOF
nohup bash ~/shopify-rollout.sh > ~/shopify-rollout.log 2>&1 &
tail -f ~/shopify-rollout.log
```
Expected: after `nohup: ignoring input`, per store `== <handle>`, the seven subscriptions of 9.7 (or listed as existing on a rerun) and two `has successfully completed` lines of 9.8, customers first; `== done` at the end (Ctrl-C stops `tail` only). The stores run one after the other; keep the Cloud Shell tab open until `== done`. If the shell drops, the backfill that was running keeps running server-side (the job's task timeout is 86400 s), but the script stops: run it again with the stores not yet done in `~/shopify-stores.txt`. Then 9.7's and 9.8's Studio checks per store (the bridge check covers every store in one query) and 9.9.

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

The app's error rate in the Dev Dashboard (about 51% for the NL store on 14 October 2026) is cosmetic: Shopify withholds the order's own phone and answers `CmaOrders` with a partial `ACCESS_DENIED`, which the adapter reads as an empty field; the orders are complete and their hash comes from the customer's phone (README Decision log, 14 October 2026). Events `failed` with `graphql_error` would be something else.

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
Expected: one row per store with `customers` the store's customers since the backfill's start and `with_contact` at most that, filled by the backfill's own reads (one HubSpot search per customer not yet linked, one per 400 ms: about seven minutes per thousand customers); `outbox_actions` 0. The share is the customers whose email found exactly one HubSpot contact; a share far below what you expect from how many buyers have a HubSpot contact means the email match is not happening (`crm_connection_id` missing in 9.6, or `crm_` codes in 9.7). Customers with no contact or with several are counted in the service's `processed` log lines (`match_none`, `match_several`, no ids), not stored. NL store, 14 October 2026: 1,830 of 1,874 customers linked, `outbox_actions` 0. Write both results into the records.

This bridge check is the only place the link shows today: Reports → Data quality (`Shop customers without a contact`) and lead to order (9.9) read the contacts' Contact-Shopify ID-1/2 instead (README Open decisions), so on the same day they showed 1,874 customers without a contact and 0 matched orders. They stay there until the HubSpot–Shopify app fills those properties.

**Browser:** Reports → Intake (and Dashboard, the intake row): the `No shop connected` text is gone; first orders appear per day for the store's market.

## 9.9 Day one

- **Lead to order**: **Studio (cma-prod-pg)** in one Run:
  ```sql
  set role cma_app;
  select set_config('app.tenant_id', '<tenant_id>', false),
         set_config('app.user_id', '<user_id>', false),
         set_config('app.actor_label', 'studio:martin', false);
  select * from cma.lead_to_order_rows(current_date - 7, current_date) limit 20;
  reset role;
  ```
  Expected: one row of three values, then deals followed by a first order of the same contact within the window. It joins deals to orders through the contacts' Contact-Shopify ID-1/2, not the link of 0008h, so it finds no order until the HubSpot–Shopify app fills those properties (NL store, 14 October 2026: 189 deals, none with an order).
- **Browser:** Reports → Data quality: `Shop customers without a contact` and the ambiguous count. These still read the contacts' Contact-Shopify ID-1/2 refs, not the link of 0008h (README Open decisions): until the HubSpot–Shopify app fills those properties every customer counts as without a contact (NL store, 14 October 2026: 1,874, while the bridge check of 9.8 had 1,830 linked). Once the app fills them, customers without a deal still count as unmatched (the CMA holds a contact only while a record points to it), so a high number is expected; a number that does not fall as deals come in means the app is not filling the ID properties or 7.3's ref fields are not set.
- **One real match, by hand:** Shopify admin → Customers → a customer with a recent order → the customer id (the number at the end of the address); live portal → the contact with that customer's email → its record id (in the address bar). In Studio, `set role cma_owner; select crm_contact_source_id, matched_at from cma.commerce_customer where connection_id = '<shop conn>' and source_id = '<customer id>'; reset role;`. Expected: the contact's record id. Ids only: nothing else of the customer goes into the records.
- **Records:** the outputs of 9.2 to 9.8 per store (the source names of 9.6, the orders per kind and the bridge check of 9.8), the check of 9.5 and the renewal values into `records/intake-prod-<date>/`.

---

# Phase 10. The email poll in prod (brief B17b)

The CRM's email engagements and the inbox conversations of the live portal into the tables of addition 0008m (run in prod on 15 October 2026, `records/0008m-prod-2026-10-15`), metadata only (`docs/ingest/README.md`, section Email). Written to run after dev passed `docs/b17b-email-ingest/MORNING_RUNBOOK.md` steps 1 to 8; Yordi agreed to the email metadata, the scopes `sales-email-read` and `conversations.read` and the held contacts on 15 October 2026 (README Decision log), so there is no other gate. The same steps as in dev, against prod. Run in prod on 16 October 2026 (`records/b17b-prod-2026-10-16`, written from Martin's report; dev in `records/b17b-dev-2026-10-16`); 10.7, day one, is not in that record. `<conn>` is the live portal's HubSpot connection (7.3), `<tenant_id>` and `<user_id>` the context block's.

Before you start:
- `main` holds the merge of B17b, and dev runs it (the same image: `deploy.sh` says `no build`).
- `country_dropdown` exists in the live portal (it is HubSpot's own country dropdown there); nothing to create.
- **Tell Kira first:** once the contacts are read again with slot 2 (10.5), 0007d's deal market falls back to more primary contacts' countries, so speed to lead and intake per market shift and show fewer unknown markets (README Open decisions).

## 10.1 The prod app: the two read scopes and the subscription

**Terminal** (in `~/cma`, on `main`)
```bash
node hubspot/render.mjs prod --target-url "https://ingest.pulse4all.app/hubspot/<key>" && cd hubspot/build/prod && hs project upload && cd ~/cma
```
Expected: `rendered prod: hubspot/build/prod`, the upload naming the live portal, build and deploy of **CMA ingest prod** succeeding with both components.

**Browser:** live portal → Development → Projects → CMA ingest prod → the app → Distribution → the Standard install → accept the update; the consent screen adds `sales-email-read` and `conversations.read`, read only.

Expected: the install active with the two scopes on the Auth tab. The token stays; if HubSpot shows a new one, `put_secret p4a-cma-prod ingest-hubspot-subs-token` (on its own line).

**Terminal** (the HTTP status only, as in the dev runbook's step 2d)
```bash
for p in "/crm/v3/objects/emails?limit=1" "/conversations/v3/conversations/inboxes?limit=1"; do gcloud secrets versions access latest --secret=ingest-hubspot-subs-token --project=p4a-cma-prod | sed 's/^/Authorization: Bearer /' | curl -s -o /dev/null -w "%{http_code}  ${p%%\?*}\n" -H @- "https://api.hubapi.com$p"; done
```
Expected: `200  /crm/v3/objects/emails` and `200  /conversations/v3/conversations/inboxes`; a `403` means the update of the install is not accepted yet.

## 10.2 What the live portal holds

**Terminal**
```bash
node docs/ingest/hubspot-email-check.mjs --project p4a-cma-prod --token-secret ingest-hubspot-subs-token --days 30
```
Expected: the four blocks as in dev (runbook step 3a): the eight properties present with the `hs_email_status` options, the candidates for the two settings (the same names as dev's when the property is HubSpot's own; otherwise pick again), the actor prefixes, the live inboxes and channels with their ids. Send me blocks 1 to 3; keep block 4 for 10.4.

## 10.3 The settings, country slot 2, the aliases

**Studio (cma-prod-pg)** after the context block (the current settings merged in, as `app_host` stays; leave out a property 10.2 gave none for)
```sql
select cma.set_connection_settings('<conn>', (select c.settings from cma.integration_connection c where c.id = '<conn>')
  || '{"email_poll": true, "email_thread_property": "<thread property>", "email_origin_property": "<origin property>", "email_automated_origins": "<automated values>"}'::jsonb);
select cma.set_connection_field('<conn>', 'contact', 'country', '', 'country_dropdown', 2::smallint);
select cma.connection_config('<conn>') -> 'settings';
reset role;
```
Expected: two empty results, then the settings with `app_host`, `email_poll: true` and the properties.

The aliases: the option values as one list (runbook step 3c's Terminal command with `--secret=ingest-hubspot-subs-token --project=p4a-cma-prod`), then the read of step 3c on `cma-prod-pg`, then `cma.set_market_alias('<option value>', '<market code>')` (or Configuration → Markets → Aliases in the Workspace) for every value naming a catalog market that has none.

Expected: every option value of a catalog market's country shows its market; the others stay empty.

## 10.4 Inboxes and channels

With block 4 of 10.2: per inbox whether it counts, its market, work type and channel; per channel its tenant channel and whether it counts (runbook step 3d's statements on `cma-prod-pg`). Defaults when nothing is set: a new inbox counts and takes the channel `email`; a new channel counts only when its kind is `email`. Which inboxes count and which market each serves is Arno's and Kira's call; set the ones they named.

Expected: `cma.connection_config('<conn>') -> 'inboxes'` as configured.

## 10.5 The jobs, then the backfill

**Terminal** (on `main`)
```bash
bash docs/ingest/deploy.sh prod --jobs
```
Expected: `image … exists (sha256:…); no build`, six job deploys, `schedule ingest-poll-email: * * * * * (Europe/Amsterdam)` next to the others. Two minutes later the Studio read of runbook step 4 on `cma-prod-pg`: `email_poll` runs `succeeded`, the `email:` cursors.

**Terminal** (contacts first, then emails and threads; `<conn>` the live portal's connection)
```bash
for o in contact crm_email inbox_thread; do gcloud run jobs execute ingest-backfill --project=p4a-cma-prod --region=europe-west4 --wait --args=--connection,<conn>,--object,$o; done
```
Expected: three successful executions. `crm_email` and `inbox_thread` start at `cma.email_start_date_of` (`email.start_date` is empty, so `intake.start_date`, 1 October 2026). A failed execution is run again with the same arguments: it continues where it stopped.

## 10.6 Read-only counts

The Studio reads of runbook step 8 on `cma-prod-pg` (counts only), and the fallback check:

**Studio (cma-prod-pg)**
```sql
set role cma_owner;
select country_source, count(*) from cma.crm_contact group by 1 order by 1;
select t.slug, (select count(*) from cma.data_quality_of(t.id) q where q.check_key = 'contact_country_fallback') as fallback_findings,
       (select count(*) from cma.data_quality_of(t.id) q where q.check_key = 'market_not_in_catalog' and q.object_type = 'contact') as contact_not_in_catalog
from cma.tenant t order by 1;
reset role;
```
Expected: most held contacts with `country_source` 2 (Contact-Country is filled on almost none, README KPIs 11); `fallback_findings` the same count for `pulse4all-subscriptions`, 0 for Invest; `contact_not_in_catalog` the values without an alias (add aliases for those that name a market, 10.3).

## 10.7 Day one

- **Runs:** `select status, error, count(*) from cma.sync_run where job = 'email_poll' and started_at > now() - interval '1 day' group by 1, 2;` (after `set role cma_owner;`, then `reset role;`): about 1,440 `succeeded`; a `failed` with `rate_limited` now and then is fine (the next run reads again); a run of `http_403` means a scope.
- **The nightly reconcile** after 03:30: `reconcile` rows with streams `crm_email` and `inbox_thread`, `succeeded`.
- **No content anywhere:** `select count(*) from cma.email_message where raw::text like '%@%';` and the same for `cma.email_thread`: 0 (counts only).
- **Records:** the outputs of 10.2 (blocks 1 to 3), 10.5 and 10.6 into `records/b17b-prod-<date>/` in a separate pull request, written from your report (ids, counts, dates and times only).

---

# 11. Tasks and the follow-up layer (additions 0008n and 0008o, night run N16-B)

Written in the night of 15 to 16 October 2026, before anything ran in dev or prod; the order corrected the morning after. Run in dev and prod on 16 October 2026 (`records/0008n-dev-2026-10-16`, `records/0008n-prod-2026-10-16`, `records/0008o-dev-2026-10-16` and `records/0008o-prod-2026-10-16`, written from Martin's report): 11.1's `70` twice, `72` and `02`, the merge as `c7a3cab`, the first half of 11.2 (the ingest at `c7a3cab`, its front intact, the `run.app` address 404) and 11.3 (14,689 tasks of 23 owners, the raw keys metadata only); 11.4 item 4 is not possible (HubSpot has no task page), and 11.1's read-only check, the rest of 11.4 and 11.5 are not in that record. Order: dev first (the morning runbook `docs/night-2026-10-16/MORNING_RUNBOOK.md` steps 2 to 5 and 7: the migrations with their verifies, the data map, the ingest from the branch, the backfill of tasks); then 11.1 in prod **before N16-B is merged**; then the merge and the `cma-web-main` build; then the dev hand check on the merge's image (morning runbook steps 8 and 9) and 11.2 to 11.5 from `main`. **Deferred until the upload route exists (backlog CMA-067; README, Decision log, 16 October 2026):** only the app versions and their test tasks (morning runbook step 6, the second half of 11.2). The backfill of tasks (11.3) needs only the new ingest image and the install's existing token and runs after 11.2's deploy. Until the app version a change to a task appears the next morning (the nightly reconcile, 03:30 since 17 October 2026) and a task deleted in HubSpot never arrives, so the task figures are incomplete; accepted (README, Open decisions: the task webhooks as a data prerequisite). The Terminal blocks of this phase run from the Chromebook (README, Access rules, Credentials on the local terminal). Why 11.1 comes before the merge: merging deploys `cma-web` to prod and Welcome calls 0008o's functions on every load, so a merge before `70` and `72` would show Welcome with an error until they ran (as 0008l did). Nothing here touches cloudbuild.yaml, an environment variable or a job schedule.

## 11.1 The two migrations and their verifies (before the merge)

**Terminal** (from the Chromebook; point-in-time recovery on, as before every prod migration)
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.backupConfiguration.transactionLogRetentionDays)"
```
Expected: `True	7`.

**Studio (cma-prod-pg)**, `70_crm_tasks.sql` as one script, as your own login.

Expected: `INSERT 0 1` near the end and `COMMIT`; a second run ends with `INSERT 0 0` and changes nothing.

**Studio (cma-prod-pg)**, `72_follow_up.sql` the same way, then `02_seed_pulse4all.sql` again (the four follow-up settings as seed values for both tenants).

Expected: `INSERT 0 1`, `COMMIT`; `02` ends without an error and its notices name nothing new but the settings.

`71` and `73` are dev only (they refuse a database without the dev seed), so prod gets the read-only check instead:

**Studio (cma-prod-pg)**
```sql
set role cma_owner;
select version, description from cma.schema_migration where version in ('0008n', '0008o') order by version;
select to_regclass('cma.crm_task') is not null as tasks, to_regprocedure('cma.open_tickets_of(uuid)') is not null as follow_up,
       (select string_agg(check_key, ',' order by sort_order) from cma.data_quality_follow_up_checks()) as checks;
select t.slug, s.key, s.value from cma.tenant_setting s join cma.tenant t on t.id = s.tenant_id where s.key like 'tickets.%' or s.key like 'leads.%' or s.key like 'tasks.%' order by 1, 2;
reset role;
```
Expected: two rows `0008n`, `0008o`; `true`, `true`, `ticket_no_owner,ticket_no_market,crm_task_owner_unlinked`; eight setting rows, four per tenant (`1,2,5`, `240`, `240`, `75`).

Then write `records/0008n-prod-<date>/` and `records/0008o-prod-<date>/` from what Studio showed (ids, counts, times; nothing else), as the earlier records.

## 11.2 The prod ingest from `main`, then the app with the task subscriptions (the app deferred, backlog CMA-067)

After the merge and the `cma-web-main` build. The ingest first: the task webhooks and the backfill's `--object task` need an ingest that knows tasks. `--front` stays on every prod service deploy and never goes with `--jobs`: since 16 October 2026 `deploy.sh` refuses a prod service deploy without it (exit 2, before any gcloud call), because without it the ingress would go to `all`.

**Terminal** (from the Chromebook, in `~/cma`, on `main` after the merge)
```bash
git switch -q main && git pull -q --ff-only && git log -1 --format=%h -- ingest/ && bash docs/ingest/deploy.sh prod --front ingest.pulse4all.app --tenant pulse4all-subscriptions && bash docs/ingest/deploy.sh prod --jobs
```
Expected: `main`'s ingest tag first (the squash commit's short sha); the image built once under it; `health: {"ok":true,"version":"<that tag>"}` through `https://ingest.pulse4all.app/health` and `run.app: 404 (refused)`; the jobs on the same image (`no build`), the schedules unchanged.

**Deferred until the upload route exists (backlog CMA-067): the rest of 11.2.** The ingest deploy above runs now; the app version, its install and the test task below wait for CMA-067's workflow, which uploads the app (README, Decision log, 16 October 2026). Its own runbook then replaces the upload; the install and the test task stay as written.

The project template gained nine task subscriptions (creation, deletion, `hs_task_status`, `hs_timestamp`, `hubspot_owner_id`, `hs_task_completion_date`, `hs_task_type`, `hs_task_priority`, association changes; 46 in all) and no new scope. A new app version is uploaded; the install is updated or reinstalled only when HubSpot asks or the subscriptions do not arrive. The upload runs through CMA-067's workflow from `main`, never with `hs project upload` on Martin's own terminal, whose `hs` holds the test account only (README, Access rules, Credentials on the local terminal).

Expected of the upload: build and deploy of **CMA ingest prod** succeeding, its render checked (`hubspot/verify/render.mjs`, `ALL 33 PASS`).

**Browser:** live portal → Development → Projects → CMA ingest prod → the app → Distribution → the Standard install. If HubSpot offers an update, accept it (no new scope is asked; the task subscriptions appear on the webhooks tab). If it offers no update or reinstall for this webhooks-only change, the upload is enough.

Expected: 46 subscriptions on the webhooks tab, nine of them for `task`.

**Browser:** in the live portal, create a test task on a test contact (a title only, no body); complete or delete it afterwards.

**Studio (cma-prod-pg)**, a few minutes later
```sql
set role cma_owner;
select object_type, kind, status, count(*) from cma.ingest_event where object_type = 'task' and recorded_at > now() - interval '15 minutes' group by 1, 2, 3 order by 1, 2, 3;
reset role;
```
Expected: at least one `task | created` row (`received`, or `processed` once the sweep ran; it runs every minute). If no task event arrives within minutes, the subscriptions did not reach the install: reinstall through the **Reinstall URL** on the Distribution tab, as 15 October showed for the scopes, then create another test task. Check the token afterwards: it stays; if HubSpot shows a new one on the install's row → Show, store it with `put_secret p4a-cma-prod ingest-hubspot-subs-token` (on its own line).

## 11.3 The backfill of tasks

After 11.2's ingest deploy, without its app version. The backfill needs only the new ingest image and the install's existing token: the CRM search lists the tasks and the read-back takes them with their first contact, deal and ticket, with the tasks API's `crm.objects.contacts.read` and the read scopes the app already holds (`hubspot/README.md`, no extra scope). Until the app version (CMA-067), a change to a backfilled task arrives with the nightly reconcile (03:30 since 17 October 2026), the next morning, and a task deleted in HubSpot stays (README, Open decisions).

The backfill takes the connection's id (a uuid), not its key, and `--from` with a date (without it, `intake.start_date`).

**Studio (cma-prod-pg)**
```sql
select c.id from cma.integration_connection c join cma.tenant t on t.id = c.tenant_id where t.slug = 'pulse4all-subscriptions' and c.adapter = 'hubspot' and c.status = 'active';
```
Expected: one uuid, the live portal's connection.

**Terminal** (from the Chromebook, in `~/cma`, the ingest job as in 9.8, the object `task` alone)
```bash
gcloud run jobs execute ingest-backfill --project=p4a-cma-prod --region=europe-west4 --args=--connection,<connection id>,--object,task,--from,2026-09-01 --wait
```
Expected: the job finishing with the stream `task` counted in its log; nothing about a body or a subject.

**Studio (cma-prod-pg)**
```sql
set role cma_owner;
select count(*) as tasks, count(*) filter (where source_deleted_at is null) as live, min(source_created_at)::date as first_task, count(distinct owner_ref) as owners from cma.crm_task;
select status_ref, label, is_done, count(*) over () as statuses from cma.connection_task_status order by 1;
select type_ref, label, is_callback, is_counted from cma.connection_task_type order by 1;
select string_agg(k, ', ') as raw_keys from (select distinct jsonb_object_keys(raw) as k from cma.crm_task) x;
reset role;
```
Expected: counts; every status and type the portal uses, each `is_done` false and `is_counted` true until 11.4; `raw_keys` without any body, subject, note or text key (the check on the column refuses them, so a key of that kind cannot be there).

## 11.4 The Sources settings

Items 1 and 2 need 11.3's task rows: set them after it.

**Browser:** Workspace → Configuration → Sources → the HubSpot connection:
1. Task statuses (after 11.3): tick Done for every status that means finished (HubSpot's `COMPLETED`; `DEFERRED` if the team treats it so).
2. Task types (after 11.3): tick Callback for the type the agents use for a promised call (HubSpot's `CALL` if that is the convention, or the custom type); untick Counted for internal types.
3. Pipelines: a response time for a ticket pipeline that differs from the default of 240 business minutes; leave empty for the default.
4. Settings: no `record_url_task`. Not possible (16 October 2026): HubSpot has no record page for a task (`/contacts/<portal id>/record/0-27/<task id>` answers 404; a task opens only as a preview on the task list), so Follow-up's task rows stay without a link (README, Open decisions).
5. The telephony connection: Unlinked calls check stays at its default (skip outbound calls never connected and never tagged) unless Arno wants every call checked.

**Browser:** Configuration → Exports → Follow-up: the response time, the warning share, the age groups and the callback window as Arno and Kira want them (defaults 240, 75, `1,2,5`, 240).

Expected: Reports → Follow-up shows the tickets with their response time in force, the tasks with their types and the Callback badge, and the links of leads and tickets open the records (a task row has none); Data quality lists `ticket_no_owner` and `ticket_no_market` once a response time is set.

## 11.5 Day one

**Browser:** Welcome as a supervisor (Needs attention with its five lines), as an agent (Waiting for you), the Live board (Follow-up now under the inbound tiles), Reports → Follow-up with the three filters.

**Studio (cma-prod-pg)**, the next morning
```sql
set role cma_owner;
select * from cma.follow_up_summary_of((select id from cma.tenant where slug = 'pulse4all-subscriptions'));
select check_key, count(*) from cma.data_quality_of((select id from cma.tenant where slug = 'pulse4all-subscriptions')) where check_key in ('ticket_no_owner', 'ticket_no_market', 'crm_task_owner_unlinked', 'telephony_call_unlinked') group by 1 order by 1;
reset role;
```
Expected: the eight counts as the Live board shows them (the task counts include a task deleted in HubSpot until the task webhooks, CMA-067); the four checks' counts, `telephony_call_unlinked` lower than before 0008o (the skipped outbound calls).

---

# 12. API budget (CMA-069)

Written on 18 October 2026 for night run N19-B, before anything ran in prod. On 18 October 2026 the app CMA ingest prod made 173,444 HubSpot calls in 24 hours, 17% of the portal's daily limit, which Juo, the Shopify connection and the other private apps share; almost all of it polling. After this deploy: counted forms every minute, polled-only forms every 5 minutes, the email poll's open check every 15 minutes, an idle threads walk one call, the nightly reconcile reading the polled forms' submissions as well (the safety net under both cadences), a backfill or reconcile pausing below 25% of the daily limit (never a poll; insurance, as the portal's Enterprise limit leaves ample headroom), and every job run logging its calls per endpoint (`docs/ingest/README.md`, section API budget). No migration, no schema change (the data map's descriptions of `form_submission` and `email_thread` only), no environment variable, no schedule change. N19-A's prod re-reads (contacts, `crm_email`, `inbox_thread`) wait until this runs in prod. The Terminal blocks run from the Chromebook in `~/cma`.

## 12.1 Deploy the ingest from `main`

After the merge. `--front` goes with the service deploy and never with `--jobs` (as 11.2).

**Terminal** (in `~/cma`, on `main` after the merge)
```bash
git switch -q main && git pull -q --ff-only && git log -1 --format=%h -- ingest/ && bash docs/ingest/deploy.sh prod --front ingest.pulse4all.app --tenant pulse4all-subscriptions && bash docs/ingest/deploy.sh prod --jobs
```
Expected: `main`'s ingest tag first (the squash commit's short sha); the image built once under it; `health: {"ok":true,"version":"<that tag>"}` through `https://ingest.pulse4all.app/health` and `run.app: 404 (refused)`; the jobs on the same image (`no build`), the schedules unchanged (sweep, poll-forms and poll-email every minute, reconcile at 03:30).

**Browser:** Workspace → Configuration → Sources → the HubSpot connection → Settings.

Expected: "How often this connection is read" with "Forms that count in Intake are read every minute", polled-only forms every 5 minutes, inbox conversations every 15 minutes, backfills and the nightly reconcile pausing below 25%, and the search-first box unticked. Nothing to save: these are the defaults.

## 12.2 After one hour: the calls per endpoint

**Terminal** (the jobs' log lines of the last hour; they hold counts, endpoint templates and ids of connections only)
```bash
gcloud logging read 'resource.type="cloud_run_job" AND jsonPayload.apiCalls>0' --project=p4a-cma-prod --freshness=1h --limit=20000 --format=json | node -e 'let s="";process.stdin.on("data",(d)=>{s+=d}).on("end",()=>{const e=JSON.parse(s).map((x)=>x.jsonPayload);const per={},job={};let t=0;for(const p of e){t+=p.apiCalls;job[p.message]=(job[p.message]??0)+p.apiCalls;for(const [k,v] of Object.entries(p.api??{}))per[k]=(per[k]??0)+v}console.log("lines",e.length,"calls",t,"per minute",(t/60).toFixed(1));console.log(job);console.table(Object.entries(per).sort((a,b)=>b[1]-a[1]));console.log("daily, newest line:",JSON.stringify(e[0]?.daily))})'
```
Expected: about 60 lines each of `poll-forms: connection` and `poll-email: connection`, plus `sweep: connection` lines; about 34 calls a minute when idle (28 counted forms, 4 or 5 polled-only forms, one engagements search, one threads call) plus the sweep's read-backs of webhook events; the endpoint table led by `GET /form-integrations/v1/submissions/forms/{id}`, with `GET /conversations/v3/conversations/threads` near 60 in the hour. The last line answers the headers question: `{"limit":…,"remaining":…}` means HubSpot sends its daily-limit headers to the app and the floor guard works; `"not_received"` means it does not and the guard never pauses. Either way nothing else changes: the guard is insurance (README, Decision log, 18 October 2026); report which it is.

## 12.3 The next day: HubSpot's own count

**Browser:** live portal → Development → Monitoring → the app **CMA ingest prod** → API calls, the last 24 hours.

Expected: under 60,000 a day (the polls about 50,000 at about 34 a minute; the rest the webhooks' read-backs, the hourly catalogs and the nightly reconcile, which now reads the polled forms too, about 50 calls), against 173,444 on 18 October 2026. If it is higher, 12.2's endpoint table shows where the calls go.

## 12.4 The morning after the first night: the same result

The proof that the slower cadences miss nothing. The nightly reconcile reads every polled form's submissions and every email engagement and inbox thread of the last 26 hours and writes only what the polls did not (a form's submissions since 18 October 2026, backlog CMA-069), so its written count is what the polls missed.

**Studio (cma-prod-pg)** (the last night's reconcile of the three objects next to their polls over the same 26 hours; counts only)
```sql
set role cma_owner;
with rec as (
  select r.tenant_id, r.connection_id, r.stream, r.status, r.error, r.from_at, r.to_at, r.counts,
         case when r.stream = 'form_submission' then 'forms_poll' else 'email_poll' end as poll_job
  from cma.sync_run r join cma.tenant t on t.id = r.tenant_id
  where t.slug = 'pulse4all-subscriptions' and r.job = 'reconcile' and r.stream in ('form_submission', 'crm_email', 'inbox_thread')
    and r.started_at > now() - interval '20 hours')
select rec.stream, rec.status, rec.error, rec.from_at, rec.to_at,
       rec.counts ->> 'fetched' as reconcile_fetched, rec.counts ->> 'upserted' as reconcile_written, rec.counts ->> 'skipped' as reconcile_unchanged,
       rec.poll_job,
       (select count(*) from cma.sync_run p where p.tenant_id = rec.tenant_id and p.connection_id = rec.connection_id and p.job = rec.poll_job
          and p.started_at between rec.from_at and rec.to_at) as poll_runs,
       (select coalesce(sum((p.counts ->> 'upserted')::int), 0) from cma.sync_run p where p.tenant_id = rec.tenant_id and p.connection_id = rec.connection_id
          and p.job = rec.poll_job and p.started_at between rec.from_at and rec.to_at) as poll_written
from rec order by rec.stream;
reset role;
```
Expected: three rows, `crm_email`, `form_submission` and `inbox_thread`, each `succeeded` with no error (or `daily_floor`: the floor paused it, see 12.2's reading); `reconcile_written` 0, or at most a handful (a submission, message or change that arrived during the reconcile itself); for `form_submission` `reconcile_unchanged` equal to `reconcile_fetched` less what it wrote (every submission of the window it already held); `poll_runs` about 1,560 (26 hours of minutes); `poll_written` the polls' own writes over the window, the same on the two email rows (one email poll serves both objects), in the hundreds or more.

## 12.5 When 12.4 is higher

**Browser:** Workspace → Configuration → Sources → the HubSpot connection → Settings → How often this connection is read: set "Forms that don't count in Intake are read every" to `1` and "Inbox conversations closed or reassigned without a new message are checked every" to `1`, each saved with Enter. No deploy: the jobs read the settings every minute.

Expected: "Saved" after each; the settings table below lists `forms_poll_interval_minutes` 1 and `email_open_check_minutes` 1; from the next minute every polled form is read every minute again and the open check runs every minute. Report 12.4's counts (the rows as Studio showed them, no ids) for the follow-up.

---

# 13. Trusted Shops reviews in prod (brief B18, addition 0008ze)

The brief asked for "phase 10", but phase 10 is the email poll: the Trusted Shops reviews are phase 13, after phase 12. Written on 25 October 2026 (PR #192), before anything ran in dev or prod. The reviews of Pulse4all Subscriptions' Trusted Shops account, read through the eTrusted API into `cma.review_channel` and `cma.review` (`docs/ingest/README.md`, section Trusted Shops; `docs/architecture/data-model/0008.md`, Data model: reviews): read only, metadata only, never the reviewer's name, email or phone, nor a review's title or text. Order: the migration in dev with its verifies, the data map's snapshot and the migration in prod, all three before the merge (13.1 to 13.3); then the merge, the existing API client's secret, the ingest from `main` with its jobs, the connection and its settings, the first poll, the channels' markets, the backfill with its check against the Control Centre, day one (13.4 to 13.11). The ingest is deployed before the connection exists, so no job of an older image meets a connection of an adapter it does not know. The Studio blocks that call a function carry the context block's second part (as 9.6); `<tenant_id>` and `<user_id>` come from its first part. `<hubspot conn>` is the live portal's HubSpot connection (7.3), `<reviews conn>` the connection of 13.7. The Terminal blocks of this phase run from the Chromebook, in `~/cma`. 13.12 (brief B18.1, addition 0008zf) is the reference guard: dev and prod before the merge of its own pull request, the new ingest image straight after it.

**To confirm on the live account.** The adapter follows the prod discovery of 25 October 2026 and the developer reference as far as it could be read. The page size 100 (`count`) and the cursor field of the reviews' paging (`after`: the answer's cursor, else the last review's id) are confirmed in practice on 25 October 2026 (845 reviews, 7 channels, 60 requests a minute, no 429). Still to confirm: `ignoreStatements=false` (asks for the star-only reviews; setting `etrusted_include_statements`) and the rate limits (not documented: the adapter paces itself at `etrusted_max_per_minute`, default 60). A first poll or backfill that fails with `http_<status>` on `/reviews` points at one of them: report the code, never a body.

**Data prerequisites** (the counts mean nothing without them):
- The reviews' transaction reference names the shop's order (an order name, else the order's id) for the order link. A review without one links to a CRM contact by the reviewer's email, else to nothing.
- The HubSpot connection is the CRM the contacts are looked up in (`crm_connection_id`). Its daily floor (`api_daily_floor_pct`, default 25) pauses the reconcile and the backfill's lookups, never the poll.
- Every channel is given its market and switched on (13.9); a channel that is not switched on does not count.
- The alert rule Negative review stays off until Kira decides (13.11).

## 13.1 The migration in dev and its verifies (before the merge)

**File:** `db/104_reviews.sql`: open it and copy all of it. **Studio (cma-dev-pg):** paste the whole script and Run, as your own login.

Expected: no error. Studio lists only the results that return rows, so `104` ends with two `setup_tenant_table` results and no error. A second run ends the same and changes nothing. `addition 0008zd (102_tag_meaning_incorrect_data.sql) must run before 0008ze` means dev lacks 0008zd: run `docs/definitions-2026-10/RUNBOOK-0008zd.md` first.

**File:** `db/02_seed_pulse4all.sql`: copy all of it. **Studio (cma-dev-pg):** paste and Run (the seed adds the alert rule Negative review, which needs `104`).

Expected: no error. Studio shows no notices, so the next block checks the rule.

**Studio (cma-dev-pg)** (read only)
```sql
set role cma_owner;
select version from cma.schema_migration where version = '0008ze';
select t.slug, r.name, r.trigger, r.enabled, r.max_rating, r.audience_permission, r.max_age_minutes
from cma.message_rule r join cma.tenant t on t.id = r.tenant_id
where r.trigger = 'review_submitted' order by 1;
reset role;
```
Expected: `0008ze`, then one rule: `pulse4all-subscriptions | Negative review | review_submitted | false | 2.00 | performance.team | 1440`.

**File:** `db/105_verify_reviews.sql`: copy all of it. **Studio (cma-dev-pg):** paste and Run. Open the results dropdown at the verdict table.

Expected: rows `A1` to `A8`, `B1` to `B18` and `C1`, each `PASS`, and `verdict | PASS | 105_verify_reviews: 27 PASS, 0 FAIL` (locally, on PostgreSQL 16 built from `00` to `105` with the seeds, the same). `REFUSED: not dev` means the instance is not dev's. C1 names the page's milliseconds, under 1000; dev's shared core may fail C1 on time alone: report the row. Any other `FAIL`: report the row.

**Studio (cma-dev-pg):** `105` again, provoked: paste the script, press Ctrl+F, search `'verify.provoke', 'false'` and change only that `false` to `true`. Run. Result 1 in the dropdown must read `true`.

Expected: every row `FAIL`, `verdict | PROVOKED, NOT A PASS | 105_verify_reviews: 0 PASS, 27 FAIL`. Blocks B and C roll back.

**Studio (cma-dev-pg):** the earlier verifies again, each pasted whole and Run: `103`, `101`, `79`, `75` and `41`.

Expected, each as it passed before this change: `103` 12 PASS, `101` 18 PASS, `79` 13 PASS, `75` 24 PASS, `41` both tenant rows PASS.

`99` builds a volume tenant, so it runs from the Terminal:

**Terminal** (in `~/cma`, on the branch)
```bash
cma_db dev && time psql "$PGCONN" -X -v ON_ERROR_STOP=1 -f db/99_verify_funnel.sql > /tmp/99.txt 2>&1; grep -E "^ *(A|B|C)[0-9]+ |verdict" /tmp/99.txt | cut -c1-160
```
Expected: rows `A1` to `A8`, `B1` to `B23` and `C1` to `C2`, each `PASS`; `verdict | PASS | 33 PASS, 0 FAIL`.

## 13.2 The data map (before the merge)

`docs/datamap/catalog.json` describes the two new tables, the five computed views and the flow `trustedshops`; `verify:datamap` fails on this branch until the snapshot is refreshed from dev, as `docs/datamap/README.md` (Refreshing the snapshot) says. Martin refreshes `docs/datamap/schema.json` from dev on this branch after running the migration there (13.1), before merging.

**Terminal** (in `~/cma`, on this branch; the `cma_db` route works without the proxy)
```bash
cma_db dev && psql "$PGCONN" -X -qAt -v ON_ERROR_STOP=1 -f tools/datamap/schema.sql > docs/datamap/schema.json
```
Expected: nothing printed; `docs/datamap/schema.json` holds `"latest_migration" : "0008ze"` (spaces around the colon).

**Terminal** (`~/cma`)
```bash
node tools/datamap/build.mjs && node tools/datamap/build.mjs --check
```
Expected: `datamap: wrote docs/datamap/index.html (<n> tables, <m> views)`, then `datamap: <n> tables, <m> views, all described; index.html current`. A problem list instead names what the catalog lacks.

**Terminal** (`~/cma`)
```bash
git add docs/datamap && git commit -m "Data map: snapshot after 0008ze" && git push origin HEAD:<branch>
```
Expected: the push of the local branch names `<branch>`; the PR now passes `verify:datamap`. After the merge: in the Claude project, say "republish the data map".

## 13.3 The migration in prod (before the merge)

`main`'s web before this change reads nothing `104` adds, so prod runs it before the merge; the web of this change needs it. `105` refuses a database without the dev seed, so prod gets a read-only check instead.

**Terminal** (point-in-time recovery on, as before every prod migration)
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.backupConfiguration.transactionLogRetentionDays)"
```
Expected: `True	7`.

**Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select version from cma.schema_migration where version >= '0008zc' order by 1;
reset role;
```
Expected: `0008zc` and `0008zd`. Without `0008zd`, run `docs/definitions-2026-10/RUNBOOK-0008zd.md` first; with `0008ze` already there, stop and report it.

**Studio (cma-prod-pg):** `db/104_reviews.sql` as one script, as your own login.

Expected: no error. Studio lists only the results that return rows, so `104` ends with two `setup_tenant_table` results and no error. A second run ends the same and changes nothing.

**Studio (cma-prod-pg):** `db/02_seed_pulse4all.sql` again (the rule Negative review, switched off, only where missing).

Expected: no error, and nothing else changes.

**Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select version from cma.schema_migration where version = '0008ze';
select to_regclass('cma.review') is not null as reviews, to_regclass('cma.review_channel') is not null as channels,
       to_regprocedure('cma.reviews_page(date,date,text,text)') is not null as page;
select t.slug, r.name, r.trigger, r.enabled from cma.message_rule r join cma.tenant t on t.id = r.tenant_id
where r.trigger = 'review_submitted' order by 1;
reset role;
```
Expected: `0008ze`; `true | true | true`; one rule `pulse4all-subscriptions | Negative review | review_submitted | false`.

## 13.4 The merge

**Browser:** Martin reviews and squash-merges PR #192 on GitHub (13.1 to 13.3 done). The merge touches `web/`, so Cloud Build trigger `cma-web-main` builds and deploys the web to prod.

Expected: the build ends `SUCCESS`; Workspace → Reports → **Reviews** opens and says `No review platform is set up yet, so there are no reviews to show.`

## 13.5 The API client and its secret

The API client exists: Martin created it on 25 October 2026 during the discovery, in the eTrusted Control Centre → Settings → SSO-clientbeheer (the Dutch interface's name for API client management): name `CMA prod ingest`, identifier `CMAprodIngest`, client id `<prefix>__CMAprodIngest`. It took the account's last free client slot (5 of 5): do not create another one. An eTrusted API client has no scopes, so this one can read and write (invites, replies, vetoes); the adapter only reads, and only `cma-ingest` can read the secret from Secret Manager (the accessor of 13.6). The client id is not a secret: it goes into the connection's settings in 13.7, never into the repository.

**Browser:** eTrusted Control Centre → Settings → SSO-clientbeheer → the row `CMA prod ingest` → the arrow → **Tonen**. Keep the page open until the next block is done. Note the client id for 13.7; the account id is its prefix before `__`, because eTrusted shows no separate account id (13.7).

Expected: the row with identifier `CMAprodIngest` and client id `<prefix>__CMAprodIngest`; **Tonen** shows the secret (it can be shown again at any time, not only once).

`put_secret` must be defined first: it is the function block under Before you start, at the top of this runbook before 7.1 (`type put_secret` prints it; a new terminal session needs it defined again). The secret is pasted only at its hidden prompt, never as an argument of a command.

**Terminal** (on its own line; the value is the client's secret)
```bash
put_secret p4a-cma-prod ingest-trustedshops-subs-token
```
Expected: the hidden prompt; paste, Enter; `stored ingest-trustedshops-subs-token (version added)`. Then close the Control Centre page. The client id is not a secret: it goes into the connection's settings (13.7). A connection setting never holds the secret, and the connection's settings refuse a key that contains "secret": the connection reaches it only by its name, the access secret name of 13.7.

**Rotating the secret** when it was exposed, for example typed into a terminal command (the first one of the prod run was). The ingest reads the secret's `latest` version, so no redeploy is needed.

**Browser:** eTrusted Control Centre → Settings → SSO-clientbeheer → the row `CMA prod ingest`: a new secret on the client's row. Keep the page open until the next block is done.

Expected: **Tonen** shows the new secret.

**Terminal** (on its own line)
```bash
put_secret p4a-cma-prod ingest-trustedshops-subs-token
```
Expected: the hidden prompt; paste the new secret, Enter; `stored ingest-trustedshops-subs-token (version added)`: a new version is added (version 2 at the first rotation).

**Terminal**
```bash
gcloud secrets versions list ingest-trustedshops-subs-token --project=p4a-cma-prod
```
Expected: the new version and the old one, both `enabled`; the old one is the number before the new (1 at the first rotation).

**Terminal**
```bash
gcloud secrets versions destroy <old version> --secret=ingest-trustedshops-subs-token --project=p4a-cma-prod
```
Expected: a `Y/n` prompt; after `Y`, `Destroyed version [<old version>] of the secret [ingest-trustedshops-subs-token].` The list of the previous block now shows the old version `destroyed` and the new one `enabled`.

## 13.6 The ingest from `main`: the service and the jobs

`--front` goes with the service deploy and never with `--jobs` (as 11.2 and 12.1). The service deploy grants the accessor on the new secret and answers `404` on `/trustedshops/<key>` (the adapter has no route); the jobs deploy adds `ingest-poll-reviews`.

**Terminal** (in `~/cma`, on `main` after the merge)
```bash
git switch -q main && git pull -q --ff-only && git log -1 --format=%h -- ingest/ && bash docs/ingest/deploy.sh prod --front ingest.pulse4all.app --tenant pulse4all-subscriptions --secret ingest-trustedshops-subs-token && bash docs/ingest/deploy.sh prod --jobs
```
Expected: `main`'s ingest tag first (the squash commit's short sha); the image built once under it; `accessor on ingest-trustedshops-subs-token`; `health: {"ok":true,"version":"<that tag>"}` through `https://ingest.pulse4all.app/health` and `run.app: 404 (refused)`; then the jobs on the same image (`no build`): seven job deploys, `schedule ingest-poll-reviews: 7 * * * * (Europe/Amsterdam)` next to the others, the sweep, `ingest-poll-forms` and `ingest-poll-email` every minute, `ingest-reconcile` at 03:30.

## 13.7 The connection and its settings

**Studio (cma-prod-pg)** in one Run (`<eTrusted account id>`: the client id's prefix, before `__`; eTrusted shows no separate account id, and prod used `9b3bfe12ca88`, as the record says)
```sql
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'studio:martin', false);
select * from cma.upsert_connection('trustedshops', 'Trusted Shops Subscriptions', '<eTrusted account id>',
                                    null, 'ingest-trustedshops-subs-token');
reset role;
```
Expected: one row of three values, then one row with `connection_id` (`<reviews conn>`) and `key`. There is no signing secret (the adapter has no route), so the fourth argument is null; the fifth is the connection's access secret name. The key is not used.

**Studio (cma-prod-pg)** in one Run (the kind and the settings; the client id `<prefix>__CMAprodIngest` from 13.5)
```sql
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'studio:martin', false);
select cma.set_connection_kind('<reviews conn>', 'reviews');
select cma.set_connection_settings('<reviews conn>',
  coalesce((select settings from cma.integration_connection where id = '<reviews conn>'), '{}'::jsonb)
  || '{"client_id": "<client id from 13.5>", "crm_connection_id": "<hubspot conn>"}'::jsonb);
select name, adapter, external_account_id, kind, status, signing_secret_name, token_secret_name
from cma.sources() where connection_id = '<reviews conn>';
reset role;
```
Expected: one row of three values, two empty results, then one row: `Trusted Shops Subscriptions`, `trustedshops`, the account id, `reviews`, `active`, an empty signing secret name, `ingest-trustedshops-subs-token`. `crm_connection_id` names the HubSpot connection whose contacts a review's email is looked up in; the match stays in the CMA (nothing is written to HubSpot or to eTrusted).

The other connection settings keep their defaults (`reviews_poll_interval_minutes` 60, `reviews_reconcile_days` 30, `etrusted_max_per_minute` 60, `etrusted_include_statements` true; `docs/ingest/README.md`, section Trusted Shops). They can be changed without a deploy.

**Browser:** `https://workspace.pulse4all.app/configuration/sources` → **Trusted Shops Subscriptions**.

Expected: the connection with kind Reviews, the secret name (name only) and the Review channels section saying `No channels read yet. They arrive with the next hourly read.` Setting `record_url_review` (Settings → Add setting; `{id}` is a review's id, `{account}` the account id, and the page previews the link) is for later, when the address of a review in the Control Centre is confirmed: until then an alert holds no link.

## 13.8 The first poll

**Terminal** (now, or wait for minute 7 of the next hour; an execution that finds one running logs `poll-reviews skipped` and exits 0)
```bash
gcloud run jobs execute ingest-poll-reviews --project=p4a-cma-prod --region=europe-west4 --wait
```
Expected: `Execution [ingest-poll-reviews-…] has successfully completed.`

**Studio (cma-prod-pg)** (read only; counts and ids only)
```sql
set role cma_owner;
select job, stream, status, counts, error, started_at, finished_at from cma.sync_run
where connection_id = '<reviews conn>' order by started_at desc limit 5;
select source_id, name, locale, market, is_counted, source_deleted_at from cma.review_channel
where connection_id = '<reviews conn>' order by name;
select count(*) as reviews, count(*) filter (where is_published) as published, min(submitted_at), max(submitted_at)
from cma.review where connection_id = '<reviews conn>';
select link_level, count(*) from cma.review where connection_id = '<reviews conn>' group by 1 order by 1;
reset role;
```
Expected: a `reviews_poll` row `succeeded`, stream `reviews`, with `fetched` and `upserted` counts (the first poll reads the last 30 days of every channel); the account's channels (seven in the discovery of 25 October 2026), each with an empty `market`, `is_counted` false and no `source_deleted_at`; reviews stored with `submitted_at` inside the last 30 days; link levels `order`, `contact` and `none` (a contact only where the reviewer's email found exactly one HubSpot contact). No alert is raised: no channel counts yet and the rule is off. A `failed` row names the cause: `client_id_not_set` (13.7's setting), `client_secret_unavailable` (the secret or its accessor, 13.5 and 13.6), `token_http_<status>` (a client id or secret of another client), `rate_limited` (resolves on the next run), `http_<status>` on the reviews call (the parameters to confirm, above).

**Browser:** Workspace → Reports → **Data quality**.

Expected: `Review channels without a market` lists the channels with the reviews held of each, and `Active markets without a review channel` lists every active market: both checks appear once the tenant has a reviews connection.

## 13.9 The channels: market and counted

**Browser:** Configuration → Sources → **Trusted Shops Subscriptions** → Review channels: per channel choose the market its reviews count for and switch **Counted** on. Leave off the channels of another business line and test channels (their reviews stay stored either way). Below, the review settings: the threshold for a negative review (default: rated 2 or lower) and the history start date (default empty: the backfill reads all history; leave it empty for 13.10).

Expected: each change saved and still there after a reload; the `New, choose a market` badge gone from every channel you mapped. A channel switched on without a market counts under the market `unknown`: give every counted channel its market. Reports → Data quality: `Review channels without a market` at 0 for the mapped channels; a market with no Trusted Shops channel stays listed under `Active markets without a review channel` (a decision for Kira, not a fault).

The fallback in **Studio (cma-prod-pg)**, one statement per channel:
```sql
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'studio:martin', false);
select cma.set_review_channel('<reviews conn>', '<channel id>', '<market code>', true);
reset role;
```
Expected: one row of three values, then an empty result. An unknown channel id is refused (`no review channel … in connection …`).

## 13.10 The backfill and the check against the Control Centre

After the channels are mapped: one full backfill without `--from`, then check Reports → Reviews against the totals per channel in the eTrusted Control Centre.

**Terminal** (`<reviews conn>` from 13.7)
```bash
gcloud run jobs execute ingest-backfill --project=p4a-cma-prod --region=europe-west4 --wait --args=--connection,<reviews conn>,--object,review
```
Expected: `Execution [ingest-backfill-…] has successfully completed.` Without `--from` and with `reviews.history_start_date` empty the run reads all history: per channel in id order, a year at a time from 1 January 2000, at `etrusted_max_per_minute` (default 60 requests a minute), so at least one request per channel and year (about 190 for seven channels, three minutes at the default pace) plus one per hundred reviews. The HubSpot contact lookups dominate the time: about 9 minutes for 845 reviews in prod. A failed execution is run again with the same arguments: it continues from the cursor `backfill:review`. A run that paused below the CRM's daily floor finishes as succeeded with the error `daily_floor`: run the same command later. A finished backfill with the same start reads nothing again; `--again` walks it again and stores nothing new.

**Terminal** (the summary line per channel; ids, counts and times only)
```bash
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="ingest-backfill" AND jsonPayload.message="backfill: review channel"' --project=p4a-cma-prod --freshness=3h --limit=20 --format='value(jsonPayload.channel,jsonPayload.read,jsonPayload.stored,jsonPayload.held,jsonPayload.linkedOrder,jsonPayload.linkedContact,jsonPayload.unlinked,jsonPayload.oldestSubmittedAt,jsonPayload.newestSubmittedAt)'
```
Expected: one line per channel: the reviews read and stored in this run, what it holds, its link levels and its oldest and newest submission.

**Studio (cma-prod-pg)** (read only; per channel)
```sql
set role cma_owner;
select ch.name, ch.market, ch.is_counted, count(r.id) as reviews, count(r.id) filter (where r.is_published) as published,
       min(r.submitted_at)::date as oldest, max(r.submitted_at)::date as newest
from cma.review_channel ch
left join cma.review r on r.tenant_id = ch.tenant_id and r.review_channel_id = ch.id
where ch.connection_id = '<reviews conn>'
group by ch.name, ch.market, ch.is_counted order by ch.name;
reset role;
```
Expected: per channel `reviews` and `published`, `oldest` the channel's first review.

**Browser:** the eTrusted Control Centre: per channel, the number of reviews (the total, and the same for the last 92 days); then Workspace → Reports → **Reviews**, period the last 92 days, the card Per review channel.

Expected: per channel the Control Centre's total counts the states APPROVED and MODERATION and leaves out REJECTED (`docs/ingest/README.md`, Trusted Shops), so it is the Studio row's `published` plus the reviews in moderation, not its `reviews` (which holds the rejected ones too), and its last 92 days equal the report's count for the channel plus the reviews in moderation; the report counts published reviews of counted channels only, by the day they were submitted in the Amsterdam zone. A channel that differs is the finding of this step: report the channel, both numbers and the oldest date of each (a missing statements-only review points at `ignoreStatements`, still to confirm, above; a missing tail at the paging). The pages of the whole history are Studio's: a report page covers at most 92 days.

## 13.11 Day one

- **Runs:** **Studio (cma-prod-pg)**, after `set role cma_owner;` and then `reset role;`: `select status, error, count(*) from cma.sync_run where job = 'reviews_poll' and started_at > now() - interval '1 day' group by 1, 2;`. Expected: about 24 `succeeded` (hourly at minute 7); a `failed` with `rate_limited` now and then is fine (the next run carries on); a run of `token_http_<status>` or `http_403` means the client.
- **The nightly reconcile** after 03:30: `reconcile` rows with stream `review`, `succeeded` (or `daily_floor`: the CRM's floor paused the contact lookups; the next night's run reads the window again).
- **Reports → Reviews** as Kira and Arno will read it: the period bar, the market filter, the per market and per channel cards, the link levels, the invite events and the card Markets and review channels.
- **No personal data:** **Studio (cma-prod-pg)**, after `set role cma_owner;` and then `reset role;`: `select count(*) from cma.review where raw::text like '%@%';`. Expected: 0 (counts only).
- **Reports → Data quality:** `Review channels without a market` at 0; `Active markets without a review channel` lists the markets Trusted Shops does not serve.
- **The alert rule:** **Browser:** Configuration → Alert rules: `Negative review` is listed and switched off. It stays off until Kira decides the threshold (the review settings on Configuration → Sources: rated 2 or lower by default) and the audience (seeded: the holders of `performance.team`, no language or clocked-in condition, no fallback, reviews at most a day old; `docs/open-decisions.md`). A rule's name and trigger cannot be changed once it exists. Once it is on, a published review of a counted channel at or below the threshold alerts within the hour (title `New review`: market, channel, rating, time, and the link when `record_url_review` is set; never the review's text or the reviewer).
- **Records:** the outputs of 13.3 and 13.5 to 13.10 into `records/reviews-prod-<date>/`, in a separate pull request, written from your report (ids, counts, dates and times only; no key, secret or personal data), and the eTrusted parameters confirmed or corrected (page size, cursor field, `ignoreStatements`, rate limits).

## 13.12 The reference guard (addition 0008zf, brief B18.1)

In prod one of the 845 reviews of the first backfill held an email address as its transaction reference (a manual invite without an event type). `db/106_review_reference_guard.sql` removes it from the review and from that review's audit rows, and has the database refuse an @ from now on; the new ingest image keeps a reference only when it fits the connection's pattern and holds no @ (`docs/ingest/README.md`, section Trusted Shops; `docs/architecture/data-model/0008.md`, Data model: review reference guard). Order: dev and the data map's snapshot, then prod, all before the merge; then the merge and, straight after it, the new ingest image. Prod runs `106` before the merge because the new image finishes runs with the count `ref_dropped`, which only `106`'s `cma.ingest_sync_run_finish()` accepts. The image follows the merge at once because until then the old image fails a run whose batch holds an @ reference (nothing of that batch is stored): a new review with one in the hourly poll, or the 2024 review read again by a backfill or by a long reconcile.

**(a) Dev, before the merge**

**File:** `db/106_review_reference_guard.sql`: open it and copy all of it. **Studio (cma-dev-pg):** paste the whole script and Run, as your own login.

Expected: no error and one result row `reviews_cleared 0 | audit_rows_scrubbed 0` in dev. A second run ends the same. `addition 0008ze (104_reviews.sql) must run before 0008zf` means dev lacks 0008ze: run 13.1 first.

**File:** `db/107_verify_review_reference_guard.sql`: copy all of it. **Studio (cma-dev-pg):** paste and Run. Open the results dropdown at the verdict table.

Expected: rows `A1` to `A4` and `B1` to `B6`, each `PASS`, and `verdict | PASS | 107_verify_review_reference_guard: 10 PASS, 0 FAIL`. `REFUSED: the connected database is not dev` means the instance is not dev's. Any `FAIL`: report the row.

**Studio (cma-dev-pg):** `107` again, provoked: paste the script, press Ctrl+F, search `'verify.provoke', 'false'` and change only that `false` to `true`. Run.

Expected: every row `FAIL`, `verdict | PROVOKED, NOT A PASS | 107_verify_review_reference_guard: 0 PASS, 10 FAIL`.

**Studio (cma-dev-pg):** the earlier verifies again, each pasted whole and Run: `105`, `77`, `75`, `67` and `33`.

Expected, each as it passed before this change: `105` 27 PASS, `75` 24 PASS, `77`, `67` and `33` passing.

**(b) The data map, before the merge**

No table, view or column changes, so `docs/datamap/schema.json` only moves its `latest_migration`; `verify:datamap` fails on this branch until Martin refreshes it from dev after running the migration there, as in 13.2.

**Terminal** (in `~/cma`, on this branch)
```bash
cma_db dev && psql "$PGCONN" -X -qAt -v ON_ERROR_STOP=1 -f tools/datamap/schema.sql > docs/datamap/schema.json
```
Expected: nothing printed; `docs/datamap/schema.json` holds `"latest_migration" : "0008zf"` (spaces around the colon).

**Terminal** (`~/cma`)
```bash
node tools/datamap/build.mjs && node tools/datamap/build.mjs --check
```
Expected: `datamap: wrote docs/datamap/index.html (<n> tables, <m> views)`, then `datamap: <n> tables, <m> views, all described; index.html current`.

**Terminal** (`~/cma`)
```bash
git add docs/datamap && git commit -m "Data map: snapshot after 0008zf" && git push origin HEAD:<branch>
```
Expected: the push of the local branch names `<branch>`; the PR now passes `verify:datamap`. After merge: in the Claude project, say "republish the data map" (when `docs/datamap/index.html` changed).

**(c) Prod, before the merge**

**Terminal** (point-in-time recovery on, as 13.3)
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.backupConfiguration.transactionLogRetentionDays)"
```
Expected: `True	7`.

**Studio (cma-prod-pg):** `db/106_review_reference_guard.sql` as one script, as your own login.

Expected on the first run: no error and one result row `reviews_cleared 1 | audit_rows_scrubbed <n>`, where `<n>` is the number of that review's audit rows (at least 1). A second run: `reviews_cleared 0 | audit_rows_scrubbed 0`.

**Studio (cma-prod-pg)** (read only; counts only)
```sql
set role cma_owner;
select count(*) from cma.review where raw::text like '%@%' or coalesce(transaction_ref, '') like '%@%';
select count(*) from cma.audit_log where table_name = 'review' and (coalesce(old_row::text, '') like '%@%' or coalesce(new_row::text, '') like '%@%');
select version from cma.schema_migration where version = '0008zf';
reset role;
```
Expected: `0`, then `0`, then `0008zf`.

**(d) The merge**

**Browser:** Martin reviews and squash-merges PR #193 on GitHub ((a) to (c) done). A merge that touches `web/` or `cloudbuild.yaml` builds and deploys prod's web through Cloud Build trigger `cma-web-main`; the ingest is not built by it, so the next step follows at once.

Expected: the PR shows merged.

**(e) The ingest from `main`, straight after the merge**

**Terminal** (in `~/cma`, on `main` after the merge; as 13.6)
```bash
git switch -q main && git pull -q --ff-only && git log -1 --format=%h -- ingest/ && bash docs/ingest/deploy.sh prod --front ingest.pulse4all.app --tenant pulse4all-subscriptions --secret ingest-trustedshops-subs-token && bash docs/ingest/deploy.sh prod --jobs
```
Expected: as 13.6: `main`'s ingest tag first; the image built once under it; `health: {"ok":true,"version":"<that tag>"}` through `https://ingest.pulse4all.app/health` and `run.app: 404 (refused)`; then the jobs on the same image (`no build`).

**(f) The next poll**

**Studio (cma-prod-pg)** (read only; after the next poll at minute 7; `<reviews conn>` from 13.7)
```sql
set role cma_owner;
select job, stream, status, counts, error, started_at, finished_at from cma.sync_run
where connection_id = '<reviews conn>' and job = 'reviews_poll' order by started_at desc limit 3;
reset role;
```
Expected: the latest `reviews_poll` run `succeeded`, with its `fetched` and `upserted` counts. `ref_dropped` appears among the counts only when a reference was left out; the reference itself is never stored or logged.

**Note.** Backups and point-in-time recovery keep the old value until their retention runs out, and an extract taken through `cma_read.review` between the backfill and `106` still holds it.

---

# 14. The asset register's API sync in prod (addition 0008zj)

Written on 27 October 2026 for 0008zj; Before 14.1 also carries 0008zk, written the same day and revised on 28 October (the mapping by field id, no view, the final step in slices). The ingest reads the asset register of Pulse4all Subscriptions (the Airtable base "Airtable 2.0", base `appsEV7MhflMLd2Xv`, table "2.0 Installed Base" `tblHVsCkAwJLqZOgu`) through the Airtable Web API: the records changed every 15 minutes (`ingest-poll-assets`) and a full snapshot nightly (`ingest-reconcile`), loaded through 0008zi's load into `cma.device` and `cma.device_component`, in chunks of `assets_load_chunk` rows since addition 0008zk (`docs/ingest/README.md`, section Airtable; `docs/architecture/data-model/0008.md`, Data model: asset sync and Data model: asset sync load). Read only: nothing is written to Airtable. The CSV import (`docs/import/devices.md`) stays as the fallback. Order: the migrations in dev with their verifies, the data map and the migrations in prod, all before the merge, then the merge (Before 14.1); then the service account and its token in Airtable, the secret and the ingest from `main` (14.1 to 14.3), the connection and its settings (14.4), its fields by id from a first dry run (14.5), the dry run and the first full read (14.6, 14.7), the schedule (14.8); then the token's rotation every 180 days (14.9). Do 14.4 to 14.7 in one sitting, before 03:30: from 14.4 on the nightly reconcile reads the register too. The Studio blocks that call a function carry the context block's second chunk (as 9.6); `<tenant_id>` and `<user_id>` come from its first chunk. `<assets conn>` is the register's connection of 0008zi (`records/0008zi-prod-2026-10-27`), whose id 14.4 shows again. The Terminal blocks run in `~/cma`.

**Data prerequisites:**
- An Airtable service account (Enterprise Scale) with read-only access to the one base, and its personal access token with the scopes `data.records:read` and `schema.bases:read` (14.1, 14.2).
- The map file's headers (`docs/import/devices-map.example.json`) named as the base names them on the day of 14.5: the mapping is generated from them once, by name, and held by field id from then on, so a later rename changes nothing; a deleted field (`unknown_field`) or a changed type (`field_type_changed`) fails every read, naming the field, until it is mapped again (14.8).
- The catalogs of 0008zi (seed `02`): models, component kinds, statuses, the market aliases.

## Before 14.1: the migrations, the data map, the merge

Two additions: 0008zj (`114`, the asset sync) and 0008zk (`116`, the load set-based, in chunks and slices, and the forecast at 50,000 devices; `117` its verify). `114` runs where `0008zj` is missing; 27 October 2026 it ran in dev and prod, and prod's `115` failed C1 on time alone (a one-call snapshot of 5,000 records), which `116` answers. The first `116` and `117` ran in dev on 27 October (`records/0008zk-dev-2026-10-27`): the load was about twice as fast, but `117` did its work in one transaction, failed C3 and C4, and its provoked rerun lost the server's connection. Both were edited in place (CLAUDE.md forbids editing a script that has run in prod; these ran in dev only) and run again in dev below. `117` now mirrors production: every chunk, slice and measurement its own transaction, its throwaway tenants removed at the start and the end. `117` runs in dev (and local databases) only, never in prod (Decision log, 28 October 2026): it removes its throwaway tenants with their audit rows, which the rule of 17 October 2026 allows in dev and local databases only, and prod's audit log stays append-only; it refuses a database without the dev seed. Prod's speed check is 14.7's first full read of the real register. Every step below says which database it reads.

**(a) Dev.** **Studio (cma-dev-pg)** (read only)
```sql
set role cma_owner;
select version from cma.schema_migration where version >= '0008zi' order by 1;
select pg_postmaster_start_time();
select count(*) as assets_with_view_id from cma.integration_connection c where c.settings ? 'view_id'
  and (c.kind = 'assets' or (c.kind is null and 'assets' = any (cma.connection_held_kinds_of(c.tenant_id, c.id))));
select slug from cma.tenant where slug like 'verify-0008zk-%' order by 1;
reset role;
```
Expected: `0008zi`, `0008zj` and `0008zk`, then the server's start time: note it; then `assets_with_view_id`, which `116` sets to 0 (report a number above 0: those connections are read whole from then on); then the throwaway tenants an earlier `117` left, if any (after 28 October `verify-0008zk-one` and `verify-0008zk-volume`), which `117`'s start cleanup removes. Without `0008zj`: **File:** `db/114_asset_sync.sql`, copy all of it; **Studio (cma-dev-pg):** paste and Run, as your own login (no error, no result rows).

**File:** `db/116_asset_sync_load.sql`: copy all of it. **Studio (cma-dev-pg):** paste the whole script and Run, as your own login.

Expected: no error and no result rows. A second run ends the same and changes nothing. It replaces the first `116`'s final step (the two-argument `cma.ingest_mark_devices_missing`) with the slices', adds two indexes, makes the forecast again and lets a run's counts carry the adaptive chunks (`chunk_size_min`, `chunk_halvings`).

**File:** `db/117_verify_asset_sync_load.sql`: copy all of it. **Studio (cma-dev-pg):** paste and Run, in a new tab. Open the results dropdown at the verdict table.

Expected, in some 5 to 10 minutes on dev's shared core: rows `A1` to `A6`, `B1` to `B8`, `C1` to `C5`, `Z1` and `Z2`, each `ok`, and `verdict | 0008zk verified | 117_verify_asset_sync_load: 21 ok, 0 FAIL`. `verdict | REFUSED: not dev or a local database` means the database lacks the dev seed: stop and report it.

The budgets follow the ingest's statement timeout, 15 seconds, not a machine (Decision log, 28 October 2026): every ingest call (`C1`, each chunk of `C4`, each slice of `C2`) under half of it, 7,500 ms; `C4` loads under the adapter's rule (from 1,000 rows, the next chunk half the size after a call slower than a third of the timeout, 5,000 ms, at least 100), and its detail names the calls, the sizes and the halvings; `C5` under 5,000 ms; `C3`, the one-call path, under 10,000 ms.

`Z2`'s detail starts with the start cleanup: `verify-0008zk-one removed` and `verify-0008zk-volume removed` are the two tenants the run of 28 October left (`absent` once they are gone), then the end cleanup, the cleanups tried again after a deadlock (usually 0), the tables with a `tenant_id` (92 locally), each with a foreign key to `cma.tenant`, and the foreign keys into a tenant's rows (220 locally), all from cma and paired on `tenant_id`. The cleanup locks the tenant and its people first, so dev's scheduler cannot add a run row while it deletes; a scheduler run that finishes during a cleanup can deadlock with it, and the cleanup then tries again (up to three attempts). A scheduler minute that falls in a cleanup may log one failure for that throwaway tenant's id (its run row is refused once the tenant is gone), and the next minute no longer lists it.

Locally (PostgreSQL 16 held to db-g1-small's memory, 1.5 GB with `shared_buffers` 560 MB and `work_mem` 4 MB, a database in Cloud SQL's collation `en_US.UTF-8`) the run gave C1 137 ms; C2's slowest slice 112 ms (all 50 together 256 ms); C3 2,337 ms (its staging insert 1,253); C4 50 calls of 1,000 with no halving, its first 490 ms, its slowest 604, the first five 489 and the last five 541 on average; C5's page 747 ms and list 827 ms; Z2's end cleanup 23 s. Dev's run of 28 October (`records/0008zk-dev-2026-10-28`) took five to six times as long for `C1`, `C2` and `C5`, and eight to sixteen times for `C4`'s calls (its slowest 9,768 ms); its chunks of 1,000 took about 5,000 ms, the line where the adapter halves, so halvings in `C4` are expected on dev. Copy the details of `C1` to `C5`, `Z1` and `Z2` into the report. Any `FAIL`: report the row.

**Studio (cma-dev-pg):** `117` again in the same tab, provoked: paste the script, press Ctrl+F, search `'verify.provoke', 'false'` and change only that `false` to `true`. Run.

Expected: every row `FAIL`, `verdict | PROVOKED, NOT A PASS | 117_verify_asset_sync_load: 0 ok, 21 FAIL`, in about the same time: the provoked run does the same work and removes its throwaway tenants as well. Locally the two runs in a row in one session took 232 s, a backend's memory peaked at 117 MB, and the server stayed up.

**Studio (cma-dev-pg)** (read only)
```sql
set role cma_owner;
select pg_postmaster_start_time();
select count(*) as throwaway_tenants from cma.tenant where slug like 'verify-0008zk-%';
reset role;
```
Expected: the start time noted above (the server stayed up), then `0`.

**Studio (cma-dev-pg):** `db/115_verify_asset_sync.sql`, then `db/113_verify_assets.sql`, each pasted whole and Run, unchanged (the load and the forecast they prove are the ones `116` makes again).

Expected: `verdict | 0008zj verified | 115_verify_asset_sync: 14 ok, 0 FAIL` (C1 names its milliseconds, under 10,000; locally 2,035 to 2,439), then `verdict | 0008zi verified | 113_verify_assets: 25 ok, 0 FAIL` (C1 names the page's and the list's milliseconds; locally 135 and 77). Copy both C1 details into the report.

**Studio (cma-dev-pg):** the earlier verifies of what `116` makes again, each pasted whole and Run: `107` (the run's counts) and `53` (a connection's settings).

Expected, each as it passed before this change: `107` 10 PASS, `53` 16 PASS.

**(b) The data map.** No table, view or column changes (`116` adds functions, an aggregate and two indexes), so `docs/datamap/schema.json` moves its `latest_migration` only; `docs/datamap/catalog.json` says how the device tables are filled now and what an asset register's `connection_field` holds. Martin refreshes the snapshot from dev on this branch after (a), before merging.

**Terminal** (in `~/cma`, on this branch)
```bash
cma_db dev && psql "$PGCONN" -X -qAt -v ON_ERROR_STOP=1 -f tools/datamap/schema.sql > docs/datamap/schema.json
```
Expected: nothing printed; `docs/datamap/schema.json` holds `"latest_migration" : "0008zk"` (spaces around the colon).

**Terminal** (`~/cma`)
```bash
node tools/datamap/build.mjs && node tools/datamap/build.mjs --check
```
Expected: `datamap: wrote docs/datamap/index.html (96 tables, 144 views)`, then `datamap: 96 tables, 144 views, all described; index.html current`.

**Terminal** (`~/cma`)
```bash
git add docs/datamap && git commit -m "Data map: snapshot after 0008zk" && git push origin HEAD:<branch>
```
Expected: the push names `<branch>`; the PR passes `verify:datamap`.

**(c) Prod.** The ingest of this change loads in chunks and slices (`cma.ingest_load_device_chunk`, `cma.ingest_mark_devices_missing`), records the mapped fields' types (`cma.ingest_record_field_types`) and finishes runs with the load's counts, phase times and slowest calls, which only `116` provides, so prod runs `114` (where `0008zj` is missing) and `116` before the merge, then `115` and `113` (not `117`); `main`'s web and ingest read nothing they add, and the forecast `116` makes again gives the same results.

**Terminal** (point-in-time recovery on, as before every prod migration)
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.backupConfiguration.transactionLogRetentionDays)"
```
Expected: `True	7`.

**Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select version from cma.schema_migration where version >= '0008zh' order by 1;
select count(*) as assets_with_view_id from cma.integration_connection c where c.settings ? 'view_id'
  and (c.kind = 'assets' or (c.kind is null and 'assets' = any (cma.connection_held_kinds_of(c.tenant_id, c.id))));
reset role;
```
Expected: `0008zh`, `0008zi` and `0008zj`, then `assets_with_view_id` `0` (14.4 sets no view; a number above 0: report it, since `116` removes them and those connections are read whole from then on). Without `0008zj`: `db/114_asset_sync.sql` first, as one script, as your own login (no error, no result rows). With `0008zk` already there, stop and report it.

**Studio (cma-prod-pg):** `db/116_asset_sync_load.sql` as one script, as your own login.

Expected: no error and no result rows, in a few seconds (it builds two indexes on the device tables). A second run ends the same.

**Studio (cma-prod-pg):** `db/115_verify_asset_sync.sql`, then `db/113_verify_assets.sql`, each pasted whole and Run (both work on throwaway tenants inside subtransactions that roll back, so nothing stays).

Expected: `verdict | 0008zj verified | 115_verify_asset_sync: 14 ok, 0 FAIL`, then `verdict | 0008zi verified | 113_verify_assets: 25 ok, 0 FAIL`. Copy both C1 details (milliseconds) into the report. `115`'s C1 is expected to pass; `FAIL` on time alone with dev's `117` all `ok` retires that row (Decision log, 27 October 2026; report its milliseconds), and the merge goes ahead. `117` does not run in prod: the merge rests on dev's `117` and prod's `115` and `113`, and 14.7 measures prod's speed on the real register.

**(d) The merge.** **Browser:** Martin reviews and squash-merges the pull request on GitHub ((a) to (c) done, every verify green). The merge touches `web/` (the job's label on System health), so Cloud Build trigger `cma-web-main` builds and deploys the web to prod.

Expected: the build ends `SUCCESS`.

## 14.1 The service account in Airtable

**Gate:** the Gemini audit of this phase's new secret and IAM binding (the prompt is in the pull request's description) has answered, and every finding is checked as README, How we work, says. Martin runs it before 14.3.

**Browser:** Airtable → Admin Panel (Enterprise Scale) → Service accounts → Create a service account: name `CMA sync`, an email on pulse4all.com that Martin controls. Then the base "Airtable 2.0" → Share → add the service account with the permission **Read only**. (The Admin Panel's wording may differ slightly; what counts is the account and its access.)

Expected: `CMA sync` listed as an active service account; in the base's share list `CMA sync` with **Read only**, and no other base shared with it.

## 14.2 Its personal access token

**Browser:** Admin Panel → the service account `CMA sync` → Personal access tokens → Create token: name `CMA ingest prod`, scopes `data.records:read` and `schema.bases:read` only, access the base "Airtable 2.0" only. Keep the page open until 14.3's first block is done: the token is shown once.

Expected: the token is shown once (it starts with `pat`). It is pasted only at the hidden prompt of 14.3, never into a command, a chat or a file.

## 14.3 The secret, the ingest from `main` and the accessor

`put_secret` must be defined first (Before you start, at the top of this runbook; `type put_secret` prints it).

**Terminal** (on its own line; the value is the token of 14.2)
```bash
put_secret p4a-cma-prod airtable-assets-pulse4all-subscriptions
```
Expected: the hidden prompt; paste, Enter; `stored airtable-assets-pulse4all-subscriptions (version added)`. Then close the Airtable page.

**Terminal** (where the secret is held; Gemini audit of 28 October 2026, FIND-04)
```bash
gcloud secrets describe airtable-assets-pulse4all-subscriptions --project=p4a-cma-prod --format="yaml(replication)"
```
Expected, exactly:
```
replication:
  userManaged:
    replicas:
    - location: europe-west4
```
User-managed replication in europe-west4 only. An `automatic:` block or a second location: report it and stop before the deploy below.

`--front` goes with the service deploy and never with `--jobs` (as 13.6). The service deploy grants `cma-ingest` the accessor on the new secret (on that secret only) and answers `404` on `/airtable/<key>`; the jobs deploy adds `ingest-poll-assets`, its schedule created paused (14.8 resumes it).

**Terminal** (in `~/cma`, on `main` after the merge)
```bash
git switch -q main && git pull -q --ff-only && git log -1 --format=%h -- ingest/ && bash docs/ingest/deploy.sh prod --front ingest.pulse4all.app --tenant pulse4all-subscriptions --secret airtable-assets-pulse4all-subscriptions && bash docs/ingest/deploy.sh prod --jobs
```
Expected: `main`'s ingest tag first (the squash commit's short sha); the image built once under it; `accessor on airtable-assets-pulse4all-subscriptions`; `health: {"ok":true,"version":"<that tag>"}` through `https://ingest.pulse4all.app/health` and `run.app: 404 (refused)`; then the jobs on the same image (`no build`): nine job deploys, `schedule ingest-poll-assets: */5 * * * * (Europe/Amsterdam), created paused` next to the others, `ingest-reconcile` at 03:30.

**Terminal** (who may read the secret, now that the service deploy granted the accessor; FIND-04)
```bash
gcloud secrets get-iam-policy airtable-assets-pulse4all-subscriptions --project=p4a-cma-prod --flatten='bindings[].members' --format='value(bindings.role,bindings.members)'
```
Expected: exactly one line, `roles/secretmanager.secretAccessor	serviceAccount:cma-ingest@p4a-cma-prod.iam.gserviceaccount.com`: the accessor for `cma-ingest@p4a-cma-prod` only. Another member or another role: report it and remove it before 14.4.

## 14.4 The connection and its settings

The register's connection exists since 0008zi (adapter `airtable`, kind `assets`, account id `appsEV7MhflMLd2Xv`). `cma.upsert_connection` with the same adapter and account id updates it, adding the token secret name; from now on the ingest reads it.

**Studio (cma-prod-pg)** in one Run (after the context block)
```sql
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'studio:martin', false);
select * from cma.upsert_connection('airtable', 'Airtable 2.0 assets', 'appsEV7MhflMLd2Xv', null, 'airtable-assets-pulse4all-subscriptions');
reset role;
```
Expected: one row of three values, then one row with `connection_id` (the register's connection of 0008zi: `<assets conn>`) and `key`. A connection id you do not know means the account id differs from the stored one: stop and report it.

**Studio (cma-prod-pg)** in one Run (the settings; `set_connection_settings` replaces the whole object, so the current one is merged in)
```sql
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'studio:martin', false);
select cma.set_connection_settings('<assets conn>',
  coalesce((select settings from cma.integration_connection where id = '<assets conn>'), '{}'::jsonb)
  || '{"table_id": "tblHVsCkAwJLqZOgu", "date_format": "dmy"}'::jsonb);
select name, adapter, external_account_id, kind, status, signing_secret_name, token_secret_name
from cma.sources() where connection_id = '<assets conn>';
select cma.connection_config('<assets conn>') -> 'settings' as settings;
reset role;
```
Expected: one row of three values, an empty result, then `Airtable 2.0 assets | airtable | appsEV7MhflMLd2Xv | assets | active | | airtable-assets-pulse4all-subscriptions`, then `{"table_id": "tblHVsCkAwJLqZOgu", "date_format": "dmy"}` (with any setting it held before). The other settings keep their defaults (`assets_poll_interval_minutes` 15, `assets_load_chunk` 1,000, `airtable_max_per_second` 2 for the poll and `airtable_full_max_per_second` 4 for a full read). There is no `view_id`: an asset register is read whole (the database refuses one, CMA04). The register's date fields arrive as ISO dates, so `date_format` matters only for a mapped date that arrives as text.

## 14.5 The register's fields, by field id

The mapping of `docs/import/devices-map.example.json` (the register's headers of 27 October 2026), carried over to the connection's fields by Airtable field id (`fld…`): 13 device columns, the pads' and the battery's serial and expiry, three named ids. The record id needs no field: it is the API's record id, the `RECORD_ID()` the export carried as `airtable_record _id`. The ids come from the live schema: a dry run without a mapping lists the table's fields (id, name, type), and `docs/ingest/airtable-fields.mjs` turns that list and the map file's headers into the Studio block. A field renamed in Airtable later keeps its id, so the mapping holds.

**Terminal** (the first dry run: the connection has no fields yet, so it lists the table's fields and reads no record)
```bash
gcloud run jobs execute ingest-backfill --project=p4a-cma-prod --region=europe-west4 --wait --args='^;^--connection;<assets conn>;--object;device;--dry-run'
```
Expected: `Execution [ingest-backfill-…] has successfully completed.` within a minute (one schema read).

**Terminal** (in `~/cma` on `main`: the dry run's field list, names and types only, piped into the generator; nothing is written to a file)
```bash
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="ingest-backfill" AND jsonPayload.message="backfill dry run"' --project=p4a-cma-prod --freshness=1h --limit=1 --format=json | node docs/ingest/airtable-fields.mjs --connection <assets conn> --map docs/import/devices-map.example.json
```
Expected: a block of 27 lines: four context lines (`set role cma_app;` and the `set_config` lines with `<tenant_id>` and `<user_id>`), twenty `select cma.set_connection_field('<assets conn>', …, 'fld…');` lines, each ending in its field's name and type as a comment (`-- aed_sn (singleLineText)`), the read-back `select` over two lines and `reset role;`; then on its own line `20 fields mapped by id; the table holds 52` (52 on 27 October 2026). `no field of the table is named "…"` means the register renamed a header since 27 October: stop and report it (the map file is configuration and changes in its own pull request). `more than one field of the table is named "…"`: report it.

**Studio (cma-prod-pg)** in one Run: paste the printed block, replace `<tenant_id>` and `<user_id>` from the context block's first chunk, and Run.

Expected: one row of three values, twenty empty results, then 20 rows: `device` with `country`, `customer_ref`, `end_of_life_on`, `first_shipped_on`, `last_shipped_on`, `model`, `order_ref`, three `ref` rows (`ns_fam_id`, `ns_internal_id`, `ns_sales_order_id`), `serial`, `status`, `stock_received_on`, `subscription_ref`, `warehouse_ref`, `warranty_until`; `device_component` with `expires_on` and `serial` for `battery` and `pads`; every `source_property` a field id (`fld` and fourteen letters or digits). `no component kind …` means the catalog lacks the kind (seed `02`); `connection … is not an asset register connection` means the wrong connection id. **Browser:** Configuration → Sources → **Airtable 2.0 assets** lists the same fields read-only.

## 14.6 The dry run

The first read in prod with the mapping: the schema check and every record mapped, nothing written (no staging, no load, no run, no cursor, no recorded type). It is the API's equivalent of the staging tool's counts.

**Terminal** (`<assets conn>` from 14.4)
```bash
gcloud run jobs execute ingest-backfill --project=p4a-cma-prod --region=europe-west4 --wait --args='^;^--connection;<assets conn>;--object;device;--dry-run'
```
Expected: `Execution [ingest-backfill-…] has successfully completed.` in under a minute (some 100 pages at four a second).

**Terminal** (the dry run's counts; counts and field names only)
```bash
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="ingest-backfill" AND jsonPayload.message="backfill dry run"' --project=p4a-cma-prod --freshness=1h --limit=1 --format='value(jsonPayload.fetched,jsonPayload.mapped,jsonPayload.fields,jsonPayload.tableFields,jsonPayload.dateFailures,jsonPayload.valuesWithAt,jsonPayload.unreadable,jsonPayload.duplicates,jsonPayload.unknownFields,jsonPayload.typeChangedFields,jsonPayload.notFieldIds,jsonPayload.apiCalls)'
```
Expected: one line: `fetched` the register's records (9,677 in the export of 27 October 2026, `records/0008zi-prod-2026-10-27`, plus any added since), `mapped` the same, `fields` 20, `tableFields` the table's fields (52 on 27 October 2026; Grid view shows 35 of them), `dateFailures` 0, `valuesWithAt` 0 (the tool's counts of 27 October), `unreadable` 0, `duplicates` 0, `unknownFields` 0, `typeChangedFields` 0, `notFieldIds` 0, and the requests (one schema read and one per page). `unknownFields` above 0: the line `backfill dry run` names the ids in `unknownFieldNames`: a mapped field was deleted since 14.5; report it. A failed execution names its code in the log (`token_unavailable`: the secret or its accessor, 14.3; `http_401` or `http_403`: the token or its access, 14.1 and 14.2; `unknown_table`: 14.4's `table_id`; `date_format_not_set`: a mapped date arrives as text, the line names the field; `paging_expired`: Airtable let the paging expire, run it again).

## 14.7 The first full read

The same full snapshot, loaded: every record of the table in chunks of `assets_load_chunk` rows (default 1,000: about ten chunks; the adapter halves the next chunk after a call slower than a third of the statement timeout, 5,000 ms), then the final step in slices of the same size (about ten) that marks missing what the run did not read. The first read records the 20 mapped fields' types. A kind whose serial and expiry the register holds empty closes the device's current component of that kind (`components_closed`; its item due unknown).

This read is prod's speed check (Decision log, 28 October 2026; `117` runs in dev only): the run records its phase times summed over its chunks, its slowest calls, `chunk_max_ms` (the slowest chunk) and `slice_max_ms` (the slowest slice of the final step), in milliseconds as the ingest measures each call, and its adaptive chunks, `chunk_size_min` (the smallest chunk size in force) and `chunk_halvings`. The budget is `117`'s: every call under half the ingest's 15-second statement timeout, 7,500 ms; a call slower than a third of it, 5,000 ms, halves the next chunk and shows as a halving. A chunk the timeout cancels is sent again once at half its size; cancelled again, the run fails before its final step, so nothing is marked missing.

**Terminal**
```bash
gcloud run jobs execute ingest-backfill --project=p4a-cma-prod --region=europe-west4 --wait --args='^;^--connection;<assets conn>;--object;device'
```
Expected: `Execution [ingest-backfill-…] has successfully completed.`

**Studio (cma-prod-pg)** (read only; counts only)
```sql
set role cma_owner;
select job, stream, status, error, counts, started_at, finished_at from cma.sync_run
where connection_id = '<assets conn>' order by started_at desc limit 3;
select count(*) as devices, count(*) filter (where source_deleted_at is not null) as missing from cma.device where connection_id = '<assets conn>';
select count(*) as staged from cma.device_import_row;
select count(*) filter (where source_type is not null) as types_recorded from cma.connection_field where connection_id = '<assets conn>';
select counts ->> 'chunk_max_ms' as chunk_max_ms, counts ->> 'slice_max_ms' as slice_max_ms, counts ->> 'chunk_size_min' as chunk_size_min,
       counts ->> 'chunk_halvings' as chunk_halvings, counts ->> 'map_ms' as map_ms, counts ->> 'upsert_ms' as upsert_ms,
       counts ->> 'components_ms' as components_ms, counts ->> 'missing_ms' as missing_ms
from cma.sync_run where connection_id = '<assets conn>' and job = 'backfill' order by started_at desc limit 1;
reset role;
```
Expected: the newest row `backfill | device | succeeded` with `fetched` and `rows` as 14.6's `fetched`, `inserted` 0 (records added since the export of 27 October would show here), `missing_now` 0, `updated` up to 9,677 where a device's mapped row from the API differs from the CSV's (`unchanged` the rest), `components_replaced` 0 (a pads or battery swapped since 27 October would show here), `components_closed` 0 (a kind the register emptied since 27 October would show here), and `unmapped_market`, `customer_ref_invalid` and `refs_dropped` as the load of 27 October counted them (8, 32 and 2) unless the register changed; the phase times in milliseconds summed over the chunks (`stage_ms`, `map_ms`, `upsert_ms`, `components_ms`, `missing_ms`; `cleanup_ms` 0); below it the CSV load of 0008zi (`assets_import`). Then the devices (9,677) with 0 missing, 0 staged rows and `types_recorded` 20. Last, the speed check: `chunk_max_ms` and `slice_max_ms` each under 7,500, `chunk_size_min` 1000 and `chunk_halvings` 0, with the four phase times; copy the line into the report. A value at or over 7,500, or a halving: report the line before 14.8. A `failed` row names its code: report it (`db_57014`: a chunk the statement timeout cancelled twice, with nothing marked missing).

**Browser:** Reports → Maintenance and Reports → Data quality: the same figures as after the CSV load of 27 October (`records/0008zi-prod-2026-10-27`), unless the register changed since.

## 14.8 The schedule, the first run and System health

**Terminal**
```bash
gcloud scheduler jobs resume ingest-poll-assets --project=p4a-cma-prod --location=europe-west4 && gcloud scheduler jobs describe ingest-poll-assets --project=p4a-cma-prod --location=europe-west4 --format='value(state,schedule,timeZone)'
```
Expected: gcloud's confirmation that the job is resumed, then `ENABLED	*/5 * * * *	Europe/Amsterdam`. A later `deploy.sh prod --jobs` keeps the schedule as it is.

Wait for the next five minutes: the first scheduled run is due at once (it has no cadence yet) and reads the records changed since 14.7 less five minutes.

**Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select job, stream, status, error, counts ->> 'fetched' as fetched, counts ->> 'updated' as updated, counts ->> 'inserted' as inserted, started_at
from cma.sync_run where connection_id = '<assets conn>' and job = 'assets_poll' order by started_at desc limit 3;
select stream, cursor from cma.sync_cursor where connection_id = '<assets conn>' order by stream;
reset role;
```
Expected: one `assets_poll | devices | succeeded` row with a small `fetched` (the records edited since 14.7, often 0); the cursors `assets:cadence` and `assets:modified` with that run's start as `at` (milliseconds). Then a run every 15 minutes: the job runs every 5, and a connection reads when its `assets_poll_interval_minutes` has passed.

**Browser:** Workspace → Configuration → System health.

Expected: the row **Asset register poll** with its last run succeeded, and the connection **Airtable 2.0 assets** OK. After 03:30 the next day: a **Nightly reconcile** run of the connection, stream `device`, succeeded, `missing_now` the records the register dropped that day (usually 0), `components_closed` the kinds the register emptied that day (their items show under `component_due_unknown`), `chunk_max_ms` and `slice_max_ms` under 7,500, and `chunk_size_min` 1000. System health's counts column shows only counts above 0, so `missing_now`, `components_closed` and `chunk_halvings` are absent on a day with none.

Day one: **Studio (cma-prod-pg)**, after `set role cma_owner;` and then `reset role;`: `select job, status, error, count(*) from cma.sync_run where connection_id = '<assets conn>' and started_at > now() - interval '1 day' group by 1, 2, 3 order by 1, 2;`. Expected: about 96 `assets_poll` `succeeded` and one `reconcile` `succeeded`; a `failed` with `rate_limited` or `paging_expired` now and then is fine (the next run carries on, or starts over). A renamed field changes nothing (its id stays). `unknown_field` means a mapped field was deleted in the register: the log line `airtable unknown field` names its id; map its replacement by id (14.5's two Terminal steps, then only that field's line in Studio). `field_type_changed` means a mapped field's type changed: the log line `airtable field type changed` names the field and both types; check its values with a dry run (14.6), then accept the new type by mapping the field again in one Run, `select cma.set_connection_field('<assets conn>', '<entity>', '<field>', '<ref_system>', '');` and then the same with its `fld…` id (after the context block); the next run records the new type. A failed poll does not move its cadence, so a lasting failure (`unknown_field`, `field_type_changed`, `token_unavailable`) writes one `failed` row every 5 minutes, about 288 a day, until it is fixed: fix it the same day. **Records:** the outputs of (a), (c) and 14.3 to 14.8 into `records/0008zj-prod-<date>/` in a separate pull request, written from your report (ids, counts and times only; no token or personal data).

## 14.9 Rotating the token (every 180 days; owner Martin)

The token of 14.2 lives until it is revoked: an Airtable personal access token does not expire on its own. Martin owns it and rotates it every 180 days (Decision log, 28 October 2026; Gemini audit of 28 October 2026, FIND-02), and at once when it may have been exposed. The ingest reads the secret's latest version and every job execution starts fresh, so the first poll after a new version uses the new token; the old one keeps working until it is revoked, so no run fails in between. `put_secret` must be defined first (14.3).

**Browser:** Airtable → Admin Panel → the service account `CMA sync` → Personal access tokens → Create token: name `CMA ingest prod <YYYY-MM-DD>` (today), the same scopes as 14.2 (`data.records:read` and `schema.bases:read` only) and the base "Airtable 2.0" only. Keep the page open: the token is shown once.

Expected: the new token shown once (it starts with `pat`); the old token still listed.

**Terminal** (on its own line; the value is the new token)
```bash
put_secret p4a-cma-prod airtable-assets-pulse4all-subscriptions
```
Expected: the hidden prompt; paste, Enter; `stored airtable-assets-pulse4all-subscriptions (version added)`. Then close the Airtable page.

**Terminal** (the secret's versions, as 13.5)
```bash
gcloud secrets versions list airtable-assets-pulse4all-subscriptions --project=p4a-cma-prod
```
Expected: the new version and the old one, both `enabled`; the old one is the number before the new (1 at the first rotation). Note both numbers.

Wait for the next poll, within 15 minutes (the connection's `assets_poll_interval_minutes`).

**Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select job, status, error, started_at from cma.sync_run
where connection_id = '<assets conn>' and job = 'assets_poll' and started_at > now() - interval '30 minutes' order by started_at desc limit 3;
reset role;
```
Expected: an `assets_poll | succeeded` row started after the new version's time; System health shows **Asset register poll** succeeded since then (or the day-one query of 14.8). A `failed` row with `http_401` or `http_403`: the new token is wrong (a typo, a scope or the base); revoke nothing, create it again (the first block) and store it again.

**Browser:** Admin Panel → `CMA sync` → Personal access tokens → revoke the old token (`CMA ingest prod`, or the previous date).

Expected: only the new token listed.

**Terminal** (the old version gone, as 13.5, so nothing can read the revoked token back)
```bash
gcloud secrets versions destroy <old version> --secret=airtable-assets-pulse4all-subscriptions --project=p4a-cma-prod
```
Expected: a `Y/n` prompt; after `Y`, `Destroyed version [<old version>] of the secret [airtable-assets-pulse4all-subscriptions].` The list of the earlier block now shows the old version `destroyed` and the new one `enabled`. The next poll succeeds again (the Studio block above, a run after the revoke). Report the date and the two version numbers; the next rotation is due 180 days from today.

# 15. Juo subscriptions in prod, the GB pilot (addition 0008zl, brief B20)

Written on 28 October 2026 for 0008zl. The ingest reads the subscriptions of the GB store (`pulse4all.myshopify.com`) and the events of its subscriptions from Juo's Admin API into `cma.subscription` and `cma.subscription_event`: the events since the cursor every 5 minutes (`ingest-poll-subscriptions`), with the subscriptions they touched, and every subscription nightly (`ingest-reconcile`); each subscription's payment state follows from both (`docs/ingest/README.md`, section Juo; `docs/architecture/data-model/0008.md`, Data model: subscriptions). Read only: nothing is written to Juo. HubSpot's own Juo events stay as they are. The other 13 stores follow later, one connection and one key each (Open decisions). Order: the migration in dev with its verify, the data map and the migration in prod, all before the merge, then the merge (Before 15.1); then the Gemini audit, the key and its secret, the ingest from `main` (15.1, 15.2), the store and the connection (15.3, 15.4), the dry runs (15.5, 15.6), the backfills (15.7), the checks (15.8) and the schedule (15.9). Do 15.4 to 15.7 in one sitting, before 03:30: from 15.4 on the nightly reconcile reads the store too. The Studio blocks that call a function carry the context block's second part (as 9.6); `<tenant_id>` and `<user_id>` come from its first part. The Terminal blocks run in `~/cma`.

**Data prerequisites:**
- The GB store's Juo Admin API key (the GB key answered 200 for `pulse4all.myshopify.com` and 401 for `pulse4all-nl.myshopify.com` on 28 October 2026); whether a key can be read-only is an Open decision (15.1).
- The GB store's commerce store row (phase 9: handle `pulse4all`, its Shopify connection). Without it every read fails `store_not_configured` (15.3).
- The store's customers in `cma.commerce_customer`: a subscription's customer joins them by id. Phase 9's backfill started at 1 October 2026, so a customer the store has not changed since then is not held, and such subscriptions count as `customers_unmatched` (15.5). Reports that need the customer read it from there; until a backfill of `commerce_customer` from the store's start, many will be unmatched.

## Before 15.1: the migration, the data map, the merge

One addition: 0008zl (`118`; `119` its verify). `119` runs in dev (and local databases) only, as `117` (Decision log, 28 October 2026): its Z1 reads every subscription and event row of the database for an email pattern after the flow verifier's fixtures; it refuses a database without the dev seed. Its block B works on throwaway tenants in a subtransaction that is always rolled back, so nothing stays.

**(a) Dev.** **Studio (cma-dev-pg)** (read only)
```sql
set role cma_owner;
select version from cma.schema_migration where version >= '0008zj' order by 1;
reset role;
```
Expected: `0008zj` and `0008zk`. Without `0008zk`: phase 14's (a) first.

**File:** `db/118_subscriptions.sql`: copy all of it. **Studio (cma-dev-pg):** paste the whole script and Run, as your own login.

Expected: no error and no result rows. A second run ends the same and changes nothing.

**File:** `db/119_verify_subscriptions.sql`: copy all of it. **Studio (cma-dev-pg):** paste and Run, in a new tab. Open the results dropdown at the verdict table.

Expected, in a few seconds: rows `A1` to `A7`, `B1` to `B15` and `Z1`, each `PASS`, and `verdict | PASS | 119_verify_subscriptions: 23 PASS, 0 FAIL`. `Z1`'s detail reads `0 of <n> subscriptions, 0 of <m> events` (in dev usually `0 of 0`: no Juo connection there). `verdict | REFUSED` means the database lacks the dev seed: stop and report it. Any `FAIL`: report the row and its detail.

**Studio (cma-dev-pg):** `119` again in the same tab, provoked: paste the script, press Ctrl+F, search `'verify.provoke', 'false'` and change only that `false` to `true`. Run.

Expected: every row `FAIL`, `verdict | PROVOKED, NOT A PASS | 119_verify_subscriptions: 0 PASS, 23 FAIL`.

**Studio (cma-dev-pg):** the earlier verifies of what `118` makes again, each pasted whole and Run, unchanged: `115` (the run's counts and a connection's settings), `105` (the kinds), `107` (the run's counts) and `53` (the kinds and the settings).

Expected, each as it passed before this change: `115` `verdict | 0008zj verified | 115_verify_asset_sync: 14 ok, 0 FAIL`, `105` 27 PASS, `107` 10 PASS, `53` 16 PASS.

**(b) The data map.** Two tables (`cma.subscription`, `cma.subscription_event`) and three reader views are new; `docs/datamap/catalog.json` describes them and `template.html` has the Juo box. Martin refreshes the snapshot from dev on this branch after (a), before merging; until then `verify:datamap` fails on the branch, which is expected.

**Terminal** (in `~/cma`, on this branch)
```bash
cma_db dev && psql "$PGCONN" -X -qAt -v ON_ERROR_STOP=1 -f tools/datamap/schema.sql > docs/datamap/schema.json
```
Expected: nothing printed; `docs/datamap/schema.json` holds `"latest_migration" : "0008zl"` (spaces around the colon).

**Terminal** (`~/cma`)
```bash
node tools/datamap/build.mjs && node tools/datamap/build.mjs --check
```
Expected: `datamap: wrote docs/datamap/index.html (98 tables, 147 views)`, then `datamap: 98 tables, 147 views, all described; index.html current` (two tables and three views more than after 0008zk).

**Terminal** (`~/cma`)
```bash
git add docs/datamap && git commit -m "Data map: snapshot after 0008zl" && git push origin HEAD:<branch>
```
Expected: the push names `<branch>`; the PR passes `verify:datamap`.

**(c) Prod.** The ingest of this change writes subscriptions and events (`cma.ingest_upsert_subscriptions`, `cma.ingest_upsert_subscription_events`, `cma.ingest_mark_subscriptions_missing`) and finishes runs of job `subscriptions_poll` with its counts, which only `118` provides, so prod runs `118` before the merge, then `115` and `105` (not `119`); `main`'s web and ingest read nothing it adds.

**Terminal** (point-in-time recovery on, as before every prod migration)
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.backupConfiguration.transactionLogRetentionDays)"
```
Expected: `True	7`.

**Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select version from cma.schema_migration where version >= '0008zj' order by 1;
reset role;
```
Expected: `0008zj` and `0008zk`. With `0008zl` already there, stop and report it.

**Studio (cma-prod-pg):** `db/118_subscriptions.sql` as one script, as your own login.

Expected: no error and no result rows, in a second or two. A second run ends the same.

**Studio (cma-prod-pg):** `db/115_verify_asset_sync.sql`, then `db/105_verify_reviews.sql`, each pasted whole and Run (both work on throwaway tenants inside subtransactions that roll back, so nothing stays).

Expected: `verdict | 0008zj verified | 115_verify_asset_sync: 14 ok, 0 FAIL` (its C1 on time as before), then `verdict | PASS | 105_verify_reviews: 27 PASS, 0 FAIL`.

**(d) The merge.** **Browser:** Martin reviews and squash-merges the pull request on GitHub ((a) to (c) done, every verify green). The merge touches `web/` (the kind's label, the job's label on System health), so Cloud Build trigger `cma-web-main` builds and deploys the web to prod.

Expected: the build ends `SUCCESS`.

## 15.1 The Gemini audit, then the GB store's key

**Gate:** the Gemini audit of this phase's new secret and IAM binding (the prompt is in the pull request's description) has answered, and every finding is checked as README, How we work, says. Martin runs it before this step.

**Browser:** Juo's admin of the GB store (`pulse4all.myshopify.com`) → Settings → API (Admin API keys): the key the CMA will use, named `CMA ingest prod` when a new one is made; read-only when Juo offers it (Open decisions: whether a store key can be read-only). Keep the page open until 15.2's first block is done.

Expected: the key shown once. It is pasted only at the hidden prompt of 15.2, never into a command, a chat or a file.

## 15.2 The secret, the ingest from `main` and the accessor

`put_secret` must be defined first (Before you start, at the top of this runbook; `type put_secret` prints it).

**Terminal** (on its own line; the value is the key of 15.1)
```bash
put_secret p4a-cma-prod ingest-juo-pulse4all-key
```
Expected: the hidden prompt; paste, Enter; `stored ingest-juo-pulse4all-key (version added)`. Then close Juo's page.

`--front` goes with the service deploy and never with `--jobs` (as 13.6). The service deploy grants `cma-ingest` the accessor on the new secret (on that secret only) and answers `404` on `/juo/<key>`; the jobs deploy adds `ingest-poll-subscriptions`, its schedule created paused (15.9 resumes it).

**Terminal** (in `~/cma`, on `main` after the merge)
```bash
git switch -q main && git pull -q --ff-only && git log -1 --format=%h -- ingest/ && bash docs/ingest/deploy.sh prod --front ingest.pulse4all.app --tenant pulse4all-subscriptions --secret ingest-juo-pulse4all-key && bash docs/ingest/deploy.sh prod --jobs
```
Expected: `main`'s ingest tag first (the squash commit's short sha); the image built once under it; `accessor on ingest-juo-pulse4all-key`; `health: {"ok":true,"version":"<that tag>"}` through `https://ingest.pulse4all.app/health` and `run.app: 404 (refused)`; then the jobs on the same image (`no build`): ten job deploys, `schedule ingest-poll-subscriptions: */5 * * * * (Europe/Amsterdam), created paused` next to the others, `ingest-reconcile` at 03:30.

**Terminal** (who may read the secret)
```bash
gcloud secrets get-iam-policy ingest-juo-pulse4all-key --project=p4a-cma-prod --flatten='bindings[].members' --format='value(bindings.role,bindings.members)'
```
Expected: exactly one line, `roles/secretmanager.secretAccessor	serviceAccount:cma-ingest@p4a-cma-prod.iam.gserviceaccount.com`. Another member: report it and remove it before 15.4.

## 15.3 The GB store in the CMA

The Juo connection's handle, `pulse4all` (its account id up to the first dot), must be the handle of a commerce store of the tenant: that store's Shopify connection holds the customers the subscriptions join.

**Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select s.handle, s.market, s.currency, s.connection_id, c.adapter, c.external_account_id, c.status,
       (select count(*) from cma.commerce_customer cu where cu.tenant_id = s.tenant_id and cu.connection_id = s.connection_id) as customers
from cma.commerce_store s join cma.integration_connection c on c.tenant_id = s.tenant_id and c.id = s.connection_id
where s.handle = 'pulse4all';
reset role;
```
Expected: one row: `pulse4all | GB | GBP | <shop conn> | shopify | pulse4all.myshopify.com | active | <customers>`. No row: stop and report it (phase 9.6 makes the store row).

## 15.4 The connection, its kind and its settings

**Studio (cma-prod-pg)** in one Run (after the context block)
```sql
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'studio:martin', false);
select * from cma.upsert_connection('juo', 'Juo GB', 'pulse4all.myshopify.com', null, 'ingest-juo-pulse4all-key');
reset role;
```
Expected: one row of three values, then one row with `connection_id` (`<juo conn>`) and `key`.

**Studio (cma-prod-pg)** in one Run (the kind first: the settings are checked on a subscriptions connection)
```sql
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'studio:martin', false);
select cma.set_connection_kind('<juo conn>', 'subscriptions');
select cma.set_connection_settings('<juo conn>', '{"juo_poll_interval_minutes": 5, "juo_max_per_second": 2}'::jsonb);
select name, adapter, external_account_id, kind, status, signing_secret_name, token_secret_name
from cma.sources() where connection_id = '<juo conn>';
select x.handle, x.store_connection_id from cma.subscription_store_connection_of('<tenant_id>', '<juo conn>') x;
reset role;
```
Expected: one row of three values, two empty results, then `Juo GB | juo | pulse4all.myshopify.com | subscriptions | active | | ingest-juo-pulse4all-key`, then `pulse4all | <shop conn>` (15.3's connection). No row in the last result: the handle matches no store; stop and report it. **Browser:** Configuration → Sources lists **Juo GB** with the kind **Subscriptions**.

## 15.5 The dry run of the subscriptions

The first read in prod: every subscription of the store mapped and counted, nothing written (no upsert, no run, no cursor).

**Terminal** (`<juo conn>` from 15.4)
```bash
gcloud run jobs execute ingest-backfill --project=p4a-cma-prod --region=europe-west4 --wait --args='^;^--connection;<juo conn>;--object;subscription;--dry-run'
```
Expected: `Execution [ingest-backfill-…] has successfully completed.` within a few minutes (100 subscriptions a page at two a second).

**Terminal** (the dry run's counts; counts and statuses only)
```bash
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="ingest-backfill" AND jsonPayload.message="backfill dry run" AND jsonPayload.object="subscription"' --project=p4a-cma-prod --freshness=1h --limit=1 --format='value(jsonPayload.fetched,jsonPayload.mapped,jsonPayload.unreadable,jsonPayload.statuses,jsonPayload.instrumentKnown,jsonPayload.withoutCustomer,jsonPayload.customersUnmatched,jsonPayload.apiCalls)'
```
Expected: one line: `fetched` the store's subscriptions (Juo's admin shows the count), `mapped` the same, `unreadable` 0, `statuses` per status (Juo's own figures), `instrumentKnown` close to `mapped` (0 means Juo did not expand the payment method: report it, the instrument's type stays empty), `withoutCustomer` 0, `customersUnmatched` the customers the CMA does not hold (Data prerequisites: expected high while the store's customers are held from 1 October 2026 only), and the requests. A failed execution names its code in the log: `token_unavailable` (the secret or its accessor, 15.2), `key_rejected` (the key is not the GB store's, 15.1), `store_not_configured` (15.3), `tenant_id_invalid` (15.4's account id), `rate_limited` (run it again), `http_<status>` (report it: a path or a query form Juo does not take).

## 15.6 The dry run of the events

**Terminal** (`<from>`: the first day the reports need, as YYYY-MM-DD; Juo holds the store's history since its migration to Juo)
```bash
gcloud run jobs execute ingest-backfill --project=p4a-cma-prod --region=europe-west4 --wait --args='^;^--connection;<juo conn>;--object;subscription_event;--from;<from>;--dry-run'
```
Expected: `Execution [ingest-backfill-…] has successfully completed.`

**Terminal** (the event types seen, counts only)
```bash
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="ingest-backfill" AND jsonPayload.message="backfill dry run" AND jsonPayload.object="subscription_event"' --project=p4a-cma-prod --freshness=1h --limit=1 --format='value(jsonPayload.from,jsonPayload.fetched,jsonPayload.mapped,jsonPayload.otherType,jsonPayload.unreadable,jsonPayload.eventTypes,jsonPayload.kept,jsonPayload.reasonDropped,jsonPayload.customersUnmatched,jsonPayload.apiCalls)'
```
Expected: one line: `from` 00:00 of `<from>` in London's time; `fetched` the events read; `mapped` the ones the CMA keeps; `otherType` the rest; `unreadable` 0; `eventTypes` Juo's types seen with counts (`subscription:renewed`, `subscription:renew-failed`, `subscription:updated`, `subscription:cancelled`, `subscription:paused`, … as `docs/ingest/README.md`, section Juo, names them); `kept` per CMA type (`renewed`, `renew_failed`, `status_changed`, `canceled`, `paused`, `resumed`, `reactivated`); `reasonDropped` the cancellations with a free-text reason (never stored); `customersUnmatched`; the requests. A type in `eventTypes` that the README's table does not name: copy it into the report (a later change may map it).

## 15.7 The backfills: the events, then the subscriptions

The events first: a paused subscription's `paused_at` comes from its pause event, and the events backfill moves the poll's cursor to its own start.

**Terminal** (the same `<from>` as 15.6)
```bash
gcloud run jobs execute ingest-backfill --project=p4a-cma-prod --region=europe-west4 --wait --args='^;^--connection;<juo conn>;--object;subscription_event;--from;<from>'
```
Expected: `Execution [ingest-backfill-…] has successfully completed.`

**Terminal**
```bash
gcloud run jobs execute ingest-backfill --project=p4a-cma-prod --region=europe-west4 --wait --args='^;^--connection;<juo conn>;--object;subscription'
```
Expected: `Execution [ingest-backfill-…] has successfully completed.`

## 15.8 The checks

**Studio (cma-prod-pg)** (read only; counts only, no customer row)
```sql
set role cma_owner;
select job, stream, status, error, counts, started_at, finished_at from cma.sync_run
where connection_id = '<juo conn>' order by started_at desc limit 3;
select stream, cursor from cma.sync_cursor where connection_id = '<juo conn>' order by stream;
select status, count(*) as subscriptions, count(*) filter (where customer_source_id is null) as without_customer,
       count(*) filter (where payment_instrument_type is null) as instrument_unknown
from cma.subscription where connection_id = '<juo conn>' and source_deleted_at is null group by 1 order by 1;
select event_type, count(*) as events, min(occurred_at)::date as first, max(occurred_at)::date as last
from cma.subscription_event where connection_id = '<juo conn>' group by 1 order by 1;
select p.payment_state, count(*) from cma.subscription_payment_state_of('<tenant_id>') p
where p.connection_id = '<juo conn>' group by 1 order by 1;
select count(*) filter (where to_jsonb(s)::text ~ '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}') as subscriptions_with_an_email
from cma.subscription s where s.connection_id = '<juo conn>';
select count(*) filter (where to_jsonb(e)::text ~ '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}') as events_with_an_email
from cma.subscription_event e where e.connection_id = '<juo conn>';
reset role;
```
Expected:
- the runs: `backfill | subscription | succeeded` with `fetched` and `inserted` as 15.5's `mapped`, `customers_unmatched` as 15.5's subscriptions without a held customer, `missing_now` 0; below it `backfill | subscription_event | succeeded` with `events_new` as 15.6's `mapped`, `skipped` as its `otherType`, `reason_dropped` as its `reasonDropped`;
- the cursors: `backfill:subscription_event` with `done` true, `juo:events` with the events backfill's start as `at` (milliseconds);
- the subscriptions per status as 15.5's `statuses`, `without_customer` 0 and `instrument_unknown` small;
- the events per type as 15.6's `kept`, the first on or after `<from>`;
- the payment states: `canceled`, `failed`, `in_retry`, `paid`, `paused` (no row for a state no subscription is in); `paid` and `in_retry` together the active subscriptions;
- `subscriptions_with_an_email` 0 and `events_with_an_email` 0. Above 0: stop and report it before 15.9.

**Browser:** Juo's admin of the GB store: the active, paused and canceled counts against the statuses above (the same, give or take subscriptions changed since 15.7), and a subscription with a failed renewal now against `in_retry`. Copy the figures into the report.

## 15.9 The schedule, the first run and System health

**Terminal**
```bash
gcloud scheduler jobs resume ingest-poll-subscriptions --project=p4a-cma-prod --location=europe-west4 && gcloud scheduler jobs describe ingest-poll-subscriptions --project=p4a-cma-prod --location=europe-west4 --format='value(state,schedule,timeZone)'
```
Expected: gcloud's confirmation that the job is resumed, then `ENABLED	*/5 * * * *	Europe/Amsterdam`. A later `deploy.sh prod --jobs` keeps the schedule as it is.

Wait for the next five minutes: the first scheduled run is due at once (it has no cadence yet) and reads the events since the events backfill's start less five minutes.

**Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select job, stream, status, error, counts ->> 'fetched' as fetched, counts ->> 'events_new' as events_new, counts ->> 'updated' as updated,
       counts ->> 'inserted' as inserted, counts ->> 'customers_unmatched' as customers_unmatched, started_at
from cma.sync_run where connection_id = '<juo conn>' and job = 'subscriptions_poll' order by started_at desc limit 3;
select stream, cursor from cma.sync_cursor where connection_id = '<juo conn>' order by stream;
reset role;
```
Expected: one `subscriptions_poll | subscriptions | succeeded` row with the events since 15.7 (`events_new`) and the subscriptions they touched (`updated`, `inserted`); the cursors `juo:cadence` and `juo:events` with that run's start as `at`. Then a run every 5 minutes.

**Browser:** Workspace → Configuration → System health.

Expected: the row **Subscriptions poll** with its last run succeeded, and the connection **Juo GB** OK. After 03:30 the next day: a **Nightly reconcile** run of the connection, stream `subscription`, succeeded, `missing_now` the subscriptions Juo no longer returns (usually 0). System health's counts column shows only counts above 0.

Day one: **Studio (cma-prod-pg)**, after `set role cma_owner;` and then `reset role;`: `select job, status, error, count(*) from cma.sync_run where connection_id = '<juo conn>' and started_at > now() - interval '1 day' group by 1, 2, 3 order by 1, 2;`. Expected: about 288 `subscriptions_poll` `succeeded` and one `reconcile` `succeeded`; a `failed` with `rate_limited` now and then is fine (the next run carries on). `key_rejected` means the key was revoked or replaced: 15.1 and 15.2 again. `empty_snapshot` on the reconcile means Juo answered no subscription: nothing was marked missing; report it. A failed poll does not move its cadence, so a lasting failure writes one `failed` row every 5 minutes until it is fixed: fix it the same day. **Records:** the outputs of (a), (c) and 15.2 to 15.9 into `records/0008zl-prod-<date>/` in a separate pull request, written from your report (ids, counts and times only; no key or personal data).
