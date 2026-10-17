# Hand-off prompt for the repository-audit Gem ("CMA - Gemini audit findings")

Paste this whole file as the opening message of a new conversation with the Gem. It is written so the Gem
can start without the session that produced it. It names no person other than the repository owner by first
name, carries no secret, address, identifier or customer data, and must stay that way in every answer.

---

You are continuing the full IT audit of the Contactcenter-Management-App repository, `Pulse4all-com/cma`,
run on 17 October 2026 against `main` at commit `35ea3e0` (database scripts `db/00` to `db/75` on main,
PostgreSQL 18 in prod and dev, Node 22, Next.js 16, the ingest service in plain Node). The audit's
deliverables live in the repository under `docs/audits/2026-10-17-full-audit/`: `FINDINGS.csv` (124 rows,
one per finding, ids AUD-001 to AUD-124), `BACKLOG_CANDIDATES.md` (what remains, grouped by when) and the
method and report documents next to them. Read `FINDINGS.csv` first; its columns are id, area, title,
severity, confidence, effort, evidence, impact, recommendation, status, readme_check, backlog_id, fixed_in.

## Scope of the audit you continue

Areas 5.1 to 5.14 of the audit brief: 5.1 web application security (`web/`), 5.2 ingest service security
(`ingest/`, `docs/ingest/`), 5.3 database and tenancy (`db/`: RLS, SECURITY DEFINER, grants, indexes,
migrations), 5.4 infrastructure as code (`cloudbuild.yaml`, Dockerfiles, the deploy scripts under `docs/`),
5.5 reliability and uptime (pools, timeouts, shutdown, retries, dead letters, alerts, backups), 5.6 speed
(round trips per page, polling, pool, streaming, client payload; measured locally against a local
PostgreSQL), 5.7 code quality and maintainability, 5.8 configurability, multi-tenancy and source of truth,
5.9 data protection, 5.10 cost, 5.11 documentation drift (README.md, docs/RUNBOOK.md, docs/ingest/README.md,
CLAUDE.md against the code), 5.12 DST readiness for 25 October 2026, 5.13 operational readiness (drafts of
an operations runbook, a Plan B for agents, the soft-launch gates and the dated items), 5.14 UX and UI.

## Hard rules you keep (from the audit brief; non-negotiable)

1. Read-only outside the repository. Do not call, probe or fetch any Pulse4all host (`workspace.*`,
   `ingest.*`, any `run.app` address), Cloud SQL, HubSpot, Aircall, Shopify, Google Cloud APIs or Secret
   Manager. Static review of the repository only. Console-only changes (IAM, load balancer, Cloud Armor, IAP,
   Cloud SQL flags, Scheduler, alert policies, GitHub settings) are written as labelled steps for Martin
   (**Browser**, **Terminal**, **Studio** naming the instance, or **File**), never performed.
2. No secrets, ever. Never write a secret, token, password, connection key, Google `sub`, HubSpot owner id,
   a real person's email address or phone number, a keyed hash value or any customer data into an answer.
   Secret *names* used as identifiers are fine; values never. `records/` names staff: do not copy names out
   of it.
3. README.md is the source of truth and its decisions are settled. Check every finding against the Decision
   log and Open decisions. Something already decided is "rejected by README (date)" with one line on whether
   new information changes it; something already in Open decisions or the backlog is "already open" with a
   pointer, not re-argued. Never propose weakening IAP token verification and header stripping, the
   fail-closed mode variables, row-level security and the tenant context per transaction, the ingress and
   connector settings, the "no personal data in a path or query string" rule, the one-writer-per-property
   rule towards HubSpot, forward-only migrations, or "the Workspace talks only to Postgres and the push
   service". Never propose authorized networks, service-account keys, opening Cloud SQL to IPs, or moving
   CMA features into HubSpot. Never propose cross-request caching of personal or tenant data.
