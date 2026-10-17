# 5.6 Speed, the static half: where the time goes in the web app's request path

**Summary.** Examined by static reading (no build, no server, no database queries): every `page.tsx` under `web/src/app`, `Shell.tsx`, `layout.tsx`, `access.tsx`, the data layer (`lib/data/postgres.ts`, `lib/db/client.ts`), identity (`lib/auth/identity.ts`, `iap.ts`, `proxy.ts`), the API plumbing (`lib/api/respond.ts`), the polling client components, the read functions in `db/*.sql` (bodies extracted to `/var/tmp/5.6/fn/`), `pg-pool` 3.14.0 and the Cloud SQL connector 1.12.0 in `node_modules`, the Next.js 16.3.8 docs in `node_modules/next/dist/docs`, `cloudbuild.yaml` and the README sections named in the task. About 2.5 hours. Everything below is **expected** (what the code says) or **estimated** (marked); nothing was **observed** running, by design of this half. Most important: (1) the Live board's 10-second poll is a full page re-render of 8 to 9 transactions (35+ database round trips) per viewer, and one of them (`cma.follow_up_summary`) re-derives the tenant's whole lead history from `speed_to_lead_of(tenant, null, null)` on every tick; (2) every request pays identity as two transactions (7 round trips) and every page view pays it twice (the page and the message poll that fires on mount); (3) the pool keeps no warm connection (`min` 0, idle 30 s), so after 30 quiet seconds the next request opens a TLS connection first, and a hidden tab's 30-second poll races that timeout. The timing log line and the round-trip regression guard are designed in sections 10 and 11 with diffs.

