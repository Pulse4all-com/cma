# Claude Code briefs: intake track

Fourteen briefs, one pull request each, in the order of `MORNING_RUNBOOK.md`. Paste a brief (from its `---` line to the next) into a new Claude Code on the web session on `Pulse4all-com/cma`. Every brief assumes the standing instructions below; they are repeated in short at the top of each brief, so a session never depends on another.

Model: Opus for B1 to B5 and B13 (data model, permissions, RLS) and B7 to B10 (authentication of requests); Sonnet is enough for B0, B6, B11, B12.

## Standing instructions (part of every brief)

1. Read `CLAUDE.md`, `README.md` and `docs/night-2026-10-10/DESIGN.md` (the sections the brief names) before writing. DESIGN.md is the specification; where it and the code of 0006 disagree on conventions, follow 0006's conventions and say so in the PR.
2. **Push early.** Commit and push the branch after the first file that compiles, and open a **draft PR** as soon as one verifier passes, so nothing is lost if the session stops. Mark ready for review only when every acceptance check passes.
3. Database work: a migration is rerunnable and forward-only, in the next `db/` numbers given in the brief, with its own verify script in the shape of `db/31_verify_ingest_crm_records.sql` (the verdict table per tenant, PASS; with `select set_config('verify.provoke', 'true', false);` swapped in, every check fails and the verdict says PROVOKED, NOT A PASS). Run every `db/` script in README order on a local **PostgreSQL 18** (install it in the session; the scripts need `uuidv7()`), then the new verify normal and provoked, then every earlier verify (`04` … `31`) unchanged. Put the local outputs under `docs/night-2026-10-10/local-records/<migration>/`. Never write `records/<migration>-dev|prod-*`: Martin writes those from the real runs.
4. Service and web work: `npm ci`, typecheck, lint, build, every pure verifier normal and with `--provoke` (each check must fail), as the brief lists.
5. No secrets, tokens, real ids of customers, real phone numbers or emails anywhere: fixtures use `example.com`, `+4400000000x`-style numbers and invented ids.
6. Nothing hardcodes Pulse4all, a market, a pipeline or a property name in code paths: those are configuration (DESIGN §3). Vendor names appear only as adapter values and inside `ingest/src/adapters/<vendor>/`.
7. The PR description lists: what was built, the acceptance results with their last lines, anything in DESIGN.md not built and why, and any deviation from DESIGN.md with the reason.
8. README: the brief says what to change. Always bump the "Last updated" line with one sentence for the PR.

---

## B0. README twenty-fourth pass: the intake track

Goal: record the night's decisions in README.md. Docs only, no code.

Read: `docs/night-2026-10-10/NIGHT_NOTES.md` §2 (decisions) and §5 (README edits) — they list every edit.

Do: apply §5 exactly: Decision log rows (10 October 2026), Roadmap's speed-to-lead track rewritten as the intake track, Planned migrations renumbered (0007, 0007a, 0007b, 0007d, 0008 Messaging moved up; Assignments 0009, mirror 0010, queue engine 0011), Source of truth rows added, Architecture's ingest paragraph, Open decisions replaced and added, KPIs section 1 pointing at DESIGN §4.4 for the speed-to-lead definition, the 0006 status lines in Environments for dev and prod (records `records/0006-dev-2026-10-09`, `records/0006-prod-2026-10-09`), the Welcome section's "Messaging, migration 0006" → "Messaging, migration 0008", "Last updated" (twenty-fourth pass).

Acceptance: `git diff --stat` touches README.md only; every heading still present (`grep -c '^## ' README.md` unchanged or +0); no line mentions a legacy private app as the plan; PR description quotes the new Decision log rows.

---

## B1. Migration 0007: intake core

Standing instructions apply (1–8). Opus.

Goal: the data model of DESIGN §4.1 and §3: markets, office hours, the connection extensions, CRM calls, associations, forms and submissions, sync cursors and runs, the configuration and ingest functions, the `cma_read` views.

