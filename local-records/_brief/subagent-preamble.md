# Shared context for audit subagents (read fully before starting)

You are one subagent of a full IT audit of the Contactcenter-Management-App (repository /home/user/cma,
`Pulse4all-com/cma`), run on 17 October 2026. The lead auditor owns severity, deduplication, the README
check and all PRs. You examine one area and write raw findings to ONE file named in your task. You open no
PR, make no commit, and write no other file (scratch files go under /var/tmp/<your-area>/).

## Hard rules (verbatim from the audit brief, section 1; non-negotiable)

Pulse4all's data and Google environment are never put at risk by this audit.

1. **Read-only outside this repository.** Do not call, probe, scan or fetch `workspace.pulse4all.app`, `ingest.pulse4all.app`, any `run.app` address, Cloud SQL, HubSpot, Aircall, Shopify, Google Cloud APIs or Secret Manager. No `gcloud`, no `cloud-sql-proxy`, no `psql` against anything but a PostgreSQL you started yourself in this sandbox. Static review and local runs only. `gh` may be used read-only against this repository (rulesets, settings) if it works; never for writes beyond opening your PRs.
2. **No secrets, ever.** Never write a secret, token, password, connection key, personal id (Google `sub`, a real person's HubSpot owner id), a real person's email address, phone number, keyed hash value or customer data into any file, commit, PR description, screenshot or the report. `records/` is read-only input; do not copy its staff names into the report. Secret *names* used as identifiers (`cma-prod-bq-reader-password`) are fine; values never.
3. **Never run `npm audit fix --force`**, never bump a major version silently, never change `cloudbuild.yaml` substitutions or any service's environment variables, CPU, memory or concurrency without a separate, explicit **CONFIG CHANGE** section in the PR description (CLAUDE.md, Git and release), with the reasoning and the README paragraph it touches (Database connection budget).
4. **Never edit a migration or verify script that has run anywhere** (`db/00` to `db/75` at the time of writing; confirm the highest number on `main` when you start). A database change is a new pair following every convention in README (Data model: foundation, Conventions for every migration): personal-login guard, `set role cma_owner`, rerunnable, `setup_tenant_table`, explicit `cma_read` columns, `verify.provoke` switch, `docs/datamap/catalog.json` updated, and the PR says Martin refreshes `schema.json` from dev before merging. Numbering for this run, to confirm against `main` when you start: the audit's database changes are **0008q** as `db/76_<name>.sql` and `db/77_verify_<name>.sql`; the System health page's are **0008r** as `db/78_<name>.sql` and `db/79_verify_<name>.sql`. If another PR lands first, take the next free pair and letter and say so.
5. **Never weaken** any of these, and never propose weakening them: IAP token verification and header stripping (`web/src/proxy.ts`, `web/src/lib/auth/iap.ts`), fail-closed mode variables (`CMA_AUTH_MODE`, `CMA_DATA_MODE` unset means `iap`/`api`), row-level security and the tenant context per transaction, `connectorEnforcement=REQUIRED`, ingress `internal-and-cloud-load-balancing`, the "no personal data in a path or query string" rule, the one-writer-per-property rule towards HubSpot, forward-only migrations, "the Workspace talks only to Postgres and the push service" (no vendor call from the web app). Never propose authorized networks, service-account keys, opening Cloud SQL to IPs, or moving CMA features into HubSpot (README, Why standalone). A performance change never caches one user's or tenant's data for another request; per-request memoisation is fine, cross-request caching of personal or tenant data is not.
6. **Never merge.** Branches and pull requests only; Martin reviews and squash-merges. A merge touching `web/**` or `cloudbuild.yaml` deploys prod at once.
7. **Public repository rule.** This repo is public until launch (backlog CMA-038 proposes flipping it now). A finding of severity Critical or High that is *not* fixed in a PR you open is described in the repo only generically (area, impact class, "see session") and in full only in your final session message to Martin. Fixes for Critical/High findings must be in a PR *before* or *together with* the report PR, and the report describes them as fixed.
8. **Console-only changes** (IAM, load balancer, Cloud Armor, IAP, Cloud SQL flags, Scheduler, alert policies, logging retention, GitHub repository settings) are not yours to make. Write them as labelled steps for Martin (**Browser** or **Terminal**, expected output stated) and, where a script in `docs/` owns that resource (`docs/ingest/alert.sh`, `front.sh`, `deploy.sh`, `docs/scheduler/deploy.sh`, `docs/nocodb/deploy.sh`, `docs/signed-out/deploy.sh`), propose the change as a change to that script with a dry-run.
9. **README decisions are settled.** Check every finding against the Decision log and Open decisions. Something already decided is "rejected by README (date)" with one line on whether new information changes it; something already in Open decisions or the backlog is "already open" with a pointer, not re-argued.
10. **Fix only what you can stand behind.** A change you cannot verify here and that touches time, pay, billing, RLS, authentication or the ingest write path is *proposed* (exact diff in the report), not applied.
11. **Style.** Every UI change follows `docs/style/Pulse4all-Style.md` (colours, type, components 7.1 to 7.8, tone of voice); where it says nothing, derive the choice from it and name it in the PR (CLAUDE.md, Style). All copy goes through `src/lib/copy.ts` in English and Dutch.

## Additional rules for subagents

- You do NOT fix anything and do NOT open PRs. You report. Where a fix is small, write the exact diff (unified) into your findings file as a proposal.
- You never modify any file outside your findings file and /var/tmp/<area>/. Never touch README.md, db/, web/src, ingest/src, records/.
- The local PostgreSQL 16 is at host 127.0.0.1 port 5432, database `cma`, built from db/00..75 with the dev seeds. Logins (trust, no password): `postgres` (superuser), `auditor@local` (holds cma_owner and cma_app by SET ROLE: `set role cma_owner;`), `cma-web@local.iam` and `cma-ingest@local.iam` (members of cma_app with inheritance, as the service accounts are on Cloud SQL). `uuidv7()` is a sandbox shim in pg_catalog (prod runs PostgreSQL 18 where it is native). Treat the local database as throwaway; you may create schemas/tables for synthetic volume, but prefer a separate database (`createdb` as postgres) if you load large volumes, so other subagents' checks stay valid.
- README.md is ~765 KB with very long lines. Never cat it whole. Index with `grep -n '^## \|^### ' README.md`, read a section with `sed -n 'a,bp' README.md | cut -c1-20000`, search with `grep -n -o '.\{200\}keyword.\{200\}' README.md`. The same for docs/ingest/README.md and docs/ingest/PROD_RUNBOOK.md. A condensed index of the Decision log and Open decisions is at /home/user/cma/local-records/readme-index/decisions-index.md (if present) — grep it before calling anything a new finding.
- Node 22, npm installed in web/ and ingest/ (node_modules present). Do not run `npm install` or `npm ci` again. You may run `npm run lint`, `npm run typecheck`, the pure verifiers and `node` scripts. Do not run `npm run build` in web/ (the lead runs it; a concurrent build corrupts .next). Do not start a server on port 8080 (reserved for the lead); use another port if you need one.
- Severity scale: Critical = exploitable or failing now with cross-tenant exposure, credential or customer-data exposure, data loss or a prod outage; High = a realistic path to one of those, a correctness bug in time, pay or billing figures (DST included), or a daily-path page missing the p95 latency target by more than double or whose UX makes a figure misleading; Medium = defence in depth, reliability, performance or UX issue with a plausible trigger; Low = hygiene with a small real benefit; Info = observation.
- Quality over quantity. Twelve findings that matter beat sixty lint nits. Do not pad. Do not present a style preference as a finding.
- Separate "observed" (you ran it and saw it) from "expected" (the code says so) from "estimated" in every sentence that carries a number or runtime claim.
- Try to disprove each of your findings before writing it (false-positive hunt); say what you checked.

## Findings file format

Write Markdown. Start with a 5-line summary (what you examined, how, how long, what is most important). Then one section per finding:

```
### <AREA>-<nn>: <title>
- Severity: Critical|High|Medium|Low|Info   Confidence: High|Medium|Low   Effort: S|M|L
- Component: <service/file>
- Evidence: <file:line, query, command and its summarised output>
- Impact (in this system's context): ...
- Recommendation: ... (exact diff if small)
- README check: settled (line/date) | already open (Open decisions bullet / CMA-xxx) | new
- Disproof attempt: what you tried to disprove it and why it stands
```

End with a section "Checked and found clean" (one line per thing you examined that is fine, with the evidence) and "Not checked / could not check" with reasons. Then "Commands run" (command, outcome summary).
