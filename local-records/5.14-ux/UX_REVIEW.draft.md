# 5.14 UX and UI review: instant, calm, consistent, in the Pulse4all style (draft)

Audit of 17 October 2026, subagent 5.14. Static reading of `web/src` (every page, component, `copy.ts`, `nav.ts`, `globals.css`, the hook), the 82 mock screenshots under `local-records/ux/before/`, and live checks against the production build on 127.0.0.1:8080 (a `next-server` process; the dev server is on 8082) with Playwright and axe-core 4.x from `web/node_modules`. Mock data only. Scratch and scripts: `/var/tmp/5.14/` (`speed.mjs`, `nav.mjs`, `hydration.mjs`, `hydration2.mjs`, `axe.mjs`, `axe.json`, `contrast.mjs`). "Observed" = run here; "expected" = the code says so; "estimated" = inferred.

The tone of voice, the components and the palette are applied with unusual discipline: every string goes through `copy.ts` in both languages (verify:copy PASS, 1728 keys), every figure has a hint, every irreversible step opens on Cancel, the keyboard model is declarative and the theme is token-only. The defects below are mostly in the *dynamics*: what the screen does between a click and the answer, what it does when something fails, and what a keycap promises.

---

## 1. Perceived speed

Targets from the brief versus what was observed (production build, warm server, 1280 px, Chrome 141 via Playwright; concurrent load from other audit sessions, so treat the numbers as indicative to ±50 ms).

| Target | Observed | Verdict |
|---|---|---|
| Shell paints within 200 ms of a navigation even when page data is slower | There is no `loading.tsx`, no `error.tsx`, no `Suspense` anywhere (`find web/src/app` → 0). `Shell` is rendered *inside every page* (23 pages), not in `layout.tsx`, so Next cannot stream a shell first: nothing changes on screen until the whole RSC payload arrives. Client swaps measured (click → `main h1` changes): 140–370 ms first pass, 112–253 ms second pass (`nav.mjs`, `clientNav.pass1/2`). | Target missed structurally, but the swap is fast enough that a skeleton would often flash. The real gap is the next row. |
| A click gets visible feedback within 100 ms | During the swap nothing changes: no `aria-busy`, no cursor, `aria-current` on the rail flips only when the new page lands (`nav.mjs`, `feedbackDuringSwap`: exactly two states, before and after). Rail links carry no `prefetch`; a hover for 1 s triggered 0 RSC requests (`prefetchOnHover: []`), expected: with no `loading.tsx` there is no static part to prefetch. | **Missed** for every navigation (140–370 ms of nothing). SAFE fix: a pending state on the rail link with `useLinkStatus` (present in `next@16.3.8`, `node_modules/next/dist/client/app-dir/link.js`) and `prefetch` on the rail links; PROPOSAL: move `Shell` into a layout so Next streams it. |
| A status change or clock-in shows its new state at once and rolls back on failure (optimistic) | `ClockInCard.tsx:27-37` and `WorkdayPanel.tsx:173-185`: `fetch` then `router.refresh()`; the new state appears only after the full server re-render. Observed: clock in 176 ms button-disabled-with-no-text until the panel appeared; status change 131 ms until the badge changed, all five status buttons disabled meanwhile (`speed.mjs`, `status.samples`). Failure: `role="alert"` with `myDay.statusFailed` / `welcome.clockInFailed` in tone ✓. End workday (`WorkdayPanel.tsx:187-193`) awaits a server action with **no** catch: a thrown error has no boundary (no `error.tsx`) and would take the page to Next's default error screen (expected, not provoked). | Fast enough on this server that optimism is cosmetic; the **focus loss** is the real defect (section 4). The End workday failure path is a states defect (section 2). |
| No spinner without words after 1 s | No spinners exist. Pending words exist where a write can be slow: `dayEditor.loading`, `roster.cellSaving`, `configuration.saving`, `team.saving`, `invitations.creating`. Clock in and status change show a disabled button without words (fine under 1 s). | Met. |
| No layout shift when data arrives | CLS per page 0.0003–0.0061 (`speed.mjs`, `cls`), all from the top bar's unread badge mounting after the first poll (`DIV.flex.items-center.gap-5`, +0.0003) and, on Follow-up, a table re-layout (0.0057). | Met; the badge could reserve its width (Info). |
| Polls update a tile, not the page | `LiveRefresh.tsx:26` `router.refresh()` every 10 s: the whole page (Shell included, 6 reads on the Live board) re-renders on the server; filters and open hints survive (observed `liveBoard.filterSurvived: true`), no flash. The clock and "since" tick locally (`LiveBoard.tsx:72`, `WorkdayPanel.tsx:134`) ✓. Messages poll is a plain JSON fetch (`MessageCenter.tsx:88-120`) ✓. | Acceptable fallback; settled (Decision log 1747, 1989; realtime service is Open decision 2097). Cost note only. |
| Double submits | Every write button disables while pending (`disabled={pending}` in ClockInCard, WorkdayPanel, DayEditor `canSave`, PersonDialog, InviteDialog, MessageComposer, Inbox, RosterPlanner); configuration checkboxes do not disable during `useSave` (idempotent PUTs, harmless). | Met. |