Files: `db/32_intake_core.sql` (migration 0007), `db/33_verify_intake_core.sql`, local outputs.

Rules beyond DESIGN: changes to 0006 objects are additive and keep every 0006 call shape (`31` must still pass unchanged); `set_connection_field` keeps its parameter order with `p_slot smallint default 1` appended; the new settings (DESIGN §3) go into the `cma.setting` catalog with their defaults; `cma.business_seconds` handles ranges spanning days, DST changes (test a range across 25 October 2026 in Europe/Amsterdam) and holidays; `normalize_market` is `stable`; every new table goes through `cma.setup_tenant_table` (RLS, policies, audit) and the application cannot delete from it (mapping rows excepted: `market_alias`, `business_hours`, `business_holiday`, `crm_contact_ref`).

Verify must prove at least: structure and privileges for every new table (RLS on, policies, audit trigger, no delete for `cma_app` where stated, grants to `cma_read` views only for readers, no raw/hash/key columns in views); `connection_field` accepts the new fields and slots and refuses `slot > 1` for non-ref fields; contact refs with two Shopify slots; `upsert_market` refuses `UK`, lower-case codes and unknown zones; alias normalisation; `business_seconds` on a weekday, across a weekend, across a holiday, across DST, outside hours, reversed range; `next_business_noon` on a Friday afternoon; calls upsert inserted/updated/stale/deleted; associations add, remove, re-add, older change ignored; form catalog refresh keeping configuration, submissions idempotent, `kept_values` filtered to `kept_fields` even when the input carries more; cursor get/set; a sync run finishes once; `ingest_contact_forget` clears what it should; tenant isolation for every new table; the Ingest user cannot call configuration functions and a configuring person cannot call ingest functions.

Acceptance: local run of `00`…`33` clean; `33` → PASS for both tenants; provoked → every check FAIL and PROVOKED, NOT A PASS; `04`…`31` unchanged PASS. Expected verdict line shape: `| pulse4all-subscriptions | … | PASS`.

README: the Data model section "Data model: intake core (migration 0007)" in the style of the 0006 section (tables, functions, what the verify proves); Planned migrations: 0007 marked written.

---

## B2. Migration 0007a: telephony

Standing instructions apply. Opus. Depends on B1 merged.

Goal: DESIGN §4.2: telephony calls, tags with history, lines, the call link, their functions and views; `ingest_contact_forget` redefined to clear linked telephony hashes.

Files: `db/34_telephony.sql`, `db/35_verify_telephony.sql`, local outputs.

Verify at least: structure and privileges; a call upserted from created → answered → ended with out-of-order events (ended first) ending in the right final state (stale guard on `source_version_at`); tags opened and closed by difference, re-tagging after untagging; catalog refresh keeping configuration; `link_calls` pairs on hash + direction + 120 s, nearest first, each side once, ignores null hashes, leaves a second candidate unlinked; `unlink_call`; forget clears linked hashes; tenant isolation.

Acceptance: as B1 with `35`; `33` and `31` still PASS.

README: "Data model: telephony (migration 0007a)".

---

## B3. Migration 0007b: commerce

Standing instructions apply. Opus. Depends on B1 merged.

Goal: DESIGN §4.3: stores, customers, orders with lines, `order_kind`, `reclassify_orders`, views.

Files: `db/36_commerce.sql`, `db/37_verify_commerce.sql`, local outputs.

Verify at least: structure and privileges; one store per connection, unique handle; customer upsert with stale guard and deletion clearing; order upsert with lines replaced as a set; `order_kind` first/repeat/unknown from `prior_orders_count`, renewal from each of the two settings, reclassification after a settings change; test orders kept and flagged; a customer id present in two stores; tenant isolation.

Acceptance: as B1 with `37`; `33`, `31` still PASS.

README: "Data model: commerce (migration 0007b)"; Planned migrations: the old 0006a row removed.

---

## B13. Migration 0007c: outbox and CRM contact write-back

