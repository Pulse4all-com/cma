# Night notes, 12 to 13 October 2026: Sources and alert rules configuration, linked accounts, Aircall and Shopify prod runbook

Written by Claude Code while Martin was away. Everything was built and verified in the session's own container (PostgreSQL 18.4 with `db/00` to `53` in README order, Node 22, the standalone build in mock and in api mode against that database); nothing touched dev, prod, Secret Manager or a vendor. One branch `night-2026-10-13` from `main`, one pull request. `records/` is untouched: the local outputs are in `local-records/`, the real runs are Martin's.

## What was built

1. **Addition 0008e** (`db/52_sources_configuration.sql`, `db/53_verify_sources_configuration.sql`), only what had no function: the connection's kind (`crm`, `telephony`, `commerce`, `automation`) with `cma.set_connection_kind()`; the reads behind the new screens (`cma.sources()`, `cma.connection_catalogs()`, `cma.markets_all()`, `cma.business_hours_all()`, `cma.business_holidays_all()`, `cma.message_rules()`); the linked accounts (`cma.linked_account_systems()`, `cma.linked_accounts()`); `cma.set_user_external_id()` and `cma.remove_user_external_id()` under the People rule instead of `users.manage_all`. Idempotent, one transaction, refuses to run before 0008d. The verify follows `45`, `47` and `49`: PASS or FAIL per check, the `verify.provoke` switch, a verdict row, and it refuses a database that is not dev (every block stops even when the client carries on). Every write of the screens goes through a function that already existed (`set_pipeline_lead`, `set_form`, `set_call_outcome`, `set_market_alias`, `upsert_assignment_rule` and its siblings, `set_connection_settings`, `set_user_external_id`, …).
2. **Configuration → Sources** (`/configuration/sources`, `/configuration/sources/{id}`): every connection with vendor, kind, account id, status, events in 24 hours, waiting, parked and the last event. A connection's page: the connection (name, vendor, account id read-only, kind with Set kind, Switch off with a confirmation, the address key, the secret names read-only, never a value); the non-secret settings with a live preview of a record link template (`app_host`, `record_url_<type>`); then by kind **Pipelines** (record type, label, Counted, Lead for deal pipelines only, the effect in each header hint), **Forms** (name, Counted, lead source, market picker), **Call outcomes** (label, Connected), **Fields** and write-back fields read-only (changes go through the runbook), **Lines** and **Tags** for telephony, the **Store** for a shop. **Apply a rule by name pattern** for forms and call outcomes: include and exclude words, what the rule sets, a row-by-row preview, and Save writes exactly the preview in one transaction. Keys B, N, S, F, O, A.
3. **Configuration → Markets**: markets (add, edit, switch off) with zone, language, currency, language skill; aliases as chips (add, ×); office hours per market as text per weekday with the tenant's default row and a market's own week in a dialog ("Use the default" clears it); holidays. Keys A, I, H.
4. **Configuration → Alert rules** (brief B14): both triggers, each rule with its effect in plain words, its alerts in 30 days and its sound (which follows the urgency); add, edit (record type, pipelines, urgency, age limit, and for a new-record rule the audience) with the effect previewed in the dialog; switch off and on; never deleted.
5. **Linked accounts on People**: Edit person shows one field per id the tenant's CRM and telephony connections use (`Owner id in <connection>`, `User id in <connection>`), saved through `set_user_external_id`, editable by whoever may edit the person; an id linked to someone else gives "This id is already linked to someone else. Unlink it there first; nothing was changed."; a **Linked** column (`n of total`) with a header hint. Data quality's "Owners without a person" and "Telephony users without a person" link to People.
6. **17 routes** under `/api/v1/configuration/{sources,markets,alert-rules}` and `/api/v1/team/directory/…/linked-accounts`, each checking `tenant.configure` (linked accounts: the People permission) before the database checks again; both data layers (Postgres and the mock with a fixture per tenant: a CRM, a telephony, a shop and an automation connection under invented adapter names).
7. **Copy**: 315 new keys in English and Dutch (1059 in all), a HeaderHint on every column that needs one. Nothing in code or copy names a tenant's pipelines, forms, markets, owners or outcomes.
8. **`docs/ingest/PROD_RUNBOOK.md` phases 8 (Aircall) and 9 (Shopify)** in the style of 7.1 to 7.9, with the helpers, the Studio context block, an expected output per step, the data prerequisites, the Intake page's change and every click path not walked through marked as such. **Blocked in part:** the Aircall adapter (B9) and the Shopify adapter (B10) with their scripts (`aircall-webhook.mjs`, `aircall-users.mjs`, `shopify-subscribe.mjs`), the `ingest-outbox` job and the backfill objects `telephony_call`, `commerce_customer`, `commerce_order` are not on `main`, so each phase opens with a gate: until they are merged only the vendor-side steps (8.1 and 8.2; 9.1 to 9.3) run.
9. **Part 4 (quiet hours, a clock-in after the window end):** behaviour not decided in README, so design and questions below, no code.
10. README: Data model (0008e section, scripts `52` and `53`, Planned migrations), Features 7 and 9, the API section (routes, screens, People, Verification), eleven Decision log rows, Open decisions, the Last updated line.

