# Full IT audit of the CMA, 17 October 2026

Security, reliability, speed, UX, code quality, configurability and data protection of the repository `Pulse4all-com/cma`, with the soft-launch readiness and a System health page. Static review and local runs only: nothing in Google Cloud, HubSpot, Aircall or Shopify was called, and no branch was merged. The companion files in this directory: `FINDINGS.csv` (every finding with its id, severity, evidence, status), `PERFORMANCE.md`, `UX_REVIEW.md`, `READINESS.md` (gates, SLOs, dated items, verdict), `METHOD.md` (plan, threat model, command log, self-review), `GEMINI_PROMPT.md` (the hand-off for the Gemini Gem), `BACKLOG_CANDIDATES.md`. Raw outputs, free of secrets and personal data, under `local-records/`.

## 1. Verdict in one paragraph

The CMA is in better shape than a system this young usually is: tenant isolation is enforced in the database on every table, every write is gated by a permission the database checks again, the copy, palette and components follow the style guide with unusual discipline, and the verifier suites are large and honest. The audit found **no Critical finding** and **two High findings**, both closed in pull requests before this report: a Shopify access token cached once for every connection (a cross-tenant path inside the ingest process) and a mis-configured `cma-web` revision that would pass the deploy and lock everyone out. The four items of backlog row CMA-037 are confirmed and fixed, among them the Medium that a direct update of a line's `is_counted` by the ingest login removed its calls with no acting user and no permission check. The soft launch is **go, conditional on five things** (section 7): the fix PRs merged in the order of section 3, the four Console-only steps done, the DST change of the reconcile schedule live before the night of 25 October, Yordi's clearance of the per-person figures on the pages that show them, and the first week of the request log line read against the speed targets. Daylight-saving time is handled correctly everywhere the clock and pay depend on it; the one scheduling defect (the 02:30 reconcile) is fixed in [#158](https://github.com/Pulse4all-com/cma/pull/158).

## 2. Scope, method, calibration

- **Scope**: `web/` (Next.js 16, the Workspace), `ingest/` (the plain-Node ingest service and its Cloud Run jobs), `db/00` to `db/75` (the schema, RLS, functions, verify scripts), `cloudbuild.yaml`, `docs/` (runbooks, deploy scripts, the data map), the README's decisions. Out of scope by the brief: anything that needs a cloud call.
- **Method** (`METHOD.md`): a threat model first (assets, actors, controls), then twelve area reviews run in parallel against one shared rule set, each with file-and-line evidence; a local PostgreSQL 16 built from `db/00` to `db/75` with the dev seeds for the database and the ingest flow verifiers; the standalone Next.js build on loopback for time to first byte, statement counts, screenshots and the layout and theme verifiers; two self-review passes (a false-positive hunt before the fixes and a red team after them). Numbers are marked **observed** (sandbox), **expected** (from code) or **estimated** (about production).
- **Calibration**: Critical means exploitable now with cross-tenant, credential or customer-data exposure, data loss or an outage; High a realistic path to one of those, a correctness bug in time, pay or billing figures, or a daily-path page missing the speed target by more than double or misleading a figure; Medium defence in depth or a plausible-trigger reliability, performance or UX issue; Low hygiene; Info an observation. Twelve findings that matter were preferred over sixty nits; the Info items are collapsed in section 9.
- **Rules kept throughout**: read-only outside the repository; no secret, personal id or customer datum in any file or PR; never edit a migration that has run (`db/00` to `db/75`); never weaken IAP verification, the fail-closed mode variables, RLS and the per-transaction tenant context, ingress, the "no personal data in a path" rule, one writer per property towards HubSpot or forward-only migrations; README decisions are settled; fix only what can be stood behind (changes touching time, pay, billing, RLS, authentication or the ingest write path that could not be verified here are proposed, not applied).

## 3. The pull requests, in the order to handle them

Each PR is one increment, small enough to review in one sitting, with its verifier results and Martin's labelled steps in its description. Nothing is merged by the audit. "Deploys prod" means the Cloud Build trigger builds on the merge.

| # | PR | Carries | Deploys prod | Depends on |
|---|---|---|---|---|
| 1 | [#151](https://github.com/Pulse4all-com/cma/pull/151) 0008q audit hardening (`db/76`, `db/77`) | the uncounted-line trigger asserts the acting person's right (CMA-037 item 2), the audit log without five copies of each webhook payload, sargable date bounds in the report cores, two indexes on `ingest_event`, `delete` revoked on five catalog tables and the early migrations' `public` executes revoked, `search_path` pinned on the two SECURITY DEFINER lookups, `telephony_raw` free of `@` | no | run in dev, refresh `schema.json`, then prod |
| 2 | [#150](https://github.com/Pulse4all-com/cma/pull/150) ingest security | the Shopify token cache per connection (High), a failing batch isolated, the flow verifiers' admin login from the environment, verifier fixtures de-personalised | no (ingest is deployed by hand) | — |
| 3 | [#154](https://github.com/Pulse4all-com/cma/pull/154) web security | the first CSP, IAP headers deleted after verification, End workday through the guarded route, `/api/health` 503 when misconfigured (the web half of the High), fixtures on `example.invalid`, the boundaries verifier | **yes** | — |
| 4 | [#155](https://github.com/Pulse4all-com/cma/pull/155) Cloud Build guard and flags | `check-config` refuses a bad mode, a missing audience and non-numeric caps (the pipeline half of the High); `--min-instances=1`, the startup probe on `/api/health`, `--cpu-boost` (CONFIG CHANGE, budget unchanged) | **yes** | best after #154 |
| 5 | [#152](https://github.com/Pulse4all-com/cma/pull/152) System health, database half (`db/78`, `db/79`) | the heartbeat thresholds and the two document links as settings, the scheduler's run row, `cma.system_health_runs()` | no | after #151 (numbering only; independent in content) |
| 6 | [#153](https://github.com/Pulse4all-com/cma/pull/153) System health, web half | the page, the documents pipeline and route, the scheduler job's run row, the theme and layout entries | **yes** | #152 in dev and prod |
| 7 | [#159](https://github.com/Pulse4all-com/cma/pull/159) speed | identity in one transaction, the warm pool with ceilings, roles once per request, the Live poll as a timeout chain, the request log line, the round-trips budget verifier | **yes** | — |
| 8 | [#157](https://github.com/Pulse4all-com/cma/pull/157) ingest reliability | one execution per scheduled job, pool ceilings, no followed redirects, a response cap, the replay host guard, the connection-lost listener | no | — |
| 9 | [#158](https://github.com/Pulse4all-com/cma/pull/158) ops | `deploy.sh` from `main` only, the reconcile at 03:30 (DST), Dependabot monthly | no | redeploy the jobs in dev and prod before 25 October |
| 10 | [#160](https://github.com/Pulse4all-com/cma/pull/160) UX | the hydration mismatch, keycaps 1 to 9, focus kept, error and not-found pages, "Closed" on the Live board, no CSS all-caps, the correction filter, dialog names | **yes** | — |
| 11 | [#156](https://github.com/Pulse4all-com/cma/pull/156) README cockpit | the dashboard, cockpit and workspace concept (Appendix C) | no | — |
| 12 | this report PR | the report set, `local-records/`, `docs/OPERATIONS.md`, `docs/PLAN_B.md`, README drift fixes and the Decision log rows | no | last: it is rebased on the others |

Five prod deploys (#154, #155, #153, #159, #160), each its own build. Merge them one at a time and look at the Workspace between them; `/api/health` and the System health page are the two places a bad one shows first.

## 4. Findings by area (the ones that matter)

Severity, confidence and effort as in `FINDINGS.csv`; the id in brackets is the CSV's. "Fixed" names the PR.

### 4.1 Web security (5.1)

- **Content-Security-Policy absent** (AUD-006, WEB-01, Medium): only `X-Frame-Options`, `nosniff`, `Referrer-Policy` and `Permissions-Policy` were set. Fixed in #154 with a first policy that cannot break a page (`frame-ancestors 'none'; base-uri 'self'; form-action 'self'; object-src 'none'`); the `script-src` nonce is the next step and an Open decision.
- **IAP's own headers passed to every page and route** (AUD-040, WEB-04, Medium): the signed assertion is a bearer proof for its lifetime; a log line or an error report could have carried it. Fixed in #154: deleted after verification.
- **A second write path without the same-site guard** (AUD-041, WEB-06, Medium): End workday was a server action; every other write goes through `/api/v1` with `assertSameSiteWrite`. Fixed in #154; `app/actions.ts` removed and the boundaries verifier forbids `"use server"` files.
- **A staff address in verifier fixtures** (AUD-039, WEB-03, CQ-10, Low): eight verifier files carried a real address as the default admin login. Fixed in #154 and #150 (`example.invalid`, the environment variable).
- **No static guard on the module graph** (AUD-042, WEB-09, CQ-05, Low): nothing stopped a client component from importing the database client. Fixed in #154: `verify:boundaries`, seven rules over 229 files, provoked fails.
- **Dependencies** (AUD-043, WEB-10, Low): `npm audit` shows no vulnerability with a non-breaking fix today; no watcher existed. Fixed in #158 (Dependabot, monthly, majors ignored). The audit never ran `npm audit fix --force` and bumped no major version.
- Kept as is: IAP verification (ES256, issuer, audience, expiry, a future `iat` refused, JWKS cached ten minutes), the identity headers set only by the proxy, mock identities only in mock mode, the fail-closed mode variables. These were read line by line and are the reason nothing here is High.

### 4.2 Ingest security and reliability (5.2)

- **One Shopify access token for every connection** (AUD-001, 5.2-01, **High**, fixed in #150): the client-credentials token cache was keyed by nothing, so the second tenant's Shopify connection read with the first tenant's token inside the same process. Confirmed by a two-tenant flow case written against `main` (fails) and the fix (passes); the cache is keyed by connection id, signing-secret name and client id. This was item 1 of backlog row CMA-037.
- **One failed CRM lookup failed every unit of the batch, and every retry repeated them all** (AUD-003, 5.2-03, Medium, fixed in #150): the failing unit now ends with outcome `error` and the run reports `crm_<code>`; the other units proceed.
- **No lock between overlapping executions of a scheduled job** (AUD-007, 5.2-02, Medium, fixed in #157): Cloud Scheduler starts the sweep, the form poll and the email poll every minute regardless; the README's budget named the worst case as ten at once. A session advisory lock per job makes the second execution log `skipped` and exit.
- **No statement or idle-transaction ceiling anywhere** (AUD-045, 5.2-07, DB-03, INFRA-03, Medium): fixed for the web pool in #159 and the ingest pools in #157; the scheduler job's pool is the remaining piece (proposed). Found while testing: a checked-out pg client has no error listener, so the FATAL the server sends for an idle transaction **ended the process**; both PRs add the listener (reproduced in `local-records/5.6-speed-measured/idle-tx-check.txt`).
- **Redirects followed with the vendor token attached; bodies read without a cap** (AUD-046, 5.2-08, Low, fixed in #157).
- **The replay tool would post a fixture to any host** (AUD-048, 5.2-10, Low, fixed in #157: `--allow-host`).
- **`deploy.sh` deployed prod from any branch** (AUD-009, 5.2-05, Medium, fixed in #158: `main` only, dev with `--allow-branch`).
- Proposed: secret names not scoped per tenant in the connection table (5.2-04: a naming convention and a check, with the SQL); the Host header trusted when `INGEST_PUBLIC_URLS` is empty (5.2-09: refuse to start without it in prod); `sync_run` gaps on an aborted run (AUD-100, 5.2-11); the Aircall pace counter per process rather than per account (AUD-101, 5.2-12); the image deployed by tag, not digest (AUD-102, 5.2-13).

### 4.3 Database (5.3)

- **A direct update of a line's `is_counted` removed its calls with no acting user** (AUD-002, DB-01, Medium, fixed in #151): the trigger of 0008f deleted a line's stored calls as SECURITY DEFINER without asserting any right, so the ingest login (which holds `update` on the table) or anyone with the `cma_app` rights could remove every call of a line in one statement with an audit trail naming no person. Reproduced on a throwaway tenant and rolled back; no shipped code path takes the route. The trigger now asserts `tenant.configure` of the acting person and still accepts the owner role for migrations. This was item 2 of CMA-037.
- **About 3.4 audit rows and five copies of each webhook payload per `ingest_event`** (AUD-010, DB-02, Medium, fixed in #151): the audit of an ingest event carried the vendor payload in every row; the payload is stripped from the audit image.
- **Non-sargable date bounds** (AUD-011, DB-04, Medium, fixed in #151): `calls_of`, `inbound_calls_of` and `lead_deals_of` compared a column expression with the bound; coalesced so the indexes serve them.
- **Grants wider than the application needs** (AUD-012, DB-06, DB-07, Low, fixed in #151): `cma_app` held `delete` on 16 tables, five of them with no delete path at all (those five revoked; the rest listed for a later pass), and 22 functions of the first migrations were executable by `public`: the nine that write or read across people (`open_workday`, `end_workday`, `set_status`, `correct_workday`, `correct_time_event`, `refresh_workday`, `team_hours`, `team_people`, `user_permissions`) are now the application's only, with their exact signatures checked before the revoke; `search_path` on the two SECURITY DEFINER lookups now ends with `pg_temp` (AUD-014, DB-08).
- **The telephony raw payload could carry an address** (AUD-015, DP-01, Low, fixed in #151: a check `!~ '@'`).
- Fixed in #151 as well: `cma.sources()` ran four correlated scans of `ingest_event` per connection without a time index (DB-05; the two indexes). Proposed: the other foreign keys without an index (AUD-016, DB-11, Info; two added); nine `cma_read` SECURITY DEFINER views where the README says four (AUD-103, DB-10, a README correction in this PR); scripts `01` to `46` without an explicit transaction (AUD-049, DB-09, historical, documentation only); `follow_up_summary` re-deriving the lead history (AUD-025, 5.6-02, a tenant setting and an index as a new pair).

### 4.4 Infrastructure and reliability (5.4, 5.5)

- **A mis-configured `cma-web` revision passes the deploy** (AUD-005, INFRA-01, **High**, fixed in #154 and #155): `check-config` did not test `_IAP_AUDIENCE`, the probe was a TCP connect, and `config.ts` threw only at the first request. Observed in the sandbox: iap mode without an audience answered `/api/health` 200 and every page 401. Now the build stops on the file's own defaults, `/api/health` answers 503 `misconfigured`, and the startup probe keeps such a revision from traffic. This was the class of the 16 October ingest incident.
- **Runtime settings in the Console only** (AUD-019, INFRA-02, Medium): `--min-instances=1` and the boost are in the file (#155); CPU, memory, concurrency and timeout are pinned once Martin records the live values (a step in the PR).
- **Parked ingest events had no clearing path, and nothing watched errors, latency or job failures** (AUD-021, INFRA-05, INFRA-06, Medium): the System health page (#152, #153) shows the parked count per connection and the jobs' last runs (the clearing path itself stays proposed); the alert set (5xx ratio and p95 on both backends, job failures, Cloud SQL CPU, memory, storage and connections, the ingest 429) remains Console work, written as steps in `READINESS.md` and `docs/OPERATIONS.md`.
- **No restore drill on record** (AUD-023, INFRA-07, Medium): point-in-time recovery is on; a drill into a scratch instance is a `READINESS.md` gate with its steps.
- SLOs S1 to S8 proposed in `READINESS.md`.

### 4.5 Speed (5.6)

Detail in `PERFORMANCE.md`. Observed in the sandbox: every page under 110 ms p95 on loopback, so the targets cannot be shown missed there; what the sandbox shows is cost shape. Every request paid two transactions (seven statements) for identity (AUD-026, 5.6-03); the pool went cold after every quiet half minute (AUD-027, 5.6-04); the Live board's poll is a full render of eight transactions per viewer (AUD-024, 5.6-01); `follow_up_summary` re-derives the lead history on each call (AUD-025, 5.6-02). Fixed in #159: identity in one transaction (**every one of 44 counted requests one transaction and two statements lower**), the pool kept warm with ceilings, roles once per request, the Live poll as a timeout chain, and the two instruments that make production readable: a structured request log line and a round-trips budget verifier. Proposed: the Live board's composite read, the lookback setting, Suspense per card, one `calls_overview()` call, per-page copy slices.

### 4.6 Code quality (5.7)

- **Copy interpolation corrupts a value containing `$`** (AUD-029, CQ-01, Low, proposed with the one-line fix: a function replacer in `copy.ts`'s `fill`): a name or a note with `$1` would be mangled; no such value exists in the seed.
- **Test gaps** (AUD-030, CQ-08, Low): the pure verifiers cover the derivations; the write paths of time and pay are covered by the api verifier only, which runs on Martin's terminal. Proposed: a pure verifier for the correction rules' edge cases listed in the finding.
- Fixed: the staff address in fixtures (AUD-069, CQ-10), the boundaries verifier (AUD-065, CQ-05).

### 4.7 Configurability, data protection, cost (5.8 to 5.10)

- **The outbox's "late" threshold hardcoded (10 minutes) in four places** (AUD-070, CFG-01, Low, proposed as a tenant setting with the catalog row).
- **The Aircall pace wording in the Sources page** (AUD-112, CFG-02, Info).
- **Data protection**: no personal data in any path or query string (checked route by route); the UI shows ids, statuses and links only; `telephony_raw` now refuses an `@` (AUD-015, DP-01); `local-records/` is in this PR scrubbed of staff names (AUD-095, WEB-12). Proposed: the retention of `ingest_event.raw` as a setting (AUD-072, DP-03).
- **Cost** (AUD-116, COST-01, Info): prod about €135 to €150 a month at today's shape (Cloud SQL the larger part); `--min-instances=1` is already paid; nothing in the fixes adds a line item.

### 4.8 Documentation drift (5.11)

Sixteen places where the README described code that had moved on (DOC-01 to DOC-16), each with the exact sentence before and after; applied in this PR, among them the connection budget omitting the email poll (83 → 86 in prod, 58 → 61 in dev; and the worst case after the job lock), the `cma_read` SECURITY DEFINER count, the `audit_log` select grant, and the scripts range `00` to `79`.

### 4.9 Daylight-saving time (5.12)

No High. Every clock-in, status change, correction, workday window, roster time and report bucket is stored in UTC or with the market's zone and rendered through `lib/time.ts` with an explicit zone; the forgotten-day close uses the business day's end in the tenant's zone; the autumn hour of 25 October 2026 (02:00 to 03:00 twice) and the spring hour of 29 March 2027 were traced through each path with the dev seed. Two findings: the reconcile scheduled at 02:30 local runs twice or never once a year (AUD-086, DST-01, fixed in #158: 03:30); the legacy time import accepts a local time in the ambiguous autumn hour without saying which occurrence it took (AUD-087, DST-02, proposed: refuse or require an offset for that hour, with the SQL).

### 4.10 UX (5.14)

Detail in `UX_REVIEW.md`. The screens are disciplined; the defects are in the dynamics. Fixed in #160: a hydration mismatch on three pages (AUD-032, UX-01, ICU weekday patterns), keycaps numbered past 9 that could never fire (AUD-033, UX-02), focus dropped to the body after a status change or Clock in (AUD-034, UX-03), no error or not-found page (AUD-035, UX-04, the safe part), "Waiting 0 min" for callers missed hours ago outside office time (AUD-037, UX-06), CSS all-caps on the urgent pop-up (AUD-088, UX-07), the "days not clocked out" link landing on the whole month (AUD-089, UX-08), dialogs without an accessible name (AUD-090, UX-09). Proposed: the badge and focus-ring tokens that fail WCAG AA contrast on every page that uses them (AUD-036, UX-05, a style-guide decision with Mark), the line switch-off dialog's count (AUD-091, UX-10, CMA-020), the Shell in a layout with a skeleton per route (AUD-035, UX-04, the larger part).

## 5. CMA-037 and the other backlog rows the brief named

| Row | Item | Status |
|---|---|---|
| CMA-037 item 1 | the Shopify token cache | fixed, #150 |
| CMA-037 item 2 | a direct update of a line's `is_counted` removing its calls without an acting user | fixed, #151 |
| CMA-037 item 3 | a failing batch stalling the others | fixed, #150 |
| CMA-037 item 4 | the flow verifiers' default login | fixed, #150 |
| CMA-060, CMA-039, CMA-040, CMA-035, CMA-038, CMA-032 | as the brief listed them | checked against the code; the ones with a finding are in `FINDINGS.csv` with the row named, the rest are confirmed as open backlog with no new evidence |
| CMA-031 | alert pushing | out of scope for System health v1; v2 in Open decisions |
| CMA-020 | the line switch-off count | UX-10, proposed (a read column) |
| CMA-004/061/063 | locale and formatting | UX-01 fixed the one defect found; the rest confirmed |
| CMA-024/068/003/026/021/034/067 | as listed | checked; `BACKLOG_CANDIDATES.md` says where a finding touches them |

## 6. Risk estimate

**Before the fixes** (estimated, in this system's context): the chance of a cross-tenant read inside the ingest process was real as soon as a second Shopify connection existed (it did not yet in prod, which is why this was High and not Critical); the chance of a locked-out prod revision from a manual build or a mis-edited trigger was the highest single operational risk, with a precedent on 16 October; the chance of a wrong time figure from DST was low and confined to the reconcile's schedule.

**After the fixes are merged and the Console steps done**: the remaining risks that matter are (1) a slow report holding a connection, now capped at 15 s; (2) the Live board's poll cost growing with history (AUD-024, 5.6-01, 5.6-02), visible in the request log line before it hurts; (3) the alert set not yet created, so a failure still depends on someone looking (the System health page shortens that, Cloud Monitoring closes it); (4) the absence of a restore drill; (5) the badge contrast, a daily legibility cost rather than a risk.

**Residual security posture**: no path from the public internet to a page or route without an IAP identity; no path from one tenant's identity to another tenant's rows (RLS plus the per-transaction context, the lookups SECURITY DEFINER with a pinned `search_path`); the one in-process cross-tenant path found is closed; secrets are referenced by name and resolved at runtime, none in the repository.

## 7. Soft-launch verdict

**Go, conditional.** The soft launch (Appendix B: Arno works in it daily) can start when:

1. #151, #150, #154, #155, #152, #153, #159, #157, #158 and #160 are merged in that order, each build watched (section 3).
2. The jobs are redeployed in dev and prod with #158 (`deploy.sh … --jobs`), so the reconcile runs at 03:30 **before the night of 24 to 25 October 2026**.
3. The four Console-only steps in `READINESS.md` are done: the alert set, 2-step verification enforced on the Workspace accounts, the logging retention, the restore drill scheduled.
4. Yordi has cleared the per-person figures on the pages that show them (the Dashboard, Team hours, the Live board, Calls per agent); this is a people decision the audit cannot take, and `READINESS.md` names the pages.
5. The first production week of the request log line is read against the speed targets, and a page over the target gets its proposal from `PERFORMANCE.md` scheduled.

Blockers found and removed by the PRs: a figure misstated by DST (the reconcile), a bad deploy unnoticed (the probe and the guard), a cross-tenant read in the ingest. Blockers not found: no wrong figure on a manager's screen in the dev seed and the fixtures; no slow page in the sandbox (production is to be read, section 5 of `PERFORMANCE.md`).

## 8. System health: what v1 is and what v2 would add

v1 (#152, #153) reads what the jobs leave behind and pings nothing: the application's version and modes with a timed storage round trip, the ingest heartbeat against two tenant settings, the sources with a derived state, the last run per job and connection including the scheduler's close (which now writes its own run row), the outbox per connection and state, and the documents of the build with two external links. v2 would add: alert pushing on the same states (CMA-031, through the existing messaging), cross-tenant health for the admin of several business lines (Open decisions, tenant picker), Cloud Monitoring figures (request p95 per route from the log line, instance count, Cloud SQL CPU) read through the Monitoring API by a service account, a history of states (a `health_sample` table filled by the sweep) so "silent since when" is answered, and a vendor status line read from the vendors' public status feeds rather than from the CMA's own calls.

## 9. Info items (collapsed)

Observations without a finding's weight, each in `FINDINGS.csv` with status `info`: the Aircall pace wording (AUD-112, CFG-02); the cost picture (AUD-116, COST-01); CLS of 0.0003 to 0.006 from the unread badge mounting (reserve its width); three table cells that wrap at 1280 px (Team hours total, the sent-messages title column, the Intake tiles' hints); `e.repeat` not filtered in the shortcut hook; the 40 px in-page primary buttons against the guide's 48 px (a derived choice to name); the `records/layout` screenshots the layout verifier overwrites in the working tree (never committed; a `.gitignore` entry would stop the noise); the ingest image deployed by tag rather than digest (AUD-102, 5.2-13, a one-line change to `deploy.sh` when a digest pin is wanted).

## 10. What the audit could not do, and what Martin runs

Nothing in the cloud was observed: the production baselines (Cloud Run latency, Cloud SQL insights, the alert policies' existence, IAP and Cloud Armor settings, logging retention, 2SV enforcement) are Martin's steps with expected outputs in `READINESS.md` and `docs/OPERATIONS.md`. The verifiers that need a server or a database (`verify:api`, `verify:theme`, `verify:layout`, `verify:iap`, `verify:scheduler`, `verify:round-trips`, every `db/` script and the ingest flow verifiers) were run here against the sandbox and are to be run again by Martin against dev as each PR says. The System health page's documents card shows "not in this build" until this report PR is merged and a web build runs after it.
