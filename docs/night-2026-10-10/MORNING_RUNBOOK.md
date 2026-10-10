# Morning runbook: the intake track

From an empty start to HubSpot, Aircall and Shopify flowing into Postgres, speed to lead reported and new deals alerting in the Workspace. Read `NIGHT_NOTES.md` §1 first (five minutes). Labels: **Browser**, **Terminal** (Cloud Shell, `~/cma`), **Studio** (instance named), **Claude Code** (a brief from `BRIEFS.md`). SQL and shell never share a block. Every step ends with what you should see.

**Realistic pace.** Tomorrow morning: phases 0 and 1, and phase 2 if B6 and B7 are back from Claude Code. The whole runbook is five to seven working days of elapsed time, most of it Claude Code building and you reviewing and releasing; phases 3 to 6 can run in any order once their migration is in.

| Phase | What | Needs | Elapsed |
|---|---|---|---|
| 0 | Pack in the repo, Yordi, Claude Code started, vendor prerequisites | nothing | 1–1.5 h |
| 1 | Migration 0007 in dev and prod, dev configuration | B0, B1 | 1 h after B1 |
| 2 | HubSpot end to end in dev | B6, B7, B8 | half a day |
| 3 | Messaging and new-deal alerts in dev | B5, B12 | 2–3 h |
| 4 | Aircall in dev (replay) | B2, B9 | 2–3 h |
| 5 | Shopify in dev (development store), with the write-back to HubSpot | B3, B13, B10 | half a day |
| 6 | Lead metrics and reports in dev | B4, B11 | 2–3 h |
| 7 | Prod, source by source | phases 1–6, Yordi heads-up sent | 1 day |

---

## Helpers (define in every new Cloud Shell)

**Terminal**
```bash
cma_db () {  # usage: cma_db dev|prod  → starts the proxy once and sets PGCONN
  local env=$1 port; [ "$env" = dev ] && port=5433 || port=5434
  pgrep -f "cloud-sql-proxy.*cma-$env-pg" >/dev/null || \
    (cloud-sql-proxy --auto-iam-authn --port $port "p4a-cma-$env:europe-west4:cma-$env-pg" >/tmp/proxy-$env.log 2>&1 &)
  sleep 3
  export PGCONN="host=127.0.0.1 port=$port dbname=cma user=$(gcloud config get-value account 2>/dev/null) sslmode=disable"
  psql "$PGCONN" -Atc "select 'connected to ' || current_database() || ' as ' || current_user"
}
run_migration () {  # usage: run_migration <env> <nn_migration.sql> <nn_verify.sql> <records dir> [earlier verify files...]
  local env=$1 mig=$2 ver=$3 rec=$4; shift 4
  cd ~/cma && mkdir -p "records/$rec" && cma_db "$env" || return 1
  psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$mig" > "records/$rec/${mig%%_*}.txt" 2>&1 && tail -3 "records/$rec/${mig%%_*}.txt"
  psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$ver" > "records/$rec/${ver%%_*}.txt" 2>&1; tail -6 "records/$rec/${ver%%_*}.txt"
  sed "s/select set_config('verify.provoke', 'false', false);/select set_config('verify.provoke', 'true', false);/" "db/$ver" > /tmp/provoke.sql
  psql "$PGCONN" -v ON_ERROR_STOP=0 -f /tmp/provoke.sql > "records/$rec/${ver%%_*}-provoked.txt" 2>&1
  grep -cE "FAIL" "records/$rec/${ver%%_*}-provoked.txt" | sed 's/^/provoked FAIL lines: /'; grep -E "PROVOKED" "records/$rec/${ver%%_*}-provoked.txt" | tail -2
  for f in "$@"; do psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$f" > "records/$rec/${f%%_*}-rerun.txt" 2>&1; echo "$f: $(grep -cE '\| PASS' "records/$rec/${f%%_*}-rerun.txt") PASS rows"; done
}
put_secret () {  # usage: put_secret <project> <name>   → hidden prompt, never echoed, never in history
  gcloud secrets describe "$2" --project="$1" >/dev/null 2>&1 || \
    gcloud secrets create "$2" --project="$1" --replication-policy=user-managed --locations=europe-west4 >/dev/null
  read -rsp "Paste value for $2 (hidden), then Enter: " v; echo
  printf %s "$v" | gcloud secrets versions add "$2" --project="$1" --data-file=- >/dev/null && echo "stored $2 (version added)"; unset v
}
```
Expected after `cma_db dev`: `connected to cma as martin@pulse4all.com`.

