# Night notes: the intake track, 9 to 10 October 2026

Written for Martin by the night chat, on his mandate: "make sensible decisions and continue; no input from Yordi, Joshua or Peter during this session". README.md (twenty-third pass, `main` at `b95dcc7`) was the starting point; everything below that changes it lands through brief B0. Nothing here was run against dev, prod or a vendor: this night produced design, briefs and runbook, no code (Claude Code on the web builds, per the workflow since 9 October 2026).

## 1. Read this first

- **What you asked for is all in**: HubSpot form submissions, every deal and ticket opened and closed, Aircall calls in and out with their tags, every Shopify store's new customers and orders (first, repeat and renewal), speed to lead from deal created to the first call started on that HubSpot contact, everything in Postgres tables readable by BigQuery, and an in-Workspace alert on every new deal. `DESIGN.md` §1 maps each need to its table, source and surface.
- **Added, because the build needs it** (§3): a market catalog with office hours (speed to lead in business time), lead to order, data-quality checks, a sync audit trail, nightly reconciliation, backfill from the insights start (1 October 2026).
- **Two vendor changes forced choices**: HubSpot no longer lets anyone create legacy private apps (new accounts since 28 September 2026, existing portals from 26 October 2026), so HubSpot runs on project apps; Shopify stopped admin-created custom apps on 1 January 2026, so Shopify runs on a Dev Dashboard app with the client credentials grant (tokens live 24 hours).
- **Speed to lead is measured on HubSpot's call engagements** (the Aircall integration logs every call on the matching contact), with Aircall's own call as the call facts and tags, linked by a keyed hash of the number. Exactly "the first call started on that HubSpot contact", and robust if one side lags.
- **Realistic pace**: fourteen pull requests and six migrations; five to seven working days elapsed. Tomorrow morning: phases 0 and 1 of the runbook, phase 2 when B6 and B7 are back.
- **Nothing goes through Make** (Martin, 10 October 2026): HubSpot, Aircall and Shopify talk to the ingest service directly, and the CMA itself writes the Shopify ids, store and totals into HubSpot (and country, currency, language when empty) through an outbox (migration 0007c). What is left for you in Make: switch off the modules that write those nine properties today, at the prod switch-on, so each property has one writer.

## 2. Decisions taken in the night (Decision log rows, 10 October 2026, "night session, to confirm")

