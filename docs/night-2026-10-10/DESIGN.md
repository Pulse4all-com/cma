# Intake track: design

Night session of 9 to 10 October 2026. This is the specification the Claude Code briefs (`BRIEFS.md`) build against; section numbers (§) are referenced from the briefs and the runbook. The README stays the source of truth for everything this file does not change; `NIGHT_NOTES.md` lists the decisions and the README edits.

Conventions that apply everywhere, taken from migration 0006 and earlier (column names too: `source_created_at`, `source_updated_at`, `source_deleted_at`, `synced_at`, `raw`): every table is tenant-scoped with RLS, the audit trigger and `cma.setup_tenant_table`; the application never deletes (mapping rows excepted); `uuidv7()` ids; functions check permissions with `cma.assert_permission`; `cma_read` views leave out raw payloads, hashes, keys and secret names; nothing names Pulse4all or a vendor in a table or column name. Vendor names appear only as **data values** (`adapter`, `source_system`) and inside the ingest service's adapters.

---

## §1 What the track delivers

| Need (Martin, 9 Oct 2026) | Delivered as | Source | Lives in |
|---|---|---|---|
| All HubSpot form submissions | `form_submission` (ids, form, time, page, UTM, contact id) | HubSpot Forms API, polled every minute | Data, Report |
| All opened and closed deals and tickets | `crm_record` (0006) with amount, currency, source channel, category; backfill from the insights start | HubSpot webhooks + read-back, nightly reconcile | Data, Report, Dashboard |
| Aircall calls, inbound and outbound, with tags | `telephony_call`, `telephony_call_tag`, tag catalog | Aircall webhooks + read-back | Data, Report |
| The call on the HubSpot contact | `crm_call` (HubSpot call engagements, which the Aircall integration logs on the contact) + `crm_association` | HubSpot webhooks + read-back | Data |
| Shopify customer linked to its HubSpot contact, ids and totals on the contact (no Make) | the Shopify adapter finds the contact by the customer's email (in memory only) and writes Contact-Shopify ID-1/2, store, totals, and country, currency, language when empty, through the outbox | Shopify → CMA → HubSpot | Data |
| All Shopify stores: new customers, all orders, first and repeat | `commerce_customer`, `commerce_order` (+ lines), `order_kind` first, repeat or renewal | Shopify webhooks + read-back per store | Data, Report |
| Speed to lead: deal created → first call started on that contact | `cma.speed_to_lead_rows()`, `cma_read.speed_to_lead`, business-time aware | derived in Postgres | Report, Dashboard |
| Everything in Postgres tables, for BigQuery | `cma_read` views over every new table | — | Data |
| In-Workspace push on new deals | `message`, `message_delivery`, `message_rule`; polled every 10 s with a browser notification | derived on ingest | Agent, Live |
| Added (night) | the outbox with the CRM contact write-back (instead of Make), lead to order, market catalog with office hours, data-quality views, sync audit (`sync_run`), nightly reconcile, Shopify subscription check | — | Report, Data |

Not in this track (unchanged README order): S2 routing and S3 offers with the accept click (migration 0009 Assignments), write-back to HubSpot (outbox), the customer-field mirror (0010), the queue engine (0011).

---

## §2 Sources and mechanics

| Source | Transport in | Authentication of the request | Read-back | Backfill | Reconcile (nightly, 26 h look-back) |
|---|---|---|---|---|---|
| HubSpot (per portal) | Webhooks of a project app (static auth, private distribution), one app per environment and portal, target URL `/hubspot/<key>` | `X-HubSpot-Signature-v3`: HMAC SHA-256 of method + URI + body + timestamp with the app's client secret, base64; timestamp at most 5 minutes old; `portalId` must equal the connection's account | CRM v3 batch read, requested properties only (§4.1) | CRM search by `createdate`/`closedate`/`hs_timestamp` ≥ insights start | CRM search by `hs_lastmodifieddate` |
| HubSpot forms | **Poll** (no webhook exists for submissions): `GET /form-integrations/v1/submissions/forms/{guid}`, newest first, 50 per page, per counted form | static token | the submission itself; contact resolved by a CRM search on the submitted email, which is never stored | same endpoint back to the insights start | the poller is its own reconcile |
| Aircall (per account) | Webhooks to `/aircall/<key>` for `call.created`, `call.answered`, `call.ended`, `call.tagged`, `call.untagged`, `call.archived` | Aircall sends a `token` in the body (no HMAC): constant-time compare with the webhook token from Secret Manager; the opaque key in the path is the second factor | `GET /v1/calls/{id}` | `GET /v1/calls?from=` (60 requests per minute per company) | same, last 26 h |
| Shopify (per store) | Shop-specific webhook subscriptions created through the Admin API to `/shopify/<key>`: `customers/create`, `customers/update`, `customers/delete`, `orders/create`, `orders/updated`, `orders/cancelled`, `orders/delete` | `X-Shopify-Hmac-Sha256`: HMAC SHA-256 of the raw body with the app's client secret, base64; `X-Shopify-Shop-Domain` must equal the connection's account | GraphQL Admin API (version pinned in connection settings, `2026-10` today); for customers also the email, in memory only, to find the HubSpot contact (§4.3a) | GraphQL `customers`/`orders` with `created_at:>=` | `updated_at:>=` plus a check that every subscription still exists (Shopify removes failing subscriptions) |