Standing instructions apply. Opus. Depends on B1 and B3 merged. (Numbered B13 because it was added after the first draft; it runs after B3.)

Goal: DESIGN §4.3a: `writeback_field`, `outbox_action`, `set_writeback_field`, `enqueue_contact_writeback`, `outbox_claim`, `outbox_finish`, `outbox_resolve`, `outbox_status`, the setting `outbox.max_attempts` (default 8), views. Database only; the worker comes in B10.

Files: `db/38_outbox.sql`, `db/39_verify_outbox.sql`, local outputs.

Verify at least: structure and privileges (the application cannot delete outbox rows; the Ingest user enqueues, claims and finishes but cannot configure or resolve; a configuring person resolves but cannot enqueue); only enabled fields are kept, unknown fields refused; dedupe on an identical payload; a newer pending action supersedes the older one for the same contact, a sent one is never touched; claim with `SKIP LOCKED` in two sessions (no double claim), backoff, a dead claim returning; parking after the maximum and resolve with retry and with drop recording the person; `slot` mode allowed only for `commerce_ref`; tenant isolation.

Acceptance: as B1 with `39`; `31`, `33`, `37` still PASS.

README: "Data model: outbox and CRM contact write-back (migration 0007c)"; Architecture's Outbox worker paragraph: lands with 0007c, first action the contact write-back.

---

## B4. Migration 0007d: lead metrics and data quality

Standing instructions apply. Opus. Depends on B1, B2, B3 merged.

Goal: DESIGN §4.4 exactly: the speed-to-lead definition, `speed_to_lead_rows`, `speed_to_lead_summary`, `lead_to_order_rows`, `intake_per_day`, `data_quality`, the `cma_read` views including `dq_*`.

Files: `db/40_lead_metrics.sql`, `db/41_verify_lead_metrics.sql`, local outputs.

Verify with a constructed day in a throwaway tenant (markets NL and GB, office hours, a holiday) at least: a deal called after 7 business minutes; a deal created Friday 16:55 called Monday 09:10 (business seconds 15 min, not 64 h; before next noon true); a deal never called (open and closed variants); an inbound call first; a call on the deal but not the contact; a call on a second associated contact; a call before creation outside and inside `pre_window_minutes`; a linked telephony call moving the effective start; a removed association no longer counting; a deal in a non-lead pipeline left out; market from the contact when the deal has none, `unknown` when neither; agent attribution through `hubspot_owner`; lead to order with first, repeat, renewal, a test order ignored, an order after `max_days` ignored, an order via Shopify slot 2; `intake_per_day` counts per market; each data-quality check firing once on purpose; the 92-day bound; permissions (an agent without `reports.view`/`performance.team` refused); tenant isolation.

Acceptance: as B1 with `39`; `31`, `33`, `35`, `37` still PASS.

README: "Data model: lead metrics (migration 0007d)"; KPIs section 1 refers to it.

---

## B5. Migration 0008: messaging core and record alerts

Standing instructions apply. Opus. Independent of B2–B4 (needs B1 for markets).

Goal: DESIGN §4.5: messages, deliveries, rules, `ingest_record_alerts`, `send_message`, the caller's reads and writes, stats, views.

Files: `db/42_messaging.sql`, `db/43_verify_messaging.sql`, local outputs.

Verify at least: structure and privileges; a rule matching agents clocked in with the market's language at the minimum level; nobody matching → fallback permission holders; `only_clocked_in` false; age limit (an old record never alerts); idempotency (second call writes nothing); a disabled rule; deliveries only for the resolved users, resolution at send time (a later team change does not alter history); `my_messages` sets `delivered_at` once and only for the caller; read and acknowledge only own rows, timestamps never move back; `send_message` targets (everyone, team, language with level, users, clocked in) and its permission; content carries no more than the reference fields; tenant isolation.

Acceptance: as B1 with `41`; `31`, `33` still PASS.

README: "Data model: messaging core and record alerts (migration 0008)"; Features 7 Messaging notes the first increment (alerts, poll every 10 s).