| # | Decision | Reason |
|---|---|---|
| D1 | The speed-to-lead track becomes the **intake track**: HubSpot (deals, tickets, contacts, call engagements, forms), Aircall, Shopify, lead metrics, new-deal alerts; S2 routing and S3 offers follow as migration 0009 | Martin's scope of 9 October night; the reports need all sources before routing is worth tuning |
| D2 | HubSpot through **project apps** (static auth, private distribution), one per environment and portal (`CMA ingest dev` test-installed in the developer test account only, `CMA ingest prod` standard-installed in the live portal), rendered from one template in `hubspot/`; no legacy private app and no legacy fallback (Martin, 9 October) | Legacy private-app creation is ending; the webhook target URL is set per app in the project configuration, so dev and prod need two apps |
| D3 | If the project app does not send `X-HubSpot-Signature-v3`, webhooks are switched off and the reconcile job runs every two minutes with a short look-back (polling), not a weaker signature | Without v3 there is no replay protection; reconcile already exists for missed webhooks |
| D4 | Form submissions are **polled** every minute (`/form-integrations/v1/submissions/forms/{guid}`); the contact is found by a CRM search on the submitted email, which stays in memory; field values are dropped except fields a form explicitly allowlists as non-personal | HubSpot offers no webhook for submissions, and the endpoint carries no contact id |
| D5 | Calls come from **two sources by purpose**: HubSpot call engagements (the contact and deal link; speed to lead) and Aircall calls (call facts, answered, durations, tags; README's source of truth for call facts), linked by `HMAC-SHA256(pepper, E.164)` of the customer's number and a 120-second window | Aircall's webhook does not carry the HubSpot contact; HubSpot's engagement does not carry Aircall's tags reliably; numbers are never stored |
| D6 | Speed to lead as defined in `DESIGN.md` §4.4: deal `createdate` → first outbound call associated with the deal's contacts or the deal, effective start from Aircall when linked; business time per market; target 60 business minutes; "before 12:00 next working day" as Kira's KPI says | Auditable, matches KPI section 1 and Martin's wording |
| D7 | A **market catalog** per tenant (ISO country, IANA zone, language, language skill and minimum level, currency) with aliases; **GB, not UK** as the code, "United Kingdom" as the label | ISO 3166-1; Shopify, Aircall, NetSuite and libphonenumber all use GB; aliases absorb sources that write UK |
| D8 | Office hours **Mon–Fri 09:00–17:00 local** per market as the provisional default | README Open decision (office hours per country) stays open; Aircall lines close at 17:00 today |
| D9 | Martin's HubSpot properties with internal names `contact_country`, `contact_language`, `contact_currency`, `contact_shopify_store`, `contact_shopify_id_1`, `contact_shopify_id_2`, `contact_netsuite_id`, `contact_shopify_total_orders`, `contact_shopify_total_spent`; codes as stored values; Shopify ids 1 and 2 as ref slots of one ref system | `VENDOR_SETUP.md` §1.1 |
| D10 | **The CMA keeps HubSpot's copy of the Shopify facts**, not Make (Martin, 10 October 2026: as little as possible through Make, as much as possible directly): the Shopify adapter finds the contact by the customer's email (in memory only) and writes Contact-Shopify ID-1/ID-2, store and totals, and country, currency and language only when empty, through the outbox (DESIGN §4.3a); contact creation stays where it is today | One integration path to audit; one writer per property; HubSpot keeps showing agents the link |
| D11 | Shopify through a **Dev Dashboard app, custom distribution**, one per Shopify organisation, installed on every store; client credentials grant; **shop-specific** webhook subscriptions to a per-store URL key; Level 1 protected customer data (names, emails, phones and addresses redacted at the source); `read_all_orders` requested | The only way to create an app since 1 January 2026; per-store keys keep 0006's one-key-per-connection model |
| D12 | First or repeat order = Shopify's lifetime `numberOfOrders` of the customer minus the customer's orders created at or after this order (`ordersCount`); renewal by configurable source names or app ids (Juo) | Exact without loading legacy orders (insights start 1 October 2026 stays) |
| D13 | Aircall webhooks created by a script through the API, which pipes the token into Secret Manager; verification by the body token (Aircall has no HMAC) plus the opaque path key; dev receives replayed fixtures only | Dashboard-created webhooks hide their token; dev holds test data only |
| D14 | One ingest service `cma-ingest` (routes per adapter) and four Cloud Run jobs (sweep every minute, forms poll every minute, reconcile 02:30, backfill on demand); min instances 1 in prod | HubSpot and Shopify expect a quick answer; the jobs give completeness and an audit trail |
| D15 | **Messaging core moves up to 0008** and ships with its first use, new-deal alerts: one message per rule and record, recipients resolved at send time (agents clocked in with the market's language at the minimum level; nobody → supervisors), polling every 10 s with a browser notification; the realtime service stays an open decision | README Features 7 and its polling fallback; agents see new leads before S3's accept click exists |
| D16 | Migration numbering: 0007 intake core, 0007a telephony, 0007b commerce (replaces the planned 0006a), 0007c outbox and CRM contact write-back, 0007d lead metrics, 0008 messaging, then 0009 assignments (on 0007c's outbox), 0010 customer-field mirror, 0011 queue engine; scripts `32` to `43`, released in the runbook's order (each depends only on lower numbers it names) | One reviewable migration per concern |
| D17 | Data quality as views (`cma_read.dq_*`) and one function for the Data page: the Data first list made measurable | KPI section 11 |
| D18 | Nothing personal is stored (`DESIGN.md` §2.1); a keyed hash is the only trace of a phone number; `ingest_contact_forget` handles HubSpot privacy deletions | Data minimisation; README rule that the CMA shows no customer data |
| D19 | **The outbox lands now** (0007c), README's design (claim, in-flight, sent, failed, `needs_review` with a named person), first action the contact write-back; 0009's owner write-back reuses it | The write-back needs it; building it once |
| D20 | The HubSpot app gets **contacts write** as its only write scope; the CMA writes only the properties in `writeback_field` (database and code check), every write an outbox row with HubSpot's answer; Shopify's app asks for the single protected field **Email** | Least privilege within HubSpot's scope granularity; auditable |

## 3. What the night added and why

0. **The outbox and the contact write-back** (DESIGN §4.3a): replaces the Make dependency of the first draft.
1. **Lead to order** (deal → first order of a linked Shopify customer within 90 days, its kind and days): KPI section 1 asks for lead-to-order conversion and time to order; the data is there once Shopify ids are on contacts.
2. **Market catalog, aliases, office hours, holidays**: speed to lead "within office hours" is Kira's definition; the catalog also serves S2 (market → language skill).
3. **`intake_per_day`**: one read for the Dashboard and BigQuery with every intake count per business date and market.
4. **Data quality**: the checks of DESIGN §4.4 (including unmatched Shopify customers and parked write-backs) on the Data page and as views.
5. **`sync_run` and reconcile**: every job leaves an auditable row; reconcile catches missed webhooks (HubSpot retries for a limited time; Shopify drops subscriptions after repeated failures, which reconcile recreates).
6. **Backfill from 1 October 2026** so the reports start complete on the insights start date.
7. **`call_link`** and the effective call start: protects speed to lead if HubSpot's call timestamp turns out to be the end of the call (risk 6).
8. **Message stats**: time from alert to read per alert, the first speed measure before the accept click.

## 4. Risks and what is not verified

1. **v3 on project apps** is not confirmed by HubSpot's documentation for this app type; the first delivery in dev shows it (runbook 2.5). Fallback D3.
2. **Aircall's authentication** is a token in the body, weaker than an HMAC; mitigated by HTTPS, the opaque path key, constant-time compare, idempotent events and read-back from Aircall's API (a forged event can only make the CMA read a real call by id).
3. **Shopify organisations**: the client credentials grant works only for stores in the app's organisation; a store elsewhere needs its own app (runbook 0.5).
4. **Shopify plan**: merchant-created custom apps on Basic or Starter plans get no protected customer data at all (Shopify community, staff answer); if a store is on such a plan, its orders webhook may be refused. Check per store in 0.5.
5. **Aircall API** availability depends on the plan (runbook 0.6).
6. **HubSpot's call timestamp** for Aircall-logged calls is assumed to be the call's start; verified on the first prod call (runbook 7.7). If not, the link supplies the start.
7. **Shared numbers**: Aircall logs a call to the most recently updated contact when two share a number, so a call can land on the wrong contact. Data quality shows calls without the expected contact; the fix is in HubSpot.
8. **Forms**: the v1 submissions endpoint covers HubSpot's own forms; non-HubSpot (collected) forms may not be returned. Check the form list after the first catalog refresh.
9. **Rate limits**: backfill and form-contact searches are throttled below half of HubSpot's search limit; a large backfill takes minutes to hours, not seconds.
10. **Shopify's Email field**: the match needs it. With custom distribution it is a selection in the Dev Dashboard, not a review, according to the documentation; if Shopify refuses, the fallback is VENDOR_SETUP §4 (Make writes only the Shopify id; the CMA does the rest). Until a contact carries its Shopify id, lead to order cannot attribute that customer's orders (data quality shows how many).
11. **Claude Code sessions stopping**: every brief asks to push early and open a draft PR after the first passing verifier, so a stopped session loses little; restart with the same brief plus "continue on branch <name>".
12. **NocoDB** reads `cma_read`, which now includes contact ids, call and order rows (no personal data, ids only). Named in the heads-up to Yordi.
13. **Effort**: Claude Code writes the code; the work that remains with Martin is review, five migration releases in two environments, vendor setup and checks: about 22 to 27 hours of his time.
14. **Contacts write scope**: HubSpot's scope covers every contact property; the CMA limits itself by configuration and code. A bug could still write a wrong value to an allowed property: every write is an outbox row, and HubSpot's property history names the app, so it is traceable and reversible.
15. **Two writers**: until the Make modules are switched off (phase 7), Make and the CMA would both write the Shopify fields in prod; the runbook switches Make off first.

## 5. README edits (brief B0 applies exactly these)

- **Decision log**: rows D1–D20 of §2, dated 10 October 2026, marked "(night session, Martin's mandate; to confirm)".
- **Roadmap**, the speed-to-lead paragraph under step 3: replaced by "**Intake track** (since 10 October 2026, Martin; design `docs/night-2026-10-10/DESIGN.md`): I1 intake core (0007: markets and office hours, HubSpot call engagements, associations, forms, sync audit), I2 HubSpot through project apps into the ingest service with jobs, I3 telephony (0007a, Aircall), I4 commerce (0007b, Shopify per store) with the outbox and the CRM contact write-back (0007c), I5 lead metrics and data quality (0007d), I6 messaging core with new-deal alerts (0008), I7 reports in the Workspace; then S2 routing and S3 offers (0009). Progress is recorded in this README."
- **Planned migrations**: the table becomes 0007 Intake core, 0007a Telephony, 0007b Commerce, 0007c Outbox and CRM contact write-back, 0007d Lead metrics, 0008 Messaging core and record alerts, 0009 Assignments (S2, S3, on 0007c's outbox), 0010 Customer-field mirror, 0011 Queue engine; the 0006a row is removed; the paragraph under the table explains the move.
- **Source of truth**: add rows "Form submissions: CRM (HubSpot), polled into Postgres, contact id only"; "Call engagement on the contact: CRM (HubSpot, logged by the telephony integration); the CMA reads it for the contact link"; amend "Orders": "Shopify; read directly per store; HubSpot holds the copy the CMA writes (ids, store, totals)"; in "What is written back to the CRM" add "the Shopify-derived contact fields (Shopify ids, store, totals; country, currency and language only when empty), through the outbox since 0007c"; Architecture's Outbox worker paragraph: lands with 0007c.
- **Architecture**, Ingest API paragraph: webhooks from HubSpot, Aircall and Shopify arrive directly at the ingest service per adapter route; Make and n8n keep using it for other sources; jobs sweep, poll-forms, reconcile, backfill.
- **KPIs, section 1**: "Speed to lead is defined in DESIGN §4.4 (night of 10 October 2026); office hours per market are tenant configuration."
- **Features 4 Speed to lead**: a note that the first increment is measurement and alerts; assignment and accept follow (0009).
- **Features 7 Messaging**: the first increment is record alerts (0008).
- **Open decisions**: remove the line about legacy private-app v3 headers; replace the S1 heads-up line with "Heads-up to Yordi for the intake track: sent <date> (`docs/night-2026-10-10/YORDI_HEADS_UP.md`)"; add: v3 on project apps (confirmed or the D3 fallback); Shopify's Email field for the match (granted, or the VENDOR_SETUP §4 fallback); moving the remaining Make scenarios (contact creation from Shopify, quotes) into the CMA, one at a time; Aircall token authentication (accepted with mitigations); Shopify organisations and store plans; HubSpot call timestamp semantics; office hours and holidays per market with Kira (provisional default D8); renewal source names for Juo; Belgium's language (nl by default); which forms count and their markets; NocoDB visibility of the new views.
- **Environments**: the dev and prod status rows gain "migration 0006 since 9 October 2026 (records/0006-dev-2026-10-09, records/0006-prod-2026-10-09)"; the Welcome section's "Messaging, migration 0006" becomes "Messaging, migration 0008".
- **Last updated**: twenty-fourth pass, the intake track.

## 6. Effort, per brief

| Brief | What | Claude Code | Martin |
|---|---|---|---|
| B0 | README pass | 20 min | 10 min review |
| B1 | 0007 intake core | 1.5–2.5 h | 45 min review + release |
| B2 | 0007a telephony | 1 h | 30 min |
| B3 | 0007b commerce | 1 h | 30 min |
| B4 | 0007d lead metrics | 1.5–2 h | 45 min |
| B5 | 0008 messaging | 1–1.5 h | 30 min |
| B6 | HubSpot project | 30 min | 1 h upload, install, secrets |
| B7 | ingest core + HubSpot | 2–3 h | 1.5 h deploy and test |
| B8 | jobs | 1.5–2 h | 1 h |
| B9 | Aircall | 1.5 h | 1 h (dev), 1 h (prod) |
| B13 | 0007c outbox and write-back | 1–1.5 h | 30 min |
| B10 | Shopify, match and outbox worker | 2.5–3 h | 2.5 h (stores, subscriptions, Make switch-off) |
| B11 | reports UI | 2–3 h | 1 h |
| B12 | messages UI + alert call | 1.5–2 h | 45 min |

Plus vendor setup (about 3 hours) and the prod phase (about a day with checks).

## 7. Facts checked in the night (sources)

- HubSpot legacy private-app creation sunset (dates, existing apps unaffected, Service Keys and the project platform as replacements): developers.hubspot.com/changelog/legacy-private-app-creation-sunset.
- HubSpot project apps: created with the CLI, configuration in `*-hsmeta.json` files, static or OAuth auth, test installs in developer test accounts, standard installs, test accounts created under Development → Test accounts: developers.hubspot.com/docs/apps/developer-platform/build-apps/create-an-app.
- HubSpot webhooks on the developer platform: `settings.targetUrl` per app, `crmObjects`, `legacyCrmObjects`, `hubEvents` for `contact.privacyDeletion`: developers.hubspot.com/docs/apps/developer-platform/add-features/configure-webhooks.
- Generic webhook subscriptions include the call object and `object.associationChange`: developers.hubspot.com/docs/guides/webhooks/create-generic-webhook-subscriptions.
- Form submissions read endpoint, 50 per page, newest first, `forms` scope: developers.hubspot.com/docs/api-reference/legacy/marketing/forms/v1/get-form-integrations-v1-submissions-forms-form_guid.
- HubSpot request validation (v3 alongside older versions for legacy apps): developers.hubspot.com/docs/apps/legacy-apps/authentication/validating-requests.
- Aircall's HubSpot integration logs every call as a call engagement and matches the most recently updated contact on shared numbers; it maintains four contact properties: support.aircall.io (HubSpot integration and workflows articles).
- Aircall webhooks: token in the body, no signature; `call.ended` about 30 seconds after hang-up; events list; created via API or Dashboard: developer.aircall.io/docs/webhooks, developer.aircall.io/docs/work-with-call-data.
- Shopify: legacy custom apps cannot be created since 1 January 2026, Dev Dashboard apps instead; client credentials grant, 24-hour tokens, same organisation only: shopify.dev/docs/apps/build/authentication-authorization/client-credentials-grant.
- Shopify protected customer data levels; custom distribution needs no request form: shopify.dev/docs/apps/launch/protected-customer-data and Gadget's documentation of the Dev Dashboard flow.
- Shopify `ordersCount` with `customer_id` and `created_at` filters: shopify.dev/docs/api/admin-graphql/2026-10/queries/ordersCount.
