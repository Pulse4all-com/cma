# Night notes, N04: split shifts, clock in again (addition 0008zp)

Night of 3 to 4 November 2026, brief N04. Written by Claude Code while Martin was away. Everything was built and verified in the session's own container: PostgreSQL 16.15 with a local `uuidv7()` shim (Cloud SQL runs 18, which has it), `db/00` to `124` replayed in number order with the dev seeds rerun after every migration, Node 22, the standalone build of `web/` in mock mode and in api mode against that database. Nothing touched dev, prod, Google Cloud or a vendor; `records/` is untouched. The outputs are in `local-records/` (its `README.md` lists them); what Martin runs is in `MORNING_RUNBOOK.md`.

## What changed

- `db/126_workday_sessions.sql` (addition 0008zp): the setting `workday.clock_in_again` (boolean, default `false`), the rule `cma.workday_can_clock_in_again(workday, at)`, `cma.refresh_workday` for a day of one or more sessions, `cma.open_workday` that clocks in again under a lock. No table, view or column changes.
- `db/127_verify_workday_sessions.sql`: S1 and A1 to A10 of the brief, 31 checks.
- `db/02_seed_pulse4all.sql`: `workday.clock_in_again = true` for Pulse4all Subscriptions (a value it does not have yet only); Pulse4all Invest keeps the default.
- `web/`: the day carries `sessions`, `sessionStartedAt`, `clockInAgain` and `canClockInAgain`; the Clock in card's "again" variant on Welcome and My day; "Back since" on a day clocked in again; End workday, Log out and the signed-out page say until when one can clock in again; My hours and Team hours mark a day of several sessions; the day editor knows sessions; the mock follows the same rule and counts pauses from non-working stretches only; `verify/corrections.mjs`, `verify/live.mjs` and `verify/api.mjs` cover it.

## The number: 0008zp, 126 and 127, not 0008zo, 125 and 126

The brief named addition 0008zo and `db/125`, `db/126`, to be confirmed free on `main`. They were free on `main`, but #216 (Flash watch cadence, merged since and run in prod, #218) adds `db/125_flash_watch_cadence.sql` as addition 0008zo. Two additions with one version would collide quietly: the second to run would find the version recorded, its `on conflict do nothing` would write no row of its own, and its verify's "recorded" check would pass on the other's row. So this change takes the next free addition, 0008zp, and the next free scripts, `126` and `127`. It needs nothing of #216 (its prerequisite is 0008zn, `122`) and runs before or after it.

## Design

**One rule, in the database.** `cma.workday_can_clock_in_again(p_workday_id, p_at default now())` (SQL, stable, invoker, `cma_app` only) is true only when the day belongs to the current tenant and is ended; the tenant's `workday.clock_in_again` is `true`; the day's last effective event, in the views' order, is an end of source `user` (the person's own Log out or End workday); `p_at` lies strictly after it (N3); `p_at` falls on the day's business date in the day's zone; `p_at` lies within the window (`business_day_start` up to, not including, `business_day_end`); and the person's time is kept (`cma.time_is_kept`, 0003d: active and `workday.own`). `cma.open_workday` calls it, and so does the web's day read, so the card on the screen and the write cannot disagree. A day the scheduler ended (`system`), whose end a correction set or a supervisor added (`correction`), or that an import wrote (`import`) is not resumable (D3). The business-date clause is implied by the window, which lies within the date (00:00 to 24:00 at most); it stays because the brief names it (a mutation that drops it is not caught, see `local-records`).

**The day's shape.** `cma.refresh_workday` walks the effective events in the order every time view takes them, `occurred_at, recorded_at, id`, and accepts start, (status)*, end, start, (status)*, end, ...: the first event is a start; a later start directly follows an end and lies strictly after it; a status never directly follows an end; two ends never follow each other; so at most the last session is open. Each violation is `CMA04` with a message naming the rule ("has a status change between a clock-out and the next clock-in", "has two clock-outs without a clock-in between them", "has a clock-in again at or before the clock-out before it", "has a clock-in while a session is open", "has a status or end event before its start", "has no effective start event"). `started_at` is the first start; `ended_at` the last end when the last effective event is an end, else null; `status` follows (N6). A day of one start and at most one end is valid exactly when it was before, but for two events at one instant (build choice B1 below).

