# local-records: the raw outputs of the full IT audit of 17 October 2026

What the audit's sandbox produced, kept as evidence for `docs/audits/2026-10-17-full-audit/`. Everything here was observed locally (a container with the repository, a PostgreSQL 16 built from `db/00` to `db/75` with the dev seeds, the standalone Next.js build on loopback, mock sign-in); nothing comes from dev or prod, and nothing here is a `records/` entry (those hold Martin's own runs only). Free of secrets and personal data: the identities are the dev seed's `example.com` people and the mock subjects; addresses in verifier fixtures are `example.invalid`.

| Directory | Holds |
|---|---|
| `_brief/` | the rule set every area review and fix worked under (the brief's hard rules, verbatim, with the findings format) |
| `5.1-web-security/` … `5.14-ux/` | one `findings.md` per area with id, severity, confidence, effort, evidence (file and line, command, output), impact, recommendation, README check and the disproof attempt; some areas carry drafts the report finalised (`5.13-readiness/`, `5.14-ux/`) |
| `5.6-speed-measured/` | time to first byte per route and mock subject before (`ttfb-mock.txt`, `ttfb-api-localdb.txt`) and after the speed PR (`ttfb-api-localdb-after.txt`); transactions and statements per request before (`round-trips-api.txt`) and after (`round-trips-api-after.txt`); the idle-transaction check (`idle-tx-check.txt`) |
| `db/` | the local build of the database from `db/00` to `db/79` and every verify script's output, including the reruns after 0008q and 0008r |
| `ux/before/`, `ux/after/`, `ux/health/` | screenshots of every page per mock subject at 1280 and 1600 px before the UX fixes, the changed screens after them, and the System health page |
| `web-baseline/` | the build, typecheck, lint and verifier outputs of `main` at the start of the audit |
| `7.4-cockpit/` | the eight README edits of the cockpit concept with their anchors (applied in `Pulse4all-com/cma#156`) |
| `readme-index/` | an index of the README's Decision log and Open decisions used for the "README check" of every finding |

The command log that ties these files to the report's claims is `docs/audits/2026-10-17-full-audit/METHOD.md`, section 4.