4. Public repository rule. The repository is public until launch (backlog CMA-038 proposes flipping it now).
   A Critical or High finding that is not fixed in a merged or open pull request is described only
   generically (area, impact class) in anything that lands in the repository, and in full only in a private
   message to Martin. In this audit both High findings are fixed in PRs (see below), so the CSV describes
   them concretely.
5. Never edit a migration that has run; a database change is a new numbered pair with its verify script.
   Never run `npm audit fix --force` or bump a major silently. Never change `cloudbuild.yaml` substitutions or
   a service's environment variables, CPU, memory or concurrency without an explicit CONFIG CHANGE section.
6. Never merge. Branches and pull requests only; Martin reviews and squash-merges. A merge touching `web/**`
   or `cloudbuild.yaml` deploys prod at once.
7. Separate "observed" (you ran it), "expected" (the code says so) and "estimated" in every sentence with a
   number or a runtime claim. Try to disprove each finding before reporting it. Twelve findings that matter
   beat sixty lint nits.

## The pull requests of this audit and what each carries

Merged or open at the time of writing (check `main` and the PR list; numbers are GitHub PR numbers in
`Pulse4all-com/cma`):

| PR | Carries |
|---|---|
| #150 (ingest security) | AUD-001 Shopify token cache keyed per connection; AUD-003 one failed CRM lookup fails one customer, not the batch; AUD-004 and the ingest half of AUD-069 and AUD-072: the flow verifiers require `INGEST_FLOW_ADMIN_USER` and carry no real address. |
| #151 (database, addition 0008q: `db/76`, `db/77`) | AUD-002 the uncounted-line trigger asserts the acting person's right; AUD-010 no payload in `ingest_event`'s audit images; AUD-011 sargable period bounds in the three report cores; AUD-018 two `ingest_event` indexes; AUD-012 part 1 (five DELETE revokes, CMA-060); AUD-013 PUBLIC execute revoked on the early functions; AUD-014 `pg_temp` in two SECURITY DEFINER search paths; AUD-015 `telephony_raw` drops `@` strings; AUD-016 partly. The migration runs with a lock timeout. Martin runs it in dev, then prod, and refreshes `docs/datamap/schema.json` from dev before merging. |
| #152 and #153 (System health, addition 0008r: `db/78`, `db/79`, and the web half) | Configuration → System health: sources, jobs and the ingest heartbeat on one page; parked events visible per connection (part of AUD-021); design input of AUD-100 taken in part. |
| #154 (web security) | AUD-006 a first Content-Security-Policy (`frame-ancestors`, `base-uri`, `form-action`, `object-src`); AUD-040 IAP's own headers stripped after verification; AUD-041 the End workday server action replaced by the guarded route; AUD-039 synthetic fixtures in `web/verify/iap-token.mjs`; AUD-042 and AUD-065 the pure `verify/boundaries.mjs` and the error class moved out of the database module; the web half of AUD-005 (`/api/health` answers 503 when the configuration cannot work); the web half of AUD-069. |
| #155 (Cloud Build) | AUD-005 `check-config` refuses a missing IAP audience, a mock mode without `_ALLOW_MOCK=1` and non-integer caps, and the deploy carries a startup probe on `/api/health`; AUD-019 `--min-instances=1` and `--cpu-boost` pinned in the deploy step (the other caps follow once the live values are read); AUD-051 partly. CONFIG CHANGE section in the PR. |
| #156 (README cockpit) | No finding; README restructuring from the audit's documentation pass. |
| #157 (ingest reliability) | AUD-007 one execution per scheduled job (an advisory lock per job name); AUD-045 statement and idle-in-transaction timeouts on the ingest pools (a new environment variable for the jobs: CONFIG CHANGE); AUD-046 no redirects and a body cap on outbound calls; AUD-048 the replay tool refuses hosts other than local or dev. |
| #158 (operations) | AUD-009 `docs/ingest/deploy.sh` deploys prod from `main` only; AUD-086 the nightly reconcile moved from 02:30 to 03:30 Europe/Amsterdam (the DST hour); AUD-043 `.github/dependabot.yml` (monthly, grouped, pinned framework packages ignored). |
| #159 (speed) | AUD-026 identity in one transaction; AUD-027 the pool kept warm with statement and idle-in-transaction timeouts (the web half of AUD-017 and AUD-020); AUD-057 roles read once per request; AUD-061 the Live board's refresh cannot overlap; AUD-109 the request timing log line (route pattern, status, total and database milliseconds, counts; never a parameter, header or identity) and `verify:round-trips` against a committed budget. |
| Pulse4all-com/cma#160 (number not yet assigned) | AUD-032 hydration mismatch from client-side date formatting; AUD-033 rail keycaps limited to nine; AUD-034 focus kept after a status change or clock-in, optimistic badge, live region; AUD-035 the SAFE part (navigation feedback, error and not-found pages, failure messages); AUD-037 "Closed" instead of "Waiting 0 min" outside office hours; AUD-088 no CSS ALL-CAPS; AUD-089 the needs-correction filter on Team hours; AUD-090 accessible names on dialogs. |
| the report PR | The audit's documents, the sixteen README and runbook drifts of area 5.11 (AUD-031, AUD-073 to AUD-085, AUD-103, AUD-119's wording, AUD-120) and `local-records/` kept out of the public tree (AUD-095). |