**Clock in again.** On today's ended day, when the rule holds at `p_occurred_at`, `cma.open_workday` locks the day (`for update`), checks the rule again under the lock, writes a start of source `user` in the tenant's default status (N4) and refreshes the day. Two tabs pressing at once give one start: the second waits for the first's lock, then its re-check (a new statement, so a new snapshot) sees the day open and returns it unchanged. Proven with two real connections (`local-records/db/concurrency-two-connections.txt`): tab B pressed one second after tab A, waited for A's lock and answered within a tenth of a second after A committed, with the open day and one new start in all; with the re-check taken out, `refresh_workday` itself refuses B's second start (`CMA04`), so the lock and the re-check give the clean answer and the shape rule is the floor. Every other case is today's (N5): an existing day is returned as it is, a new day only for a person whose time is kept and not before the window start. No maximum number of sessions (N2).

**The gap.** Nothing is written for it. A stretch begins only at a start or status event and runs to the next effective event of any kind, so the stretch before a log out ends at the end, and the end begins none: the gap yields no row in `cma.time_interval_all`, so it is in no figure (D2). Nobody is clocked in during it (`cma.is_clocked_in` reads an open day).

**The web.** The day read (`readDay`) and the team-now query read, in the same query, the day's effective starts (`sessions`), the latest one (`sessionStartedAt`), the tenant's setting (`clockInAgain`) and the rule at the database's now (`canClockInAgain`), through one lateral join; no view or function column changes, and a person's own entry on the board still equals `GET /api/v1/me/day` field for field. `HoursDay` and `TeamDay` gain `sessions` (Team hours through a subquery around `cma.team_hours`, whose columns stay). Welcome and My day show an ended day that can take another session with the Clock in card below it in its "again" variant (badge "Clocked out", "You can clock in again today until 22:00. Your status will be set to Available.", button "Clock in again", focus and Enter as before, the same route); an open day of more than one session keeps "Started at" (the first start) and adds "Back since" (the latest start); the clock needs no change (closed seconds plus the running stretch). End workday's confirmation, the Log out page and the signed-out page say until when one can clock in again while the setting is on and the window open, else today's text; the Log out warning adds that the time until the next clock-in is not counted. My hours marks "2 sessions" next to the date, Team hours as a neutral chip. The day editor derives each row's kind (the earliest row and a row directly after a clock-out are clock-ins with the Clock-in badge, the others status changes), refuses two clock-outs without a clock-in between them, and treats a row whose kind changed as a changed row.

## Night defaults (confirmed 4 Nov 2026)

Each is a Decision log row of 3 November 2026, "Night default (confirmed 4 Nov 2026)": Martin confirmed N1 to N7 and B1 to B7 as built on 4 November 2026, B4's Dutch words included, after a pre-check found no stored day that B1 refuses (`records/0008zp-precheck-2026-11-04`).

| | Night default | As built |
|---|---|---|
| N1 | A boolean setting `workday.clock_in_again`, universal default `false`; Pulse4all Subscriptions `true` in seed `02` | `126` section 1; `02`'s last block (`on conflict do nothing`, so a change survives a rerun); Pulse4all Invest stays `false` |
| N2 | No maximum number of sessions per day | No limit; `127` A3 takes a third session |
| N3 | A new session starts strictly after the previous end | In the rule (`p_at > end`) and in the shape (`start > previous end`); `07` block C still reads ended |
| N4 | A new session starts in the tenant's default status | `open_workday` writes the default status, as a first clock-in |
| N5 | Outside the conditions, Clock in on an ended day answers the day unchanged | No new error; `127` A1, A4, A5 |
| N6 | `started_at` the first session's start, `ended_at` the last end when the last effective event is an end | `refresh_workday`; columns and views unchanged |
| N7 | The hours export keeps its columns; the status-changes export gives each session's stretches | Unchanged functions; `127` A2 reads both exports |