Every source follows 0006's pattern: **log first** (`ingest_event`, ids only), **answer 200**, **read back** the object from the source with the configured properties only, **upsert** guarded by the source's updated time, **finish** the event. A failure leaves the event for the sweeper with backoff; ten failures park it as `needs_review`.

Event keys (unique per connection): HubSpot `hs:<eventId>`; Aircall `ac:<event>:<call id>:<timestamp>`; Shopify `sh:<X-Shopify-Event-Id>`. Canonical kinds stay 0006's six: creation → `created`; property change, answered, ended, tagged, untagged, paid, updated, cancelled → `changed`; deletion → `deleted`; merge → `merged`; restore → `restored`; association change → `associated`. Canonical object types: `deal`, `ticket`, `contact`, `crm_call`, `form_submission`, `telephony_call`, `commerce_customer`, `commerce_order`.

### §2.1 What is never stored

Names, email addresses, phone numbers, postal addresses, free-text bodies (deal names, ticket subjects and content, call notes and bodies, Aircall comments, form field values), recording or voicemail links. Phone numbers and form emails pass through the ingest service's memory only: a number becomes a keyed hash (§6.3), an email (form or Shopify customer) becomes a HubSpot contact id. Shopify access is Level 1 plus the one protected field **email** (needed for the match, §4.3a); names, phones and addresses stay redacted at the source.

---

## §3 Configuration (all tenant data, nothing hardcoded)

| What | Where | Pulse4all values (runbook) |
|---|---|---|
| Markets: ISO country code, name, time zone, language code, language skill key and minimum level, currency | `cma.market` (§4.2) | GB, IE, NL, BE, DE, AT, CH, FR, SE, DK, NO, FI |
| Aliases of a market as sources write it (`UK`, `United Kingdom`, `nederland`) | `cma.market_alias` | `uk` → GB and the full names |
| Office hours per market (`*` = default) and holidays | `cma.business_hours`, `cma.business_holiday` | Mon–Fri 09:00–17:00 local, provisional (Open decisions) |
| Which source property feeds which canonical field | `cma.connection_field` (0006, extended §4.1) | the HubSpot properties of `VENDOR_SETUP.md` §1 |
| Pipelines counted, lead pipelines (speed to lead), routed, work type | `cma.connection_pipeline` (0006 + `is_lead`) | sales pipeline(s) `is_lead`, test pipelines not counted |
| Forms counted, lead source label, market, kept non-personal fields | `cma.connection_form` | set after the first poll |
| Call outcomes that count as connected | `cma.connection_call_outcome` | Connected = true |
| Aircall lines: market, counted; tags: counted | `cma.telephony_number`, `cma.telephony_tag` | per line |
| Shopify stores: handle, market, currency, time zone | `cma.commerce_store` | one row per store |
| Write-back to the CRM: which value goes to which contact property, mode `always`, `if_empty` or `slot` | `cma.writeback_field` (§4.3a) | VENDOR_SETUP §1.1 properties |
| Alert rules | `cma.message_rule` (§8) | new deal → agents with the market's language, clocked in |
| Per-connection non-secret settings: `app_host` (HubSpot link host), `api_version` (Shopify), `client_id` (Shopify), `shop_handle`, `crm_connection_id` (Shopify: the HubSpot connection its customers are matched to) | `integration_connection.settings` (new jsonb) | runbook |
| Settings (`cma.setting` catalog, `tenant_setting` values) | `intake.start_date` (`2026-10-01`), `speed_to_lead.pre_window_minutes` (0), `speed_to_lead.target_minutes` (60), `lead_to_order.max_days` (90), `forms.deal_window_hours` (72), `commerce.renewal_source_names` (empty), `commerce.renewal_app_ids` (empty), `alerts.max_age_minutes` (60) | defaults |
| People's ids in other systems | `cma.app_user_external_id` (0001), vocabulary `hubspot_owner`, `aircall_user` | per agent, Studio until a screen exists |

---

## §4 Data model

### §4.1 Migration 0007: intake core (`db/32_intake_core.sql`, verify `db/33_verify_intake_core.sql`)

**Changes to 0006 objects** (backward compatible: every 0006 call keeps working, `31` must still pass):

- `integration_connection.settings jsonb not null default '{}'`, at most 4 kB, refusing any key containing `secret`, `token`, `password` or `key` (case-insensitive). Adapter allowed values stay data (`hubspot`, `aircall`, `shopify` today).
- `connection_field`: `field` accepts `market`, `language`, `country`, `currency`, `store`, `amount`, `source_channel`, `category`, `ref`; new `slot smallint not null default 1 check (slot between 1 and 9)` in the primary key. Entity rules: `contact` takes `country`, `language`, `currency`, `store`, `ref`; records take `market`, `language`, `currency`, `amount`, `source_channel`, `category`. Slot > 1 only for `ref`.
- `crm_contact_ref`: new `slot smallint not null default 1` in the primary key (`tenant_id, contact_id, system, slot`); `external_id` keeps its length rule. A contact can now hold Shopify ids 1 and 2.
- `crm_contact`: new `currency text` (ISO 4217, upper case, 3 letters) and `store text` (a store handle, `^[a-z0-9-]{1,60}$`); deletion clears them like country and language.
- `crm_record`: new `amount numeric(14,2)`, `currency text`, `source_channel text` (≤ 100), `category text` (≤ 100).
- `connection_pipeline`: new `is_lead boolean not null default true` (counts for speed to lead).
- `ingest_upsert_records()` and `ingest_upsert_contacts()` accept the new keys; `set_connection_field()` gains `p_slot smallint default 1` as the last parameter, the 0006 call shape unchanged.
- `market` values written by `ingest_upsert_records` / `country` by `ingest_upsert_contacts` pass through `cma.normalize_market(text)` (alias table, then upper-case ISO code if it is a known market, else the trimmed source value with `market_unknown` true in the data-quality view).