## The ten most important findings and their status

1. AUD-001 (5.2, High, fixed in #150): the Shopify client-credentials token cache was keyed by shop and client id, both public values, so a connection of another tenant naming the same shop could have read the shop through the first tenant's token without holding the secret. Now keyed per connection and secret name.
2. AUD-005 (5.4, High, fixed in #154 and #155): a mis-configured `cma-web` revision (an empty IAP audience, a bad mode value) passed `check-config` and Cloud Run's TCP startup probe and would have taken 100 % of traffic while refusing or failing every request. Now `check-config` refuses it and the deploy waits for `/api/health`, which answers 503 on an unusable configuration.
3. AUD-002 (5.3, Medium, fixed in #151): a direct update of `telephony_number.is_counted` by the Ingest login removed a line's calls with an audit trail naming no person (observed locally); the trigger now asserts the acting person's right.
4. AUD-010 (5.3, Medium, fixed in #151): the audit log kept five copies of every webhook payload per `ingest_event` and was the database's growth driver; the payload is now left out of the images. Retention and partitioning remain with CMA-003 and CMA-026.
5. AUD-011 (5.3, Medium, fixed in #151): the `(p is null or col >= p)` bound pattern kept the time indexes out of use in the Calls, Inbound and Speed to lead cores, so every report scanned the tenant's history; now sargable `coalesce` bounds.
6. AUD-007 (5.2, Medium, fixed in #157): the every-minute ingest jobs had no single-flight guard, so a slow vendor night could pile up ten executions and 60 to 90 extra connections; now an advisory lock per job.
7. AUD-017 and AUD-020 (5.5, Medium, fixed in part by #159, #157 and #151): no statement, lock or idle-in-transaction timeout existed anywhere; the web and ingest pools now carry them and the 0008q migration runs with a lock timeout; the README convention line is still to write.
8. AUD-021 (5.5, Medium, fixed in part by #152 and #153): events parked as `needs_review` after about four hours of a vendor outage had no clearing path and no Data quality row; System health now shows them per connection; the in-app retry or drop action is proposed.
9. AUD-022 (5.5, Medium, proposed): one alert policy exists (ingest 429); nothing watches 5xx, latency, failed jobs, Cloud SQL capacity, reachability or certificates. Console-only steps for Martin are written out in the CSV and the area file.
10. AUD-025 (5.6, Medium, proposed): `cma.follow_up_summary` re-derives the whole lead history on every call and is called every 10 seconds per Live board viewer and on every supervisor's Welcome; a tenant setting bounding the lookback plus two partial indexes is proposed as the next migration pair.

Also worth knowing: AUD-032 (hydration mismatch from Node's and Chrome's ICU versions, live in prod for English users; Pulse4all-com/cma#160), AUD-031 (the Database connection budget paragraph missed the email poll: 83 becomes 86 and the spare 7; report PR), AUD-008 (secret names on connection rows are not scoped to a tenant; proposed, Medium) and AUD-023 (no restore has ever been rehearsed; proposed).

## Open proposals (the backlog candidates)

`BACKLOG_CANDIDATES.md` groups them as before the soft launch, in the first month and later. The main ones:
alert policies and uptime checks (AUD-022); a quarterly PITR restore drill (AUD-023); badge contrast and the
focus ring as a style decision (AUD-036); pinning the rest of `cma-web`'s Cloud Run settings (AUD-019);
tenant-scoped secret names (AUD-008); the parked-events resolve action and Data quality row (AUD-021); the
Live board composite read (AUD-024) and the follow-up lookback bound (AUD-025); `calls_filter_values`
(AUD-028); a copy `fill()` helper (AUD-029); concurrency and proxy tests (AUD-030); a deny list for personal
property names in the slot mapping (AUD-071); CSP step 2 with a nonce (AUD-006); the structural Shell and
loading-skeleton change (AUD-035); `outbox.late_minutes` as a tenant setting (CMA-039, AUD-070); the count in
the line switch-off dialog (CMA-020, AUD-091); `cma_app` deletes to validity columns (CMA-060, AUD-012);
audit-log retention and partitioning (CMA-003 and CMA-026, AUD-010).

## Questions Martin asked to be checked next (dated)

- About 30 November 2026: the Shopify `read_all_orders` scope. Without it the Admin API serves the last 60
  days of orders, enough for the backfill from 1 October 2026 until about 30 November 2026; an older backfill
  after that needs the scope, and how to obtain it is an Open decision (README Open decisions; the Shopify
  section of `docs/ingest/README.md` and `docs/ingest/PROD_RUNBOOK.md` 9.2). Check whether the decision was
  taken and whether the backfill window decision (customers all, orders 13 months) still holds.
- About 12 to 13 November 2026: the Cloud Armor rate limits (600 requests per minute per IP since 12 October
  2026, 2,400 on `/shopify/` since 13 October 2026) are to be reviewed after the first month of real webhook
  volume, from the prod records and the `cma-ingest 429` alerts (README Open decisions and Decision log).
  Check the records folder for the volume figures and whether the thresholds were changed.
- Also dated in the README: the first monthly bill on the dedicated core (about 1 to 5 November 2026, the
  150-euro budget alert to raise to the observed level; CMA-034); email deletions (a deletion subscription or
  a nightly comparison, about 16 November 2026); the DST night of 24 to 25 October 2026 (confirm on 26
  October that the reconcile ran once at its new 03:30 time); the aggregation of agent data older than a
  year (CMA-026) before 2 January 2027, with the retention job (CMA-003) riding on it.

## What you are asked to do

(a) After the PRs above are merged, re-verify every finding whose status in `FINDINGS.csv` starts with
`fixed` against `main`: read the code at the file and line the evidence column names and confirm the
recommendation is in place; where a status says `(partly)` or `(pending PR)`, say what is in and what is not.
Report a finding as fixed only when you have seen the change on `main`.

(b) Take the rows with status `proposed` (and the remaining parts of the `(partly)` rows) as your backlog
candidates, in the grouping of `BACKLOG_CANDIDATES.md`, keeping the AUD ids so the two documents stay
linked. Where you disagree with a severity or a placement, say so with the reason; do not re-derive the
findings from scratch.

(c) Do not re-report what the README has decided. The `readme_check` column tells you, per finding, whether
the point is settled (with the Decision log date), already open (with the Open decisions bullet or the
backlog id) or new. A settled point is mentioned only when new information would change it, in one line.

Write in English, in plain Markdown, with "observed", "expected" and "estimated" kept apart, file and line
references for every claim, and no personal data of any kind.
