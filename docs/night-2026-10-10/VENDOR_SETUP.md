# Vendor setup: HubSpot, Aircall, Shopify (and switching Make off for these fields)

What Martin does in the vendors' own screens, with exact values. The runbook (`MORNING_RUNBOOK.md`) says when. Click paths were checked against the vendors' documentation on 9 October 2026; screens move, so where a path differs, the named page is what matters. **Secrets never go into chat, the repository or a document**: they are pasted only into Secret Manager by the commands in the runbook.

---

## 1. HubSpot

### 1.1 Contact properties (Martin's list, with the night's decisions)

Create in **both** the developer test account `CMA dev` and the live Subscriptions portal, identical internal names. Path: Settings (gear) → Data Management → Properties → object **Contact** → Create property. Group: create a group **Pulse4all market and ids** for all of them.

| Label | Internal name | Field type | Values (stored value = code; label in brackets) |
|---|---|---|---|
| Contact-Country | `contact_country` | Dropdown select | `GB` (United Kingdom), `IE` (Ireland), `NL` (Netherlands), `BE` (Belgium), `DE` (Germany), `AT` (Austria), `CH` (Switzerland), `FR` (France), `SE` (Sweden), `DK` (Denmark), `NO` (Norway), `FI` (Finland) |
| Contact-Language | `contact_language` | Dropdown select | `en` (English), `nl` (Dutch), `de` (German), `fr` (French), `sv` (Swedish), `da` (Danish), `nb` (Norwegian Bokmål), `fi` (Finnish) |
| Contact-Currency | `contact_currency` | Dropdown select | `EUR` (Euro), `GBP` (Pound sterling), `SEK` (Swedish krona), `DKK` (Danish krone), `NOK` (Norwegian krone), `CHF` (Swiss franc), `USD` (US dollar) |
| Contact-Shopify Store | `contact_shopify_store` | Dropdown select | one option per store, value = the store handle exactly as in Shopify (for example `pulse4all-nl`), label = the store name |
| Contact-Shopify ID-1 | `contact_shopify_id_1` | Single-line text | the numeric Shopify customer id, digits only |
| Contact-Shopify ID-2 | `contact_shopify_id_2` | Single-line text | a second customer id (another store, or a duplicate customer) |
| Contact-Netsuite ID | `contact_netsuite_id` | Single-line text | NetSuite's internal customer id |
| Contact-Shopify Total Orders | `contact_shopify_total_orders` | Number (formatted number, no decimals) | |
| Contact-Shopify Total Spent | `contact_shopify_total_spent` | Number (currency format) | in the currency of Contact-Shopify Store |

Decisions taken (also in `NIGHT_NOTES.md`):

- **GB, not UK.** ISO 3166-1 alpha-2 is GB; Shopify, Aircall, NetSuite and phone-number libraries all use GB. "United Kingdom" stays the label agents see. A source that writes `UK` anyway is caught by the market alias (`uk` → GB) and reported in data quality.
- **Codes as stored values, names as labels**: language ISO 639-1 lower case, currency ISO 4217 upper case. Norwegian is `nb` (Bokmål, as Shopify and browsers write it).
- **Shopify ID-1 and ID-2 without a second store field**: a Shopify customer id identifies its store in the CMA (every store is its own connection), so ID-2 needs no store of its own. Contact-Shopify Store is the store of ID-1. A contact whose country differs from its store's market shows up in data quality (Martin's cross-check).
- **The CMA fills the Shopify fields itself** (Martin, 10 October 2026: as little as possible through Make): Contact-Shopify ID-1/ID-2, Contact-Shopify Store, Total Orders and Total Spent always; Contact-Country, Currency and Language only when empty, so an agent's value is never overwritten (DESIGN §4.3a). Shopify still owns the facts; HubSpot holds the copy the CMA keeps current.
- Internal names are what the CMA's configuration points at (`connection_field`); renaming a label later breaks nothing.

Deals and tickets: no new properties are required. The CMA reads `pipeline`, `dealstage`, `hubspot_owner_id`, `createdate`, `closedate`, `hs_lastmodifieddate`, `amount`, `deal_currency_code`, `hs_analytics_source` on deals and `hs_pipeline`, `hs_pipeline_stage`, `hubspot_owner_id`, `createdate`, `closed_date`, `hs_lastmodifieddate`, `hs_ticket_category` on tickets. A deal's market comes from its contact's Contact-Country unless a deal property is mapped later.