## Verification (outputs in `local-records/`)

| Check | Normal | Provoked |
|---|---|---|
| `npm ci`, `npm run typecheck`, `npm run lint`, `npm run build` (web) | clean, exit 0 | |
| `verify:copy` | PASS, 1059 keys, en and nl | FAIL, 5 problems |
| `verify:corrections` 31, `verify:csv` 16, `verify:dashboard` 17, `verify:live` 29, `verify:team` 26, `verify:roster` 31, `verify:configuration` 92, `verify:messages` 24, `verify:import` 23 (and `verify:reports` 28) | ALL PASS | ALL PROVOKED CHECKS FAILED |
| theme (mock, build) | PASS, 33 pages | FAIL, 5 problems |
| layout (mock, build) | PASS: 1280, 1920, the gate at 1279, navigation for five identities, the Configuration group with eight pages, Sources, Markets and Alert rules | FAIL, 6 problems |
| hints (mock, build) | PASS, 91 headers and 20 tiles on 9 pages | FAIL, 1 problem |
| `verify/api.mjs` against the build (mock auth, api data, local database at `53` with `reports-fixture.sql`) | `ALL 218 PASS` (dev has 219: the call-outcome check needs a call outcome the fixture lacks) | `ALL 218 PROVOKED CHECKS FAILED` |
| `verify/api.mjs --sources` (database / mock data) | `ALL 31 PASS` / `ALL 32 PASS` | all failed / all failed |
| `52` first run and rerun | clean; the rerun writes nothing new | |
| `53` | 13 PASS, verdict PASS | A1, B1, B8 FAIL, verdict `PROVOKED, NOT A PASS` |
| `53` on a database without the dev seed | `REFUSED: not dev`, every block stopped | |
| twelve mutations of `52`, each on a copy of the database | all caught by `53` | |
| `04` to `51` after `52` | identical to the same verifies at `51` (`07` and `10` list the new migration row) | |

Not run here (they need a server, IAP or a real database): `verify:iap`, `verify:scheduler`, the theme and layout runs against dev, every db/ script in dev or prod, a Docker build (no Dockerfile change), the ingest verifiers (no change under `ingest/`).

Found on the way: the mock fixture's urgent message opens a pop-up that covered the manager's pages and failed theme, layout and hints on `main` too (proven on a checkout of `main`); the three verifiers now acknowledge it first.

## Decisions to confirm (each a Decision log row ending "(Claude Code, for Martin to confirm)")

1. A connection has a kind in the data model's terms (`crm`, `telephony`, `commerce`, `automation`), never derived from the vendor; it decides the Sources sections and which ids People offers; a kind the rows contradict is refused.
2. The Sources page never creates a connection and never shows or accepts a secret (names only; a secret-looking settings key is refused three times over). Connections come from the runbook.
3. Linked accounts follow the People rule (`set_user_external_id` moves from `users.manage_all` to it); nobody links their own ids on screen; the database still lets an admin link their own (seed or Studio).
4. Ids are typed by hand tonight; no owner sync. A picker needs the CRM owners and telephony users read through the ingest service into a catalog per connection (id, active; a name or email only if Yordi agrees), refreshed by the reconcile, with a data-quality count of entries without a person.
5. An alert rule's sound follows its urgency (one tone for normal, chime and pop-up for urgent); rules are switched off, never deleted; name and trigger fixed once a rule exists.
6. Rules by name pattern: words typed per run and never stored; the preview is what is saved, in one transaction; lead source from the first include word in the name; market from the two-letter prefix through the aliases; a name without a prefix keeps its market.
7. Office hours are edited a week at a time, a market's own week starting from the default.
8. Adapter names are lower-case letters and digits only, because ids read `<adapter>_owner` / `<adapter>_user` (`upsert_connection` still accepts an underscore; a later check could make that explicit).
9. `53` is dev only, like `49`; prod gets a read-only Studio check.
10. The browser verifiers acknowledge the mock urgent message first.
11. Phases 8 and 9 are written ahead of B9 and B10 with a gate; the Aircall signing secret is created empty and granted before the webhook exists; store, subscriptions and backfill in one sitting; renewal lists set from the backfilled orders.