Round trips are counted from `web/src/lib/db/client.ts:183-225`: `withoutTenant` = pool checkout + `begin` + query + `commit` = **3 database round trips** (the brief's "4" counts the checkout; a warm checkout is local); `withTenant` = `begin` + `set_config` + N queries + `commit` = **3 + N**. Identity (`getAccess`) = 1 `withoutTenant` + 1 `withTenant` = **2 transactions, 7 round trips** (`postgres.ts:786-853`). "tx" = transactions, "RT" = database round trips, "depth" = sequential waves of database work on the request's critical path (identity is always 2 waves: tenant lookup, then principal).

---

## 1. Round trips per page

### 1.1 What every page pays before its own reads

| Step | File:line | tx | RT | Notes |
|---|---|---|---|---|
| `resolve()` → `connection()` → `getAccess()` | `src/app/access.tsx:16-27`, `src/lib/auth/identity.ts:120-127` | 2 | 7 | `find_tenants_for_identity` without tenant (`postgres.ts:786-790`), then the principal read inside the tenant (`postgres.ts:802-853`: joins + `cma.user_timezone()` + `cma.user_permissions()` subquery + earliest role subquery). Memoised per request with React `cache()`: the page, the Shell and a route handler in the same request share it. |
| `previewed()` when the real principal holds `users.manage_all` **and** a preview cookie names a role | `identity.ts:130-141` | +1 | +4 | `listRoles(real)` = `select * from cma.roles()`. |
| `Shell` for a principal with `canPreview` | `src/components/Shell.tsx:62-63` | +1 | +4 | `listRoles(access.real)` again, for the role select. Sequential **after** the page's reads (the Shell renders once the page body returned its JSX). Not memoised: an admin with a preview cookie reads `cma.roles()` twice per request, three times on People. |
| `MessageCenter` (client, in the Shell's top bar on every page) | `src/components/MessageCenter.tsx` MC+69 lines 54-75 (`void tick()` at mount) | +3 | +12 | Fires `GET /api/v1/me/messages` immediately when the page mounts and every 10 s after: identity 2 tx + `listMyMessages` 1 tx with 2 statements (`postgres.ts:1419-1429`). So **a page view costs identity twice** (page render + first poll). |

### 1.2 The table

Roles from the default ladder (`db/01_foundation.sql:379-390`): **A** agent (`workday.own, roster.view, leads.accept, performance.own`), **S** supervisor (A + `workday.team, performance.team, monitoring.live, messages.send`), **M** manager (S + `roster.manage, reports.view, tenant.configure`, …, and `users.manage_all` since migration 0004 (`db/21_teams_skills.sql`), which is `PREVIEW_PERMISSION` in `lib/auth/preview.ts:23`: the one with `canPreview`). Counts exclude the MessageCenter's poll (+3 tx on every page) and the Shell's `listRoles` unless stated (+1 tx for M).

| Page | Data calls (in order; `[ ]` = parallel `Promise.all`) | tx | RT | Depth | Notes |
|---|---|---|---|---|---|
| Welcome `/` (`src/app/page.tsx:36-62`) | identity; `[getWorkday, listStatuses, getTeamHours(S), listAppLinks, getMyRoster, listMyMessages(2 st.), getFollowUpSummary(S), getInboundNow(S, 4 st.), getMyFollowUp]` | A 8 / S 11 / M 12 | A 32 / S 47 / M 51 | 3 (M 4) | 6 (A) to 9 (S) transactions fired at once on a pool of **5**: at least two pool waves. `getFollowUpSummary` and `getInboundNow` are the heavy ones (section 7). |
| My day `/day` (`day/page.tsx:17-28`) | identity; `[getWorkday, listStatuses]` | 4 | 15 | 3 | Two transactions for one card; one composite read would do. |
| My hours `/hours` (`hours/page.tsx:12-23`) | identity; `getHours` | 3 | 11 | 3 | Bounded by the period (`between $1 and $2`), own rows only. |
| Messages `/messages` (`messages/page.tsx:14-18`) | identity; `listMyMessages` (2 st.) | 3 | 12 | 3 | `Inbox` re-fetches the list on the arrival event (`Inbox.tsx:44-50`), not on mount. |
| My schedule `/schedule` (`schedule/page.tsx:18-42`) | identity; `getMyRoster` | 3 | 11 | 3 | |
| My account `/account` (`account/page.tsx:20-24`) | identity; `getMyProfile` | 3 | 11 | 3 | |
| My follow-up `/me/follow-up` (`me/follow-up/page.tsx:18-35`) | identity; `[getMyFollowUp, listSettings]` | 4 | 15 | 3 | |
| **Live board** `/live/board` (`live/board/page.tsx:38-60`) | identity; `[getTeamNow(2 st.), listTeamMembersNow, getRosterToday, listSettings, getInboundNow(4 st.), getFollowUpSummary]` | S 8 / M 9 | S 35 / M 39 | 3 (M 4) | **Repeated in full every 10 s per viewer** by `LiveRefresh` (`router.refresh()`, `LiveRefresh.tsx:12-19`). 6 parallel tx on a pool of 5. README's "One read per page (`team_now`)" (line 1190) is stale: six reads since 0004, 0005, 0008i, 0008o. |
| Team hours `/team/hours` (`team/hours/page.tsx:19-45`) | identity; `listTeamPeople`; `[getTeamHours, listStatuses]` | S 5 / M 6 | 19 / 23 | 4 (M 5) | `listTeamPeople` is awaited alone before the pair (it validates `?person=`); it could join the `Promise.all` and the check move after. |
| People `/team/people` (`team/people/page.tsx:41-48`) | identity; `[listDirectory, listRoles, listTeams, listSkills, listOrganisations, getLinkedAccounts, listInvitations]`; Shell `listRoles` | 10 | 39 | 4 | `cma.roles()` read twice (page + Shell), thrice with a preview cookie. 7 parallel tx on a pool of 5. |
| Roster planner `/roster/planner` (`roster/planner/page.tsx:19-48`) | identity; `listTeams`; `[getRosterWeek(4 st.), listRosterWeeks, listAbsenceTypes]`; Shell | 7 | 30 | 5 | `getRosterWeek` runs 4 statements sequentially inside one transaction (`postgres.ts:1298-1317`): correct (the header's permission check first). |
| Roster print `/roster/planner/print` (`print/page.tsx:19-37`) | identity; `getRosterWeek` | 3 | 14 | 3 | No Shell. |
| Send a message `/messages/send` (`messages/send/page.tsx:21-31`) | identity; `[listTeams, listSkills, listTeamPeople(S), getMessageStats]`; Shell(M) | 6 / 7 | 23 / 27 | 3 (M 4) | |
| Dashboard `/reports/dashboard` (`reports/dashboard/page.tsx:29-56`) | identity; `[getTeamStatusTime, getIntake(3 st.), getCrmRecordsPerDay, getSpeedToLeadRows]` | 6 | 25 | 3 | All four bounded by the period (section 7). |
| Speed to lead (`speed-to-lead/page.tsx:40-61`) | identity; `[getSpeedToLeadSummary, getSpeedToLeadRows]` | 4 | 15 | 3 | `speed_to_lead_of` computed twice for the same range (summary and rows). |
| Intake (`intake/page.tsx:26-43`) | identity; `getIntake` (3 st.) | 3 | 13 | 3 | |
| Inbound (`inbound/page.tsx:56-74`) | identity; `getInboundService` (4 st.: `inbound_service`, connections, `missed_reasons`, settings) | 3 | 14 | 3 | |
| **Calls** (`reports/calls/page.tsx:36-57`) | identity; `[getCallsOverview(6 st.), getCallsTagUse(2 st.)]` | 4 | 21 | 3 | `getCallsOverview` runs **`cma.calls_overview` three times** (`postgres.ts` 1811-1836 and `callsFilterLists` 238-245: once for the page, once grouped by market and once by line for the filter lists), plus `telephony_history_start` and the threshold setting. Each `calls_overview` reads the current **and** the previous period. |
| **Calls per agent** (`calls-per-agent/page.tsx:28-48`) | identity; `[getCallsPerAgent(5 st.), getCallsPerAgentTags(2 st.)]` | 4 | 20 | 3 | `calls_per_person` + **2 × `calls_overview`** (filter lists again) + `calls_per_person_tags`. |
| Forms (`reports/forms/page.tsx:37-62`) | identity; `[getFormsReport(5 st.), getFormsAnswers, getFormsAnswers(narrowed)]` | 4-5 | 19-23 | 3 | `forms_report` twice inside `getFormsReport` (`postgres.ts` R186-188: the grouped rows and the whole-period row). |
| Follow-up report (`reports/follow-up/page.tsx:46-65`) | identity; `[getOpenLeads, getOpenTickets, getOpenTasks, getFollowUpByOwner(S), listSettings]` | 7 | 27 | 3 | `open_leads_of` (the lead history, section 7) computed **twice**: by `open_leads()` and again inside `follow_up_by_owner()` (`db/72_follow_up.sql`). |
| Data quality (`data-quality/page.tsx:27-41`) | identity; `getDataQuality` (2 st.) | 3 | 12 | 3 | Unbounded by design (section 7); a report page. |
| Configuration pages (M) `statuses, teams, absences, exports, app-links, markets, sources, alert-rules` (`configuration/*/page.tsx`, frame `configuration/gate.tsx`) | identity; 1 to 4 reads in `Promise.all`; Shell | 4-7 | 15-27 | 4 | |
| **Sources → connection** `/configuration/sources/[id]` (`sources/[id]/page.tsx:16-46`) | identity; `getSource` (6+ st.); `getMarkets`; `getFormCategories`; `listSettings`; Shell | 7 | 32 | **7** | The deepest page: four reads awaited one after another (lines 27, 42, 44, 46) that do not depend on each other. |
| Invite `/invite/[token]` | `previewInvitation` (withoutTenant) | 1 | 3 | 1 | No identity read; correct. |
| Logout `/logout`, `/logout/done` | identity; `getWorkday` | 3 | 11 | 3 | |
| No access `/no-access` | none | 0 | 0 | 0 | |

API routes the UI polls or calls on an interval (`src/lib/api/respond.ts:53-58`: `forPrincipal` → `getAccess` first):

| Route | tx | RT | Statements after identity |
|---|---|---|---|
| `GET /api/v1/me/messages` (unread poll, every page) | 3 (4 for an admin with a preview cookie) | 12 | `cma.my_messages()` (which contains an `update … set delivered_at`) and `cma.my_unread_count()` |
| `GET /api/v1/team/now` (not used by the UI; the board re-renders instead) | 3 | 12 | `team_now()`, status flags |
| `GET /api/v1/telephony/inbound-now` | 3 | 14 | `inbound_today()`, `missed_callbacks()`, `missed_callbacks_summary()`, connections |
| `GET /api/v1/reports/follow-up/summary` | 3 | 11 | `follow_up_summary()` |
| `GET /api/v1/me` | 2 | 7 | none: identity only. The cheapest authenticated request; a good probe for the lead's identity-cost measurement. |

---

## 2. Per-request memoisation

- **React `cache()` is used once**: `getAccess` (`identity.ts:14`, `:120`). It is the only `cache(` in `web/src` (grep). Shell (`Shell.tsx:62`), `resolve()` (`access.tsx:19`), `forPrincipal` (`respond.ts:55`) and the server action (`actions.ts`) all go through it, so the principal is read once per request. Good.
- **Read twice per request**: `cma.roles()` via `data().listRoles(real)` in `identity.ts:135` (`previewed()`, when a preview cookie is set) and `Shell.tsx:63` (every page, every admin), a third time on People (`team/people/page.tsx:43`). Safe fix, per request only (the argument is the same `access.real` object reference from the memoised `getAccess`, so `cache()` keys on it correctly):

```diff
--- a/web/src/lib/auth/identity.ts
+++ b/web/src/lib/auth/identity.ts
@@
 export const getAccess = cache(async (): Promise<Access | null> => {
@@
-    return applyPreview(real, roleKey, await data().listRoles(real));
+    return applyPreview(real, roleKey, await rolesOf(real));
@@
+/** The tenant's roles, read once per request however many components ask (Shell, preview, People). Per request only. */
+export const rolesOf = cache((me: Principal) => data().listRoles(me));
--- a/web/src/components/Shell.tsx
+++ b/web/src/components/Shell.tsx
@@
-import { getAccess, type Principal } from "@/lib/auth/identity";
+import { getAccess, rolesOf, type Principal } from "@/lib/auth/identity";
@@
-  const roles = access?.kind === "granted" ? await data().listRoles(access.real).catch(() => []) : [];
+  const roles = access?.kind === "granted" ? await rolesOf(access.real).catch(() => []) : [];
```
  (People passes `me`, which equals `access.real` when no preview is active; with a preview it must stay the narrowed principal, so leave it.)
- **Nothing caches across requests** except: the pool and connector (`client.ts:107-163`, `globalThis.__cmaDb`), the JWKS (`iap.ts:25-34`, module-level `Map` of key sets, section 6), the mock state (`mock.ts:689`, `globalThis.__cmaMock`, dev only) and the static `copy` of the default locale in `layout.tsx:17`. `postgres.ts` has no module-level `Map` or object state (grep). The rule in the preamble (per-request memoisation only) holds today.
- **Where `cache()` is safe to add**: `rolesOf` above; `listSettings` (read on Live board, My follow-up, Follow-up report, Sources → connection, alongside other reads in the same request); `listStatuses` + `getWorkday` could become one composite read instead (section 1). Never a module-level cache of settings or roles: they are tenant data and change through the Configuration screens.

---

## 3. Streaming

- **No `loading.tsx`, no `error.tsx`, no `<Suspense>` anywhere** under `web/src` (grep: zero hits).
- `layout.tsx:25-32` renders only `<DesktopOnly>` (pure CSS, server component, `DesktopOnly.tsx:11-25`); **the Shell is rendered by each page**, after the page has awaited every read (`page.tsx:51-62` then `:76`; `live/board/page.tsx:57-60` then `:95`). So the first byte of HTML waits for the slowest read of the page; the top bar, rail and breadcrumbs could have been sent after identity alone.
- Which pages would benefit: Welcome (9 reads, two of them heavy), the Live board, the Calls, Calls per agent, Follow-up and Data quality reports. Pattern (no new file conventions): keep `resolve()` and `<Shell>` in the page, move the reads and the tiles into an async server component rendered inside `<Suspense fallback={<TilesSkeleton/>}>` as the Shell's child. TTFB then equals identity (2 tx) + Shell render; the reads stream in after. Style: the skeleton is white cards with the Border Grey outline (Pulse4all-Style 7.3), no spinner colour outside the palette.
- **Prefer in-page `<Suspense>` over `loading.tsx`**: the Next 16 docs (`02-guides/prefetching.md` lines 19-23, 41-42) say a dynamic route is **not prefetched at all unless it has a `loading.js`**; today every page is dynamic (`connection()` in `access.tsx:18`, `headers()` in `getIdentity`) and none has one, so the rail's 10 to 27 `<Link>`s cause **no prefetch requests**. Adding `loading.tsx` would make every page view prefetch each visible rail link up to its loading boundary (`layout.tsx` has no data, so no database cost, but 10 to 27 extra HTTP requests per page view). In-page `<Suspense>` streams without changing prefetch behaviour.
- `router.refresh()` (Live board, `ClockInCard`, `WorkdayPanel`) re-renders the whole server tree regardless of boundaries; streaming does not reduce the poll's cost, section 4 does.

---

## 4. Polling

| Component | Interval | What it fetches | tx / RT per tick | Re-renders |
|---|---|---|---|---|
| `LiveRefresh.tsx:12-19` (Live board only) | `setInterval` 10 s while visible; paused hidden; once on return (`:25-32`) | `router.refresh()` = the **whole** `/live/board` RSC render: identity + 6 reads (+ Shell `listRoles` for M) | **8-9 tx / 35-39 RT** | Whole page (server components); client state kept |
| `MessageCenter.tsx` MC+69 54-75 (every page) | `setTimeout` chain: 10 s visible, 30 s hidden (`lib/messages.ts:9-10`); first tick at mount; restarts on visibility change and on the inbox's change event | `GET /api/v1/me/messages[?since=]` | **3 tx / 12 RT** (4 tx for an admin with a preview cookie) | The badge only (`setUnread`); no page re-render |
| `InboundLive.tsx`, `FollowUpLive.tsx` | none of their own | server components re-read by the board's refresh | included above | — |
| `LiveBoard.tsx:49-55`, `WorkdayPanel.tsx:27-33` | 1 s local clock via `useSyncExternalStore` | nothing | 0 | the tick text only. Good. |
| `ClockInCard.tsx:28-36`, `WorkdayPanel.tsx:109-124` | on click | `POST /api/v1/me/day/start`, `/me/status`, then `router.refresh()` | 3 tx + a full page render (Welcome: up to 12 tx) | Whole page |
| `Inbox.tsx:44-50` | on `MESSAGES_ARRIVED_EVENT` | `GET /api/v1/me/messages?limit=` | 3 tx | list only |

**Load at 20 concurrent users, all tabs visible (expected from the code; estimated mix: 16 agents, 4 supervisors on the board):**

- Unread poll: 20 × 6/min = **120 requests/min → 360 tx/min, 1 440 RT/min** (6 tx/s, 24 RT/s; the chain adds the request's own latency to the 10 s, so slightly less).
- Live board: 4 × 6/min = 24 renders/min × 8 tx = **192 tx/min, 840 RT/min**, each render also serialising the page (section 8: about 90 KB of copy per render, estimated).
- Total background, before anyone clicks or navigates: **≈ 550 tx/min ≈ 9 tx/s, ≈ 2 300 round trips/min ≈ 38/s**, i.e. about 2 300 `begin`/`set_config`/`commit`/query statements per minute on the single-vCPU `db-custom-1-3840`, next to the ingest sweep and form poll every minute. Each page view adds its row from section 1 plus 3 tx for the first poll.
- Hidden tabs poll every 30 s: exactly the pool's `idleTimeoutMillis` (section 5), so a lone hidden tab makes the pool drop and re-open a TLS connection on alternate polls (expected from `pg-pool/index.js:409-415`; the timer starts when the client is released, the next poll arrives 30 s + latency later).
- Risk in `LiveRefresh`: `setInterval` fires every 10 s whatever the previous refresh took; under load a refresh slower than 10 s overlaps the next (Next cancels the stale one client-side, the server still renders both). `MessageCenter` uses a `setTimeout` chain and cannot overlap. Fix: the same chain in `LiveRefresh` (`timer = setTimeout(tick, REFRESH_MS)` after `router.refresh()` resolves is not observable; use `startTransition` + `useTransition`'s `isPending` to skip a tick while one is pending).

**Database time budget of the two polls (20 ms each, from the brief):** the unread poll's 3 transactions run 6 statements (`find_tenants_for_identity`, the principal read, `begin/set_config/commit` ×, `my_messages`, `my_unread_count`); two-thirds of its transactions are identity. `my_messages` runs an `update` on every tick (`db/42_messaging.sql` extract line 38, `set delivered_at = now() … where … delivered_at is null`: usually 0 rows, index `message_delivery_user_idx (tenant_id, user_id, read_at)` covers the prefix), which is why it is correctly **not** marked STABLE. The Live poll is a page render of 8 transactions, including the lead-history recompute (section 7): statically it cannot meet 20 ms of database time; the lead's EXPLAIN decides by how much.

---

## 5. Pool and connector (`web/src/lib/db/client.ts:137-152`)

Today: `max` = `CMA_DB_POOL_MAX` (5), no `min` (pg-pool default 0, `node_modules/pg-pool/index.js:90`), `idleTimeoutMillis: 30_000`, `connectionTimeoutMillis: 10_000`, no `statement_timeout`, no `idle_in_transaction_session_timeout`, no `keepAlive` in the pg config. `pool.on('error')` logs idle-client errors (`:146`).

- **`min` is supported** by the installed pg-pool 3.14.0: `index.js:90` (`this.options.min = this.options.min || 0`), `:124` (`_isAboveMin`), `:409-415` (the idle reaper skips clients while `_clients.length <= min`). It does **not** open connections eagerly (no eager connect anywhere in `_pulseQueue`/`newClient`): `min: 1` keeps the first connection alive once it exists; a warm-up at pool creation opens it.
- **What a new connection costs on the connector path** (expected from `@google-cloud/cloud-sql-connector/dist/cjs/connector.js:213-240` and `cloud-sql-instance.js:113-263`): the ephemeral certificate and the IAM token are fetched and refreshed **in the background** (hourly or before the cert expires), so a new pooled connection is **not** an IAM token exchange; it is TCP + TLS handshake to the instance's public IP with the cached client cert (`socket.js getSocket`) + the PostgreSQL startup message. Estimated 30 to 100 ms in-region, not the brief's 100-300 ms (the IAM exchange happens once an hour, not per connection). The first request after `open()` also pays `connector.getOptions()` (instance metadata + cert: one or two Google API calls, estimated 200-600 ms) once per process.
- **Keep-alive**: the connector already calls `tlsSocket.setKeepAlive(true, DEFAULT_KEEP_ALIVE_DELAY_MS)` (`socket.js:115`), so `keepAlive` in the pg config changes nothing on Cloud Run (pg would call `setKeepAlive` on the same stream, `pg/lib/connection.js:48-49`). It matters only for the local path (`client.ts:113-123`).
- **Cloud Run CPU throttling** (reference, Martin's side): with the default "CPU only during requests", timers and keepalive probes run only while a request is in flight; `min-instances=1` keeps the instance, not the socket. A connection kept idle overnight by `min: 1` may be found closed in the morning: pg-pool's idle `error` handler removes a dead idle client (`:146`), but a client that dies silently is detected only at the first query (one `DB_UNAVAILABLE`, `translateDbError` `client.ts:64-78`, then a retry succeeds). Mitigation options: accept one failed request per quiet night; or validate a client idle for more than N minutes with `select 1` before use (track `lastUsedAt` on the client in `transaction()`); or `--no-cpu-throttling` (a CONFIG CHANGE with cost, not proposed here).
- **Arithmetic for the budget** (README, Database connection budget, line 153): cma-web is reserved 4 instances × 5 = 20. `min: 1` adds nothing to the ceiling (`max` stays 5); it changes the idle floor from 0 to at most 4 connections across 4 instances (1 in normal running with `min-instances=1`). `min: 2` likewise (floor 8, ceiling 20). The 15 October observation ("no connection of cma-web open while idle") becomes "1 per instance" and the README paragraph must say so.
- **Proposed diff** (connector path; the local path gets `keepAlive: true` and the same timeouts):

```diff
--- a/web/src/lib/db/client.ts
+++ b/web/src/lib/db/client.ts
@@ -24,6 +24,7 @@
  *   CMA_DB_NAME       cma                                     (default cma)
  *   CMA_DB_POOL_MAX   5                                       (per Cloud Run instance)
+ *   CMA_DB_POOL_MIN   1                                       (idle floor per instance; README, Database connection budget)
  *   CMA_DB_IP         PUBLIC | PRIVATE                        (default PUBLIC)
@@ -96,6 +97,7 @@ function dbConfig() {
     database: process.env.CMA_DB_NAME ?? 'cma',
     poolMax: Number(process.env.CMA_DB_POOL_MAX ?? 5),
+    poolMin: Number(process.env.CMA_DB_POOL_MIN ?? 1),
     ipType: process.env.CMA_DB_IP === 'PRIVATE' ? IpAddressTypes.PRIVATE : IpAddressTypes.PUBLIC,
   };
 }
@@ -137,11 +139,27 @@ async function open(): Promise<DbState> {
   const pool = new pg.Pool({
     ...clientOpts,
     user: cfg.user,
     database: cfg.database,
     max: cfg.poolMax,
-    idleTimeoutMillis: 30_000,
+    // pg-pool keeps `min` idle clients out of the idle reaper (it never opens them; the warm-up below
+    // does). The ceiling stays `max`: within the Database connection budget (README) this moves the idle
+    // floor from 0 to 1 per instance, nothing else.
+    min: cfg.poolMin,
+    // Longer than the hidden tab's 30 s unread poll (lib/messages POLL_HIDDEN_MS), which otherwise races
+    // the reaper and re-opens a TLS connection every other poll
+    idleTimeoutMillis: 300_000,
     connectionTimeoutMillis: 10_000,
+    // A statement past 15 s is a defect, not a report: it must not hold one of the five connections
+    // until Cloud Run's request timeout. Sent as a startup parameter by pg (pg/lib/client.js:558-566).
+    statement_timeout: 15_000,
+    idle_in_transaction_session_timeout: 30_000,
     application_name: 'cma-web',
   });
   pool.on('error', (err) => console.error('[cma-db] idle client error', err.message));
+  // Warm-up: the first connection (TLS handshake, startup) opens now, in the background, instead of on
+  // the first visitor's request after a deploy or a scale-out; a failure here is logged, the request
+  // path retries on its own
+  void pool.connect().then((c) => c.release()).catch((err: Error) => console.warn('[cma-db] warm-up failed', err.message));
```
  (`maxLifetimeSeconds` is not needed: an established TLS session does not depend on the cert's later rotation. `allowExitOnIdle` is for scripts whose process should end when the pool is idle, not for the server; the job script `jobs/close-forgotten-workdays.mjs` makes its own pool with `pg` directly.) Errors `57014` (statement timeout) and `25P03` (idle-in-transaction) are five-character SQLSTATEs → `DB_ERROR` 500 today (`client.ts:72-77`); add `57014` to a "took too long" mapping if a distinct message is wanted.

---

## 6. The IAP key set

Confirmed cached: `iap.ts:25-34` keeps one `createRemoteJWKSet` per URL in a module-level `Map` with `cooldownDuration: 30_000, cacheMaxAge: 600_000`. jose refetches at most once per 10 minutes per instance (one HTTPS GET to `www.gstatic.com`, estimated 30-80 ms) and, on an unknown `kid`, at most once per 30 s. A fresh instance pays one fetch on its first IAP request. **Not a suspect** for steady-state TTFB; the proxy's work per request is one ES256 verify (sub-millisecond).

---

## 7. Database functions proportional to history

Function bodies extracted to `/var/tmp/5.6/fn/*.sql` from the latest defining migration. Volatility: every read function is `STABLE` except `cma.my_messages` (`language plpgsql`, no marker: it updates `delivered_at`, so VOLATILE is correct) and `find_tenants_for_identity` (`sql stable security definer`). No STABLE function contains a write (checked the extracts for `update`/`insert`: only `my_messages` and the `mark_messages_read` that follows it).

| Function (page) | Bound | Evidence | Verdict |
|---|---|---|---|
| `follow_up_summary` → `follow_up_summary_of` → `open_leads_of` (Welcome S/M, **Live board every 10 s**, Follow-up report twice) | **None.** `open_leads_of` selects from `speed_to_lead_of(p_tenant_id, null, null)` and `lead_deals_of(p_tenant_id, null, null)`: every lead deal since `intake.start_date`, each with a `lateral lead_calls_of(...)` over `crm_call`/`call_link`/`telephony_call` to find its first call, then filters `status = 'not_called_open'` | `db/72_follow_up.sql` (`open_leads_of` lines 10, 20, 25 of the extract), `db/40_lead_metrics.sql` (`speed_to_lead_of` lines 10-20, `lead_deals_of` 41-47) | **Grows with the lead history; recomputed on every board tick and every supervisor's Welcome.** A tenant setting such as `follow_up.lead_lookback_days` (configuration, not code) applied in `open_leads_of`, or a derived "open lead" set maintained by the ingest, is the structural fix; a materialised count refreshed by the sweep would also take it off the request path (both are database changes: new pair `db/76`/`77`, catalog.json). |
| `open_tickets_of` (same callers) | Scans every ticket ever mirrored: `crm_record … record_type = 'ticket' and source_deleted_at is null`, SLA state computed with `business_seconds_of()` per row | `72_follow_up.sql` extract lines 13-25; indexes on `crm_record`: `(tenant_id, source_created_at)`, `(tenant_id, connection_id, contact_source_id)` only (`db/30…:227-228`) | Grows with ticket history; no index on `record_type`. A partial index `(tenant_id, record_type) where source_deleted_at is null`, or the closed-stage filter inside the scan, bounds it. |
| `open_tasks_of` | Every non-deleted `crm_task`, due state computed per row; done filter after the join | extract lines 20-26; `crm_task_due_idx (tenant_id, due_at)` (`:135`) | Grows with task history; a partial index on not-done tasks would bound it. |
| `inbound_today_of`, `missed_callbacks_of`, `missed_callbacks_summary_of` (Welcome S, Live board) | Bounded by time: `inbound_calls_of(tenant, now() - waiting_max)` / `now() - lookback days`; the per-caller lateral uses `counterpart_hash` | `60_inbound_service.sql` extract lines 22-36, 25-44; indexes `telephony_call_started_idx (tenant_id, started_at)`, `telephony_call_hash_idx` (`db/…:93-94`) | Bounded (today / the lookback). `missed_callbacks_of` is called twice per `getInboundNow` (directly and inside `missed_callbacks_summary_of`). |
| `team_now` (board) | Today only: `workday_summary` at `business_date = today`, lateral over `time_interval` of that day | `19_team_now.sql` extract lines 38-55 | Bounded. |
| `my_messages`, `my_unread_count` | Per user via `message_delivery_user_idx (tenant_id, user_id, read_at)`; `my_messages` orders by `message.created_at desc limit n` over all of the user's deliveries (read and unread), joined to `message` | `42_messaging.sql` extract lines 30-46, 58-61 | Bounded per user; grows slowly (one delivery per broadcast). Fine. |
| `team_hours`, `team_status_time` (Welcome S: 7 days; Team hours; Dashboard) | `between p_from and p_to`, at most 92 days (`CMA04`) | `09_corrections.sql` extract 22-32; `15_team_status_time.sql` 26-40 | Bounded. |
| `calls_overview`, `calls_per_person`, `calls_tag_use`, `calls_per_person_tags` → `calls_of` | Bounded by `started_at` range (plus the like-for-like previous period); per call an `array_agg` of tags (lateral) | `62_calls_overview.sql` `calls_of` extract lines 34-63, 103 | Bounded, but the Calls page runs `calls_overview` **three times** and Calls per agent **two extra times** for the filter lists (section 1). Proposal: a light `cma.calls_filter_values(from, to)` returning distinct markets and lines (one scan, no aggregates), called once per request. |
| `speed_to_lead_rows/summary`, `intake_per_day` | `report_range(from, to)` → `lead_deals_of(from, to)` on `crm_record_created_idx` | `40_lead_metrics.sql` extracts | Bounded. Speed to lead computes `speed_to_lead_of` twice per page (summary + rows). |
| `crm_records_per_day` | `source_created_at` range, ≤ 92 days | `30_ingest_crm_records.sql` extract 18-33 | Bounded. |
| `data_quality_of` (Data quality report) | **Unbounded by design**: `lead_deals_of(null, null)` twice, full `crm_contact` scans, counts since `v_start` | `74_forms_reporting.sql` extract 17-57 | A report page (p95 1.5 s target); grows with history; acceptable now, worth an EXPLAIN on the largest tenant. |
| `sources()` (Configuration → Sources) | Four correlated subqueries over `ingest_event` per connection: last 24 h count, `status in ('received','failed')` count, `needs_review` count, `max(recorded_at)`; indexes on `ingest_event` are `(tenant_id, connection_id, next_attempt_at)` and `(tenant_id, connection_id, object_type, object_id)` only | `52_sources_configuration.sql` extract 35-38; `db/…:193-195` | **Grows with every webhook ever received** (the sweep runs every minute). Admin page only. An index `(tenant_id, connection_id, recorded_at)` and a partial one on the open statuses, or a retention rule for `ingest_event` (none found in README), bound it. |
| `roster_today`, `my_roster`, `roster_*`, `my_profile`, `team_people`, `team_members_now`, `roles`, `tenant_settings`, `app_links`, `telephony_history_start`, `forms_*` | Today / the week / catalogs; `forms_report` twice per page | extracts | Bounded. |
| `find_tenants_for_identity`, the principal read | One row by `(system, external_id)`; `user_permissions()` is `sql stable` | `52…`, `05_time_model.sql` | Bounded; the cost is the two transactions, not the SQL. |

`jsonb_agg` of large sets: `my_follow_up()` (one jsonb per person, bounded), `connection_task_catalogs`/`connection_missed_reasons` (per connection, configuration), `roster_people` arrays. None on a polled path.

---

## 8. Client side

- **39 `"use client"` modules** (38 components + `hooks/useKeyboardShortcuts.ts`; list in Commands run). Candidates to become server components or shrink: `HeaderHint` (hover/focus hint; CSS `:focus-within`/`:hover` or `<details>` would do), `PrintButton` (a form with `window.print()` needs client; tiny), `TeamHoursView` and `CallsPerAgentTable` (tables whose rows could render on the server with only the filter/sort controls as client islands). The interactive filters (`CallsFilters`, `FormsFilters`, `DashboardFilter`, `MarketFilter`, `PeriodBar`, `WeekBar`), dialogs, planner, directory and composer rightly stay client.
- **Hydration payload: the whole `copy` dictionary.** `copy={copy}` is passed to client components in 40 places under `src/app` (136 across app + components, grep); on one line to at least 16 client components (AbsenceConfig, AlertRulesConfig, AppLinksConfig, CallsFilters, CallsPerAgentTable, ClockInCard, DashboardFilter, ExportsConfig, FollowUpFilters, FormCategories, InvitationsSection, MarketFilter, MarketsConfig, SourceConfig, StatusConfig, TeamsConfig) and across lines to `LiveBoard` (`live/board/page.tsx:118-123`), `TeamHoursView` (`team/hours/page.tsx:113-124`), `RosterPlanner`, `TeamDirectory`. **Observed locally**: `JSON.stringify(t("en"))` = **89 369 bytes, 1 728 leaf keys** (`hints` alone 15 362; `/var/tmp/5.6/copysize.mjs`). React Flight writes a repeated object reference once per response (expected), so each page that hands `copy` to any client component carries about **90 KB** of copy in its RSC payload (inline `<script>` in the HTML, and again in every `router.refresh()` of the Live board: ≈ 90 KB × 6/min ≈ 540 KB/min per board viewer, estimated), plus the CPU to serialise it per render on the 1-vCPU instance. Fix: pass slices (`copy.live`, `copy.shell`, the component's `hints`), as `MessageCenter` (`copy.messages`) and `Inbox` already do. Low risk, mechanical, typed by `Copy["live"]`.
- **Fonts**: one self-hosted variable font `src/fonts/Montserrat-VF.ttf`, **744 936 bytes**, `display: swap` (`layout.tsx:10-15`), served hashed and immutable from `/_next/static/media`. Good (no third-party request); a Latin subset in WOFF2 would be roughly a quarter of that (estimated) for the first visit only. Low.
- **Images**: `public/brand/logo-blue.png` 28 KB (`priority`), `logo-white-small.png` 4 KB; `images: { unoptimized: true }` (`next.config.ts`). Fine.
- **`next/link` prefetch**: default (`prefetch` not set anywhere; `NavGroup.tsx` renders no `<Link>`, the Shell does, `Shell.tsx:128,161`). Every page is dynamic and has no `loading.tsx`, so **no prefetch happens** (docs, section 3): each navigation is one RSC request. Neutral for the database; no instant transitions either.
- **Cache headers**: `/_next/static` immutable by Next; `cache-control: no-store` on every API answer (`respond.ts:18`) and on the mock redirect/401s. The LB pass-through is Martin's to verify (not checkable here).
- **Route segment config**: `export const dynamic = "force-dynamic"` on about 50 API routes (redundant with `headers()` but harmless); pages use `await connection()` (`access.tsx:18`, `logout/done/page.tsx:12`, `invite/[token]/page.tsx:26`, `no-access/page.tsx:14`). No `revalidate`, no `export const runtime` (Node runtime everywhere; `proxy.ts` header comment says Node runtime).
- **`output: "standalone"`**, `poweredByHeader: false`, security headers for every path (`next.config.ts`). No `compress` setting (Next's default gzip on; the LB may re-compress).

---

## 9. Cloud Run and database contention (reference; Martin measures)

- `cloudbuild.yaml:57-69`: the deploy passes `--port=8080`, `--max-instances=${_MAX_INSTANCES}` (4) and `--set-env-vars`; **no `--cpu`, `--memory`, `--concurrency`, `--cpu-boost`, `--min-instances`, `--execution-environment`, `--no-cpu-throttling`**. `min-instances=1` was set by hand on 12 October 2026 (README Decision log line 1859); `gcloud run deploy` keeps unspecified settings, so the build does not undo it, but the file does not carry it (a re-created service would start at 0). Defaults then (Cloud Run documentation, from memory, not verified here): 1 vCPU, 512 MiB, concurrency 80, CPU throttled outside requests, no startup boost.
- What that implies for Next.js 16 SSR under 20 users: one instance takes all 20 (concurrency 80 is reached long after CPU is); every page render is CPU-bound in Node (RSC serialisation incl. the 90 KB copy, React rendering) on **one vCPU shared with the poll traffic** (≈ 2 requests/s background + renders). 512 MiB: a Next standalone server with React 19 typically sits at 150-300 MB RSS (estimated); fine, but a memory spike from a large report render has little headroom. Autoscaling on CPU (60 %) would add a second instance under load, which doubles the pool count (budget: still within 20) and halves per-instance pool warmth. `--cpu-boost` helps only cold starts (already mitigated by `min-instances=1`).
- The database: `db-custom-1-3840` (1 vCPU, README line 1757) serves the ingest sweep and the form poll every minute (ingest pools up to 25 + 15 in the budget), NocoDB, and the web's ≈ 9 tx/s of polls (section 4). `follow_up_summary` every 10 s per board viewer is the one query that scales with history on that shared vCPU.

---

## 10. A regression guard: `verify:round-trips`

**Goal.** Fail the pure-ish verifier suite when a page's or route's transaction count grows past a committed budget, without touching production behaviour. Transactions can only be counted with a running app against a database, so this verifier sits with `verify:api` (Martin's terminal, api data mode with the local PostgreSQL, mock auth), not with the pure ones.

**Counter design.** One per-request record `{ tx, rt, dbMs }` in `src/lib/db/client.ts`, correlated to the request by the **OpenTelemetry trace id of Next's own request span** (`node_modules/next/dist/server/base-server.js:491-547`: `BaseServer.handleRequest` wraps `handleRequestImpl`, sets `http.status_code` and `next.route` when the response is done). This is the only context that covers a whole request in both pages and route handlers: a Node `AsyncLocalStorage.run()` started inside `resolve()` ends when `resolve()` returns, before the page's own reads (the page's continuation after `await resolve()` is outside the store), and React `cache()`'s scope outside rendering (route handlers) is not documented (grep of the Next docs found nothing). With a tracer provider registered in `instrumentation.ts` (section 11) `trace.getActiveSpan()` returns a span of the current request anywhere in the render; without one it returns `undefined` and the counter is a no-op.

**Exposure, only when `CMA_DB_TRACE=1`** (never set in `cloudbuild.yaml`): route handlers add a header `x-cma-db: tx=3;rt=12;ms=4.8` in `ok()`/`fail()` (`respond.ts:27-33`; the data call has completed before `ok()` is built), pages render `<meta name="cma-db" content="tx=…;rt=…;ms=…">` from the Shell after its own awaits (all database work of today's pages completes before the Shell's JSX is produced; once tiles stream behind `<Suspense>`, the verifier reads the log line of section 11 instead, which carries the same record). No parameter values, no SQL text, no identity in either.

```diff
--- a/web/src/lib/db/client.ts
+++ b/web/src/lib/db/client.ts
@@
 import 'server-only';
 import pg from 'pg';
+import { trace } from '@opentelemetry/api';
 import { AuthTypes, Connector, IpAddressTypes } from '@google-cloud/cloud-sql-connector';
@@
+// ---- Per-request database accounting (section 5.6 of the October 2026 audit) ------------------------
+// Correlated by the trace id of Next's request span (instrumentation.ts registers the provider). Counts and
+// milliseconds only: never SQL text, parameters or identities. Read by the request log line (instrumentation)
+// and, with CMA_DB_TRACE=1 (local only), by the x-cma-db header and the cma-db meta for verify/round-trips.mjs.
+export interface DbStats { tx: number; rt: number; dbMs: number }
+const stats = new Map<string, DbStats>();
+export const DB_TRACE = process.env.CMA_DB_TRACE === '1';
+
+function currentTraceId(): string | undefined {
+  return trace.getActiveSpan()?.spanContext().traceId;
+}
+/** The current request's record, created on first use; undefined outside a traced request */
+export function dbStats(): DbStats | undefined {
+  const id = currentTraceId();
+  if (!id) return undefined;
+  let s = stats.get(id);
+  if (!s) {
+    if (stats.size > 10_000) stats.clear(); // a safety valve, never expected: takeDbStats() removes each entry
+    s = { tx: 0, rt: 0, dbMs: 0 };
+    stats.set(id, s);
+  }
+  return s;
+}
+/** Removes and returns the record of a finished request (called from the span processor) */
+export function takeDbStats(traceId: string): DbStats | undefined {
+  const s = stats.get(traceId);
+  stats.delete(traceId);
+  return s;
+}
+export function formatDbStats(s: DbStats | undefined): string {
+  return s ? `tx=${s.tx};rt=${s.rt};ms=${s.dbMs.toFixed(1)}` : 'tx=0;rt=0;ms=0';
+}
+
@@ async function transaction<T>(
   const { pool } = await db();
+  const s = dbStats();
+  const t0 = performance.now();
+  if (s) s.tx += 1;
   const client = await pool.connect().catch((err) => { throw translateDbError(err); });
+  const q: Querier = {
+    query: (text, values) => { if (s) s.rt += 1; return client.query(text, values); },
+  };
   try {
-    await client.query('begin');
-    await setContext(client);
-    const result = await fn(client);
-    await client.query('commit');
+    await q.query('begin');
+    await setContext(q);
+    const result = await fn(q);
+    await q.query('commit');
     return result;
   } catch (err) {
     await client.query('rollback').catch(() => undefined);
     throw translateDbError(err);
   } finally {
+    if (s) s.dbMs += performance.now() - t0;
     client.release();
   }
 }
--- a/web/src/lib/api/respond.ts
+++ b/web/src/lib/api/respond.ts
@@
-import { CmaDbError } from "@/lib/db/client";
+import { CmaDbError, DB_TRACE, dbStats, formatDbStats } from "@/lib/db/client";
@@
-const NO_STORE = { "cache-control": "no-store" } as const;
+const NO_STORE = { "cache-control": "no-store" } as const;
+/** no-store, plus the request's database count when CMA_DB_TRACE=1 (local verification only) */
+function responseHeaders(): Record<string, string> {
+  return DB_TRACE ? { ...NO_STORE, "x-cma-db": formatDbStats(dbStats()) } : { ...NO_STORE };
+}
@@
-  return NextResponse.json({ data }, { status, headers: NO_STORE });
+  return NextResponse.json({ data }, { status, headers: responseHeaders() });
@@
-  return NextResponse.json({ error: { code, message } }, { status, headers: NO_STORE });
+  return NextResponse.json({ error: { code, message } }, { status, headers: responseHeaders() });
--- a/web/src/components/Shell.tsx
+++ b/web/src/components/Shell.tsx
@@
+import { DB_TRACE, dbStats, formatDbStats } from "@/lib/db/client";
@@ const ownRoleName = ...
+  // Local verification only (CMA_DB_TRACE=1): the request's database count for verify/round-trips.mjs
+  const dbTrace = DB_TRACE ? formatDbStats(dbStats()) : null;
@@
     <div
       data-rail=…
     >
+      {dbTrace ? <meta name="cma-db" content={dbTrace} /> : null}
```
(`transaction()` passes its wrapper `q` to `setContext` and `fn`, which already take a `Querier`; `one()` and the callers are unchanged. `Shell.tsx` importing `lib/db/client` is server-only, as `respond.ts` already does.)

**The verifier** `web/verify/round-trips.mjs` (`npm run verify:round-trips`, env `BASE`, requires `CMA_AUTH_MODE=mock CMA_DATA_MODE=api CMA_DB_TRACE=1` on the server): for each row of a committed budget `web/verify/round-trips.json` — `{ "path": "/", "subject": "supervisor", "tx": 11, "rt": 47 }` for every page and polled route, per mock subject (`agent-one`, `supervisor`, `manager`, `analyst`; `db/06_seed_dev_time_model.sql`) — it fetches the path with `x-cma-mock-subject` (as `verify/api.mjs:91-94` does), reads `x-cma-db` (routes) or `<meta name="cma-db">` (pages), and fails when `tx` or `rt` exceeds the budget, when a page under `src/app/**/page.tsx` or a polled route has no budget row (so a new page cannot ship uncounted; it lists `src/app` itself), or when the header/meta is missing (trace off). `--provoke` lowers every budget by one, so every check must fail. Lowering a budget is the normal change when a fix lands; raising one is a reviewed decision named in the PR. Pages whose reads depend on data volume (none: counts are per request, not per row) need no fixture beyond the dev seed.

---

## 11. The request timing log line

**Requirement.** One structured JSON line per request: route pattern (never the path with its parameters), method, status, total ms (to the end of the response, streaming included), database ms, transaction and round-trip counts, RSC or document; no personal data (no path parameters, no headers, no identity, no query string).

**Where it can be emitted in Next.js 16 App Router** (from `node_modules/next/dist/docs/01-app`):
- `proxy.ts`: sees the start, not the end of the render; `event.waitUntil()` (`proxy.md:163-198`) only keeps the proxy alive for its own promises. A response header set there cannot carry render time. **No.**
- `instrumentation.ts` `register()`: runs once per server start; `onRequestError` fires only on errors (`instrumentation.md`, "Exports"). Alone, **no**; as the place to register a tracer provider, **yes**.
- `after()` from `next/server` (`after.md`): runs after the response is finished, in pages, layouts, route handlers and the proxy; inside Server Components it may not call `headers()`/`cookies()` (`after.md`, "In Server Components"), so the route and start time must be captured before. It would have to be called from every page (`resolve()` is the one shared place) and every route (`forPrincipal`), and it does not see the route pattern or the status. **Possible, second choice** (no new dependency).
- `logging.incomingRequests` in `next.config.ts` (`logging.md:61-79`): development only. **No.**
- **Next's OpenTelemetry spans** (`open-telemetry.md:259-296`; `base-server.js:491-547`): the `BaseServer.handleRequest` span ends when `handleRequestImpl` settles, i.e. when the response is complete, and carries `http.method`, `http.status_code`, `next.route` (the route pattern, e.g. `/configuration/sources/[id]`), `next.rsc`. A `SpanProcessor.onEnd` on that span type has the route pattern, the status and the duration from Next itself, for pages and route handlers alike, with no code in pages. It also gives the trace id that section 10's counter uses. **First choice.** Cost: `@opentelemetry/api` + `@opentelemetry/sdk-trace-node` (which brings `sdk-trace-base`, `core`, `resources`, `context-async-hooks`, `semantic-conventions`), loaded only under `process.env.NEXT_RUNTIME === 'nodejs'` as the docs require (`open-telemetry.md:84-95`). Next resolves the app's `@opentelemetry/api` when installed (`server/lib/trace/tracer.js:47-58`), so the provider registered here is the one Next's tracer uses. No exporter, no network: the processor writes to stdout, which Cloud Run's log agent parses as structured JSON (`severity`, `message` and the fields below become `jsonPayload`).

```diff
--- /dev/null
+++ b/web/src/instrumentation.ts
@@
+/**
+ * Observability hooks (Next.js instrumentation file). Node runtime only: registers the tracer provider
+ * whose span processor writes one JSON line per request (route pattern, status, total ms, database ms,
+ * transactions, round trips; no path parameters, headers, query string or identity).
+ */
+export async function register() {
+  if (process.env.NEXT_RUNTIME === "nodejs") {
+    await import("./instrumentation.node");
+  }
+}
--- /dev/null
+++ b/web/src/instrumentation.node.ts
@@
+import { NodeTracerProvider } from "@opentelemetry/sdk-trace-node";
+import type { ReadableSpan, SpanProcessor } from "@opentelemetry/sdk-trace-base";
+import { takeDbStats } from "@/lib/db/client";
+
+/** Next's request span (base-server.js handleRequest); its end is the end of the response */
+const REQUEST_SPAN = "BaseServer.handleRequest";
+
+const requestLog: SpanProcessor = {
+  onStart() {},
+  onEnd(span: ReadableSpan) {
+    if (span.attributes["next.span_type"] !== REQUEST_SPAN) return;
+    const route = typeof span.attributes["next.route"] === "string" ? span.attributes["next.route"] : null;
+    // Static assets and unknown paths have no route pattern; they are not timed here (no path is ever logged)
+    if (!route || route.startsWith("/_next")) return;
+    const db = takeDbStats(span.spanContext().traceId);
+    const [s, ns] = span.duration;
+    const totalMs = s * 1000 + ns / 1e6;
+    const status = Number(span.attributes["http.status_code"] ?? 0);
+    console.log(JSON.stringify({
+      severity: status >= 500 ? "ERROR" : totalMs > 800 ? "WARNING" : "INFO",
+      message: "request",
+      route,
+      method: span.attributes["http.method"] ?? null,
+      status,
+      rsc: span.attributes["next.rsc"] === true,
+      totalMs: Math.round(totalMs * 10) / 10,
+      dbMs: db ? Math.round(db.dbMs * 10) / 10 : 0,
+      tx: db?.tx ?? 0,
+      rt: db?.rt ?? 0,
+    }));
+  },
+  forceFlush: async () => {},
+  shutdown: async () => {},
+};
+
+// No exporter and no sampling change: the processor above is the only consumer
+const provider = new NodeTracerProvider({ spanProcessors: [requestLog] });
+provider.register();
```
Notes for the lead: (a) `next.route` is set on the span only when Next resolved a route; the 401 the proxy answers has none and stays with the proxy's own `console.warn` (`proxy.ts:58`); (b) `tx`/`rt` need section 10's counter; without it the line still has route, status and total ms; (c) the span's duration ends when `handleRequestImpl` settles, which for a streamed page is when the last chunk is written, so it is "total server time", not TTFB; the lead's `autocannon`/`curl -w` measure TTFB from outside, and the two together separate render time from stream time; (d) `serverExternalPackages` may need the OTel SDK packages added if the bundler complains (`next.config.ts`); (e) the dependency additions and the new file are to be named in the PR; no `cloudbuild.yaml` change is needed (stdout is already collected). **Fallback without dependencies**: `proxy.ts` sets `x-cma-request-start` (epoch ms) and `x-cma-route` (the pathname with uuid, date and token segments replaced by `:id`/`:date`/`:token`) on the forwarded request (it already strips and sets request headers, `proxy.ts:41-45, 84-89`); `resolve()` and `forPrincipal()` read them via `headers()` and call `after(() => console.log(JSON.stringify({ route, status?, totalMs: Date.now() - start, … })))`; the status is unknown in pages, the route pattern is approximate, and the database counts need the `AsyncLocalStorage` run around `handler()` in `forPrincipal` (works) and React `cache()` in pages (works during render). Less exact; no new packages.

---

## Findings

### 5.6-01: The Live board's 10-second poll is a full page render of 8 to 9 transactions per viewer
- Severity: Medium (High if the lead measures the board's render above 1.6 s p95 or its database time far above the 20 ms poll budget)   Confidence: High   Effort: M
- Component: `web/src/components/LiveRefresh.tsx:12-19`, `web/src/app/live/board/page.tsx:38-60`, `web/src/lib/data/postgres.ts` (`getTeamNow` 1042-1056, `getInboundNow` 1785-1810, `getFollowUpSummary` 1962-1971)
- Evidence: `router.refresh()` every 10 s re-runs the page: identity (2 tx, 7 RT) + `Promise.all` of six reads (`getTeamNow` 2 statements, `listTeamMembersNow`, `getRosterToday`, `listSettings`, `getInboundNow` 4 statements, `getFollowUpSummary`) = 8 tx / 35 RT, 9 tx / 39 RT for an admin (Shell `listRoles`), six transactions competing for a pool of five, every render serialising the page's RSC payload including the ~90 KB `copy` object (section 8). Four viewers = 192 tx/min and 840 round trips/min from this screen alone (expected; section 4).
- Impact (in this system's context): the single-vCPU database and the 1-vCPU Cloud Run instance spend most of their steady-state work on re-reading six things that rarely change, and the heaviest of them (5.6-02) grows with history. The brief's target of 20 ms database time per poll cannot be met by a design that re-renders the page.
- Recommendation: (1) one composite read `getLiveBoard(me)` in `CmaData` (mock + postgres) running today's six statements in **one** transaction (9 RT instead of 35; one pool slot instead of six), also used by a new `GET /api/v1/live/board` so other tools get the same answer; (2) the poll fetches that route and updates the tiles and rows in `LiveBoard` (a client island) instead of `router.refresh()`, so identity + 1 tx per tick (3 tx, 12 RT) and no RSC payload; (3) replace `setInterval` with a `setTimeout` chain so ticks never overlap. README: the Live board paragraph's "One read per page (`team_now`)" and "re-reads itself with `router.refresh()` every 10 seconds" need the new wording; "the fallback until the realtime service" stays.
- README check: settled that polling every 10 s is the interim until the realtime service (line 1190, Roadmap step 2); **the cost per tick is new information**, the interval itself is not re-argued. README's "one read per page" is stale (new since 0004/0005/0008i/0008o).
- Disproof attempt: checked whether `router.refresh()` could render less (no Suspense boundaries, no `loading.tsx`: it renders the whole tree) and whether the board could hit `/api/v1/team/now` instead (it does not; `LiveBoard.tsx` has no fetch). Checked that `getAccess` is memoised within the refresh (it is) so identity is paid once per tick, not per read. Stands.

### 5.6-02: `cma.follow_up_summary` re-derives the whole lead history on every call, and it is called every 10 seconds per board viewer and on every supervisor's Welcome
- Severity: Medium (High if EXPLAIN on the production-sized tenant shows it dominating the board's database time; a daily-path figure)   Confidence: High   Effort: M (database change, new pair `db/76`/`77`)
- Component: `db/72_follow_up.sql` (`follow_up_summary_of`, `open_leads_of`), `db/40_lead_metrics.sql` (`speed_to_lead_of`, `lead_deals_of`, `lead_calls_of`); callers `postgres.ts:1962-1971`, `page.tsx:60`, `live/board/page.tsx:60`
- Evidence: `open_leads_of` selects from `speed_to_lead_of(p_tenant_id, null, null)` and joins `lead_deals_of(p_tenant_id, null, null)` (extract lines 10, 20), i.e. every lead deal since `intake.start_date` with a lateral `lead_calls_of` per deal (`crm_call` ∪ `telephony_call` through `call_link`, `crm_association` exists-check), then keeps `status = 'not_called_open'`. The same set is computed again by `follow_up_by_owner_of` on the Follow-up report (twice per page) and `open_tickets_of`/`open_tasks_of` scan every mirrored ticket and task (no index on `record_type`; `crm_record` indexes at `db/30…:227-228`).
- Impact: a count that should be O(open leads) is O(all leads ever) × their calls, on the most frequently executed path of the app (section 4: 24 board renders/min for four viewers) and on the Welcome of every supervisor and manager. It grows for ever with the mirror.
- Recommendation: a configurable bound rather than code: a tenant setting `follow_up.lead_lookback_days` (default e.g. 60, `cma.setting` catalog) applied as `p_from` in `open_leads_of` (an uncalled lead older than that is not a live follow-up), and a partial index `crm_record (tenant_id, record_type) where source_deleted_at is null` plus one on not-done tasks, as `db/76_follow_up_bounds.sql` + `db/77_verify_follow_up_bounds.sql` with `catalog.json` updated. Alternatively the sweep (every minute, already running) maintains a small `cma.follow_up_counts` table the board reads (one row per tenant). Both are Martin's to run; the first is the smaller increment. The lead's EXPLAIN (`select * from cma.follow_up_summary_of(<tenant>)`) tells which.
- README check: new (follow-up 0008o paragraph lines 987-990 describes the counts, not a bound; no Open decision on lookback).
- Disproof attempt: looked for a date bound anywhere in the chain (`lead_deals_of` has `p_from`/`p_to` parameters, but `open_leads_of` passes `null, null`; `s.start_date` bounds only from intake start). Looked for a materialised table of open leads (none; `with … materialized` in `follow_up_summary_of` is a CTE hint within one call). Stands.

### 5.6-03: Identity costs two transactions (7 round trips) per request and is paid twice per page view
- Severity: Medium   Confidence: High   Effort: S (one transaction) / M (skip the mount poll)
- Component: `web/src/lib/data/postgres.ts:784-853` (`findPrincipal`), `web/src/lib/auth/identity.ts:120-127`, `web/src/components/MessageCenter.tsx` MC+69 lines 54-66, `web/src/lib/api/respond.ts:53-58`
- Evidence: `findPrincipal` runs `withoutTenant` (tenant lookup) and then a separate `withTenant` (principal): two pool checkouts, two `begin`/`commit`. `MessageCenter` mounts inside the Shell on every page and calls `GET /api/v1/me/messages` at once (`void tick()`), which runs `getAccess` again in its own request: a page view = 4 identity transactions + the page's reads + 1 messages transaction. On the unread poll, identity is 2 of its 3 transactions (section 4), so the 20 ms budget is spent mostly on who the caller is.
- Impact: the fixed cost of every request (page, API, poll) is 7 database round trips before any data is read; at 20 users polling, ≈ 240 identity transactions per minute carry no information that changed.
- Recommendation: (1) one transaction for both steps: inside `withoutTenant`, after the lookup, `select set_config('app.tenant_id', $1, true), set_config('app.user_id', '', true), set_config('app.actor_label', '', true)` and the principal query in the same transaction (`set_config(…, true)` is transaction-local already; RLS sees the tenant from that statement on; the SECURITY DEFINER lookup is unchanged). Saves one checkout, one `begin`, one `commit` per request (2 tx → 1, 7 RT → 5):
```diff
--- a/web/src/lib/data/postgres.ts
+++ b/web/src/lib/data/postgres.ts
@@ async findPrincipal(identity: Identity): Promise<Principal | null> {
-    const tenants = await withoutTenant((q) =>
-      q.query<{ tenant_id: string }>(
-        "select tenant_id from cma.find_tenants_for_identity($1, $2)",
-        [identity.provider, identity.subject],
-      ),
-    );
-    const match = tenants.rows[0];
-    if (!match) return null;
-    if (tenants.rows.length > 1) {
-      console.warn(`[cma-data] identity (${identity.provider}) matches ${tenants.rows.length} tenants; no tenant picker yet`);
-      return null;
-    }
-    const tenantId = match.tenant_id;
-
-    // 2. Inside that tenant, as cma_app under row-level security: the app_user check
-    return withTenant({ tenantId }, async (q) => {
+    // One transaction: the SECURITY DEFINER lookup without a tenant, then the tenant context for the rest
+    // of it (set_config(…, true) is transaction-local, as withTenant sets it), then the app_user check under
+    // row-level security. The same two statements as before, one connection checkout and one begin/commit.
+    return withoutTenant(async (q) => {
+      const tenants = await q.query<{ tenant_id: string }>(
+        "select tenant_id from cma.find_tenants_for_identity($1, $2)",
+        [identity.provider, identity.subject],
+      );
+      const match = tenants.rows[0];
+      if (!match) return null;
+      if (tenants.rows.length > 1) {
+        console.warn(`[cma-data] identity (${identity.provider}) matches ${tenants.rows.length} tenants; no tenant picker yet`);
+        return null;
+      }
+      const tenantId = match.tenant_id;
+      await q.query(
+        `select set_config('app.tenant_id', $1, true), set_config('app.user_id', '', true), set_config('app.actor_label', '', true)`,
+        [tenantId],
+      );
```
  (the rest of the function body is unchanged; `verify:api`'s identity and spoofing checks prove it). (2) The Shell can hand `MessageCenter` an `initialUnread` when the page already read messages (Welcome does) and the first poll waits one interval; or the first poll runs only when the page did not carry the count. README "Login (`findPrincipal`)" describes two steps, not two transactions: wording only.
- README check: settled as to the two-step lookup (line 1060) and "one transaction per call" (line 1058); merging keeps both. New as to cost.
- Disproof attempt: checked that `set_config` mid-transaction is what `withTenant` does anyway (it is: `client.ts:217-224`, first statement after `begin`) and that nothing in the lookup depends on a committed state between the steps (the comment at `postgres.ts:836` "deactivated between the two steps" becomes moot). Checked `getAccess` memoisation across the page and its first poll (separate HTTP requests: separate `cache()` scopes by design). Stands.

### 5.6-04: The pool keeps no warm connection and its idle timeout equals the hidden tab's poll interval
- Severity: Medium   Confidence: High   Effort: S
- Component: `web/src/lib/db/client.ts:137-152` (and `:113-123` local path)
- Evidence: no `min` (default 0, `pg-pool/index.js:90`), `idleTimeoutMillis: 30_000`; the hidden-tab poll is 30 s (`lib/messages.ts:10`); the reaper starts its 30 s timer at release (`index.js:409-415`) and the next poll arrives 30 s plus latency later: the connection is gone, a TLS handshake + startup is paid (estimated 30-100 ms in-region; section 5), and this repeats on alternate polls. After any 30 quiet seconds the next page (Welcome: 8-11 parallel transactions) opens up to five connections at once. No `statement_timeout`: a slow report holds one of five connections until Cloud Run's request timeout.
- Impact: the first request after every lull pays connection setup on top of its reads; a long-running statement can starve the four other connections for every other user on the instance.
- Recommendation: the diff in section 5 (`min: 1` from `CMA_DB_POOL_MIN`, `idleTimeoutMillis: 300_000`, `statement_timeout: 15_000`, `idle_in_transaction_session_timeout: 30_000`, a warm-up `connect().release()` at pool creation). Within the Database connection budget (ceiling unchanged at 4 × 5 = 20; idle floor 1 per instance): the README paragraph (line 153) gets one sentence. No `cloudbuild.yaml` change (the default of 1 lives in code; `_DB_POOL_MIN` can be added later if a tenant needs it).
- README check: new (the budget paragraph records "no connection open while idle" as an observation, not a rule).
- Disproof attempt: checked pg-pool's `min` semantics in the installed version (exempts from reaping, does not pre-open: hence the warm-up); checked that the connector sets TCP keep-alive itself (`socket.js:115`), so the brief's "no keepAlive" is not a defect on Cloud Run; checked that Cloud Run CPU throttling can still let an idle connection die overnight (section 5 caveat: one failed request, then recovery). Stands with that caveat.

### 5.6-05: Nothing streams: the Shell waits for the slowest read on every page
- Severity: Low (Medium for Welcome and the reports if the lead's measurements put them near the p75 targets)   Confidence: High   Effort: M
- Component: `web/src/app/layout.tsx:25-32`, every `page.tsx` (e.g. `page.tsx:51-76`, `live/board/page.tsx:57-95`)
- Evidence: zero `loading.tsx`/`<Suspense>` under `src`; the Shell is rendered by each page after `await Promise.all(...)`.
- Impact: TTFB = identity + the slowest of up to nine reads (Welcome) instead of identity alone; the rail and top bar, which need only the principal, arrive last.
- Recommendation: section 3: in-page `<Suspense>` around an async tiles component for Welcome, the Live board and the report pages; not `loading.tsx` (it switches on rail prefetching: 10-27 extra requests per page view, `prefetching.md:19-42`). Skeleton per style guide 7.3.
- README check: new.
- Disproof attempt: confirmed in the Next 16 docs that a dynamic route without `loading.js` is not prefetched (so today's no-prefetch state is a side effect, not a decision) and that `after`/streaming need no config. Stands.

### 5.6-06: `cma.roles()` is read two or three times per request for an admin
- Severity: Low   Confidence: High   Effort: S
- Component: `web/src/components/Shell.tsx:62-63`, `web/src/lib/auth/identity.ts:135`, `web/src/app/team/people/page.tsx:43`
- Evidence: section 2. Each is a separate `withTenant` (4 RT).
- Impact: one or two avoidable transactions on every page for the people who also see the most pages (managers), sequential after the page's reads (depth +1).
- Recommendation: the `rolesOf = cache(...)` diff in section 2 (per request only).
- README check: new.
- Disproof attempt: checked `cache()` keying (same object reference `access.real` in both callers within one request). Stands.

### 5.6-07: The Calls pages run `cma.calls_overview` three times (Calls) and two extra times (Calls per agent) per request
- Severity: Medium (report target p95 1.5 s; each call scans the current and the previous period)   Confidence: High   Effort: S (SQL) / M (new function pair)
- Component: `web/src/lib/data/postgres.ts:238-245` (`callsFilterLists`), `:1811-1836`, `:1897-1911`; `db/62_calls_overview.sql`
- Evidence: `callsFilterLists` calls `calls_overview(from, to, null, null, 'market')` and `calls_overview(from, to, market, null, 'line')` only to list the filter values; `calls_of` aggregates tags per call (`array_agg` lateral) and the function computes the previous period like for like. Sequential statements inside the transaction (6 in `getCallsOverview`).
- Impact: three to five full-period aggregations for one page; proportional to the calls in two periods, so the month view is the slow one.
- Recommendation: a light `cma.calls_filter_values(p_from, p_to)` returning distinct `market` and `(connection_id, line_ref, line_name)` from `calls_of` without aggregates and without the previous period (new pair `db/76`/`77`, `catalog.json`), called once per request and shared by the two data functions through a per-request `cache()`; `verify:reports` fixture `db/63`/`64` covers the figures.
- README check: new (0008j paragraph line 878 describes the figures, not the filter lists' cost).
- Disproof attempt: checked whether `calls_overview` with group 'market' is cheaper than the page's call (same `calls_of` scan plus grouping; it is not). Stands.

### 5.6-08: The whole `copy` dictionary (≈ 90 KB) is serialised into the client payload of most pages and every board refresh
- Severity: Low (Medium on the Live board, where it is repeated six times a minute per viewer)   Confidence: Medium (payload size observed locally; Flight's one-copy-per-response deduplication expected, not measured)   Effort: S
- Component: `copy={copy}` at `web/src/app/live/board/page.tsx:122`, `team/hours/page.tsx:122`, `roster/planner/page.tsx:68`, `reports/calls-per-agent/page.tsx:94`, `configuration/sources/[id]/page.tsx:50` and the client components listed in section 8
- Evidence: `JSON.stringify(t("en")).length` = 89 369 (observed, `/var/tmp/5.6/copysize.mjs`); 136 `copy={copy}` props in `src`.
- Impact: ≈ 90 KB more HTML per page (the RSC payload is inlined), CPU to serialise it on the 1-vCPU instance, ≈ 540 KB/min per board viewer (estimated).
- Recommendation: pass slices typed `Copy["live"]` etc., as `MessageCenter` and `Inbox` already do; the `hints` (15 KB) only where a hint renders. `verify:copy` is unaffected (it checks `copy.ts`, not props).
- README check: new.
- Disproof attempt: checked whether `copy` reaches the client at all (yes: `"use client"` components receive it as props) and whether a slice would break the components' typing (they index `copy.<section>`; mechanical). Stands.

### 5.6-09: Three reads grow with history on admin or report pages (`sources()`, `data_quality_of`, `open_tickets_of`/`open_tasks_of` on the report)
- Severity: Low (Medium once `ingest_event` holds months of webhooks)   Confidence: High   Effort: S (indexes) / M (retention)
- Component: `db/52_sources_configuration.sql` (`sources()`), `db/74_forms_reporting.sql` (`data_quality_of`), `db/72_follow_up.sql`
- Evidence: section 7 rows; `ingest_event` indexes at `db/…:193-195` do not cover `status` or `recorded_at`; no retention rule for `ingest_event` in README (grep).
- Impact: Configuration → Sources slows with every webhook received by the sweep (every minute); Data quality scans the whole mirror by design.
- Recommendation: `ingest_event (tenant_id, connection_id, recorded_at desc)` and a partial index on `status in ('received','failed','needs_review')` in the audit's `db/76` pair; an Open decision on `ingest_event` retention (outputs of real runs stay; the question is how long).
- README check: new (retention), new (indexes).
- Disproof attempt: checked for an existing retention job (`docs/ingest`, `jobs/`: none for `ingest_event`). Stands.

### 5.6-10: Welcome fires 8 to 11 transactions at once on a pool of five, and two of them could be one
- Severity: Low   Confidence: High   Effort: S
- Component: `web/src/app/page.tsx:51-62`, `day/page.tsx:25-28`
- Evidence: section 1; `getWorkday` + `listStatuses` are two transactions on Welcome and My day for one card.
- Impact: at least two pool waves per Welcome; with the first message poll arriving within the same second, three.
- Recommendation: a composite `getMyDay(me)` (day + statuses in one transaction, 5 RT instead of 8) in `CmaData`; the merged identity (5.6-03) and `min: 1` (5.6-04) take the rest.
- README check: new.
- Disproof attempt: checked that the reads really are independent (they are; only `hasClock` gates both). Stands.

### 5.6-11: `LiveRefresh` uses `setInterval`, so slow renders overlap
- Severity: Low   Confidence: High   Effort: S
- Component: `web/src/components/LiveRefresh.tsx:17-19`
- Evidence: fixed 10 s interval regardless of the previous refresh's duration; `MessageCenter` uses a `setTimeout` chain (MC+69 57-61) and cannot overlap.
- Impact: under load (exactly when it hurts) renders queue up on the server.
- Recommendation: `useTransition` around `router.refresh()` and skip the tick while `isPending`; or the same chain as `MessageCenter`. Folds into 5.6-01.
- README check: new.
- Disproof attempt: considered Next's client-side cancellation of superseded refreshes (it does not cancel the server render). Stands.

### 5.6-12: Cloud Run flags live outside the repository (reference)
- Severity: Info   Confidence: High   Effort: S (a `--min-instances=1` line is a CONFIG CHANGE, Martin's call)
- Component: `cloudbuild.yaml:57-69`
- Evidence: section 9.
- Impact: a re-created service would lose `min-instances=1`; CPU/memory/concurrency are implicit defaults nobody can read from the repo.
- Recommendation: Martin decides whether to pin `--min-instances=1` (and nothing else) in the deploy step, with the CONFIG CHANGE section the preamble requires.
- README check: settled (`min-instances=1`, Decision log 12 October 2026); the file-vs-console question is new.
- Disproof attempt: `gcloud run deploy` preserves settings not passed (documented behaviour); the finding is about the record, not a regression. Stands as Info.

### 5.6-13: No request timing and no round-trip guard exist today (proposals in sections 10 and 11)
- Severity: Info   Confidence: High   Effort: M
- Component: `web/src/instrumentation.ts` (absent), `web/src/lib/db/client.ts`, `web/verify/`
- Evidence: no `instrumentation.ts` under `web/src` (ls); no per-request logging anywhere but `console.warn` on rejected IAP tokens and `console.error` on 5xx (`respond.ts:63`).
- Recommendation: section 11's span processor (first choice) and section 10's counter + `verify:round-trips`.
- README check: new.
- Disproof attempt: looked for Cloud Run's own request log as a substitute (it has latency and status per URL path, but no route pattern, no database split, and it keeps the path with its parameters: the 12 October decision on ingest paths applies to the same log). Stands.

---

## Checked and found clean

- `getAccess` is memoised per request with React `cache()` (`identity.ts:120`); Shell, page, route handlers and the server action share one principal read.
- No cross-request cache of tenant or personal data anywhere in `web/src` (grep for `new Map`/module state in `postgres.ts`: none; `globalThis` only for the pool and the mock state).
- The IAP JWKS is cached 10 minutes per instance with a 30 s cooldown (`iap.ts:30`).
- The Cloud SQL connector refreshes the ephemeral cert and IAM token in the background and sets TCP keep-alive on every socket (`cloud-sql-instance.js:113-263`, `socket.js:115`); a new connection is TLS + startup, not an IAM exchange.
- Every page's reads are in `Promise.all` where independent, except Team hours (`listTeamPeople` first), Roster planner (`listTeams` first, needed for the team parameter) and Sources → connection (four sequential, 5.6-… noted in section 1).
- The clocks on My day and the Live board tick locally (`useSyncExternalStore`, 1 s, no requests).
- `my_messages` is correctly VOLATILE (it writes `delivered_at`); every other read function is STABLE; `find_tenants_for_identity` is the only SECURITY DEFINER read.
- `team_hours`, `team_status_time`, `crm_records_per_day`, `calls_*`, `speed_to_lead_*`, `intake_per_day`, `inbound_*`, `missed_callbacks_*`, `team_now`, `roster_*`, `my_*` are bounded by the period, today or the user (section 7).
- Fonts self-hosted (`next/font/local`), images unoptimised and tiny, `output: standalone`, security headers on every path, `cache-control: no-store` on every API answer.
- No `revalidate`, no `runtime` override, no `unstable_cache`/`"use cache"`; pages are dynamic through `connection()`.
- The job script makes its own `pg` pool and does not import `client.ts` (`jobs/close-forgotten-workdays.mjs:24`), so the counter diff cannot affect it.

## Not checked / could not check

- No build, no server, no `EXPLAIN`, no `autocannon` (the lead's half). All numbers above are counts from the code or marked estimates.
- The load balancer's pass-through of `/_next/static` cache headers and any LB compression.
- Cloud Run's current CPU, memory and concurrency (console state; defaults assumed from documentation).
- Whether Cloud SQL closes idle client connections (relevant to the `min: 1` caveat): `pg_stat_activity` in Studio over a quiet night tells.
- React Flight's deduplication of the repeated `copy` object inside one response (expected from React 19; the lead can confirm with `curl` and `wc -c` on a page).
- React `cache()` scope inside route handlers outside rendering (not documented in the Next 16 docs shipped in `node_modules`; the design in section 10 therefore relies on OTel's context instead).
- Index usage inside `workday_summary_all` (a grouped view; predicate pushdown expected, not proven).

## Commands run

- `find web/src/app -name page.tsx`, `… layout.tsx|loading.tsx|route.ts`: 37 pages, 1 layout, 0 loading files, 97 route handlers.
- `grep -rn 'cache(' web/src`: one hit (`identity.ts:120`). `grep -rln 'Suspense\|loading.tsx' web/src`: none. `grep -rl '^"use client"' web/src`: 39 files (listed in section 8).
- `grep -n 'withTenant(\|withoutTenant(\|Promise.all' web/src/lib/data/postgres.ts`: every data function is exactly one transaction; `findPrincipal` two; no `Promise.all` inside the data layer (statements inside a transaction are sequential).
- `grep` of `data()`, `await`, `Promise.all`, `<Shell` across every `page.tsx` (section 1 table).
- `grep -n 'min\b\|_isAboveMin\|allowExitOnIdle\|idleTimeoutMillis' web/node_modules/pg-pool/index.js`; `sed -n '85,130p;385,430p'`: `min` supported, exempts from reaping only.
- `grep -n 'keepAlive\|setKeepAlive' web/node_modules/pg/lib/connection.js`, `…/cloud-sql-connector/dist/cjs/socket.js`: the connector sets keep-alive.
- `grep -n 'refresh\|ephemeral\|token' …/cloud-sql-instance.js`, `sed -n '205,240p' …/connector.js`: background refresh; TLS socket per connection.
- `awk` extraction of 46 read functions from `db/*.sql` to `/var/tmp/5.6/fn/`, `grep` of `from cma.`/`where`/`between`/`now()`/`language … stable` in each (section 7); `grep -h 'create index' db/*.sql` for the hot tables.
- `node --experimental-strip-types /var/tmp/5.6/copysize.mjs`: `copy(en)` JSON 89 369 bytes, 1 728 leaf keys.
- `grep` in `web/node_modules/next/dist/docs/01-app` for instrumentation, `after`, `loading`, prefetching, OpenTelemetry, `logging`; `sed -n '488,550p' web/node_modules/next/dist/server/base-server.js`: the request span and its attributes.
- `grep -n 'cpu\|memory\|concurrency\|min-instances' cloudbuild.yaml`; `sed -n '50,95p' cloudbuild.yaml`.
- README: `grep -n '^## \|^### '`, `sed -n '1058p;1060p;1188p;1190p;1208p'`, `grep -o '…Database connection budget…'`, `grep -o '…min-instances…'`; `local-records/readme-index/decisions-index.md` grep for pool/cache/streaming/min-instances.
- `wc -c web/src/fonts/*.ttf web/public/brand/* web/src/app/globals.css`.
