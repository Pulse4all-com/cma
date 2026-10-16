# CLAUDE.md: working rules for Claude Code in this repository

## Source of truth
- README.md is the source of truth for scope, architecture, source-of-truth rules, roles, features, KPIs, roadmap, Decision log and Open decisions. It is large: read the sections relevant to the task, and refer to them by name. Treat its decisions as settled unless asked to reopen one.
- docs/RUNBOOK.md describes how changes are built, merged, released and verified.
- web/CLAUDE.md and web/AGENTS.md hold the Next.js rules for web/. Read them before touching web/.
- Write everything in English: code, comments, SQL, docs, commit messages and PR descriptions.

## Style
- docs/style/Pulse4all-Style.md is the style of everything the CMA shows. Every UI change follows it: colours, type, components (7.1 to 7.8) and tone of voice for copy.
- Where two rules meet, the more specific wins. Where it says nothing, derive the choice from it and name it in the PR; never pick freely.

## Principles
1. Configurable, not tailor-made: markets, skills, statuses, thresholds, SLAs and rules are tenant configuration or seed data, never code. Nothing Pulse4all- or vendor-specific is hardcoded; vendors sit behind adapters.
2. Multi-tenant and role-based from the first line: every table is tenant-aware (`cma.setup_tenant_table()` for RLS, grants and audit), every query and route respects role permissions.
3. Open: data is reachable through the API (`/api/v1/...`).
4. Step by step: the smallest working version, but the clean option over the shortcut.
5. One source of truth per data type (README, Source of truth). Postgres mirrors the owning system and never overrules it. HubSpot stays the CRM; never propose moving CMA features into HubSpot.
6. Data first: flag when a feature or metric depends on a HubSpot or Aircall data prerequisite that is not in place.
- The CMA UI shows no customer data: ids, statuses and links to HubSpot or Aircall only.
- Flag anything that weakens configurability, tenant separation, security, data protection or the source-of-truth rules.

## Git and release
- Never push to main; it only accepts pull requests (repository ruleset). Work on a branch, open a PR, never merge it yourself. Martin reviews and squash-merges.
- A merge to main that touches web/** or cloudbuild.yaml builds and deploys PROD (Cloud Build trigger cma-web-main). README, db/, docs/ and records/ do not build.
- One increment per PR, small and reviewable. The PR description states what changed, why, how it was checked, and what Martin still has to run.
- In this session, run in web/: `npm ci`, `npm run build`, `npm run typecheck`, `npm run lint`, and the pure verifiers (`npm run verify:copy`, `verify:corrections`, `verify:csv`, `verify:dashboard`, `verify:live`, `verify:team`, `verify:roster`, `verify:configuration`, `verify:messages`, `verify:import`, `verify:datamap`, `verify:signed-out`, `verify:invitations`, `verify:preview`, `verify:follow-up`). Report the results in the PR. Verifiers that need a server or a database (`verify:api`, `verify:theme`, `verify:layout`, `verify:iap`, `verify:scheduler`) and every db/ script are run by Martin in his own terminal or Cloud SQL Studio.
- records/ holds outputs of real runs only. Write a record only when Martin supplies the values from his own runs (ids, counts, times; no keys, secrets or personal data), and say in it that it was written down from his report, as in PRs #120 and #121. Never invent a value, alter what a record already says, or backdate one; a later run is added as its own section or record.
- Never change cloudbuild.yaml substitutions or environment variables without saying so explicitly in the PR.

## Database (db/)
- Scripts are numbered and run in order; a change is a new script plus its verify script (for example `32_<name>.sql` and `33_verify_<name>.sql`), not an edit to a script that has run in prod. Every new tenant table gets `cma.setup_tenant_table(table)`.
- Follow the conventions in README (Architecture, Data model sections): error codes, permissions, the provoke switch in verify scripts.
- A PR that adds or changes a table, view or column in cma or cma_read updates docs/datamap/catalog.json (a `what` and `how` for each new table, an entry for each new computed view) and says in its description that Martin refreshes docs/datamap/schema.json from dev on this branch after running the migration there, before merging; until then verify:datamap fails on this branch, which is expected. A change to how or how often a source fills a table (webhooks, job schedules, catalogs) updates that table's `how` in the same PR.

## Ingest (ingest/, docs/ingest/)
- No ingest route takes personal data in its path or query string: the path holds the adapter and the connection key (an identifier, not a secret), secrets travel in headers or signatures, data in the body. Cloud Run's request log keeps the URL (Decision log, 12 October 2026).

## Security and data
- No secrets, tokens, passwords or connection strings in code, commits, PR descriptions or setup scripts.
- No real personal or customer data in code, fixtures or tests; use the dev seed.
- Authentication follows README (Authentication): Pulse4all signs in with Google Workspace through IAP; the app verifies IAP's signed token on every request and matches people on their external id, never on email. Never trust plain identity headers or weaken this check; mock identities exist in dev only.

## Instructions for Martin
- Every command block in a PR description or reply is labelled with where it runs: **Studio** (SQL in Cloud SQL Studio, naming the instance cma-dev-pg or cma-prod-pg), **Terminal** (Martin's own Linux terminal: Chromebook Linux or his Linux machine, in ~/cma unless stated), **Browser** (a page or click path) or **File** (a repository path). Never mix SQL and shell in one block. A query that returns customer rows is a Studio block, never Terminal (README, Where a command runs).
- Give one step at a time and state the expected output.
- When a decision is made or something changes, update README.md in the same PR (Decision log entry, affected sections, the "Last updated" pass line).