## Part 4: quiet hours and the late clock-in (design and questions, no code)

README leaves both open (Open decisions: "quiet hours and Spain's right to disconnect"; Forgotten clock-outs: "whether a clock-in after the window end … should be refused"), so the night wrote the design and the questions instead of code.

### Quiet hours

**Today:** a message gets one delivery row per recipient at send time (optionally only those clocked in). The open Workspace polls; every new message shows a toast with one tone, an urgent one a pop-up with a chime that must be acknowledged, and a desktop notification while the tab is hidden (if the person allowed it). An assignment alert goes to the owner's person whether or not they are clocked in. There is no email or mobile push, so an interruption outside working time happens only where the Workspace is open outside working time.

**Proposal (A, recommended):** a person is *quiet* when their time is kept and they are not clocked in, or, for people whose time is not kept (managers, admins), outside the tenant's workday window in their zone. While quiet: no tone, no desktop notification, no pop-up; the message waits in the inbox and the unread count updates silently. An urgent message received while quiet pops up at the next clock-in (or when the window opens). No new configuration: it follows the clock and the window that exist (0008b). B: tenant quiet hours per market as settings (more configuration, and a second window next to the workday window). C: a per-person preference on My account (Features table: "preferences and quiet hours"), later and on top of A.

**Built after the answer:** the quiet state computed in the data layer from the own day and the window settings (or one read function in an addition 0008f if the data layer cannot read them in one statement), returned with `GET /api/v1/me/messages`; `MessageCenter` suppresses tone, notification and pop-up while quiet and shows a held urgent message when quiet ends; one inbox line "Quiet until you clock in" in both locales; the pure decision in `src/lib/messages.ts` with checks in `verify/messages.mjs`, the route in `verify/api.mjs`.

**Questions for Martin (with Yordi on the Spanish rule):** (1) is "not clocked in means quiet" (and outside the window for those without a clock) the rule? (2) does an urgent, must-acknowledge broadcast wait for the clock-in too, without a sender's override? The proposal says yes to both. (3) may the inbox show messages that arrived outside working time when a person opens it then (nothing interrupts, but they are visible)? The proposal says yes.

### A clock-in after the window end

**Today:** `cma.open_workday` refuses a new day before the window start (`CMA04`, "The workday starts at {time}") and accepts one after the window end. That day counts nothing (time after the window end is not counted), and the forgotten-day close ends it after the grace at its last event, the late clock-in itself (the close never ends a day before its last event, which wins over the window end), so it leaves a day without time, flagged for a manager, and a "Workday closed automatically" notice to the person.

**Proposal (A, recommended):** refuse a new day from the window end on, the mirror of the start: `CMA04` "the workday ended at %", copy "The workday ended at {time}" in both locales on Welcome and My day. The grace stays the scheduler's alone (no clock-in in the grace). A day that already exists is returned as today (a clock-in on an ended day changes nothing). A tenant without a window (00:00 to 24:00, the default) never sees it. B: keep accepting and show "time after {time} does not count", which still leaves the empty flagged day.

**Built after the answer:** addition 0008f with `open_workday` redefined and its verify (the clock-in at 21:59 and 22:00 for the dev window, the provoke switch, dev and prod like `47`); the route maps the message as the early one; `verify:api` cannot force the hour, so the database verify proves it (as for the start).

**Question for Martin:** refuse a clock-in from the window end on, yes or no; and exactly at the window end, or earlier (for example no new day in the last 15 minutes)? The proposal: yes, exactly at the window end.

## Left for the morning

- `MORNING_RUNBOOK.md` in this folder: review and merge the pull request, run 0008e in dev (`52`, `53`, `33`, `31`) and prod (`52`, a read-only check, `33`, `31`), the dev verifier runs against the merged image (`verify:api` full and `--sources`), a browser check of each new screen in prod, then `PROD_RUNBOOK.md` phases 8 and 9 as far as their gates allow.
- Briefs needed before phases 8 and 9 can finish: B9 (the Aircall adapter, `aircall-webhook.mjs`, `aircall-users.mjs`, the backfill object `telephony_call`, and which Aircall value the connection pins) and B10 (the Shopify adapter, `shopify-subscribe.mjs`, the `ingest-outbox` job, the commerce backfill objects). The Open decision "Aircall tags as a refinement of connected" is to be decided before B9.
- The two Part 4 questions; the owner and user picker (Decision 4) as a later increment.
- The dev run of `verify:api` leaves one switched-off rule `API verifier rule` on Configuration → Alert rules (rules are never deleted).
- Records of the real runs (`records/0008e-dev-<date>`, `records/0008e-prod-<date>`) are Martin's to commit.