### 1.2 Developer test account (dev)

Live portal → Development → Testing → **Test accounts** → Create developer test account, name `CMA dev`. Note its account id (digits in the URL after `/`). In `CMA dev`:

1. Create the nine properties of §1.1.
2. Sales: one deal pipeline **Sales test** (stages: New, Contacted, Won (closed won), Lost (closed lost)); Service: one ticket pipeline **Support test** (New, Waiting, Closed).
3. Marketing → Forms: one form **CMA test lead** with email, first name and a dropdown "Interest" (values hs1, frx). Publish; keep the share link.
4. Five test contacts with fake emails `test1@example.com` … `test5@example.com`, Contact-Country and Contact-Language filled on three of them and left empty on two (to see `if_empty` at work); Contact-Shopify fields left empty (the CMA fills them in phase 5).

### 1.3 The project apps

Built from `hubspot/` in the repository (brief B6): **CMA ingest dev** and **CMA ingest prod**, each a project with static auth and private distribution; uploaded from Cloud Shell with the HubSpot CLI; webhooks and scopes in the configuration files.

- Dev app: Development → Projects → CMA ingest dev → the app → Distribution → **Test installs** → Install in `CMA dev`. Never *Standard install*.
- Prod app: Development → Projects → CMA ingest prod → the app → Distribution → **Standard install** in the live portal (when the runbook's prod phase says so).
- After install: the app's **Auth** tab shows the client secret; the installed app shows the static access token. Copy each straight into the Secret Manager command of the runbook (it reads from the clipboard paste into a hidden prompt); never anywhere else.

Subscriptions the project declares (`crmObjects` unless stated): deal `object.creation`, `object.deletion`, `object.merge`, `object.restore`, `object.propertyChange` on `pipeline`, `dealstage`, `hubspot_owner_id`, `closedate`, `amount`, `object.associationChange` (deal ↔ contact); ticket the same with `hs_pipeline`, `hs_pipeline_stage`, `hubspot_owner_id`, `closed_date`; contact `object.propertyChange` on the nine properties of §1.1, `object.deletion`, `object.merge`; call `object.creation`, `object.propertyChange` on `hs_call_status`, `hs_call_disposition`, `hubspot_owner_id`, `object.deletion`, `object.associationChange` (call ↔ contact, call ↔ deal); `hubEvents` `contact.privacyDeletion`. Scopes: read-only for deals, tickets, calls, forms, call dispositions and owners (owners are staff: id and email, used once to map agents to their CMA person), and **read and write on contacts** for the write-back. HubSpot's contact write scope covers every contact property; the CMA writes only the properties configured in `writeback_field` (checked in the database and again in code), and every write is an `outbox_action` row with HubSpot's answer. Exact scope names fixed by B6 from HubSpot's scope list.

---

## 2. Aircall

Prod only: there is no Aircall sandbox, and dev holds test data only. Dev gets replayed synthetic events (brief B8, `ingest/tools/replay.mjs`).

1. **Plan check**: Aircall Dashboard → Integrations & API → API Keys must be available (it is on the plans with API access; if the menu is missing, the plan lacks it and the runbook's Aircall phase stops there).
2. **API key**: Integrations & API → API Keys → Generate an API key, description `CMA ingest (prod)`. The API ID and API token go straight into the runbook's Secret Manager command as `{"api_id":"…","api_token":"…"}`.
3. **Webhook**: created by the script `docs/ingest/aircall-webhook.mjs` (brief B8) through `POST /v1/webhooks` with the events `call.created`, `call.answered`, `call.ended`, `call.tagged`, `call.untagged`, `call.archived` and the ingest URL with the connection key; the script writes the returned token into Secret Manager and prints only the webhook id. (Dashboard-created webhooks do not show their token, which is why the script creates it.)
4. **Tags**: the existing tag list stays; the CMA reads it (`GET /v1/tags`) and counts every tag until one is set `is_counted` false. Data first: tagging must be on for every line on the add-a-number checklist.
5. **People**: each agent's Aircall user id goes on their CMA person as `aircall_user` (runbook Studio step); the Aircall Dashboard → Users list shows the id in the user's URL.

The Aircall–HubSpot integration stays as it is: it logs every call as a HubSpot call engagement on the contact, which is what speed to lead measures (DESIGN §4.4).

---

## 3. Shopify

### 3.1 Organisation check (first, it decides one app or several)

Shopify admin of any store → Settings → Apps → Develop apps → **Build apps in Dev Dashboard**. In the Dev Dashboard, Stores lists every store of the organisation. All Pulse4all stores in one organisation → one app; a store in another organisation → one app per organisation (the client credentials grant only works inside one organisation).

### 3.2 The prod app

Dev Dashboard → Apps → Create app → name **CMA ingest** → Versions → Create a version:

- Scopes: `read_customers`, `read_orders`, and `read_all_orders` if offered (without it Shopify serves only the last 60 days of orders; the CMA then computes first versus repeat from the customer's lifetime order count, DESIGN §4.3, so it still works).
- No app URL needed (not embedded), no extensions, no webhooks in the version (the CMA creates shop-specific subscriptions per store).
- Distribution: **Custom**.
- Protected customer data: the app needs Level 1 plus the single protected field **Email** (to find the customer's HubSpot contact; used in memory, never stored). In the Dev Dashboard: the app → API access requests → Protected customer data access → select customer data and the **Email** field only (not name, phone, address), with the reason "match the customer to our CRM contact; not stored". With custom distribution this is a selection, not a review, according to Shopify's and Gadget's documentation; if the Dashboard asks for a review or refuses, see the fallback in §4.
- Release the version, then Home → **Install app** → choose every Pulse4all store, one by one.
- Settings → Credentials: the **Client ID** goes into the connection settings (not secret); the **Client secret** goes straight into Secret Manager.

### 3.3 The dev app and store

Dev Dashboard → Stores → Create development store **cma-dev**. Create a second app **CMA ingest dev** the same way, installed on `cma-dev` only. In `cma-dev`: Settings → Payments → enable the test gateway (Bogus); create three customers with the emails `test1@example.com`, `test2@example.com` and `test4@example.com` (the same as three HubSpot test contacts, so the match finds them) and one with `nobody@example.com` (no contact: data quality counts it); five orders, one customer with two orders. In the dev app's API access requests, select the Email field as in §3.2.

### 3.4 Webhook subscriptions

Created per store by `docs/ingest/shopify-subscribe.mjs` (brief B9) through the Admin GraphQL API (`webhookSubscriptionCreate`, API version from the connection settings), topics `CUSTOMERS_CREATE`, `CUSTOMERS_UPDATE`, `CUSTOMERS_DELETE`, `ORDERS_CREATE`, `ORDERS_UPDATED`, `ORDERS_CANCELLED`, `ORDERS_DELETE`, to that store's ingest URL. The nightly reconcile checks they still exist (Shopify removes a subscription after repeated failed deliveries) and recreates them.

---

## 4. Make: switched off for these fields

Martin, 10 October 2026: as little as possible through Make, as much as possible directly through the CMA. For the intake nothing goes through Make: HubSpot, Aircall and Shopify talk to the ingest service directly, and the CMA writes the Shopify fields of §1.1 into HubSpot itself (DESIGN §4.3a).

What remains for Make, once, at the prod switch-on (runbook phase 7): open every Make scenario that writes any of the nine properties of §1.1 (the private app "Pulse4all – Make Contacts" is the likely one) and remove those modules or mappings, so each property has **one writer**. Two writers would overwrite each other and make the HubSpot property history meaningless for an audit. Anything else those scenarios do (creating contacts from Shopify, quotes) is untouched; moving those to the CMA is a later decision (Open decisions).

**Fallback if Shopify will not grant the Email field**: the match cannot happen in the CMA. Then the smallest Make role is to write only Contact-Shopify ID-1 (and ID-2) on the contact it already finds by email; the CMA still writes store, totals and the if-empty fields once the id is there, because it can then match by the id. Decide on the day if it happens; the CMA's code supports both (the match step is skipped when the email is redacted).