**Studio context** (every Studio session that calls a configuration function; dev uses the dev seed's admin, prod uses you):

**Studio (cma-dev-pg)**
```sql
set role cma_owner;
select t.slug, t.id as tenant_id, u.id as user_id, u.email
from cma.tenant t join cma.app_user u on u.tenant_id = t.id
where t.slug = 'pulse4all-subscriptions' and u.email in ('admin@example.com', 'martin@pulse4all.com');
reset role;
```
Then, with the two ids from that row:
```sql
set role cma_app;
select set_config('app.tenant_id', '<tenant_id>', false),
       set_config('app.user_id', '<user_id>', false),
       set_config('app.actor_label', 'studio:martin', false);
```
Every configuration statement below runs after this block in the same Studio tab; `reset role;` at the end.

---

## Phase 0. Start (about 1 to 1.5 hours, much of it in parallel)

### 0.1 The pack into the repository

The download link and its sha256 are in the chat message that delivered this pack.

**Terminal**
```bash
cd ~/cma && git switch main -q && git pull -q --ff-only && git log --oneline -1
curl -fsSL -o ~/night-2026-10-10.tgz '<URL from the chat>'
echo '<sha256 from the chat>  /home/'"$USER"'/night-2026-10-10.tgz' | sha256sum -c
tar -xzf ~/night-2026-10-10.tgz -C ~/cma && ls docs/night-2026-10-10
git switch -c docs/night-2026-10-10 && git add docs/night-2026-10-10 && git commit -qm "Night pack 10 Oct 2026: intake track design, briefs and runbook" && git push -qu origin docs/night-2026-10-10
```
Expected: `main` at `b95dcc7` (or newer), `night-2026-10-10.tgz: OK`, seven files listed (`README.md`, `NIGHT_NOTES.md`, `DESIGN.md`, `BRIEFS.md`, `VENDOR_SETUP.md`, `MORNING_RUNBOOK.md`, `YORDI_HEADS_UP.md`), the push prints nothing.

**Browser:** GitHub → the compare banner for `docs/night-2026-10-10` → Create pull request → Squash and merge. (Docs only; no build is triggered because the trigger watches `web/**`.)

### 0.2 Yordi

**Browser:** Gmail → send `YORDI_HEADS_UP.md` (paste the text). Nothing waits on his answer except phase 7 (prod), which waits on the heads-up being *sent* (README rule); if he answers with a change, it is a configuration or a scope change, not a rebuild.

### 0.3 Start Claude Code (three parallel sessions)

**Claude Code:** B0 (README pass), B1 (migration 0007), B6 (HubSpot project). Paste each brief from `BRIEFS.md` into its own session. Expected: three draft PRs within the hour; B1 is the long one.

### 0.4 HubSpot prerequisites (while Claude Code works)

**Browser:** `VENDOR_SETUP.md` §1.2: create the developer test account `CMA dev` and note its account id. Then §1.1: the nine contact properties in `CMA dev` and in the live portal (about 20 minutes per portal). Then the rest of §1.2 in `CMA dev` (pipelines, the test form, five test contacts; the Shopify ids on two of them come in phase 5).
Also note the live portal's host from the browser address bar: `app.hubspot.com` or `app-eu1.hubspot.com`.

Expected: both portals show the group "Pulse4all market and ids" with nine properties; `CMA dev` has its account id written down.

### 0.5 Shopify prerequisites

**Browser:** `VENDOR_SETUP.md` §3.1 (organisation check), §3.3 (development store `cma-dev` and the app **CMA ingest dev**, installed on `cma-dev`, test gateway on, three customers and five orders), §3.2 (the prod app **CMA ingest**, scopes, custom distribution, the **Email** protected field, installed on every store; installing starts no data flow, subscriptions do). Write down per store: handle, market, currency, time zone.

Expected: Dev Dashboard shows both apps; the prod app's Installs count equals the number of stores. If a store is missing from the install list, it is in another organisation: note it, phase 5 creates a second app for it.

### 0.6 Aircall check and the Make inventory

**Browser:** Aircall Dashboard → Integrations & API: confirm **API Keys** exists (no key yet; it is created in phase 7). Make: list the scenarios that write any of the nine contact properties (`VENDOR_SETUP.md` §4); nothing changes in Make until phase 7, where those modules are switched off before the CMA's write-back goes live.

---

## Phase 1. Migration 0007 (after B1's PR is ready; B0 can merge any time before)

### 1.1 Review and check out

**Terminal**
```bash
cd ~/cma && git fetch -q && git switch -q <B1 branch> && git log --oneline -3 && ls db/32_* db/33_* docs/night-2026-10-10/local-records/0007/
```
Expected: the two scripts and Claude Code's local outputs, whose last verdict lines read PASS for both tenants (and PROVOKED, NOT A PASS in the provoked file).

### 1.2 Dev

**Terminal**
```bash
run_migration dev 32_intake_core.sql 33_verify_intake_core.sql 0007-dev-$(date +%F) 31_verify_ingest_crm_records.sql
```
Expected: the migration's last lines record `0007`; the verdict table with `PASS` for `pulse4all-invest` and `pulse4all-subscriptions`; `provoked FAIL lines:` a number above zero and `PROVOKED, NOT A PASS` twice; `31_verify_ingest_crm_records.sql: 2 PASS rows`.

### 1.3 Prod

**Browser:** Console → SQL → `cma-prod-pg` → Backups: point-in-time recovery shows enabled (else take an on-demand backup first).

**Terminal**
```bash
run_migration prod 32_intake_core.sql 33_verify_intake_core.sql 0007-prod-$(date +%F) 31_verify_ingest_crm_records.sql
git add records/0007-*-$(date +%F) && git commit -qm "0007: records dev and prod" && git push -q && git log --oneline -1
```
Expected: the same as dev. **Browser:** the B1 PR → Squash and merge (database only, no build).

### 1.4 Dev configuration: markets, aliases, office hours

**Studio (cma-dev-pg)** after the Studio context block (dev seed admin):
```sql
select cma.upsert_market('GB', 'United Kingdom', 'Europe/London',     'en', 'GBP', null, null, 10);
select cma.upsert_market('IE', 'Ireland',        'Europe/Dublin',     'en', 'EUR', null, null, 11);
select cma.upsert_market('NL', 'Netherlands',    'Europe/Amsterdam',  'nl', 'EUR', null, null, 20);
select cma.upsert_market('BE', 'Belgium',        'Europe/Brussels',   'nl', 'EUR', null, null, 21);
select cma.upsert_market('DE', 'Germany',        'Europe/Berlin',     'de', 'EUR', null, null, 30);
select cma.upsert_market('AT', 'Austria',        'Europe/Vienna',     'de', 'EUR', null, null, 31);
select cma.upsert_market('CH', 'Switzerland',    'Europe/Zurich',     'de', 'CHF', null, null, 32);
select cma.upsert_market('FR', 'France',         'Europe/Paris',      'fr', 'EUR', null, null, 40);
select cma.upsert_market('SE', 'Sweden',         'Europe/Stockholm',  'sv', 'SEK', null, null, 50);
select cma.upsert_market('DK', 'Denmark',        'Europe/Copenhagen', 'da', 'DKK', null, null, 51);
select cma.upsert_market('NO', 'Norway',         'Europe/Oslo',       'no', 'NOK', null, null, 52);
select cma.upsert_market('FI', 'Finland',        'Europe/Helsinki',   'fi', 'EUR', null, null, 53);
select cma.set_market_alias(a, c) from (values
  ('uk','GB'),('united kingdom','GB'),('great britain','GB'),('england','GB'),('ireland','IE'),
  ('netherlands','NL'),('nederland','NL'),('the netherlands','NL'),('belgium','BE'),('belgie','BE'),('belgië','BE'),
  ('germany','DE'),('deutschland','DE'),('austria','AT'),('österreich','AT'),('switzerland','CH'),('schweiz','CH'),
  ('france','FR'),('sweden','SE'),('sverige','SE'),('denmark','DK'),('danmark','DK'),('norway','NO'),('norge','NO'),
  ('finland','FI'),('suomi','FI')) v(a, c);
select cma.set_business_hours('*', d::smallint, '09:00-17:00') from generate_series(1, 5) d;
select key, name from cma.skill where dimension = 'language' order by sort_order;
reset role;
```
Expected: twelve empty results for the markets, 26 rows of `set_market_alias`, five of `set_business_hours`, then the tenant's language skill keys. Belgium is set to Dutch; change it to `fr` or split it later if the team prefers.

With the language keys from the last result, link each market to its skill (example for keys `english`, `dutch`; use the real keys and the minimum level the team wants, 3 = Fluent):

**Studio (cma-dev-pg)** after the context block
```sql
select cma.upsert_market(code, name, time_zone, language_code, currency, '<skill key>', 3::smallint, sort_order)
from cma.market where language_code = '<en|nl|de|fr|sv|da|no|fi>';
reset role;
```
Expected: one row per updated market. (Repeat per language.)

---

## Phase 2. HubSpot end to end in dev (after B6 and B7 are merged; B8 for the jobs)

### 2.1 Deploy the ingest service to dev

**Terminal**
```bash
cd ~/cma && git switch -q main && git pull -q --ff-only && bash docs/ingest/deploy.sh dev
```
Expected: the image built and pushed, the service `cma-ingest` deployed in europe-west4, the URL printed (`https://cma-ingest-…europe-west4.run.app`), and one Studio statement printed for the IAM database user's grant.

**Studio (cma-dev-pg)**: paste the printed grant statement as is. Expected: `GRANT ROLE`.

**Terminal**
```bash
curl -s "$(gcloud run services describe cma-ingest --project=p4a-cma-dev --region=europe-west4 --format='value(status.url)')/health"
```
Expected: `{"ok":true,"version":"<short sha>"}` (or the shape B7 documents).

### 2.2 The dev connection

**Studio (cma-dev-pg)** after the context block (replace `<CMA dev account id>`):
```sql
select * from cma.upsert_connection('hubspot', 'HubSpot CMA dev', '<CMA dev account id>',
                                    'ingest-hubspot-dev-signing', 'ingest-hubspot-dev-token');
```
Expected: one row with `connection_id` and `key`. Keep both in the tab; the key goes into the webhook URL (it is not a secret, the signature is the proof).

**Studio (cma-dev-pg)** (same tab, `<conn>` = the connection id):
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
Use the host you noted in 0.4 for the live portal; developer test accounts in the EU data centre also use `app-eu1`. Expected: the last result is the mapping as JSON with twelve fields. The deal's `market` comes from `deal_country` (country names, turned into codes by the market aliases of 1.4), then from the contact's country (decision of 10 October 2026, migration 0007d).

### 2.3 Render, upload and install the dev app

**Terminal**
```bash
npm install -g @hubspot/cli@latest >/dev/null 2>&1; hs --version
hs account auth
```
Expected: a CLI version ≥ 7.6; `hs account auth` asks for a personal access key: Browser → live portal → the link the CLI prints → generate the key → paste it at the prompt. The account is the **live portal** (projects live in its Development area), not `CMA dev`.

**Terminal** (`<URL>` from 2.1, `<key>` from 2.2)
```bash
cd ~/cma && node hubspot/render.mjs dev --target-url "<URL>/hubspot/<key>" && cd hubspot/build/dev && hs project upload && cd ~/cma
```
Expected: render writes `hubspot/build/dev`; the upload ends with a successful build and deploy of project **CMA ingest dev**.

**Browser:** live portal → Development → Projects → CMA ingest dev → the app → Distribution → **Test installs** → Install in `CMA dev` → review the scopes (read-only, plus write on contacts for the write-back) → Connect app.

### 2.4 The two dev secrets

**Terminal**
```bash
put_secret p4a-cma-dev ingest-hubspot-dev-signing    # paste the app's client secret (Auth tab)
put_secret p4a-cma-dev ingest-hubspot-dev-token      # paste the static access token of the test install
for s in ingest-hubspot-dev-signing ingest-hubspot-dev-token; do
  gcloud secrets add-iam-policy-binding "$s" --project=p4a-cma-dev \
    --member="serviceAccount:cma-ingest@p4a-cma-dev.iam.gserviceaccount.com" --role=roles/secretmanager.secretAccessor >/dev/null && echo "accessor on $s"
done
```
Expected: `stored …` twice, `accessor on …` twice. Nothing else is printed.

### 2.5 First events

**Browser:** `CMA dev` → Contacts → test1 → Create deal in **Sales test**. Then on the contact: Log activity → Call, direction Outbound, outcome Connected, five minutes after the deal's creation time.

**Terminal**
```bash
gcloud run services logs read cma-ingest --project=p4a-cma-dev --region=europe-west4 --limit=30 | grep -E "hubspot|signature|header" | tail -10
```
Expected: accepted requests (200) and, if `INGEST_LOG_HEADER_NAMES=1` is set by the deploy, the header names including `x-hubspot-signature-v3` and `x-hubspot-request-timestamp`. **If v3 is missing, stop here** and tell the chat: the fallback (reconcile every two minutes instead of webhooks, NIGHT_NOTES §4 risk 1) is a configuration of the reconcile schedule, not new code.

**Studio (cma-dev-pg)**
```sql
set role cma_owner;
select object_type, kind, status, count(*) from cma.ingest_event group by 1, 2, 3 order by 1, 2;
select record_type, source_id, pipeline_id, stage_id, is_closed, contact_source_id, market from cma.crm_record;
select source_id, country, language, currency, store from cma.crm_contact;
select source_id, direction, occurred_at, status, duration_seconds from cma.crm_call;
select from_type, to_type, removed_at from cma.crm_association;
reset role;
```
(Column names as B1 built them.) Expected: events `processed`; one deal with its contact id and market from the contact's country; the contact with the four attributes; one outbound call; associations call → contact and deal → contact.

### 2.6 Jobs (after B8 is merged)

**Terminal**
```bash
cd ~/cma && git pull -q --ff-only && bash docs/ingest/deploy.sh dev --jobs
gcloud run jobs execute ingest-backfill --project=p4a-cma-dev --region=europe-west4 --wait \
  --args="--connection,<conn>,--object,deal,--from,2026-10-01"
```
Expected: jobs `ingest-sweep`, `ingest-poll-forms`, `ingest-reconcile`, `ingest-backfill` and their schedules; the backfill execution completes. Then submit the test form once from its share link (fake email of test2) and wait two minutes.

**Studio (cma-dev-pg)**
```sql
set role cma_owner;
select job, stream, status, counts, started_at, finished_at from cma.sync_run order by started_at desc limit 10;
select source_form_id, submitted_at, page_host, contact_resolution, kept_values from cma.form_submission;
reset role;
```
Expected: succeeded runs; one submission `resolved` to test2's contact id, `kept_values` empty until the form's Interest field is configured with `cma.set_form(...)`.

Records: **Terminal** `mkdir -p records/intake-hubspot-dev-$(date +%F)` and save the outputs above there (copy from Studio as text), committed with the next PR.

---

## Phase 3. Messaging and new-deal alerts in dev

1. **Claude Code:** B5 (migration 0008), then B12 (web and ingest).
2. **Terminal:** `run_migration dev 42_messaging.sql 43_verify_messaging.sql 0008-dev-$(date +%F) 31_verify_ingest_crm_records.sql 33_verify_intake_core.sql`, then the same for prod (PITR check first), records committed, B5 merged.
3. **Studio (cma-dev-pg)** after the context block — the Pulse4all rule:
```sql
select cma.upsert_message_rule('New deal', 'deal', '{}'::text[], 'leads.accept', true, true, 'leads.manage', 'normal');
select cma.set_connection_settings('<conn>', '{"app_host":"app-eu1.hubspot.com","record_url_deal":"https://{app_host}/contacts/{account}/record/0-3/{id}","record_url_ticket":"https://{app_host}/contacts/{account}/record/0-5/{id}"}'::jsonb);
reset role;
```
Expected: one uuid, then an empty result. The alert's link comes from the template `record_url_<record type>` (0008 keeps no vendor address pattern in the database). `set_connection_settings` replaces all settings, so the statement repeats `app_host`; add any other key the connection already has. Prod later takes the same statement with the live `app_host`.
4. B12 merged → prod builds the web; dev gets the image (README release flow, by short SHA) and the ingest is redeployed: `bash docs/ingest/deploy.sh dev`.
5. Check: in the dev Workspace as an agent with the NL language skill (mock identity switch), clocked in; create a deal in `CMA dev` for a contact with country NL. Expected: a toast within 15 seconds, the inbox count 1, the link opening the deal in `CMA dev`. In Studio: `select title, body, ref_id from cma_read.message order by created_at desc limit 1;` and its delivery row with `delivered_at` and, after opening, `read_at`.

---

## Phase 4. Aircall in dev (replay)

1. **Claude Code:** B2 (migration 0007a), then B9.
2. **Terminal:** `run_migration dev 34_telephony.sql 35_verify_telephony.sql 0007a-dev-$(date +%F) 31_verify_ingest_crm_records.sql 33_verify_intake_core.sql`, then prod, records, merge B2.
3. **Studio (cma-dev-pg)** after the context block: a dev connection with an invented account and invented secrets:
```sql
select * from cma.upsert_connection('aircall', 'Aircall replay (dev)', 'replay-dev', 'ingest-aircall-dev-signing', 'ingest-aircall-dev-token');
reset role;
```
4. **Studio (cma-dev-pg)** after the context block: `select cma.set_connection_settings('<conn>', '{"replay":true}'::jsonb); reset role;` (honoured only by the dev service).
5. **Terminal:** `put_secret p4a-cma-dev ingest-aircall-dev-signing` (type any long random string, for example from `openssl rand -hex 24` in another tab; it never leaves dev), and `put_secret p4a-cma-dev ingest-aircall-dev-token` with `{"api_id":"replay","api_token":"replay"}`; grant the accessor as in 2.4; redeploy (`bash docs/ingest/deploy.sh dev`); replay the fixtures as `docs/ingest/README.md` (Aircall) says.
Expected: `telephony_call` rows with tags opened and closed as the fixtures say; the read-back step is skipped for the replay connection as B9 documents (no Aircall API in dev).

---

## Phase 5. Shopify in dev (development store)

1. **Claude Code:** B3 (migration 0007b), then B13 (migration 0007c, the outbox), then B10.
2. **Terminal:** `run_migration dev 36_commerce.sql 37_verify_commerce.sql 0007b-dev-$(date +%F) 31_verify_ingest_crm_records.sql 33_verify_intake_core.sql`, then prod, records, merge B3. The same for B13: `run_migration dev 38_outbox.sql 39_verify_outbox.sql 0007c-dev-$(date +%F) 31_verify_ingest_crm_records.sql 33_verify_intake_core.sql 37_verify_commerce.sql`, then prod, records, merge B13.
3. **Studio (cma-dev-pg)** after the context block:
```sql
select * from cma.upsert_connection('shopify', 'Shopify cma-dev', 'cma-dev.myshopify.com', 'ingest-shopify-dev-signing', null);
select cma.set_connection_settings('<conn>', '{"client_id":"<dev app client id>","api_version":"2026-10","shop_handle":"cma-dev","crm_connection_id":"<hubspot dev conn>"}'::jsonb);
select cma.upsert_commerce_store('<conn>', 'cma-dev', 'CMA dev store', 'NL', 'EUR', 'Europe/Amsterdam');
select cma.set_writeback_field('<hubspot dev conn>', 'commerce_ref',    'contact_shopify_id_1',         'slot',     true, 1::smallint);
select cma.set_writeback_field('<hubspot dev conn>', 'commerce_ref',    'contact_shopify_id_2',         'slot',     true, 2::smallint);
select cma.set_writeback_field('<hubspot dev conn>', 'commerce_store',  'contact_shopify_store',        'always',   true);
select cma.set_writeback_field('<hubspot dev conn>', 'commerce_orders', 'contact_shopify_total_orders', 'always',   true);
select cma.set_writeback_field('<hubspot dev conn>', 'commerce_spent',  'contact_shopify_total_spent',  'always',   true);
select cma.set_writeback_field('<hubspot dev conn>', 'country',         'contact_country',              'if_empty', true);
select cma.set_writeback_field('<hubspot dev conn>', 'currency',        'contact_currency',             'if_empty', true);
select cma.set_writeback_field('<hubspot dev conn>', 'language',        'contact_language',             'if_empty', true);
reset role;
```
The store dropdown in `CMA dev` needs the option `cma-dev` (add it to Contact-Shopify Store there).
4. **Terminal:** `put_secret p4a-cma-dev ingest-shopify-dev-signing` (the dev app's client secret), accessor grant, redeploy with `bash docs/ingest/deploy.sh dev && bash docs/ingest/deploy.sh dev --jobs` (adds `ingest-outbox`), then `node docs/ingest/shopify-subscribe.mjs --project p4a-cma-dev --shop cma-dev.myshopify.com --client-id <dev app client id> --secret-name ingest-shopify-dev-signing --url "<URL>/shopify/<key>"` and a backfill run for `commerce_customer` and `commerce_order` from 2026-10-01.
5. **Browser:** in `cma-dev`, create one more test order for `test1@example.com`.
Expected: customers and orders in Studio, the earlier orders classified first and repeat correctly (`order_kind`), the new order arriving within a minute by webhook. Within two minutes, in `CMA dev`: test1, test2 and test4 show Contact-Shopify ID-1, Store `cma-dev` and their totals; test4 (which had no country) now shows NL and EUR, while the contacts that had a country keep theirs; `select status, count(*) from cma_read.outbox_action group by 1;` shows `sent`; `nobody@example.com` appears only as a count in `select * from cma.data_quality();`.

---

## Phase 6. Lead metrics and reports in dev

1. **Claude Code:** B4 (migration 0007d), then B11.
2. **Terminal:** `run_migration dev 40_lead_metrics.sql 41_verify_lead_metrics.sql 0007d-dev-$(date +%F) 31_verify_ingest_crm_records.sql 33_verify_intake_core.sql 35_verify_telephony.sql 37_verify_commerce.sql`, then prod, records, merge B4.
3. **Studio (cma-dev-pg)** after the context block:
```sql
select * from cma.speed_to_lead_rows(current_date - 7, current_date);
select * from cma.speed_to_lead_summary(current_date - 7, current_date, 'market');
select * from cma.lead_to_order_rows(current_date - 7, current_date);
select * from cma.data_quality();
reset role;
```
Expected: the phase 2 deal with about five business minutes to first call (if created within office hours); lead to order for the contact that got a Shopify id and an order after the deal; data-quality counts that make sense for the test data.
4. B11 merged → the Report pages in dev show the same numbers.

---

## Phase 7. Prod, source by source

Gates: the Yordi heads-up is sent (0.2); NocoDB: the new `cma_read` views are visible to NocoDB's workspace members, so either hide them in NocoDB or keep the workspace to the build team (`YORDI_HEADS_UP.md` names it); `cma-ingest` prod with min instances 1.

1. **Terminal:** `bash docs/ingest/deploy.sh prod && bash docs/ingest/deploy.sh prod --jobs`, the printed grant in **Studio (cma-prod-pg)**.
2. **Studio (cma-prod-pg)** after the context block (as yourself): the market, alias and office-hours statements of 1.4 and the market-to-skill links; the message rule of phase 3.
3. **HubSpot:** connection as in 2.2 with the live portal's account id and secret names `ingest-hubspot-subs-signing`, `ingest-hubspot-subs-token`, the live host in `app_host`; render prod with the prod URL and key, upload, **Standard install** in the live portal, the two secrets with `put_secret p4a-cma-prod …`, accessor grants. Then backfill deal, ticket, crm_call, form_submission from 2026-10-01. Then pipelines: `select * from cma.connections_all();` and `cma.set_connection_pipeline(...)` / `cma.set_pipeline_lead(...)` for the test pipelines (not counted) and the lead pipelines; forms: `cma.set_form(...)` per counted form with its market and lead source; call outcomes: `cma.set_call_outcome(<conn>, '<Connected guid>', true)`.
4. **People:** **Terminal** `node docs/ingest/hubspot-owners.mjs --project p4a-cma-prod --token-secret ingest-hubspot-subs-token` and, after step 5, `node docs/ingest/aircall-users.mjs --project p4a-cma-prod --api-secret ingest-aircall-subs-token`; each prints one `select cma.set_user_external_id(...)` per person who exists in the CMA. Paste those into **Studio (cma-prod-pg)** after the context block. People without a line are not in the CMA yet (data quality lists them).
5. **Aircall:** API key (VENDOR_SETUP §2.2) into `put_secret p4a-cma-prod ingest-aircall-subs-token` as `{"api_id":"…","api_token":"…"}`; connection `upsert_connection('aircall', 'Aircall Subscriptions', '<company id>', 'ingest-aircall-subs-signing', 'ingest-aircall-subs-token')`; `node docs/ingest/aircall-webhook.mjs --project p4a-cma-prod --url "<prod URL>/aircall/<key>" --api-secret ingest-aircall-subs-token --token-secret ingest-aircall-subs-signing` (it stores the webhook token itself); accessor grants; backfill `telephony_call` from 2026-10-01; lines and markets with `cma.set_telephony_number(...)`.
6. **Make, then Shopify:** first switch off the Make modules found in 0.6 that write the nine properties (one writer per property). Then per store: connection (`<handle>.myshopify.com`), settings with the prod app's client id and `crm_connection_id` = the live HubSpot connection, the write-back fields of phase 5 on the live HubSpot connection (once), `upsert_commerce_store`, the shared client secret once as `ingest-shopify-app-signing` (every store connection names it), subscriptions with `shopify-subscribe.mjs --project p4a-cma-prod --shop <handle>.myshopify.com --client-id <prod client id> --secret-name ingest-shopify-app-signing --url "<prod URL>/shopify/<key of that store>"`, backfill customers and orders from 2026-10-01.
7. **Check end to end** on the first real new deal of the day: alert delivered, deal and contact rows, the Aircall call and its HubSpot call engagement, `call_link` within two hours (sweep), the deal in `speed_to_lead_rows`. Compare the engagement's `occurred_at` with the Aircall call's `started_at` for the same call: equal within seconds means HubSpot's timestamp is the start (NIGHT_NOTES §4 risk 6); minutes apart means the effective start must come from the link, which DESIGN §4.4 already does.
8. Records: `records/intake-prod-<date>/` with the Studio outputs of the checks; README pass by Claude Code (B0's follow-up: status lines in Environments).
