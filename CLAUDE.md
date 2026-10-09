# CLAUDE.md: working rules for Claude Code in this repository

## Source of truth
- README.md is the source of truth for scope, architecture, source-of-truth rules, roles, features, KPIs, roadmap, Decision log and Open decisions. It is large: read the sections relevant to the task, and refer to them by name. Treat its decisions as settled unless asked to reopen one.
- docs/RUNBOOK.md describes how changes are built, merged, released and verified.
- web/CLAUDE.md and web/AGENTS.md hold the Next.js rules for web/. Read them before touching web/.
- Write everything in English: code, comments, SQL, docs, commit messages and PR descriptions.

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
- In this session, run in web/: `npm ci`, `npm run build`, `npm run typecheck`, `npm run lint`, and the pure verifiers (`npm run verify:copy`, `verify:corrections`, `verify:csv`, `verify:dashboard`, `verify:live`, `verify:team`, `verify:roster`, `verify:configuration`). Report the results in the PR. Verifiers that need a server or a database (`verify:api`, `verify:theme`, `verify:layout`, `verify:iap`, `verify:scheduler`) and every db/ script are run by Martin in Cloud Shell or Cloud SQL Studio.
- Never write to records/: it holds outputs of real runs only. Never create, edit or backdate a record.
- Never change cloudbuild.yaml substitutions or environment variables without saying so explicitly in the PR.

## Database (db/)
- Scripts are numbered and run in order; a change is a new script plus its verify script (for example `32_<name>.sql` and `33_verify_<name>.sql`), not an edit to a script that has run in prod. Every new tenant table gets `cma.setup_tenant_table(table)`.
- Follow the conventions in README (Architecture, Data model sections): error codes, permissions, the provoke switch in verify scripts.

## Security and data
- No secrets, tokens, passwords or connection strings in code, commits, PR descriptions or setup scripts.
- No real personal or customer data in code, fixtures or tests; use the dev seed.
- V1 authentication is for building and testing only; V2 (OAuth with HubSpot) must be in place before real go-live.

## Instructions for Martin
- Every command block in a PR description or reply is labelled with where it runs: **Studio** (SQL in Cloud SQL Studio, naming the instance cma-dev-pg or cma-prod-pg), **Terminal** (Cloud Shell, in ~/cma unless stated), **Browser** (a page or click path) or **File** (a repository path). Never mix SQL and shell in one block.
- Give one step at a time and state the expected output.
- When a decision is made or something changes, update README.md in the same PR (Decision log entry, affected sections, the "Last updated" pass line).
