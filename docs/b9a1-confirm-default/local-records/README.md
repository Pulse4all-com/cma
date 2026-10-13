# Local run of brief B9a.1 (irreversible confirmations open on Cancel), 13 October 2026

Claude Code's local runs, not a release record. No migration: `db/` and `ingest/` are not changed.

**Build:** the standalone build of `web/` (Next.js 16, Node 22.22) in mock auth and data, one server per language (`CMA_DEFAULT_LOCALE=nl` for Dutch). The browser is the session's pre-installed Chromium (141), mapped to the revision Playwright 1.63 expects; the verifiers ran unchanged apart from the new block in `layout.mjs`.

| File | What | Result |
|---|---|---|
| `typecheck.txt`, `lint.txt`, `build.txt` | `npm run typecheck`, `npm run lint`, `npm run build` | all exit 0 |
| `layout.txt`, `layout-provoked.txt`, `layout-after-provoked.txt` | `verify/layout.mjs` with the new irreversible-confirmation checks, normal, `--provoke`, then normal again on the same server | `layout: PASS`; provoked `FAIL (12 problems)`, six of them the new checks (the confirmation not opening on Cancel on Lines, Teams and the planner; the box unticked while the confirmation is open and after Enter; Enter at open calling the lines route); the normal run afterwards passes, so the mock stands as before |
| `layout-new-checks-on-main-build.txt` | the new `layout.mjs` against a build of `main`'s components (the dialog before this change) | `FAIL (13 problems)`, all from the new checks: on Lines, Teams and the planner the confirmation opens on the confirm button, which is the primary style with the `Enter` keycap, and Enter at open writes (`PUT …/lines` with `isCounted: false`, `PUT …/teams/en/dissolved`, `POST …/roster/weeks/…/copy`). The box itself already stayed ticked while the dialog was open on `main` (the checkbox is controlled) |
| `theme.txt`, `theme-provoked.txt`, `hints.txt`, `hints-provoked.txt` | `verify/theme.mjs` and `verify/hints.mjs`, normal and `--provoke` | `theme: PASS (33 pages …)`, provoked `FAIL (5 problems)`; `hints: PASS (91 headers and 20 tiles …)`, provoked `FAIL (1 problems)` |
| `verify-<name>.txt`, `verify-<name>-provoked.txt` | the pure verifiers CLAUDE.md names, normal and `--provoke` | all PASS (`configuration` 92) and all provoked checks failed; `copy` 1061 keys, its provoked run exits 1 with 5 problems, as designed |
| `confirm-browser-check-en.txt`, `confirm-browser-check-nl.txt`, `confirm-browser-check.mjs`, `screenshots/` | the four irreversible confirmations in Chromium, English and Dutch | 19 of 19 in each language. Lines: opens on Cancel, the confirm button outlined in the error colour without a keycap, the sentence of 0008f, Enter at open and Esc cancel without a write, the box ticked throughout, a click on the confirm button saves once (`isCounted: false`) and the box unticks after the save, ticking it again does not ask. Dissolve on Teams, Copy previous week on the planner (C) and End workday on My day (E, after clocking in through the API): open on Cancel, the style, Enter cancels without a write. Screenshots of each dialog at open and of Lines after a confirmed switch-off |

Not run here: `verify:api` (it calls no confirmation), `verify:iap`, `verify:scheduler` (Martin's, against dev or a server).