Build choices of the night (confirmed 4 Nov 2026):

| | Choice | Why |
|---|---|---|
| B1 | Events at one instant are taken in the views' order (`recorded_at`, then `id`): a status recorded after an end at the end's own instant is refused now (`CMA04`) | Before, `0003` accepted it and `time_interval_all` then counted that status as an open stretch to the window end (a latent miscount). With sessions it would also count the gap. `127` A9 shows the one changed case |
| B2 | The day gets four fields, not the brief's three: `clockInAgain` (the tenant setting) next to `canClockInAgain` | The copy on an open day ("You can clock in again today until 22:00") needs the setting before the day ends, as `dayEndsAt` gives the window end; `canClockInAgain` is true only on an ended day |
| B3 | Day editor: a new or changed status or clock-in at the minute of a clock-out is a row problem ("This time is the same as a clock-out. Choose another minute"); at one minute a clock-out sorts after the other rows | The database takes one instant's events in the order they were written, so such a row would land after the clock-out (B1) and be refused; an untouched status at a clock-out's minute (the scheduler's `last_event` close) stays as it is |
| B4 | Dutch "sessie" for Session; "Opnieuw inklokken" for Clock in again; "Terug sinds" for Back since | Copy in the tone of the existing Dutch strings |
| B5 | The signed-out page behind IAP (`/logout/done`) says until when one can sign in and clock in again | Its old text "Your workday has ended for today" would be wrong on a day that can take another session; not named in the brief |
| B6 | The mock team fixture has one split-shift day (Ana, 09:00 to 13:00 and 17:00 to 21:00) | So Team hours in mock mode shows the marker |
| B7 | The day's shape is not under the setting: in every tenant a supervisor's correction may write a day of several sessions, where 0003 refused a second start; a day of several sessions stays valid when the setting is switched off | The setting governs the person's own Clock in again; gating the shape would make a later correction of an existing split day fail once the setting is off |

## Every function checked (brief 2.5 to 2.9)

Read against its current definition (the script named); none needed a change, so `126` redefines only `refresh_workday` and `open_workday`.

| Function or view | Current in | Verdict | Proven by |
|---|---|---|---|
| `cma.set_status` | `05` | Unchanged. Compares the time with `started_at` (the first start), refuses an ended day (`CMA03`); the web passes no time (now()), so a status lands in the open session. A time passed by hand into an earlier session would land there, as a time before the last status could before; a time in the gap is refused by `refresh_workday` | `127` A9; `verify/api.mjs` |
| `cma.end_workday` | `05` | Unchanged. Refuses an ended day; an end goes to the open session | `127` A2, A3 |
| `cma.correct_workday` | `46` | Unchanged. Its last step is `refresh_workday`, so a supervisor can add a second session, void an end and the next start to merge two, and Add day with two sessions (its first change is still the earliest start); no check assumes one start or one end | `127` A7; `10` unchanged |
| `cma.correct_time_event` | `46` | Unchanged, the same (one change, then `refresh_workday`) | `10` unchanged |
| `cma.close_forgotten_workdays` | `46` | Unchanged. An open later session is an open day: ended at the planned shift end, else `workday.auto_close_at`, never after the window end, never before the day's last effective event (so never before the session's start), source `system`, flagged, one notice and one digest | `127` A8; `47` unchanged |
| `cma.time_interval_all` | `46` | Unchanged: the gap yields no row; columns unchanged | `127` A2 |
| `cma.workday_summary_all` | `50` | Unchanged: sums the stretches; `needs_correction` and `current_status_id` as before | `127` A2, A8, A9 |
| `cma.team_now` | `19` | Unchanged. First start, the closed working stretches of every session, the running stretch of the open one; in the gap the day reads ended (the board's Clocked out). Today only, so not on `127`'s fixed date | `verify/api.mjs` (the own entry equals the own day, with the new fields), `verify/live.mjs` |
| `cma.team_day` | `50` | Unchanged: every event, effective or not | `127` A2 |
| `cma.team_hours` | `09` | Unchanged: the summary; the web adds `sessions` around it | `127` A2 |
| `cma.team_status_time` | `15` | Unchanged: one row per status, the gap in none | `127` A2 |
| `cma.export_hours` | `13` | Unchanged columns (N7): first start, last end, worked without the gap | `127` A2 |
| `cma.export_status_changes` | `13` | Unchanged: one row per stretch, so each session's start and end | `127` A2 |
| `cma.is_clocked_in` | `42` | Unchanged: an open day only, so nobody is clocked in during the gap (message targeting "only clocked in" skips them) | `127` A2 |
| `cma.load_import_batch`, `cma.void_import_batch` | `110`, `50` | Unchanged: an imported day is one session (start, gap statuses, end), valid under the new shape; the void calls no refresh | `51`, `111` unchanged; `127` A5 |

## Review

`cma-reviewer` reviewed the diff in four parts (the migration, the verify and seed, the day editor, the web data layer and screens), because the container restarted every ten minutes or so in the night and a single review was cut off twice before it answered; each part wrote its findings to a file as it went.

- **Critical, fixed:** the day editor ordered untouched rows by their HH:MM, so a valid day with a clock-out at 12:00:10 and a clock-in again at 12:00:40 would open with problems on rows nobody touched. Rows that keep their time are now taken at their stored instant (seconds kept, also in what is sent) and ordered as the database orders them; `verify/corrections.mjs` has the case (44 checks with the second round's two). A second-round review of the fix found no Critical and no Should fix; of its three Nice items, Add row at equal minutes and two more pinned verifier cases are done, the third (where atEnd shows when a clock-out is moved onto an untouched clock-in's exact instant) is left.
- **Should fix, fixed:** null-safe comparisons in `127` (A2's day events and Team hours, A8's notices, A3's seconds); `126`'s header names the all-tenant corrections (B7) and the second tie (B1); the Log out warning says the current session's start; "Back since" left-aligned (Style guide 4); Add row appends when the last session is open; seed `02`'s first guard names 0003b.
- **Nice, done:** a control in A5 (the day is resumable from its own tenant), A1 on the catalog default (the setting not set), an A6 row for A3 (31 checks), fixed roster instants in A8, the client caveat in `127`'s header, its temp table dropped, Team hours read in the function's order, the event id as the editor's last tie-break.
- **Nice, not done:** a notice when "Clock in again" is pressed after the window closed (the card simply disappears on the refresh); watching the Live board's read if the team grows (one rule call per person).

## Proven locally, and what was not

Proven (outputs in `local-records/`): `126` twice (`INSERT 0 1` then `INSERT 0 0`), `02` after it, `127` 31 PASS, provoked 0 PASS and 31 FAIL with every block failing, `127` against a database at 0008zn FAIL, nine mutations of `126` (eight caught; the ninth is the business-date clause the window implies), the two-connection clock-in, `07` (block C still ended), `10`, `14`, `16`, `18`, `20`, `47`, `51` and `111` unchanged against their run at 0008zn; the web's build, typecheck, lint and every pure verifier; `verify/api.mjs` against this branch's build in api mode on the local database: 281 PASS with the setting on (the branch that clocks in again), 281 PASS with it off, provoked all 281 failed; `main`'s build and `main`'s `verify/api.mjs` on a database at 0008zp with the setting on: 3 of 279 failed, exactly the checks that assume an ended day stays ended, so `main`'s web runs on the migrated database; a hand run of the flow in mock mode with screenshots.

Not proven here: PostgreSQL 18 (dev and prod run it; the scripts use nothing version-specific), the IAP sign-in after Log out (D1: Log out, Log in on the signed-out page, Welcome shows the card again; Martin's hand check in dev and prod), dev's data, and the branch's web in dev before the merge: dev runs the images prod's build makes, by short SHA (`docs/RUNBOOK.md` section 4; a dev-only web build is backlog CMA-068), so `verify:api` and the hand check against dev follow the merge in the morning runbook.

## After the rebase on `main` (4 November 2026)

The branch was rebased on `main` at `ca16bba` (#214, #216, #218 to #222 merged since the night); the conflicts were in `CHANGELOG.md`, `docs/decisions.md` and `docs/architecture/data-model/0008.md`, resolved by keeping both sides with this change's entries after `main`'s in date order, and the metric catalog's generated files were regenerated from the merged `catalog.json` (no difference). Martin confirmed N1 to N7 and B1 to B7 as built the same day, after a pre-check in dev and prod found no stored day that the new shape refuses (`records/0008zp-precheck-2026-11-04`). The checks were run again on the rebased branch (`local-records/`, `*-after-rebase.txt`): a fresh database replayed from `db/00` to `125`, then `126` twice (`INSERT 0 1`, then `INSERT 0 0`), `127` 31 PASS, provoked 0 PASS and 31 FAIL with nine blocks failed, `07` block C still `ended ended`; the web's build, typecheck (0 errors) and lint (0 errors, `main`'s two warnings) and every pure verifier as on `main` (`copy` 3397 keys, `corrections` 44, `flash` 64; `roster` with `main`'s known date-range failure); `verify/api.mjs` on that database with `web/verify/reports-fixture.sql` loaded: `ALL 324 PASS` with the setting on and with it off, provoked all 324 failed. Without the fixture four of `main`'s Flash checks answer 409 `not_set_up`, because a tenant without a shop or a CRM connection has no Flash file to give; dev has both.

## Found on the way (not caused by this change, not changed)

- `27_verify_configuration.sql` fails its A4 at 0008zn already ("2 scheduler role(s) with other permissions than workday.close_forgotten"): since 0008s the scheduler role also holds `follow_up.refresh`, and since 0008zn `flash.snapshot`. Before and after `126` alike; the verdict rows still read PASS. `27` has run in prod, so it is not edited; the fix is a later verify that checks the scheduler's set against the permissions its additions granted.
- `verify:roster` fails one check of 36 in this container on `main` too: the container's ICU formats the range as "12 – 18 October 2026" with spaces. Not this change.
- The browser verifiers (`theme`, `hints`, `layout`), run here against this branch's mock build and against `main`'s, report the same problems on both (1, 14 and 11), all on report pages this change does not touch (Attempts, Inbound, Calls, Funnel, the Reports accordion).
- `02_seed_pulse4all.sql`'s Flash block reads `cma.setting` without a `to_regclass` guard, so on a database before 0003b the seed errors at its end; dev and prod are long past that. The new block guards in two steps, as the window block does.

## Risks

- **A forgotten later session counts nothing until corrected.** With Pulse4all's `workday.auto_close_at` of 17:00 and no published shift, an evening session clocked in after 17:00 and never ended is closed at its own start (the rule's "never before the last event"), so it counts zero and is flagged for review. The same is true today for a person who clocks in after 17:00 and forgets. A published shift end avoids it.
- **The roster's adherence.** Split shifts are not in the roster (one entry per person per day), so during the gap adherence reads "left early". Out of scope (next steps).
- **Main's web between the prod migration and the merge.** With `02` run in prod the setting is on for Pulse4all Subscriptions before the new web is live. Main's screens offer no Clock in on an ended day (Welcome shows the ended card, the Clock in card only without a day), so nobody can clock in again through them; `POST /api/v1/me/day/start` would. A minute or two, then the merge.
- **Rollback.** `workday.clock_in_again = false` for the tenant (Studio) restores "an ended day stays ended" at once, without a deploy; days already of two sessions stay valid and counted.
- **Spain's daily registration.** Whether a split day, with each session's stretches in the status-changes export, is enough for Spain's daily registration of working time is a question for Yordi (Open decisions).

## Next steps (out of scope, nothing built)

- Split shifts in the roster: more than one entry per person per day, so adherence follows the sessions.
- A sessions column (or one row per session) in the hours export (the export's columns stay an Open decision).
- The agent proposing an end time for a forgotten session (the four-eyes path of Forgotten clock-outs).
- A configuration screen for `workday.clock_in_again` (no Configuration page lists the workday settings yet; the Configuration API and Studio set it).
