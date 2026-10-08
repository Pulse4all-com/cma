# Night notes: the build of 7 to 8 October 2026

Written at the end of the night chat, 8 October 2026, for Martin. README.md (fifteenth pass, in `night-05-readme.patch`) is the source of truth; this file says what the night decided on its own, what it left out, what it could not prove here, and what it found. The runbook for the morning is `MORNING_RUNBOOK.md`.

## 1. Two findings that come before the slices

**The repository is public on purpose.** `git clone https://github.com/Pulse4all-com/cma` succeeded from the night's container without any credential, which is what Martin intended: public until the launch, then private, so a build chat reads `main` without a zip (decision of 8 October 2026, in the README's Decision log). The night read it as an accident at first; this file and the README say it as a decision. No secret lives in the repository by design; while it is public, the README and `records/` name staff (roles, emails, Finn's first clock-in), which Yordi should know. Writing still needs a credential: a per-chat, repository-scoped, short-lived fine-grained token would let a build chat push branches and open the PRs; the patches stay the default.

**PR #39 did not carry the fourteenth README pass.** `main` at `d2d03e7` ("README: fourteenth pass …") holds a README whose last line says *eleventh pass* (943 lines). The thirteenth pass (`b330f57`, 967 lines) was on `main` before it; the fourteenth pass exists only as the file you uploaded (979 lines). The fifteenth pass was written on your upload and `night-05-readme.patch` replaces `README.md` whole, so its diff against `main` is large on purpose. Nothing else in the repository regressed: `db/`, `web/` and `records/` on `main` match what the fourteenth pass describes.

## 2. What the night built, per slice

| Slice | Branch and commit | Patch | What |
|---|---|---|---|
| 1 | `night-01-0004` | `night-01-0004.patch` | migration 0004 (`db/21_teams_skills.sql`), verify `22`, the Pulse4all teams and skills in `02`, the dev `admin` identity and the test people's memberships and skills in `03` and `06`, verify `14` made to pass after 0004, `records/0004-dev-2026-10-08/` placeholder |
| 2 | `night-02-team` | `night-02-team.patch` | the People screen (`/team/people`, Team group), the directory, roles, teams, skills, organisations and memberships routes, the team filter and column on the Live board, `src/lib/team.ts` with `verify/team.mjs` (18), the local `CMA_DB_HOST` path in `client.ts`, API verifier 89, `records/team-2026-10-08/` placeholder |
| 3 | `night-03-0005` | `night-03-0005.patch` | migration 0005 (`db/23_roster.sql`), the dev roster fixture `24`, verify `25`, `records/0005-dev-2026-10-08/` placeholder |
| 4 | `night-04-roster` | `night-04-roster.patch` | the roster planner, the print view, My schedule, the shift line on the Live board, the shift sentence on Welcome, the roster routes, `src/lib/roster.ts` with `verify/roster.mjs` (31), `verify/live.mjs` at 26, API verifier 111, theme 13 pages, layout 5 identities, `records/roster-2026-10-08/` placeholder |
| 4b | `night-04b-print` | `night-04b-print.patch` | found on the morning's first print in prod: the 1280px gate also fired on paper (A4 landscape lays out below 1280px), so the print dialog showed the gate; `DesktopOnly` gets `print:` variants; the sheet's time cells no longer wrap and the logo is the plain image; the saved-weeks browser lists written weeks only (`cma.roster_weeks()` is a calendar of the range) |
| 5 | `night-05-readme` | `night-05-readme.patch` | README fifteenth pass (whole file), `db/people_add_prod.template.sql` deleted, this file and the runbook under `docs/night-2026-10-08/` |

Every slice is complete on its own and was gated as the handover's section 5 asks: every `db/` script on a local PostgreSQL **18.6** (Cloud SQL runs 18; one minor behind) on top of `00` to `20` in the README's order, the verify passing and failing when provoked; every web slice through `npm run typecheck`, `npm run lint`, `npm run build`, the pure verifiers normal and provoked, theme and layout against the local mock server, and the API verifier normal and provoked against the local database through the new `CMA_DB_HOST` path (the verifier's output of the last run is in section 7).

## 3. Defaults the night took (each also in the README's Decision log, marked "to confirm")

From the handover's section 4, applied as given: cells are a shift or an absence, breaks are statuses; rosters per week per team or whole tenant; agents see published entries only; `roster.manage` edits and publishes (manager, admin), `roster.view` reads (every role but analytics); absence types are tenant rows; the Team group sits after Live; My schedule sits in the Time group; access requests are out; nothing hardcodes Pulse4all.

Taken beyond section 4:

1. **Routes.** `GET /api/v1/team/people` is already the time-kept list for Add day, so the Team screen's data lives at `/api/v1/team/directory` (list, add, `role`, `active`, `teams`, `skills` per person) plus `/api/v1/team/roles`, `/teams`, `/skills`, `/organisations`, `/memberships`; the roster at `/api/v1/roster/weeks[/{monday}[/cells|/publish|/copy]]`, `/api/v1/roster/absence-types`, `/api/v1/me/roster`, `/api/v1/team/shifts-today`.
2. **Who manages whom.** A managing role is one holding `users.manage_agents`, `users.manage_all` or `tenant.configure` (`cma.role_is_managing`). `users.manage_agents` may touch non-managing people and assign non-managing roles only (so a manager may also set someone to `analytics`); `users.manage_all` everyone. Nobody changes their own role or deactivates themselves; the last admin cannot lose the role. The rule is derived from permissions, never a role key.
3. **`add_person` takes the login id as given.** The numeric check on a Google id lives in the People screen's hint, not in migration code (a system name in a function would be vendor-specific). The template `db/people_add_prod.template.sql` is retired and deleted in slice 5.
4. **Validity as half-open `timestamptz`** on `team_member` and `user_skill`; a change ends the row and starts a new one. `skill_level` is a table per dimension; a dimension without rows is binary.
5. **Roster versioning.** Entries are versioned rows (`valid_to`, `superseded_by`); agents and the Live board read as of the week's latest publication (`cma.roster_published_entry`), the planner reads current rows; `roster_publication` logs every publish. At most one current entry per person per date across all rosters (a partial unique index; the second write is `CMA03`). Past days are locked for planning (today in the person's zone is open), any week ahead is open. `off` ("Day off") is a fifth seeded absence type, so a typed `off` differs from an empty cell.
6. **`clock_timestamp()`** for `recorded_at`, `valid_to` and `published_at` (found by verify B6: a publish and an edit in one transaction could not be told apart with `now()`).
7. **Adherence.** `roster.adherence_tolerance_minutes` is a tenant setting (default 5); the Live board's flags (late, left early, expected, absent, not planned) are derived in the web from the plan and the clock, never stored.
8. **Coverage.** Computed per team per work type per day from shifts and skills; optional `coverage_target` rows per team, work type and weekday (write function exists, no screen yet); one person is shown as a single-person dependency.
9. **Navigation.** A Team group (people icon) after Live with People and Roster; My schedule in Time after My hours. Agents keep keys 1 to 4; a supervisor sees seven pages, a manager or admin nine. The nav model gained any-of permissions (`holdsAny`) for People.
10. **Print as PDF.** A print view (`/roster/planner/print`, A4 landscape, the style guide's document rules) plus the browser's print dialog, whose Save as file gives the PDF: zero dependencies, theme-verified. A server-generated PDF (pdf-lib) stays the follow-up if a file for e-mail is wanted.
11. **Local database path.** `client.ts` opens a plain `pg.Pool` when `CMA_DB_HOST` is set (with `CMA_DB_PORT`, `CMA_DB_USER`, optional `CMA_DB_PASSWORD`); Cloud Run never sets it, so the connector path is unchanged. It is what let the API verifier prove the night's SQL end to end.
12. **Immediate per-cell saves** in the planner, with the state shown per cell, instead of the demo's whole-week Save and dirty guard: every write is an audited version and nothing is lost on a closed tab.
13. **The dev `admin` identity** (`admin@example.com`, mock subject `admin`) in `03` and `06`. In prod Martin and Joshua become `admin` by one Studio statement per person (the runbook, step 1.4): a migration cannot know who the builders are, and `cma.set_person_role()` refuses one's own role.
14. **Numbering**: `21` migration 0004, `22` its verify, `23` migration 0005, `24` the dev roster fixture, `25` its verify.
15. **Verify `14` changed** (slice 1): its A7 accepted `workday.export` on the manager only, and block B used the manager to configure; after 0004 the admin holds both and the manager has lost `tenant.configure`. It now accepts the admin and picks block B's configuring role by permission, so it passes before and after 0004 (checked both ways locally, normal and provoked). Verifies `16`, `18`, `20` pass unchanged after 0004 and 0005.

## 4. Left out, and why

- The status configuration screen, export formats, the scheduler for forgotten days, the agent desk, access requests: out by the handover.
- Skill filters on the Live board (the handover's "team and skill filters beyond the Live board" put the skill filter out of the night; the team filter is in).
- Coverage targets on a screen: the model and `cma.set_coverage_target()` exist; the planner shows a target when one is set. The configuration screens of step 5 get the editor.
- A server-generated PDF file (see default 10).
- Shift templates, swaps, requests, forecasting (Target scope, Rostering).
- An agent's own teams and skills on Welcome or My day and a My account panel: with the configuration screens.
- Supervisors on the planner: a supervisor holds `roster.view` and `monitoring.live` (own schedule and the shift line), not `roster.manage`. Whether a supervisor plans their own team is a grant for Arno and Kira, not code.

## 5. What could not be tested in the night

- **Nothing in dev or prod.** The night had no Google identity: no Cloud SQL, no Cloud Run, no Cloud Build. Every script ran on PostgreSQL 18.6 locally; every verifier ran against the local mock server and the local database. The morning runbook does the dev and prod runs and the hand checks; the `records/*-2026-10-08` folders are placeholders until then.
- **The real Docker build.** `npm run build` ran locally with the repository's settings (the same command the Dockerfile runs); Cloud Build itself runs after the merge.
- **IAP mode** (the identity headers, the `google` provider on the Add a person form): the night ran in mock auth. The print view and the planner behave the same in both modes.
- **`git apply` on `main`** was tested on a scratch clone of `d2d03e7` (section 7): all five patches apply cleanly in sequence.

## 6. Known risks

- **PostgreSQL version**: 18.6 locally against Cloud SQL's 18.x. The scripts use nothing beyond what `00` to `20` already use (`uuidv7()`, `unique nulls not distinct`, partial unique indexes, `clock_timestamp()`), all in 18.0.
- **The ladder change touches Martin's role.** Migration 0004 removes `tenant.configure` from the system `manager` row in every tenant. Martin is `manager` in prod until step 1.4 of the runbook sets him `admin`; between the two, no screen in prod uses `tenant.configure`, so nothing breaks, but do run step 1.4 before trying to add Joshua. Finn stays `supervisor` and is unaffected.
- **The roster's business-day rule.** A shift is local `00:00` to `24:00` in the person's zone; nothing crosses midnight (Martin, 7 October). A tenant with night shifts needs the `business_day_end` setting first (Open decisions).
- **Immediate saves and a slow connection.** A cell that fails to save shows its reason under the cell and keeps the typed text; nothing is retried on its own.
- **The theme verifier on the print view** checks the screen rendering, not paper. The print stylesheet (`@page` A4 landscape, `@media print`) was checked by reading, not by printing: do one Save as file in Chrome on the morning's hand check.
- **Verify `25` and the week boundary.** Block B plans "this week" and "next week" relative to the run; on a Sunday evening in UTC near midnight a date computed as this week could roll over. Not seen; mentioned because the fixture `24` and the API verifier also plan relative to today.
- **`records/layout/` screenshots**: the layout verifier wrote to a temporary folder in the night; the morning run writes the real ones into `records/layout/` for the commit, as before.
- **`npm audit`**: unchanged, 5 high in `eslint-config-next` (devDependency), no fix; documented in Open decisions.
- **The heads-up to Yordi**: drafted 7 October; whether it was sent is not known to the night. Open decisions carry the four questions.

## 7. The night's verify output (local)

`22_verify_teams_skills.sql` verdict: `pulse4all-invest | admin | admin | 0 | 0 | PASS`, `pulse4all-subscriptions | admin | admin | 5 | 11 | PASS` (roles with `tenant.configure`, roles with `users.manage_all`, teams, skills); provoked: `FAIL A2`, `FAIL B2`, verdict `PROVOKED, NOT A PASS`.

`25_verify_roster.sql` verdict: `pulse4all-invest | admin, manager | admin, agent, manager, supervisor | 5 | 0 | PASS`, `pulse4all-subscriptions | … | 5 | 3 | PASS` (roles with `roster.manage`, roles with `roster.view`, absence types, roster weeks); provoked: `FAIL A2`, `FAIL B1`.

`14_verify_tenant_settings.sql` after 0004: PASS, provoked `FAIL A2`, `FAIL B5`, `FAIL C1`. `16`, `18`, `20`: PASS after 0004 and 0005.

Pure verifiers: copy 388 keys PASS; corrections 26, csv 15, dashboard 17, live 26, team 18, roster 31: all PASS and all fail provoked. Theme: PASS, 13 pages; provoked FAIL. Layout: PASS, five identities; provoked FAIL.

API verifier against the local database (`records/team-local` and `records/roster-local` in the night's folder, copied under `docs/night-2026-10-08/local-records/` in slice 5): `ALL 111 PASS`; `ALL 111 PROVOKED CHECKS FAILED, as they must`.

`git apply --check` of the five patches in sequence on a fresh clone of `main` (`d2d03e7`): clean.

## 8. For the fifteenth pass's successor

Decisions to take with Arno on the first real week: the entry method (quick typing) and the absence types; whether supervisors plan; the coverage targets per team. With Yordi: nothing new in the night beyond what the heads-up already asks (rosters are staff data; the shift line is monitoring in the same sense as the Live board).