Server TTFB (the lead's measurement, p95 ≤ 77 ms) is not the bottleneck; the client has nothing to show while it waits.

## 2. States

Loading: none of the pages has a loading state (no `loading.tsx`, no skeleton). Error: no `error.tsx`, `global-error.tsx` or `not-found.tsx` exists, so a data error or a mistyped address shows Next's default page: observed `GET /nope` → "404 · This page could not be found." in Next's inline styles, English only, no shell, no Montserrat token (the `DesktopOnly` gate still wraps it). Every key named below exists in `en` and `nl` (verify:copy PASS checks every key in every language; the type `Copy = Deep<typeof en>` enforces it at typecheck).

| Page | Loading | Empty | Error | Success / refused |
|---|---|---|---|---|
| Welcome `/` | missing (full-page wait) | `welcome.updatesEmpty`, `welcome.waitingNone`; Needs attention shows `0` with a success badge (good) | clock-in: `welcome.clockInFailed` (alert); refused before the window: `welcome.clockInTooEarly` with the database's time (`ClockInCard.tsx:55-58`, the model refusal) | clock-in: card replaced by the open day (implicit) |
| My day `/day` | missing | Clock in card (the empty state is an action, good) | `myDay.statusFailed` (alert); End workday: **missing** (unhandled server action) | status change: badge changes, no announcement; End workday: `myDay.dayEnded` card |
| My hours `/hours` | missing | `myHours.empty` | `myHours.invalidRange` (custom range) | – |
| My schedule `/schedule` | missing | per day `mySchedule.notPublished` / `noShift` (7 rows always) | – | – |
| Messages `/messages` | missing | `messages.empty` | mark read / acknowledge failure: **silent** (`Inbox.tsx:58-63, 69-74`: `if (res.ok)` only; `messages.loadFailed` exists but is unused) | `messages.allRead`, badges Acknowledged |
| Send a message | missing | `messages.sentEmpty`, `messages.noPeople` | `messages.sendFailed`, `messages.nobody` (400 invalid) | `messages.sentTo`/`sentToOne` (Notice) |
| Live board | missing | `live.noPeople`, `live.empty` (filter), `live.missedEmpty` (filled with the lookback), `live.nobodyWaiting`, `reports.noTelephony` | poll failure: silent (fine) | – |
| People | missing | `team.empty`, `invitations.empty`; dialogs: `team.noTeams`, `linkedNoSystems` | `team.saveFailed/notPermitted/notFound/conflict/linkedTaken`, `invitations.*` (per status) | `team.saving`, `invitations.creating`, `invitations.readyTitle`, `copied` |
| Roster | missing | `roster.noPeople`, `noWeeks`, `noCoverage`; placeholder from the first absence type | per cell: `problemFormat/Order/Absence/Past/Conflict/Scope/SaveFailed`; `publishFailed`, `copyFailed` | `cellSaving`, `cellSaved`, `copied` |
| Team hours | missing | `teamHours.empty` | `teamHours.tooLong`, `myHours.invalidRange`; editor: `dayEditor.loadFailed`, `saveFailed/notPermitted/notFound/conflict`, row and day problems | editor closes, table refreshes (implicit); `dayEditor.loading` |
| Dashboard | missing | `dashboard.empty`; not connected: `reports.noTelephony/noShop` | `dashboard.tooLong`, `myHours.invalidRange` | `dashboard.cappedNote` (warning Notice) |
| Speed to lead | missing | `speedToLead.empty`, `openEmpty` | `reports.tooLong` | `minutesNote`, `totalNote` |
| Follow-up | missing | `followUp.leadsEmpty/ticketsEmpty/tasksEmpty/byOwnerEmpty/filteredEmpty` | – | – |
| Waiting for you | missing | `followUp.myEmpty` | – | – |
| Intake | missing | `intake.empty`; `reports.noTelephony/noShop` per column group | `reports.tooLong` | `intake.startNote` |
| Inbound | missing | `inbound.empty`; `reports.noTelephony` | `reports.tooLong` | `slNote` |
| Calls / Calls per agent | missing | `calls.empty`, `noConversations`; `callsPerAgent.empty`; `reports.noTelephony` | `calls.filterIgnored`, `reports.tooLong` | `deltaNoHistory` ("No history to compare yet") |
| Forms | missing | `forms.empty`, `answersEmpty`; `reports.noForms` | `forms.filterIgnored` | `changeNoHistory` |
| Data quality | missing | n/a (muted rows at 0) | – | – |
| My account | missing | `account.noTeams/noSkills/noEmployer/noRole/allowsNone` | – | – |
| Configuration pages | missing | `configStatuses.empty`, `configAppLinks.empty`, `configAlertRules.empty`, `configSources.empty`, `pipelinesEmpty`… ; **missing** on Absence types (`AbsenceConfig.tsx:68` renders the table unconditionally) and Markets (`MarketsConfig.tsx:129`) | `configuration.notSaved/notPermitted/notFound/invalid` + per-screen conflicts | `configuration.saving/saved` (SaveNote, role=status) |
| Any page, data layer throws | – | – | **missing**: Next default error page | – |
| Unknown address | – | – | **missing**: Next default 404 | – |

Refused actions explain the rule: the clock-in window (model), the frozen status flags (`configStatuses.flagsFrozen`), the roster past day (`problemPast`), the own-day correction (`teamHours.ownDay` as a title), the invite ceiling (`invitations.notPermitted`), the kind conflict (`configSources.kindConflict`). Good.

## 3. Consistency with the style guide

Checked against `docs/style/Pulse4all-Style.md` 2.x, 3.3, 4, 5, 7.1–7.8.

- Colours by meaning: status colours from flags (`lib/dashboard.ts:44-57` GROUP_BG/FILL), Leaf Green / Deep Blue / Light Blue / Soft Rose, always with a label or title (`DashboardCharts.tsx:28-31, 153-155`). Deltas as muted text with an arrow, never coloured (`CallsParts.tsx:72-104`), "No history to compare yet" ✓. No donuts, no red stacked bars; the only `tone="error"` fills are badges ("Over time", "Past target", "Overdue") ✓. The theme verifier proves palette-only painting.
- Type: dense scale tokens in `globals.css:43-56` (title 24, panel 18, body 14, small 13, caption 12, table line-height 1.4); headings `text-p4a-heading` ✓.
- Spacing: 8 px grid via Tailwind spacing (p-6 cards, gap-6 blocks, h-10 rows) ✓. Card radius 15 / padding 24 ✓ (`primitives.tsx:111`), button radius 4 ✓, inputs 40 px ✓, table header Background Blue 13 px semibold ✓, zebra `#FDFBF1` ✓, right-aligned numbers ✓ (`tabular text-right` throughout).
- Buttons: 7.2 says primary 48 px; the app's `Button` default `md` is 40 px and every in-page primary (Add day, Add a person, Publish, Send, Add rule) is 40 px; only Clock in, Log out and Accept are 48 (`primitives.tsx:18-23`, `ClockInCard.tsx:50`, `logout/page.tsx:39`). A derived choice for dense screens; name it in the README or set `lg` for the page primary. One primary per view ✓ (Publish turns primary only when there is something to publish, `RosterPlanner.tsx:371`).
- **ALL-CAPS**: `MessageCenter.tsx:225` and `:246` set `uppercase tracking-wide` on the toast kind label and the "Urgent message" label (visible in every screenshot as "URGENT MESSAGE"). Rule 4 "No ALL-CAPS, not in headings, labels, buttons or badges"; the copy verifier cannot see CSS. `TeamsConfig.tsx:105` uppercases market codes (codes, acceptable).
- Exclamation marks / trailing periods / all-caps in copy: verify:copy PASS (observed). Headings end without a period ✓.
- Locale: dates through `lib/time.ts` with `en-GB`/`nl-NL` ✓; week range via `formatRange` (CMA-061, observed "Week 42 12–18 October 2026" in `manager-1280-roster_planner.png`) ✓. **But** five places format with `new Intl.DateTimeFormat(locale === "nl" ? "nl-NL" : "en-GB", …)` outside `lib/time` (`Inbox.tsx:35`, `app/page.tsx:178`, `messages/send/page.tsx:34`, `RosterPlanner.tsx:357`, `roster/planner/print/page.tsx:44`), and `RosterPlanner.tsx:357` passes no `timeZone` (see section 10).
- Period bar, breadcrumbs, rail: consistent on every page (screenshots); the folded rail and `?` hints verified (`hydration2.mjs`: `data-hints="hidden"`, `kbd display none`, cookie set, `aria-pressed="true"`).
- Badge contrast fails the guide's own 7.8 minimum (section 7 below).

## 4. Keyboard-first and focus

- Hook (`useKeyboardShortcuts.ts:345-352`): ignores Ctrl/Alt/Meta (AltGr on Windows arrives as Ctrl+Alt → ignored, so Spanish keyboards are safe), ignores typing in inputs/selects/textarea/contentEditable, scopes to an open dialog, prefers a control inside `main` over the rail ✓. `e.repeat` is not filtered: holding a digit navigates repeatedly (Low).
- **Keycaps 10–18**: `nav.ts:211,214` numbers every visible page `String(++n)`; the hook returns on `e.key.length !== 1`, so a key "10" can never fire. Observed `data-shortcut` per subject (`nav.mjs`): supervisor 1–15, manager and admin 1–18, analyst 1–12; the Dashboard is "10" for the manager, every report 11–18. The README (Shell and navigation) still says "a manager or admin nine" and "numbered 1, 2, 3 without gaps"; the layout verifier checks gaps, not the ceiling. The agent (1–5) is unaffected.
- **Focus after a status change**: S → arrows → Enter works (`WorkdayPanel.tsx:143-171`), then every status button is disabled during the write (`disabled={isCurrent || pending}`, line 258) and the focused one loses focus to `<body>`; after the refresh focus is still on `<body>` (observed `status.activeElementAfterSettle: "BODY"`). The agent must press S again for the next change. The same after Clock in (`clockIn.activeElementAfter: "BODY"`): the card is replaced and nothing receives focus.
- Dialogs: native `<dialog>` + `showModal()` everywhere (focus trap, Esc) ✓; focus returns to the opener: observed End workday (Esc → "End workday" button), Correct a day (Esc → the row's Correct button, `TeamHoursView.tsx:98-102`), Edit person (Esc → Edit) ✓. Irreversible confirmations open on Cancel (`ConfirmDialog.tsx:388-392`), Esc twice with unsaved changes ✓. The urgent pop-up refuses Esc by decision (1846) ✓.
- Focus ring: observed `outline solid 2px rgb(158,207,245) offset 2px` and `:focus-visible` on the first Tab stop (`globals.css:115-118`) ✓, but Light Blue on white is 1.65:1 (section 7).
- Dialog names: `DayEditor` has `aria-labelledby` ✓; `PersonDialog`, `InviteDialog`, `FormDialog`, `ConfirmDialog` and the urgent pop-up have none (observed `personDialog.hasAriaLabel: {null,null}`): a screen reader announces "dialog" without a name (Low).
- Tables: Down/Up enter, arrows move, Enter opens ✓ (`TeamHoursView.tsx:73-117`, `TeamDirectory.tsx:61-98`, `CallsPerAgentTable.tsx:295-301`).
- Shortcut clashes: W (rail fold) yields to the roster's and schedule's W by the `main` rule ✓; C (Configuration) yields to Copy previous week and Custom range ✓; S on Follow-up filters versus S on My day: different pages ✓; A on the urgent pop-up versus A on People: the dialog scope wins while open ✓.

## 5. Irreversible steps and confirmations

| Write | Confirms? | Should it? | Note |
|---|---|---|---|
| Clock in | no | no (reversible: End workday) | ✓ |
| Status change | no | no | ✓ |
| End workday | yes, ordinary (Enter confirms) | yes, ordinary | ✓ (`WorkdayPanel.tsx:286-296`); the dialog has no title id |
| Log out | a page with the clock's figures (decision 1856) | yes | ✓ |
| Correct a day / Add day | Save with a required reason; Esc twice when dirty | reason is the confirmation | ✓ history kept |
| Roster cell | no (saved on blur) | no (retype) | ✓ |
| Publish / Publish changes | yes, ordinary | yes | ✓ agents see it at once |
| Copy previous week | yes, irreversible (opens on Cancel) | yes | ✓ |
| Mark all read / Acknowledge | no | no | ✓ |
| Send message | no | borderline: reaches n people, no recall | a count preview ("Will reach 23 people") before Send would fit the model; today the count comes after |
| Edit person (role, active, teams, skills, linked ids) | Save; Esc twice | deactivating a person: no consequence stated | Low: `team.activeHint` explains inactive on the checkbox ✓ |
| Invite / New link / Revoke | Revoke: second tap ✓ | ✓ | |
| Retire status / absence / app link / skill | no | Retire is reversible (Reactivate) | ✓; the destructive style is right |
| Make default | no | reversible | ✓ |
| Dissolve team | irreversible dialog ✓ | ✓ | |
| Switch off connection | ordinary dialog (`SourceConfig.tsx:806`) | ordinary (data refused, nothing deleted) | ✓ |
| Stop counting a line | irreversible dialog ✓ (`SourceConfig.tsx:812`) | yes | **CMA-020**: the text says calls are removed but not how many: `SourceLine` (`types.ts:1367-1375`) carries no count, so the dialog cannot ask for it without a new read column (the delete is `db/54_uncounted_lines.sql:153-158`). PROPOSAL. |
| Switch off alert rule / form rule / outcome rule | no (reversible), rule preview before save ✓ | ✓ | |
| Remove alias / holiday / setting row | no | reversible by re-adding | ✓ |
| Preview as role | no | no (narrows only) | ✓ |

## 6. Reading the numbers

- Units named everywhere (min, s, business minutes, %, h m) ✓; time zones named where they differ (`zoneLabel`, "in your own time zone", "the time zone of its line's market") ✓.
- "Compared with": Calls and Forms tiles say "vs the previous period" or "vs the same point in the previous period" with the dates in the title (`CallsParts.tsx:62-104`) ✓; "No history to compare yet" before the history start ✓ (observed on Forms: "↑ 200% vs the same point in the previous period").
- Definitions in hints: talk time without ringing (`hints.callsAvgTalk`, `calls.intro`), counted lines only (`hints.offered`, `intake.intro`), service level definition with the seconds filled in (`inbound.slNote`), median "half faster, half slower" (`hints.median`), medians do not add up (`speedToLead.totalNote`) ✓. This covers CMA-042/CMA-054's expected-differences need for Calls, Inbound and Speed to lead.
- **Live board "Waiting 0 min"** (`InboundLive.tsx:353-357`, `manager-1280-live_board.png`): every missed caller shows "0 min" on a Saturday because waiting counts office time; a manager reads 0 min as "just now". The hint explains it, the cell does not. Say it in the cell: "Closed" or "0 min · office closed" when the market is closed since the call, and keep the figure for open hours.
- Dashboard Intake tiles at 1280 px (`manager-1280-reports_dashboard.png`): six tiles across make the hint lines wrap to three lines ("2 new customers · 2 repeat · 1 renewals"); the Leads tile hint "Counted form submissions" wraps. Polish: 3+3 tiles under 1536 px.
- Team hours total "10h 48m" wraps onto two lines (`TeamHoursView.tsx:221-222` lacks `whitespace-nowrap`; `manager-1280-team_hours.png`). Polish.
- Sent-messages table at 1280 (`manager-1280-messages_send.png`): the title column is squeezed to one word per line. Polish: give the title column `min-w` or drop the Median column below 1536 px.

## 7. Accessibility basics

- Contrast (computed, `contrast.mjs`; confirmed by axe-core on 10 of 29 pages, 56 nodes, all `color-contrast`, `axe.json`):
  - Success badge `#27AE6F` on `#E6F6EE`: **2.55:1** (12 px semibold: "Active", "On", "Covered", "Acknowledged", "Within target", "Saved" and "Link copied" as text on white 2.85:1).
  - Warning badge `#C98A1B` on `#FBF1DC`: **2.62:1** ("Needs a correction", "Not clocked out", "Urgent", "One person", "At risk", "Expired").
  - Error badge `#B8433C` on `#F8E4E1`: **4.40:1** (just under 4.5; "Over time", "Past target", "Overdue").
  - Info, Neutral badges, Muted and Footnote Grey on Sand/white/Background Blue, Heading on Background Blue, white on Deep Blue: all ≥ 5.1:1 ✓.
  - Focus ring Light Blue on white 1.65:1, on Sand 1.62:1, on Background Blue 1.48:1 (WCAG 2.2 1.4.11 wants 3:1 for the indicator). Denim would give 5.1:1, Deep Blue 6.6:1.
  - Disabled button 2.5:1 (exempt), white on Leaf Green 2.85:1 (the `positive` variant is defined but unused).
  - Candidate tones that pass 4.5:1 on their surfaces (same hue, darker): success `#17784A` (4.91), warning `#9C6A12` (4.17) / `#8A5D0F` (5.12), error `#A83D36` (5.07). Or Inkt text on the tinted surface with the colour as a dot (14.4:1). These are proposed semantic defaults (guide 2.3, 14: flag to Mark, log a D-series decision).
- `aria-*`: controls carry names (axe found no `label`/`button-name` violation on any page; the `<input>`s without `aria-label` sit inside `<label>` wrappers). Live regions: toasts `role="status" aria-live="polite"` ✓, failures `role="alert"` ✓, SaveNote `role="status"` ✓, rule preview `aria-live="polite"` ✓; the clock is `aria-live="off"` on purpose ✓; a status change announces nothing (Low). `LiveBoard.tsx:100`: `aria-label` on a `<div>` without a role (axe `aria-prohibited-attr`, incomplete). Dialog names: see section 4.
- `prefers-reduced-motion`: `globals.css:120-127` zeroes animations and transitions ✓.
- 1280 px: every screenshot has `scrollWidth` equal to the viewport (82 rows in `screenshots-before.log`) ✓; wide tables scroll inside their cards with `role="region" tabIndex={0}` ✓. `DesktopOnly.tsx` is pure CSS with `print:` variants ✓.

## 8. Information architecture

Each page answers one question (titles and intros say which). Welcome is the to-do home: Updates, Needs attention (counts with links), Reports, the day card, Waiting for you, app links. Navigation grouping (Live, Team, Time, Reports, Configuration) matches the pages; Messages as a bare page for everyone is right. Handles (the cockpit lens):

| Signal | Where | Handle present | Planned / missing handle |
|---|---|---|---|
| Days not clocked out (31 days) | Welcome, Needs attention | link `/team/hours?range=month` (`lib/follow-up.ts:192`) | lands on the whole month; no filter or sort for "needs correction" rows (`TeamHoursView` has only a person filter). Add `?needs=correction` or sort chips first |
| Leads past target | Welcome, Live strip, Follow-up tiles | link `/reports/follow-up?state=attention`; rows link to the deal in HubSpot | assign an owner: in HubSpot by design (source of truth); the link is the handle ✓ |
| Tickets at risk / over time / without owner | same | same | same |
| Tasks overdue | same | same | same |
| Missed callers not called back | Welcome → `/live/board`; Live board table | link to the call in telephony (only with `record_url_call`) | hand the call to an agent, mark as called back: none; README Roadmap step 3 (telephony sync, callbacks KPI 5, Open decision 2132). Planned |
| Inbound today tiles (service level, waiting now) | Live board | none | none planned beyond the realtime service; acceptable for a watch tile |
| Person late / expected / absent | Live board rows | none | message the person or team (`/messages/send` exists but is not linked from the row), open the roster day, correct the day: none. A row menu with Message, Roster, Team hours would complete the cockpit |
| Coverage short / single person | Roster coverage grid | the grid above is the handle ✓ | coverage targets live in Configuration (admin only, settled 7 Oct); say "ask an admin" in `roster.coverageIntro` |
| Not clocked in / Clocked out tiles | Live board | tile filters the table ✓ | – |
| Unlinked telephony users / owners | Calls per agent, Data quality | link to People ✓ | – |
| Data quality counts | Data quality | words only | record lists stay in the source by design ✓ |
| Unread / urgent messages | top bar badge, Welcome Updates | inbox ✓, Acknowledge ✓ | – |

## 9. The manager's first week (Arno, `manager` subject)

Walked as the mock manager (permissions `workday.own, workday.team, workday.export, performance.team, monitoring.live, reports.view, users.manage_agents, skills.manage, roster.manage, roster.view, messages.send`; the db/21 ladder adds `leads.accept, performance.own, leads.manage, quality.manage`, which no screen uses yet).

1. **Welcome**: the mock's urgent fixture pop-up first (by design, decision 1846; in every "before" screenshot because the run did not acknowledge it). Needs attention is exactly the cockpit he needs; every line has a handle. Fine.
2. **Team hours → Correct a day**: keyboard flow complete; reason required; history shown. He cannot correct his own day (title says so). Download buttons present. Polish: the total wraps.
3. **People**: he may edit agents, supervisors and the analyst, not himself or the admin (observed `people.editButtons`). Invite (V) is the easy path; Add a person needs the agent's account id, which the agent reads from No access yet ✓. Skills ✓ (`skills.manage`).
4. **Roster**: first team by default, placeholder from the absence types ✓, week range in his locale ✓, Publish and Copy previous week confirm ✓. What he lacks: absence types and coverage targets are admin-only (`tenant.configure`, settled 7 Oct 2026); the planner says "a target comes from the team's configuration" without saying who sets it.
5. **Live**: Inbound tiles, Follow-up strip, people rows. Signals without a handle (section 8). "Waiting 0 min" (section 6).
6. **Reports**: every figure hinted; the Calls/Inbound/Speed to lead expected-differences notes exist (section 6). The keycaps 10–18 do not work (section 4). Nothing to reconcile blindly except Calls per agent "Answered" versus Aircall's own per-user counts (transfers are not mentioned anywhere; estimated gap, not verified).
7. **Messages**: Send ✓; "Confirmed –" for normal messages ✓; the sent table is cramped at 1280.
8. **Configuration**: hidden from him (by design). First-week admin dependencies: coverage targets, office hours per market (speed to lead), export format, the invitation domains, alert rules. All seeded or set by Martin; acceptable.

Permissions he lacks and will ask for: none that the README does not already settle; the friction is wording ("ask an admin") not access.

## 10. Hydration errors (React #418)

Root cause: client components format dates with `Intl.DateTimeFormat` during render, and Node 22 (ICU 77.1 here, `process.versions.icu`) and Chrome 141 (ICU 78, CLDR 48) disagree on the en-GB `weekday: "short"` pattern: Node "Sat 17 Oct", Chrome "Sat, 17 Oct" (observed, `hydration.mjs`: `browserIntl.inboxEnGB: "Sat, 17 Oct, 14:05"` versus Node `"Sat 17 Oct, 14:05"`). The same happens in prod for every user on Chrome 141+ against the Node 22 image. Exact expressions:

1. `/messages`: `Inbox.tsx:35` `fmtWhen` → `new Intl.DateTimeFormat(locale === "nl" ? "nl-NL" : "en-GB", { timeZone, weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" })`, rendered at `Inbox.tsx:120`. Observed diff SSR "Sat 17 Oct, 19:14" → DOM "Sat, 17 Oct, 19:14", error in both UTC and Europe/Amsterdam browsers.
2. `/roster/planner`: `RosterPlanner.tsx:389` (and the `aria-label` at `:420`) `fmtDate(d, locale, "compact")` → `lib/time.ts:78-86` with `weekday: "short"`. Observed SSR "Mon 12 Oct" → DOM "Mon, 12 Oct". **Second, latent cause** `RosterPlanner.tsx:357`: `new Intl.DateTimeFormat(…, { dateStyle: "medium", timeStyle: "short" })` with **no `timeZone`** → server UTC versus the browser's zone: observed on the published Team NL week "16:56" (SSR) → "18:56" (DOM) in a Europe/Amsterdam browser, no diff in a UTC browser.
3. `/configuration/alert-rules`: `AlertRulesConfig.tsx:94` → `SourcesList.tsx:157` `fmtWhen` → `fmtDate(…, "compact")`. Observed "Last alert Sat 17 Oct 18:31" → "Last alert Sat, 17 Oct 18:31".

Not affected (server components or no weekday): Welcome Updates times, Send-page table, People invitations, Live board missed-at, Follow-up, Sources list (all `diffs: []`). `nl-NL` output is identical in both ICUs ("za 17 okt, 14:05"), so Dutch users would not see the error; English ones do.

Fix (SAFE): make `fmtDate`/`fmtWhen` assemble the parts themselves (`formatToParts` → `${weekday} ${day} ${month}`), so the output does not depend on the ICU's pattern, or pass the three labels pre-formatted from the server as the Live board and Team hours already do; and add `timeZone` to `RosterPlanner.tsx:357` (or move it to `fmtDateTime`). A regression check: `verify/layout.mjs` could fail on any `pageerror` containing "#418".

## 11. Backlog items in scope

- CMA-004 hints toggle: observed `?` sets `data-hints="hidden"`, hides every `kbd` (`display: none`), writes the cookie, `aria-pressed` true ✓; `aria-keyshortcuts` kept on rail links ✓.
- CMA-061 roster copy: the fix was the week range through `formatRange` and the placeholder/absence keywords from configuration (decision 1980). Observed "Week 42 12–18 October 2026", placeholder "9-17:30 or off", keywords sentence from the tenant's absence types ✓. Remaining locale gap on that page: the day headers and the "Published as … on {when}" use ad-hoc formatting (section 10).
- CMA-063 rail and breadcrumbs: breadcrumbs on every page but Welcome, trail on Sources detail, folded rail by W with pills ✓ (screenshots and `layout.mjs` coverage).
- CMA-020 line switch-off count: not done; needs a stored-calls count per line in the lines read (PROPOSAL, section 5).

## 12. Top ten UX changes with the biggest effect on daily use

1. **SAFE** Keep focus after a status change and after Clock in: focus the newly current status button (or the group) after the refresh, and the Status group or the clock after Clock in; keep only the *clicked* button disabled during the write (`WorkdayPanel.tsx:258`, `ClockInCard.tsx:47`).
2. **SAFE** Stop numbering past 9: `nav.ts:211,214` give `key: null` once `n > 9` (no keycap, no `data-shortcut`), and fix the README sentence; PROPOSAL alternative: a letter per group (R for Reports) plus digits inside the group.
3. **SAFE** Pending feedback on navigation: a client `RailLink` using `useLinkStatus` (Next 16) that dims the link / shows a small indicator within one frame, plus `prefetch` on rail links; PROPOSAL: move `Shell` into `app/layout.tsx` (active page from the pathname, `wide`/`trail` via a slot) so Next streams the shell and a `loading.tsx` skeleton per route.
4. **SAFE** Fix the hydration mismatches: `fmtDate` compact via `formatToParts`, `Inbox.fmtWhen` through `lib/time`, `timeZone` on `RosterPlanner.tsx:357`; a `#418` assertion in `verify/layout.mjs`.
5. **SAFE** Add `app/error.tsx` and `app/not-found.tsx` in the shell's tone with copy in both languages ("This page could not be loaded. Try again or go to Welcome"), and catch the End workday action's failure with `myDay.endFailed` (new key); surface Inbox mark-read/acknowledge failures with the existing `messages.loadFailed` or a new key.
6. **PROPOSAL** Badge and focus-ring contrast: darker semantic text tones for success/warning/error badges (candidates in section 7) or Inkt text on the tinted surface; a Denim or Deep Blue focus ring on light surfaces. Changes style tokens: name it in the PR and flag to Mark (guide 14).
7. **SAFE** Live board missed callers: show "Closed" (or "0 min · office closed") instead of a bare "0 min" when the market has been closed since the call (`InboundLive.tsx:353-357`), copy in both languages.
8. **SAFE** Remove `uppercase tracking-wide` from the toast and urgent labels (`MessageCenter.tsx:225,246`); give every `<dialog>` an `aria-labelledby`; `role="group"` on the Live tiles container.
9. **SAFE** Needs attention → Team hours: a `needs=correction` filter (chips first, or only those rows) so the handle lands on the rows to fix, not the whole month.
10. **PROPOSAL** Handles on the Live board rows (Message this person/team, open the roster day, correct the day) and on the missed-callers rows (hand to an agent / mark called back when the telephony sync lands); and CMA-020's count of stored calls in the line switch-off dialog (needs a count column in the lines read).

Polish (not in the ten): Team hours total `whitespace-nowrap`; Dashboard Intake tiles 3+3 under 1536 px; sent-messages table columns; empty states for Absence types and Markets tables; reserve the inbox badge width in the top bar; filter `e.repeat` in the hook; "ask an admin" in the roster coverage intro.
