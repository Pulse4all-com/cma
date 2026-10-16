# Local records, night of 15 to 16 October 2026

These are the outputs of the night's local runs in Claude Code's container: PostgreSQL 16 from the distribution, Node 22, and the standalone build of `web/`. They are not release records; `records/` stays Martin's. No value here comes from dev, prod or GCP.

## `web/` (N16-A)

| File | What |
|---|---|
| `npm-ci.txt`, `typecheck.txt`, `lint.txt` | `npm ci`, `npm run typecheck` and `npm run lint` in `web/`, all exit 0. `npm run build` ran before the browser verifiers (exit 0, the build those runs used). |
| `verify-<name>.txt` | The pure verifiers CLAUDE.md names, each with its exit code: copy (1402 keys), corrections 31, csv 16, dashboard 17, live 39, team 26, roster 36, configuration 92, messages 24, import 23, datamap (72 tables, 89 views), signed-out 16, invitations 27, preview 18 (new), reports 75. |
| `layout.log`, `theme.log`, `hints.log` | The browser verifiers against the build in mock mode on a freshly started server: PASS. `layout` covers the folded rail (cookie and W), the hidden hints (cookie and ?), `aria-keyshortcuts`, breadcrumbs on six pages, preview as role for the admin and ignored for the manager and the agent, and the roster's week bar; `theme` 46 pages (four new: the folded rail on Welcome and Inbound, the preview banner, the roster); `hints` 233 headers and 59 tiles, with the keycaps hidden. |
| `*-provoked.log` | The same three with `--provoke`: FAIL with 41, 6 and 3 problems, as they must. |
| `verify-api-preview-mock*.txt` | `verify/api.mjs --preview` against the build in mock auth and mock data: 11 PASS, and provoked all failed. |
| `screenshots/` | From `verify/layout.mjs` at 1280 px: the folded rail on Welcome and Inbound, the admin previewing as the agent, the Sources detail with its breadcrumbs, the roster's week bar, My account with "What your role allows", and Speed to lead without the 80th percentile. |