**New tables**

| Table | Columns (beyond `tenant_id`, `id`, created/updated) | Keys and rules |
|---|---|---|
| `market` | `code` (ISO 3166-1 alpha-2, upper case; `GB` not `UK`), `name`, `time_zone` (IANA, checked against `pg_timezone_names`), `language_code` (ISO 639-1, lower case), `language_skill_key` (nullable, a `skill` key of dimension language), `min_language_level` (nullable, 1–9), `currency` (ISO 4217), `status` (active, inactive), `sort_order` | unique `(tenant_id, code)` |
| `market_alias` | `alias` (lower-cased, trimmed), `code` | PK `(tenant_id, alias)`, FK to market |
| `business_hours` | `market` (`*` or a market code), `weekday` (1 = Monday … 7), `opens_at time`, `closes_at time` | PK `(tenant_id, market, weekday, opens_at)`, `closes_at > opens_at`, ranges of one day do not overlap |
| `business_holiday` | `market` (`*` or code), `day date`, `name` | PK `(tenant_id, market, day)` |
| `crm_association` | `connection_id`, `from_type`, `from_id`, `to_type`, `to_id`, `first_seen_at`, `removed_at` (null while current), `source_changed_at` | PK `(tenant_id, connection_id, from_type, from_id, to_type, to_id)`; the stored direction is fixed: activity or record → contact, activity → record |
| `crm_call` | `connection_id`, `source_system`, `source_id`, `occurred_at` (HubSpot `hs_timestamp`), `direction` (inbound, outbound, unknown), `status` (source value ≤ 40), `outcome_ref` (≤ 100), `duration_seconds`, `owner_ref`, `source_app` (≤ 60, for example `aircall`, mapped from the engagement's source), `counterpart_hash` (§6.3, nullable), `source_created_at`, `source_updated_at`, `source_deleted_at`, `synced_at`, `raw` (requested properties minus the numbers) | unique `(tenant_id, connection_id, source_id)`; stale guard on `source_updated_at` |
| `connection_call_outcome` | `connection_id`, `outcome_ref`, `label`, `is_connected` (default false), `status` | PK `(tenant_id, connection_id, outcome_ref)`; refresh keeps `is_connected` |
| `connection_form` | `connection_id`, `source_form_id`, `name` (≤ 200, the form's name, not a customer value), `is_counted` (default true), `lead_source` (≤ 60), `market` (nullable), `kept_fields text[]` (default empty; field names whose values may be stored because they are not personal, for example a product interest), `status` (active, archived) | PK `(tenant_id, connection_id, source_form_id)`; refresh keeps the four configured columns |
| `form_submission` | `connection_id`, `source_id` (conversion id), `source_form_id`, `submitted_at`, `page_host`, `page_path` (no query string), `utm jsonb` (`source`, `medium`, `campaign`, `term`, `content`, each ≤ 200), `contact_source_id` (nullable), `contact_resolution` (resolved, no_email, not_found, ambiguous, pending), `kept_values jsonb` (only `kept_fields`, each value ≤ 200), `synced_at` | unique `(tenant_id, connection_id, source_id)`; insert-only apart from resolution |
| `sync_cursor` | `connection_id`, `stream` (≤ 100, for example `forms:<guid>`), `cursor jsonb` (≤ 2 kB) | PK `(tenant_id, connection_id, stream)` |
| `sync_run` | `connection_id`, `job` (backfill, reconcile, forms_poll, subscriptions_check, link_calls), `stream`, `from_at`, `to_at`, `started_at`, `finished_at`, `status` (running, succeeded, failed), `counts jsonb` (fetched, upserted, stale, skipped, failed), `error` (≤ 200) | append-only apart from finishing its own row once |

**Functions** (configuration needs `tenant.configure` unless stated; ingest needs `ingest.write`; every function sets nothing global and works for the current tenant only)

| Function | Does |
|---|---|
| `cma.upsert_market(p_code, p_name, p_time_zone, p_language_code, p_currency, p_language_skill_key default null, p_min_language_level default null, p_sort_order default 100)` | create or update a market; refuses an unknown time zone, a lower-case country, `UK` (with the message "use GB") |
| `cma.set_market_status(p_code, p_status)`, `cma.set_market_alias(p_alias, p_code)`, `cma.remove_market_alias(p_alias)` | |
| `cma.normalize_market(p_value text) returns text` | alias, then known code, else trimmed value; immutable per call, used by the ingest functions and the reads |
| `cma.set_business_hours(p_market text, p_weekday smallint, p_hours text)` | replaces the day's ranges from `'09:00-12:30,13:00-17:00'`; `''` = closed |
| `cma.set_business_holiday(p_market, p_day, p_name)`, `cma.remove_business_holiday(p_market, p_day)` | |
| `cma.business_seconds(p_market text, p_from timestamptz, p_to timestamptz) returns integer` | office seconds between two instants in the market's zone (the market's own hours, else `*`), holidays excluded; 0 when `p_to <= p_from`; null for an unknown market |
| `cma.next_business_noon(p_market text, p_at timestamptz) returns timestamptz` | 12:00 local on the first working day after `p_at`'s local date |
| `cma.set_connection_settings(p_connection uuid, p_settings jsonb)` | replaces settings; refuses secret-looking keys |
| `cma.set_pipeline_lead(p_connection, p_record_type, p_pipeline_id, p_is_lead)` | |
| `cma.set_form(p_connection, p_form_id, p_is_counted, p_lead_source, p_market, p_kept_fields text[])` | |
| `cma.set_call_outcome(p_connection, p_outcome_ref, p_is_connected)` | |
| `cma.set_user_external_id(p_user uuid, p_system text, p_external_id text)`, `cma.remove_user_external_id(p_user, p_system)` | needs `users.manage_all`; the vocabulary stays data |
| `cma.ingest_upsert_calls(p_connection, p_calls jsonb) returns table(source_id text, outcome text)` | outcome inserted, updated, stale, deleted; at most 500 |
| `cma.ingest_upsert_associations(p_connection, p_items jsonb)` | items `{from_type, from_id, to_type, to_id, removed, changed_at}`; a removal sets `removed_at`, a re-add clears it; older changes than stored are ignored |
| `cma.ingest_upsert_call_outcomes(p_connection, p_items jsonb)`, `cma.ingest_upsert_forms(p_connection, p_items jsonb)` | catalog refreshes, configured columns kept, missing entries archived |
| `cma.ingest_upsert_form_submissions(p_connection, p_items jsonb) returns table(source_id text, outcome text)` | inserted or known; `kept_values` filtered again in SQL against `kept_fields` (defence in depth) |
| `cma.ingest_cursor_get(p_connection, p_stream) returns jsonb`, `cma.ingest_cursor_set(p_connection, p_stream, p_cursor)` | |
| `cma.ingest_sync_run_start(p_connection, p_job, p_stream, p_from, p_to) returns uuid`, `cma.ingest_sync_run_finish(p_run, p_status, p_counts, p_error default null)` | a run finishes once |
| `cma.ingest_contact_forget(p_connection, p_contact_source_id)` | privacy deletion: contact attributes and refs cleared, `counterpart_hash` cleared on its calls (and, from 0007a, on linked telephony calls), form submissions keep the id but lose `kept_values` |

`cma_read` views: `market`, `business_hours`, `business_holiday`, `crm_call` (no raw, no hash), `crm_association`, `connection_form`, `form_submission` (no `kept_values` unless the field is configured, which it is by definition), `sync_run`. The existing `crm_record`, `crm_contact` and `crm_contact_ref` views gain the new columns.

### §4.2 Migration 0007a: telephony (`db/34_telephony.sql`, `db/35_verify_telephony.sql`)

| Table | Columns | Keys and rules |
|---|---|---|
| `telephony_call` | `connection_id`, `source_system`, `source_id`, `direction` (inbound, outbound), `status` (≤ 40), `missed_reason` (≤ 60), `started_at`, `answered_at`, `ended_at`, `duration_seconds`, `talk_seconds` (ended − answered, null if unanswered), `user_ref` (the telephony user id), `number_ref` (the line id), `counterpart_hash`, `is_archived`, `source_version_at` (the newest event or read time; stale guard), `source_deleted_at`, `synced_at`, `raw` (allowlisted keys) | unique `(tenant_id, connection_id, source_id)` |
| `telephony_tag` | `connection_id`, `tag_ref`, `name` (≤ 100), `is_counted` (default true), `status` | PK `(tenant_id, connection_id, tag_ref)` |
| `telephony_call_tag` | `connection_id`, `call_source_id`, `tag_ref`, `tagged_at`, `untagged_at` | PK `(tenant_id, connection_id, call_source_id, tag_ref, tagged_at)`; current tags have `untagged_at` null |
| `telephony_number` | `connection_id`, `number_ref`, `name` (the line's name), `digits` (the company's own line in E.164, not a customer number), `market` (nullable), `is_counted` | PK `(tenant_id, connection_id, number_ref)`; refresh keeps `market`, `is_counted` |
| `call_link` | `telephony_call_id`, `crm_call_id`, `method` (`hash_time`), `delta_seconds`, `linked_at` | unique on each side; never rewritten, a wrong link is retired by `cma.unlink_call()` (tenant.configure) |

Functions: `cma.ingest_upsert_telephony_calls(p_connection, p_calls jsonb)` (each call carries its current tag set; the function opens and closes `telephony_call_tag` rows by difference at `source_version_at`), `cma.ingest_upsert_telephony_catalog(p_connection, p_kind text, p_items jsonb)` with kinds `tag`, `number`, `cma.set_telephony_number(p_connection, p_number_ref, p_market, p_is_counted)`, `cma.set_telephony_tag(p_connection, p_tag_ref, p_is_counted)`, `cma.link_calls(p_since timestamptz) returns integer` (ingest.write or tenant.configure): pairs a telephony call and a CRM call of the same tenant with equal non-null `counterpart_hash`, the same direction and `abs(started_at − occurred_at) ≤ 120 s`, nearest first, each side once. `ingest_contact_forget` is redefined to clear linked telephony hashes too.

Views: `cma_read.telephony_call` (no raw, no hash), `telephony_call_tag`, `telephony_tag`, `telephony_number`, `call_link`.

### §4.3 Migration 0007b: commerce (`db/36_commerce.sql`, `db/37_verify_commerce.sql`)

| Table | Columns | Keys and rules |
|---|---|---|
| `commerce_store` | `connection_id` (one store per connection), `handle` (`^[a-z0-9-]{1,60}$`, for example the store handle the HubSpot dropdown uses), `name`, `market`, `currency`, `time_zone` | unique `(tenant_id, connection_id)`, unique `(tenant_id, handle)` |
| `commerce_customer` | `connection_id`, `source_system`, `source_id`, `state` (≤ 30), `locale` (≤ 20), `orders_count`, `amount_spent numeric(14,2)`, `amount_currency`, `source_created_at`, `source_updated_at`, `source_deleted_at`, `synced_at`, `raw` | unique `(tenant_id, connection_id, source_id)`; stale guard |
| `commerce_order` | `connection_id`, `source_system`, `source_id`, `order_name` (the shop's order number, ≤ 40), `customer_source_id`, `source_created_at`, `processed_at`, `source_updated_at`, `cancelled_at`, `cancel_reason`, `is_test`, `currency`, `total_amount`, `subtotal_amount`, `tax_amount`, `discount_amount`, `refunded_amount`, `financial_status`, `fulfillment_status`, `source_name` (≤ 60), `app_ref` (≤ 100), `landing_host`, `landing_path`, `utm jsonb`, `referring_host`, `tags text[]` (each ≤ 60, at most 30), `prior_orders_count` (the customer's orders created before this one at the source, test orders excluded), `prior_count_exact` boolean, `order_kind` (first, repeat, renewal, unknown), `source_deleted_at`, `synced_at`, `raw` | unique `(tenant_id, connection_id, source_id)`; stale guard |
| `commerce_order_line` | `connection_id`, `order_source_id`, `line_source_id`, `sku` (≤ 100), `product_ref`, `variant_ref`, `quantity`, `unit_price numeric(14,2)`, `currency` | PK `(tenant_id, connection_id, order_source_id, line_source_id)`; replaced as a set when its order is upserted with lines |

`order_kind`, computed in the upsert: `renewal` when `source_name` is in `commerce.renewal_source_names` or `app_ref` in `commerce.renewal_app_ids` (Juo subscription orders, once Martin names them); else `first` when `prior_orders_count = 0`; `repeat` when > 0; `unknown` when the count is missing. Recomputed when the order or the settings change (a function `cma.reclassify_orders()` for tenant.configure).

Functions: `cma.upsert_commerce_store(p_connection, p_handle, p_name, p_market, p_currency, p_time_zone)`, `cma.ingest_upsert_commerce_customers(p_connection, p_items jsonb)`, `cma.ingest_upsert_commerce_orders(p_connection, p_items jsonb)` (items may carry `lines`), `cma.reclassify_orders()`. Customer deletion clears `locale`, counts and amounts, keeps the id. Views: `cma_read.commerce_store`, `commerce_customer`, `commerce_order`, `commerce_order_line` (no raw).

Join to CRM: `crm_contact_ref` with `system = 'shopify'` (the ref system name is the connection field's `ref_system`, data) and any slot, on `external_id = commerce_customer.source_id` across the tenant's commerce connections. A customer id matching customers in two stores is reported by the data-quality view, never guessed.

### §4.3a Migration 0007c: outbox and CRM contact write-back (`db/38_outbox.sql`, `db/39_verify_outbox.sql`)

Martin, 10 October 2026: as little as possible through Make, as much as possible directly through the CMA. The one Make dependency of the first draft (filling the HubSpot copies of Shopify facts) moves into the CMA. The outbox is README's (Architecture, Outbox worker): every action towards another system is a row, delivered by a worker with claim, in-flight, sent, failed and a `needs_review` parking state that needs a named person. It lands here, earlier than planned, and 0009 (assignments, owner write-back) reuses it.

**Flow.** Shopify customer created or updated → read-back (the email in memory) → the HubSpot connection named in the store connection's `crm_connection_id` is searched for a contact with that email → exactly one: `cma.enqueue_contact_writeback` with the customer's id, store handle, lifetime order count and amount spent, the store's market and currency, and the language of the customer's locale → the outbox job reads the contact's current values, applies the modes, writes the difference in one batch update, records HubSpot's answer. None or several contacts: counted in data quality (`dq_commerce_unmatched`, `dq_commerce_ambiguous`), nothing written; contact creation stays out of scope (Open decisions). The email is dropped after the search.

| Table | Columns | Keys and rules |
|---|---|---|
| `writeback_field` | `connection_id` (the CRM connection), `field` (`commerce_ref`, `commerce_store`, `commerce_orders`, `commerce_spent`, `country`, `currency`, `language`), `target_property` (≤ 100), `slot` (1–9; only `commerce_ref` uses 1 and 2), `mode` (`always`, `if_empty`, `slot`), `enabled` | PK `(tenant_id, connection_id, field, slot)`; `slot` mode only for `commerce_ref` |
| `outbox_action` | `connection_id` (target), `action` (`crm.contact.set_properties` today), `target_type`, `target_id`, `payload jsonb` (canonical field → value; ≤ 4 kB), `dedupe_key` (≤ 200), `reason` (≤ 100, for example `commerce_customer:<id>`), `status` (pending, in_flight, sent, failed, needs_review, superseded), `attempts`, `next_attempt_at`, `claimed_at`, `sent_at`, `result jsonb` (properties written and skipped, the source's response id; ≤ 4 kB), `error` (≤ 200), `created_by` (the acting user), `resolved_by`, `resolved_at` | unique `(tenant_id, dedupe_key)`; a newer pending action for the same target and action supersedes older pending ones; a sent action never reopens |

| Function | Does | Permission |
|---|---|---|
| `cma.set_writeback_field(p_connection, p_field, p_target_property, p_mode, p_enabled, p_slot default 1)` | | `tenant.configure` |
| `cma.enqueue_contact_writeback(p_connection uuid, p_contact_source_id text, p_values jsonb, p_reason text) returns uuid` | keeps only enabled fields, refuses unknown fields, dedupes on the payload's hash, supersedes older pending actions for the contact, null when nothing is enabled | `ingest.write` |
| `cma.outbox_claim(p_connection uuid, p_limit int default 50)` | `FOR UPDATE SKIP LOCKED`, counts an attempt, backoff like `ingest_claim_events`; a dead worker's claim comes back | `ingest.write` |
| `cma.outbox_finish(p_ids uuid[], p_outcome text, p_result jsonb default null, p_error text default null)` | sent, failed; failure at `outbox.max_attempts` (setting, default 8) → `needs_review` | `ingest.write` |
| `cma.outbox_resolve(p_id uuid, p_decision text)` | `retry` or `drop` for a parked action, recording the person | `tenant.configure` |
| `cma.outbox_status()` | per connection and status: counts, oldest pending, parked | `tenant.configure` or `reports.view` |

**Modes, applied by the worker against the contact's current values** (read in the same run): `always` writes when different; `if_empty` writes only when HubSpot's value is empty (never overwrites an agent's country, currency or language); `slot` for `commerce_ref`: the id already in slot 1 or 2 → nothing; slot 1 empty → slot 1 (and `commerce_store` with it); else slot 2 empty → slot 2; both taken by other ids → nothing written, recorded in `result` and counted in data quality. `commerce_store`, `commerce_orders` and `commerce_spent` describe the customer in slot 1: they are written only when this customer's id is, or just became, slot 1 (whatever their mode), so a second store's customer never overwrites the first one's totals. The worker writes **only** properties named in `writeback_field` (enforced again in code by refusing any property not in the connection's configuration), one batch update per run per connection.

Views: `cma_read.outbox_action` (payload included: ids, counts and amounts, no personal data), `cma_read.writeback_field`.

### §4.4 Migration 0007d: lead metrics (`db/40_lead_metrics.sql`, `db/41_verify_lead_metrics.sql`)

**Speed to lead (the definition, auditable):**

- Population: `crm_record` rows with `record_type = 'deal'`, not deleted, pipeline counted and `is_lead`, `source_created_at` on or after `intake.start_date`.
- Start: the deal's `source_created_at` (HubSpot `createdate`).
- Contacts of the deal: `contact_source_id` plus current `crm_association` rows deal → contact.
- First call: the earliest `crm_call` that is not deleted, has `direction = 'outbound'`, is associated (current association) with one of those contacts or with the deal itself, and whose effective start is at or after start − `speed_to_lead.pre_window_minutes`. Effective start = the linked telephony call's `started_at` when a `call_link` exists, else `crm_call.occurred_at`.
- Also reported: first call of any direction, first connected call (outcome `is_connected` or linked telephony `answered_at` not null), whether an inbound call came first, the first call's agent (`owner_ref` → `app_user_external_id` system `hubspot_owner`; fallback the deal's owner).
- Market: the deal's own market, else its primary contact's country, else `unknown`.
- Measures: `elapsed_seconds`; `business_seconds` (`cma.business_seconds` in the market); `within_target` (business seconds ≤ `speed_to_lead.target_minutes`·60); `before_next_noon` (first call before `cma.next_business_noon(market, start)`); `status` called, not_called_open, not_called_closed.

| Function or view | Does | Permission |
|---|---|---|
| `cma.speed_to_lead_rows(p_from date, p_to date)` | one row per deal created in the business-date range (tenant zone), at most 92 days | `reports.view` or `performance.team` |
| `cma.speed_to_lead_summary(p_from, p_to, p_group text)` | `p_group` in day, market, agent, pipeline: deals, called, median and p80 business minutes, % within target, % before next noon, open not called | same |
| `cma.lead_to_order_rows(p_from, p_to)` | per deal: first non-test, non-cancelled order of any linked Shopify customer created after the deal within `lead_to_order.max_days`, its kind, store and days | same |
| `cma.intake_per_day(p_from, p_to)` | per business date and market: form submissions (counted forms), deals created, deals closed, tickets created, tickets closed, calls in and out, tagged calls, new commerce customers, first orders, repeat orders, renewals | same |
| `cma.data_quality()` | counts per check (below) with the current total, for the Data page | `reports.view` or `tenant.configure` |
| `cma_read.speed_to_lead`, `lead_to_order`, `intake_per_day_v` | the same rows for BigQuery and NocoDB, all tenants a reader sees | reader |
| `cma_read.dq_*` | one view per check, ids only | reader |

Data-quality checks (the Data first list made measurable): deals without a contact; deal contacts without country or language; markets written by a source that are not in the catalog; HubSpot owners and Aircall users without a CMA person; CRM calls without any contact association; telephony calls without a link after 24 h (only meaningful once both sources run); Shopify customers without a HubSpot contact ref, split into no contact found and several contacts found (§4.3a); write-backs parked in `needs_review`; contacts whose two Shopify slots are full; contacts whose country differs from their store's market; a Shopify id matching customers in two stores; pipelines seen but never reviewed (counted by default, so a new test pipeline would count); forms without a market.

### §4.5 Migration 0008: messaging core and record alerts (`db/42_messaging.sql`, `db/43_verify_messaging.sql`)

| Table | Columns | Keys and rules |
|---|---|---|
| `message` | `kind` (alert, announcement), `urgency` (normal, urgent), `title` (≤ 120), `body` (≤ 500), `ref_system`, `ref_type`, `ref_id`, `ref_url` (https only, ≤ 500), `rule_id` (nullable), `sender_user_id`, `created_at`, `expires_at` | unique `(tenant_id, rule_id, ref_system, ref_type, ref_id)` where `rule_id` is not null (one alert per rule and record, retries are harmless) |
| `message_delivery` | `message_id`, `user_id`, `delivered_at` (first time the recipient's poll returned it), `read_at`, `acknowledged_at` | PK `(tenant_id, message_id, user_id)`; timestamps only move from null to a value |
| `message_rule` | `name`, `trigger` (`record_created`), `record_type`, `pipeline_ids text[]` (empty = all counted), `audience_permission` (default `leads.accept`), `match_language` (default true), `only_clocked_in` (default true), `fallback_permission` (default `leads.manage`), `urgency`, `enabled`, `max_age_minutes` (default from `alerts.max_age_minutes`) | |

Message content carries references only (README Messaging): title "New deal", body `<market> · <pipeline label> · created <local time>`, `ref_url` the record in HubSpot built from `settings.app_host` and the portal id; never a customer name.

| Function | Does | Permission |
|---|---|---|
| `cma.upsert_message_rule(p_name text, p_record_type text, p_pipeline_ids text[], p_audience_permission text, p_match_language boolean, p_only_clocked_in boolean, p_fallback_permission text, p_urgency text, p_max_age_minutes integer default null) returns uuid` (identified by name), `cma.set_message_rule_enabled(p_id, p_enabled)` | | `tenant.configure` |
| `cma.ingest_record_alerts(p_connection, p_record_type, p_source_ids text[]) returns integer` | for each record created less than `max_age_minutes` ago, each enabled rule: resolve recipients now (holders of the audience permission, clocked in if asked, with the market's language skill at the market's minimum level if asked; nobody matches → holders of the fallback permission), write one message and its delivery rows; idempotent | `ingest.write` |
| `cma.send_message(p_title, p_body, p_urgency, p_target jsonb)` | managers' manual message: target everyone, team keys, language with level, user ids, only clocked in | `messages.send` |
| `cma.my_messages(p_since timestamptz default null, p_limit int default 50)` | the caller's messages, newest first; sets `delivered_at` on first return | any signed-in user |
| `cma.my_unread_count()`, `cma.mark_messages_read(p_ids uuid[])`, `cma.acknowledge_message(p_id)` | acknowledgement also sets `read_at` | own rows only |
| `cma.message_stats(p_from, p_to)` | per message: recipients, delivered, read, acknowledged, median seconds to read | `messages.send` or `performance.team` |

Views: `cma_read.message` (title and body hold references only, so both are included), `message_delivery`, `message_rule`.

Planned migrations after this track: **0009** Assignments (S2 routing, S3 offers with the accept click; owner write-back on 0007c's outbox), **0010** customer-field mirror, **0011** queue engine. (README's 0006a commerce becomes 0007b.)

---

## §5 The ingest service (`ingest/`)

One Cloud Run service `cma-ingest` per project (europe-west4), Node 22 ESM, `pg` and the Cloud SQL Node.js connector exactly as `web/src/lib/db/client.ts` connects, its own service account `cma-ingest@<project>.iam.gserviceaccount.com` as an IAM database user in `cma_app`. Public, invoker check disabled, max instances 5 (dev 2), min instances 1 in prod (HubSpot and Shopify expect an answer within seconds; a cold start plus the read-back budget would miss it), request body limit 1 MB, concurrency 20.

Routes: `GET /health` (version, no database); `POST /hubspot/:key`; `POST /aircall/:key`; `POST /shopify/:key`. The path key is looked up with `cma.ingest_connection(key)`; unknown or inactive → 404 with an empty body, wrong adapter for the route → 404. Authentication failure → 401 with an empty body and nothing written. Every database call afterwards runs as the tenant's Ingest user.

Layout: `src/server.mjs`, `src/core/` (connection lookup, secrets with a 5-minute cache, event recording, claim and finish, budgeted read-back, structured logging, the keyed hash), `src/adapters/hubspot/`, `src/adapters/aircall/`, `src/adapters/shopify/` (each: `verify.mjs`, `map.mjs` events → canonical, `read.mjs` read-back, `backfill.mjs`, `reconcile.mjs`). The core never reads a vendor payload. Logs are JSON with connection id, counts, durations and error codes; never payloads, ids of contacts or customers, numbers, emails or secrets.

Jobs (Cloud Run jobs on the same image, `node jobs/<name>.mjs`), triggered by Cloud Scheduler:

| Job | Schedule | Does |
|---|---|---|
| `sweep` | every minute | claim due events per active connection and process them; second read for records without a contact; `cma.link_calls(now() − 2 h)` |
| `poll-forms` | every minute | per HubSpot connection: refresh the form catalog hourly, read new submissions per counted form until the cursor, resolve contacts, upsert, move the cursor |
| `reconcile` | 02:30 Europe/Amsterdam | per connection and object type: everything modified in the last 26 h, through the same upserts (stale guard), one `sync_run` row each; Shopify: subscriptions checked and recreated |
| `outbox` | every minute | per CRM connection: claim pending write-backs, read current values, write the difference, finish |
| `backfill` | manual (`--connection <id> --object <type> --from <date>`) | the same, from `intake.start_date`, throttled under each source's rate limit, resumable through `sync_cursor` |

Secrets (Secret Manager in the project, names stored on the connection, accessor granted per secret to the service account only): HubSpot `ingest-hubspot-<slug>-signing` (client secret), `ingest-hubspot-<slug>-token` (static token); Aircall `ingest-aircall-<slug>-signing` (webhook token), `ingest-aircall-<slug>-token` (JSON `{"api_id","api_token"}`); Shopify `ingest-shopify-<app-slug>-signing` (client secret, also used to mint the 24-hour token by the client credentials grant; the client id sits in `settings`); hash pepper `ingest-hash-pepper-<tenant-slug>`.

---

## §6 Security, privacy and audit

1. **Authentication per request** as in §2, before anything but the key lookup touches the database. HubSpot and Shopify: HMAC with constant-time compare; Aircall: token compare plus path key, HTTPS only, and the account check against the payload where the payload names it.
2. **Account pinning**: the HubSpot `portalId`, the Shopify shop domain and the Aircall webhook's own token all pin a request to one connection; a mismatch is recorded as `ignored` with `portal_mismatch` and never read back.
3. **Keyed hash for phone numbers**: `HMAC-SHA256(pepper, E.164)` hex, pepper per tenant in Secret Manager, numbers normalised with libphonenumber using the line's or market's country as default region. The hash only links a telephony call to a CRM call; it is cleared by `ingest_contact_forget`. Rotating the pepper breaks old links only (they are stored in `call_link`).
4. **Least privilege**: read-only scopes at every source, except HubSpot contacts write for the write-back of §4.3a (limited to `writeback_field` in the database and in code); the Ingest user holds `ingest.write` only; readers see `cma_read` only; NocoDB and BigQuery never see raw, hashes, keys or secret names.
5. **Audit**: every table carries the change history trigger; every job run is a `sync_run` row; every event its `ingest_event` row with attempts and error; every alert its delivery row with timestamps.
6. **Dev holds test data only**: the HubSpot dev app is test-installed in the developer test account only; Aircall in dev receives replayed synthetic fixtures (no Aircall sandbox exists); Shopify dev uses a development store. Real data reaches prod only.
7. **Retention** follows the source: deletion and privacy deletion clear attributes; nothing is kept that the source deleted, apart from ids and times needed for counts.

---

## §7 Reports in the Workspace

Report surface (desktop, Pulse4all style, keyboard-first, no customer data on screen):

- **Dashboard** (exists): new deals and tickets per day and market (0006), plus two cards: speed to lead today (median business minutes, % within target) and new customers and first orders today.
- **Report → Speed to lead**: period bar, grouping (day, market, agent, pipeline), the summary table, a list of open deals not called (deal id, market, pipeline, age in business minutes, HubSpot link icon; no names).
- **Report → Intake**: per day and market, the counts of `intake_per_day` with sparklines; tagged calls per tag and direction; orders first, repeat and renewal per store.
- **Data → Data quality**: the checks of §4.4 with counts and, for the team, links to the HubSpot records.
- **Messages**: an inbox icon with the unread count in the rail, toasts for new alerts, a browser notification when the tab is in the background (permission asked on a click, never on load), an urgent alert opens a dialog with a sound that needs Acknowledge.

API (same data layer, JSON, IAP): `GET /api/v1/reports/speed-to-lead?from&to&group`, `GET /api/v1/reports/speed-to-lead/rows`, `GET /api/v1/reports/intake?from&to`, `GET /api/v1/reports/data-quality`, `GET /api/v1/me/messages?since`, `POST /api/v1/me/messages/read`, `POST /api/v1/me/messages/:id/ack`. Every route checks the same permission as its function.

---

## §8 New-deal alert flow

1. HubSpot sends `object.creation` for a deal → event recorded, 200.
2. Read-back upserts the record; the record is new and its `source_created_at` is within `max_age_minutes` → the service calls `cma.ingest_record_alerts(connection, 'deal', ids)`.
3. The function resolves recipients at that moment and writes message + deliveries in one transaction; a retry writes nothing new (unique rule + record).
4. Each open Workspace polls `GET /api/v1/me/messages?since=` every 10 seconds (README's fallback until the realtime service is chosen); a new alert shows a toast and, in the background, a browser notification. Opening it marks it read; the link opens HubSpot in a new window.
5. Backfilled and reconciled records never alert (they do not come through a `created` event within the age limit).
6. `cma.message_stats` gives delivery and read times per alert, the first measure of how fast agents see new leads, before S3's accept click exists.