---

## B6. HubSpot project apps (config only)

Standing instructions apply. Sonnet.

Goal: `hubspot/` as one project template rendered into two apps, **CMA ingest dev** and **CMA ingest prod**, on HubSpot's current developer platform (static auth, private distribution), never a legacy private app.

Read: HubSpot docs (verify the current platform version and schema; say which version you used): developers.hubspot.com/docs/apps/developer-platform/build-apps/create-an-app, …/build-apps/app-configuration, …/add-features/configure-webhooks.

Files: `hubspot/template/` (hsproject.json, `src/app/app-hsmeta.json`, `src/app/webhooks/webhook-hsmeta.json` with placeholders for env values only); `hubspot/env/dev.json`, `hubspot/env/prod.json` (uid suffix, name, targetUrl placeholder, maxConcurrentRequests 10); `hubspot/render.mjs` (renders `hubspot/build/<env>/`, refuses a placeholder targetUrl unless `--draft`; `build/` git-ignored; `--target-url <url>` sets it without editing files); `hubspot/verify/render.mjs` (pure: both render, uids differ, URLs differ, scopes identical, the contacts write scope the only write scope, the subscription list equals `VENDOR_SETUP.md` §1.3, placeholder refused); `hubspot/README.md` (render, `hs account auth`, `hs project upload` from `hubspot/build/<env>`, installs: dev only by Test installs into `CMA dev`, prod by Standard install; where the client secret and token appear; how to see the first delivery's headers in the ingest logs).

Subscriptions and scopes: exactly `VENDOR_SETUP.md` §1.3 (crmObjects where supported, `hubEvents` for privacy deletion, `legacyCrmObjects` only where needed; list which in the PR). Scopes: the minimum read-only set for deals, tickets, calls, forms, call dispositions and owners, plus contacts **read and write** (the write-back of DESIGN §4.3a; the only write scope, and the verifier asserts it is the only one); name the exact scope strings and the doc page they came from.

Acceptance: `node hubspot/verify/render.mjs` → ALL n PASS; `--provoke` → ALL n PROVOKED CHECKS FAILED; `node hubspot/render.mjs dev --draft` writes a project whose files match the documented schema.

README: Decision log row (10 October 2026) on project apps is added by B0; here only Architecture under Code: `hubspot/`.

---

## B7. The ingest service: core, HubSpot webhooks and read-back, deploy

Standing instructions apply. Opus. Depends on B1 merged.

Goal: `ingest/` per DESIGN §5 and §2 for HubSpot: `GET /health`, `POST /hubspot/:key` with v3 verification, account pinning, event recording, the budgeted read-back (3 s) for deals, tickets, contacts, calls and associations, the call outcome catalog, the keyed hash for call numbers, and `docs/ingest/deploy.sh` for the service (jobs come in B8).

Files: `ingest/package.json`, `ingest/Dockerfile`, `ingest/cloudbuild.yaml` (not wired to a trigger), `ingest/src/server.mjs`, `ingest/src/core/*.mjs`, `ingest/src/adapters/hubspot/{verify,map,read}.mjs`, `ingest/verify/*.mjs`, `ingest/tools/replay.mjs` (posts a fixture to a URL, signing it with a secret read from an env var or a local file, never echoed), `docs/ingest/deploy.sh` (per project: service account, IAM database user and its grant into `cma_app` printed as the Studio statement Martin runs, secret accessor per named secret, Artifact Registry image, Cloud Run deploy with the settings of DESIGN §5, prints the service URL), `docs/ingest/README.md`, `docs/ingest/hubspot-owners.mjs` (lists HubSpot owners with the token secret and prints, per owner, one Studio statement `select cma.set_user_external_id(u.id, 'hubspot_owner', '<owner id>') from cma.app_user u where u.email = '<owner email>';` for people who exist in the CMA; staff data only, printed to the terminal, never written to a file).

Deploy script: `bash docs/ingest/deploy.sh dev|prod` deploys the service (B8 adds `--jobs`); dev sets `INGEST_LOG_HEADER_NAMES=1`; `GET /health` answers `{"ok":true,"version":"<short sha>"}`.

Behaviour: unknown key 404; wrong route for the adapter 404; bad or old signature 401, nothing written; `portalId` ≠ connection account → recorded ignored `portal_mismatch`; batch ≤ 500 per `ingest_record_events`; DB error before commit → 500; read-back reads only the properties named in `cma.connection_config` plus DESIGN-listed standard ones (VENDOR_SETUP §1.1 last paragraph), uses batch read endpoints, 429/timeout → finish failed (backoff); call numbers hashed in memory and dropped; header names (never values) logged when `INGEST_LOG_HEADER_NAMES=1` so the first delivery shows which signature headers HubSpot sends.

Verifiers (pure, no database): `verify/signature.mjs` (valid v3, wrong secret, 6-minute-old timestamp, tampered body, wrong URI, missing header), `verify/mapping.mjs` (HubSpot generic and hubEvents payload samples → canonical events, ids only, portal mismatch), `verify/hash.mjs` (normalisation of national and international formats to the same hash, different pepper → different hash, no number in the output). Flow verifier `verify/flow.mjs` against the local PostgreSQL with `db/00…33` and a fake HubSpot server: signed batch → events, records, contacts, calls, associations; unsigned → 401 and nothing written; duplicate → not written twice; HubSpot down → 200, events failed with backoff; tenant isolation.

Acceptance: `npm ci && npm run lint && npm test` in `ingest/`; each verifier ALL n PASS and `--provoke` ALL n PROVOKED CHECKS FAILED; `bash -n docs/ingest/deploy.sh`; the image builds locally (`docker build`) if Docker is available, else say so.

README: Architecture's Ingest API paragraph: routes, adapters, jobs to come; Code: `ingest/`.

---

## B8. Ingest jobs: sweep, forms poll, reconcile, backfill

Standing instructions apply. Opus. Depends on B7 merged.

Goal: DESIGN §5 jobs for HubSpot (Aircall and Shopify plug into the same job runner in B9 and B10): `jobs/sweep.mjs`, `jobs/poll-forms.mjs`, `jobs/reconcile.mjs`, `jobs/backfill.mjs`, each a `sync_run` row; and the Cloud Run jobs `ingest-sweep`, `ingest-poll-forms`, `ingest-reconcile`, `ingest-backfill` plus Cloud Scheduler entries in `docs/ingest/deploy.sh` behind a `--jobs` flag (`ingest-backfill` gets no schedule; it runs with `gcloud run jobs execute ingest-backfill --args=--connection,<id>,--object,<type>,--from,<date>`) (scheduler service account with `run.invoker` on the jobs only; schedules of DESIGN §5; time zone Europe/Amsterdam).

Forms: catalog refresh hourly (`ingest_upsert_forms`), submissions per counted form newest first until the cursor (`submittedAt` + conversion id), contact resolution by a CRM search on the email field (field name from the form definition's email field; the email lives in memory only), UTM parsed from the page URL, page URL stored as host and path only, `kept_values` only for `kept_fields`. Backfill: `--connection`, `--object deal|ticket|crm_call|form_submission|contact`, `--from` (default the `intake.start_date` setting), throttled to stay under half the documented rate limit, resumable from `sync_cursor`. Reconcile: last 26 h by `hs_lastmodifieddate` by default, `--lookback-minutes <n>` to shorten it (so the polling fallback of NIGHT_NOTES D3 is only a schedule change), same upserts.

Verifiers: `verify/forms.mjs` (pure: UTM parsing, host and path only, email dropped, kept fields only, cursor stop), `verify/jobs-flow.mjs` against local PostgreSQL and the fake HubSpot server: sweep processes due events and stops at max attempts; forms poll idempotent across two runs; backfill resumes after an interruption; reconcile picks up a change the webhook missed and leaves a newer row alone.

Acceptance: as B7.

README: Architecture: the jobs and their schedules.

---

## B9. Aircall adapter, webhook script, replay

Standing instructions apply. Opus. Depends on B2 and B8 merged.

Goal: DESIGN §2 for Aircall: `POST /aircall/:key` with token verification (constant time, from Secret Manager), events → canonical (`telephony_call`), read-back `GET /v1/calls/{id}` (Basic auth from the token secret JSON), tags and numbers catalogs (`GET /v1/tags`, `GET /v1/numbers`, hourly in sweep), counterpart number hashed with the line's market as default region, reconcile and backfill (`GET /v1/calls?from&to`, 60 requests per minute per company, stay under 30), `link_calls` already in sweep.

Files: `ingest/src/adapters/aircall/*`, verifiers, fixtures under `ingest/verify/fixtures/aircall/` (invented ids and numbers), `docs/ingest/aircall-webhook.mjs` (creates the webhook through `POST /v1/webhooks` with the six events of VENDOR_SETUP §2, pipes the returned token into `gcloud secrets versions add <name> --data-file=-` and prints only the webhook id; `--list` and `--delete <id>` too), `docs/ingest/aircall-webhook.mjs` arguments: `--project <gcp project> --url <full webhook url> --api-secret <token secret name> --token-secret <signing secret name>`; `docs/ingest/aircall-users.mjs` (prints one Studio statement per Aircall user whose email exists in the CMA, as `hubspot-owners.mjs` does, system `aircall_user`); `docs/ingest/README.md` section Aircall, and replay instructions for dev: a dev connection with an invented token secret and the connection setting `{"replay":true}`, under which the read-back uses the event's own call object instead of the API; the service honours `replay` **only** when the environment variable `INGEST_ALLOW_REPLAY=1` is set, which `deploy.sh dev` sets and `deploy.sh prod` never does (a verifier case proves a prod-configured service ignores it).

Verifiers: token compare (right, wrong, missing, timing-safe function used), mapping of each event type, out-of-order events, flow against local PostgreSQL with a fake Aircall API.

Acceptance: as B7.

README: Open decisions: Aircall's token-in-body authentication noted with its mitigations (DESIGN §6.1–2).

---

## B10. Shopify adapter and subscription script

Standing instructions apply. Opus. Depends on B3, B8 and B13 merged.

Goal: DESIGN §2, §4.3 and §4.3a for Shopify, plus the outbox worker: `POST /shopify/:key` with `X-Shopify-Hmac-Sha256` verification on the raw body (client secret), shop domain pinning, `X-Shopify-Event-Id` as event key, the client credentials grant (client id from `settings`, secret from Secret Manager, token cached until 5 minutes before its 24 h expiry, one per store), read-back through GraphQL at the connection's `api_version` (customers: id, state, locale, numberOfOrders, amountSpent, createdAt, updatedAt; orders: the fields of DESIGN §4.3 with up to 250 line items paged, `sourceName`, the app id, landing and referring URLs reduced to host, path and UTM), the prior-order count as `numberOfOrders` of the customer minus `ordersCount(query: "customer_id:<id> AND created_at:>='<order createdAt>'")` (both exact → `prior_count_exact` true), reconcile and backfill (`updated_at:>=` / `created_at:>=`), and the subscription check in reconcile. **Matching and write-back (§4.3a):** on a customer's read-back, read its email in memory, search the HubSpot connection named by the store connection's `crm_connection_id` for contacts with that email (CRM search, throttled), exactly one → `cma.enqueue_contact_writeback` with `commerce_ref`, `commerce_store`, `commerce_orders`, `commerce_spent`, `country` (the store's market), `currency` (the store's currency), `language` (the locale's language part); none or several → counted (no write), the email dropped either way; when Shopify redacts the email (no Email field granted), search instead for contacts whose configured `commerce_ref` properties hold the customer id (VENDOR_SETUP §4 fallback). **Outbox worker:** `ingest/src/adapters/hubspot/write.mjs` and `jobs/outbox.mjs` (Cloud Run job `ingest-outbox`, every minute, in `deploy.sh --jobs`): claim per CRM connection, batch-read the targets' current values of the configured properties, apply `always`, `if_empty` and `slot` exactly as DESIGN §4.3a, write the difference with one batch update, finish with the result (written and skipped properties); a property not in `writeback_field` is never written (code check, with a verifier case); 429 and timeouts → failed with backoff.

Files: `ingest/src/adapters/shopify/*`, `ingest/src/adapters/hubspot/write.mjs`, `ingest/jobs/outbox.mjs`, verifiers, fixtures (invented), `docs/ingest/shopify-subscribe.mjs` (arguments `--project <gcp project> --shop <handle>.myshopify.com --client-id <id> --secret-name <client secret name> --url <full webhook url> [--api-version 2026-10] [--list|--delete <id>]`; mints a token by the client credentials grant, creates the seven subscriptions of VENDOR_SETUP §3.4, prints ids only), `docs/ingest/README.md` section Shopify.

Verifiers: HMAC (right, wrong secret, tampered body, missing header, base64 compare timing-safe), shop pinning, mapping per topic, the prior-count arithmetic including a customer with older orders, token cache expiry, the email never reaching a log or the database (a verifier greps the flow's database and logs for the fixture email), the mode logic (`if_empty` keeps an agent's value, `slot` fills 1 then 2 and stops at full, `always` writes only a difference), a non-configured property refused, flow against local PostgreSQL with a fake Shopify GraphQL endpoint and a fake HubSpot (search and batch update).

Acceptance: as B7.

README: Source of truth row for orders: the CMA reads Shopify directly and keeps HubSpot's copy (ids, store, totals) itself; "What is written back to the CRM" gains the Shopify-derived contact fields.

---

## B11. Web: intake reports

Standing instructions apply. Sonnet. Depends on B4 merged (and running in dev).

Goal: DESIGN §7 reports: Dashboard cards (speed to lead today, new customers and first orders today), Report → Speed to lead (period bar, grouping, summary, open not called with HubSpot link icons), Report → Intake, Data → Data quality; the API routes of §7 with the same permissions as their functions; copy in both locales; mock mode data for all of it; Pulse4all style (project file `Pulse4all-Style.md` is not in the repo: follow the existing pages' theme tokens and components).

Files: `web/src/lib/api/reports.ts` (or the existing pattern), data-layer methods on Postgres and mock, pages under the existing Report and Data groups, `web/verify/` additions: the API verifier gains the new routes (permission refusals included), theme and layout checks for the new pages.

Acceptance: `npm run typecheck`, `lint`, `build`; pure verifiers and the API verifier normal and `--provoke` against the local mock server and a local database with `db/00…39` plus a small fixture (invented ids).

README: Features 5 (reporting) notes the first reports; API section lists the routes.

---

## B12. Web and ingest: messages and new-deal alerts

Standing instructions apply. Sonnet. Depends on B5 merged; touches `ingest/` (one call).

Goal: DESIGN §8: the ingest calls `cma.ingest_record_alerts(connection, 'deal', ids)` after a read-back upserts a deal that arrived by a `created` event (one line in the HubSpot read path, with its flow-verifier case); the Workspace polls `GET /api/v1/me/messages?since=` every 10 s while visible (and every 30 s hidden), shows a toast, a rail inbox with the unread count, a browser notification when hidden (permission asked from a button in the inbox, never on load), an urgent dialog with sound and Acknowledge; marking read on open; the HubSpot link opens a new window. Routes of DESIGN §7 for messages. Mock mode emits an alert every few minutes for the dev identities.

Acceptance: as B11, plus the ingest flow verifier case (a created deal → one message, a retry → none, a backfilled deal → none).

README: Features 7 Messaging: first increment live (polling, browser notification); Open decisions: the realtime service choice stays open.
