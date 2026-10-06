# Demo analysis: contactcenter.pulse4all.app as blueprint for the CMA

Oct 5, 2026 · @Martin

## Summary

The demo is a complete, working time-and-status app for a small call center team, and its screens and flows can be adopted almost one to one; its data layer cannot. The address is `contactcenter.pulse4all.app` (the `callcenter.` host in the request does not exist in DNS). It runs on Firebase: hosting, email-and-password sign-in and a Firestore database, all driven by one HTML file with about 980 lines of plain JavaScript and no framework or build step. Finn created the first admin account on 1 October 2026; the Make.com connection was added on 4 October.

What it covers, in README terms: Features 1 (workday and time tracking), 2 (a weekly roster, without coverage), 3 (skills as languages with a level), 7 (messaging with targeting and read receipts), plus management of hours, corrections, a CSV export for payroll, team approval and a Make.com entry point for pushing messages. Everything a manager needs for a team of 10 to 30 agents is there, in the Pulse4all style, with calm copy and sensible empty states.

The verdict for the CMA:

- Adopt the information architecture, the two-mode navigation (Agent and Management), every screen layout and most of the copy
- Adopt the behaviour rules: one open shift per person, status categories that drive colour, the forgotten-clock-out dialog, urgent messages that must be confirmed, read receipts, corrections that stay visible as corrected
- Rebuild the data layer on migration 0002 and Postgres; the demo computes hours in the browser from raw events, trusts the agent's computer clock, and has no tenant, no audit trail and no server-side rules
- Replace the hardcoded status list, skill levels and role names with tenant configuration, and the Make.com connection with the ingest API

The CMA already has the harder half (time model, RLS, IAP login, API); the demo supplies the easier half that is still missing: the management screens, the roster, messaging and the agent's day at a glance.

## How this was done

The whole application logic is one inline script, so the analysis rests on the full source, not on clicking around. Steps, all on 5 October 2026 between 21:30 and 22:00 CEST:

1. Resolved the host: `callcenter.pulse4all.app` returns NXDOMAIN at Google and Cloudflare DNS; `contactcenter.pulse4all.app` resolves to Firebase Hosting; `callcenter.pulse4all.com` is a Plesk panel, not the demo
2. Downloaded the page and split out the script (977 lines, 80 KB) and the stylesheet (231 lines, 16 KB); read both completely
3. Signed in with a headless Chromium (Playwright) as Martin Bartels, role Admin, at 1366 × 900 and at 390 × 844 as a phone
4. Captured 21 screens: sign-in, all seven management views, the dashboard and hours for this month, the correct-a-day and add-day dialogs, the skills dialog, both targeting modes of the message form, the three agent views, and two mobile views
5. Read the live Firestore data through the app's own SDK session: 3 users, 2 agent status documents, 8 messages, the month documents with every status event since 1 October, the skills and setup documents. The `config` collection cannot be listed (security rules); its two known documents can be read

Nothing was changed. No status was clicked and no message was sent, because Martin's account was clocked in with status Outbound during the whole session. Screenshots are in the sandbox and can be attached on request. The Firebase security rules themselves are not readable from the client; what they allow is inferred from the code paths that succeed.

## Stack and architecture of the demo

The demo is a Firebase serverless app: there is no backend of its own, the browser talks straight to Firebase Auth and Firestore, and all rules live in the client and in Firestore security rules.

| Layer | Demo | CMA (README: Architecture, Authentication, API) | Carries over? |
| --- | --- | --- | --- |
| Hosting | Firebase Hosting, project `workspace-pulse4all` | Cloud Run behind a load balancer and IAP, EU region | No |
| Login | Firebase Auth, email and password, self-registration, password reset email | Google Workspace through IAP, `app_user` decides access, external id matching | No; the approval flow idea does carry over |
| Database | Firestore, five top-level collections, documents merged client-side | Cloud SQL Postgres with tenants, RLS, audit log, write functions | No |
| Business rules | In the browser (`dayStats`, `setStatus`, `forMe`, `saveEdit`) | In SQL functions and views (`open_workday`, `set_status`, `correct_time_event`, `workday_summary`) | Rules yes, code no |
| Realtime | Firestore `onSnapshot` listeners on own status, own month, skills, messages, this week's roster; managers also on all users and all statuses | Realtime push service via outbox (Roadmap step 6); screens poll or subscribe | Pattern yes |
| Automation entry | A service user with role `koppeling`; Make posts to the Firestore REST API with that user's token | Ingest API on Cloud Run with per-tenant keys | No; see Messaging |
| Frontend | One HTML file, vanilla JS, event delegation on `data-act`, HTML strings, no dependencies | Next.js 16, TypeScript, Tailwind v4 with Pulse4all tokens | No; structure and copy yes |
| Clock | The agent's device clock (`Date.now()`), stored as epoch milliseconds, day key in device local time | Database clock, `timestamptz`, business day in the user's IANA zone | No |
| Export | CSV built in the browser, semicolon separated, BOM, formula-injection guard | BigQuery on `cma_read`, plus an export in the app | Format rules yes |

Three architectural points matter for the port:

- **Everything is client-trusted.** A user who can sign in can call Firestore directly with their token. Whatever the security rules do not forbid is allowed, including backdating a status change by posting an event with an old `t`. The CMA's rule "the database clock decides" exists for this reason
- **Reads fan out.** The dashboard loads one document per agent per month in the period with four parallel workers, then aggregates in the browser. Fine for 2 agents and 1 month; at 30 agents over a year it is 360 reads per refresh and all logic in the client. The CMA answers this with `workday_summary` and later BigQuery
- **No separation of tenants or employers.** One Firestore database, one team, one skill list. Business lines, organisations and customers do not exist as concepts

## Roles, modes and the access gate

Four roles exist, stored as a string on the user document; two of them unlock a Management mode that sits beside the Agent mode in the header.

| Role (stored) | Shown as | Sees | May do |
| --- | --- | --- | --- |
| `agent` | Agent | Agent mode only: Home, Schedule, My hours | Clock, change status, read messages |
| `management` | Management | Both modes: Live, Dashboard, Hours and export, Schedule, Messages, Team | Everything in Management except Admin; edits only users with role Agent; cannot change roles or names |
| `beheer` | Admin | Both modes plus the Admin tab | Everything: names, roles (not their own), skill catalog, Make connection, disable any user |
| `koppeling` | Make.com | Nothing; the UI shows "Your account is disabled" | Writes messages through the REST API; never appears on the board or in Team |

**Mode switch.** Managers and admins get a segmented control Agent | Management in the header. The choice is remembered in the browser (`localStorage`, key `sk_mode`); a manager lands in Management by default. A manager who clocks in appears on the Live board like an agent: the board lists active users who are agents or who have a live status document. The running status chip in the header works in both modes and jumps to Home.

**Access gate.** The user document is watched live, so the screen follows the account state without a reload:

1. Empty database → "Create the first admin" (the account becomes `beheer`; a `config/setup` marker prevents a second first-admin)
2. Not signed in → Sign in, with Forgot password (reset email) and Request an account
3. Request an account → Firebase Auth user plus a user document with `role: agent, active: false, pending: true`
4. Signed in, no user document → "Request access" with a name field (same pending document)
5. Pending → "Your request has been sent", refreshes itself once approved
6. Disabled, or role `koppeling` → "Your account is disabled"; Log out
7. Active → the app; if `active` or `role` changes later, the page reloads; a name change updates the avatar in place

Approval, rejection (deletes the document), disable and enable live in Team; the Team tab carries a badge with the number waiting.

**For the CMA.** Sign-in and self-registration are replaced by IAP plus `app_user` (README: Authentication), and the "no access yet" page already exists. What carries over is the queue: a pulse4all.com account that hit "no access yet" can be listed for a manager to grant a role and employer, which is the demo's approval step without the password. The Admin versus Management split is a clean answer to the README's open decision on an `admin` role: configuration and user management for admins, operations for managers, and `mayEdit` becomes a permission on the ladder (`users.manage_agents` versus `users.manage_all`).

## Data model as found in Firestore

Five top-level collections, one subcollection, and every document is a nested map that the browser merges itself. Times are epoch milliseconds from the device; days are `YYYY-MM-DD` strings in device local time.

| Collection or document | Fields | Written by | CMA equivalent (migration) |
| --- | --- | --- | --- |
| `users/{uid}` | `name`, `email`, `role`, `active`, `pending`, `createdAt`, `skills` as `{skillId: level 1–3}` | Self at registration; managers and admins | `app_user`, `user_role`, `app_user_external_id` (0001); skills table (new) |
| `agents/{uid}` | Live status: `state` (status id or `off`), `since` (last change), `start` (clock-in), `day` (shift day), `read` as `{messageId: readAt}` | The agent only, on every status change and mark-as-read | A current-status view over `time_event`; `message_delivery.read_at` (new) |
| `agents/{uid}/months/{YYYY-MM}` | `days` as `{day: {ev: [{s, t, m?}], ed?: {by, at}}}`; `s` status id, `t` time, `m` end entered afterwards | The agent (append) and managers (whole-day overwrite) | `workday`, `time_event` with corrections (0002) |
| `rosters/{monday}` | `shifts` as `{uid: [7 strings]}`, `at`, `by` | Managers, whole week at once | Roster and shift tables (Roadmap step 5) |
| `messages/{id}` | `title`, `body`, `urgent`, `at`, `by`, `byName`; targeting `skill`, `minLevel`, `uids`, `emails`, `status` | Managers, Make.com | `message`, `message_delivery`, outbox (new) |
| `config/skills` | `list` as `[{id, name, type: taal or overig}]`, `at`, `by` | Admins | Skill catalog per tenant with three dimensions (new) |
| `config/setup` | `by`, `at` | First admin | Not needed |

**What the data holds today.** Three users: Finn (Admin, first account, 1 October 14:12), Martin (Admin, 1 October 14:15) and the Make.com service account (4 October). Two live status documents. Eight messages, all urgent, all tests, six aimed at Martin by id, one at everyone, one at Dutch speakers level 1. Five shift days with 45 status events in total; one day corrected by a manager; one end time entered afterwards. No roster has been saved yet, so Live and Home show no shift. No skills document exists, so the four default languages apply and nobody has a level.

**Observations that shape the port**

- Read receipts are a growing map on the agent's own live document: one key per message, never pruned. Harmless at 50 messages, wrong at 5,000. In the CMA this is a row per recipient per message
- The shift day is the clock-in day. A shift that crosses midnight stays on the day it started, and the clock-out shows as a date plus time. Migration 0002 does the same (business day in the user's zone) and caps an open day at the end of that day
- A correction overwrites the day's event array and stamps `ed: {by, at}`. Nothing records what the day looked like before, who asked, or why. 0002 keeps every superseded row, with reason and approver
- The status at the moment a message was sent is recomputed from the agent's own events every time the list renders. It is cheap because the data is local; in Postgres this is resolved once, at send time
- Skill ids are slugs of the name (`german`, `bci-worklist`) and stay stable when the name changes; a sound pattern worth keeping
- `emails` on a message exists only for Make.com, which does not know user ids. In the CMA, Make will know neither; the ingest API resolves targets by CRM user id or email against `app_user_external_id`

## The agent's perspective

An agent has three screens and lives on the first one: Home shows the day, the status panel and the messages, and nothing else competes for attention.

**Header.** Logo, the three tabs (Home with an unread badge, Schedule, My hours), and on the right a running status chip (dot, status name, timer since the last change) that appears on every screen except Home and jumps back to it, the avatar with initials, and Log out. The browser tab title becomes "(2) Pulse4all" when two messages are unread.

**Home: greeting and day line.** "Good morning, Martin" by time of day with the first name. Below it: "Monday 5 October. Your shift today: 09:00–17:30." or "You have no shift in the schedule today." A third line lists the agent's own languages and skills with levels when they are set.

**Home: status panel** (right column, 416 px, sticky; first on narrow screens).

- Not clocked in: a grey dot, "Not clocked in", a light-blue idle timer `--:--`, the line "Clock in to start your shift. Your status will be set to Available." or, after a shift, "Clocked out at 15:38. 1:11 worked today.", and one large primary button Clock in
- Clocked in: a coloured dot and the status name, a 56–64 px timer counting since the last status change, the line "Since 19:18. Clocked in at 10:24, 11:10 worked." (the worked total refreshes every 20 seconds), a two-column grid of fifteen status buttons each with its category dot (the active one filled deep blue), and a secondary Clock out button
- Every status change is one tap and gives a toast: "Clocked in at 10:24", "Status: Lunch", "Clocked out at 17:31". Buttons are disabled while a write is in flight; the agent's own writes are queued so two quick taps cannot cross

The fifteen statuses fall into three colour categories, and only the category is shown by colour: Available is green; Break and Lunch are light blue; Training, Meeting, IT Problems, Expert, Coaching, Follow up, Other, BCI indirect, BCI worklist, Outbound, Email M&SM and End of Shift are rose. The names are Pulse4all's own; the pattern (one green, a few blue pauses, many rose work types) is what to keep.

**Home: messages** (left column). Newest first, each a card: Urgent chip, New chip while unread, bold title that turns regular once read, body text, "Today 14:11, Finn Bartels", and a Mark as read button. Above the list: Turn on notifications (browser Notification API, shown until answered) and Mark all as read when more than one is unread. Empty state: "No messages yet. New messages from your team lead will appear here." An agent only sees messages that match them: by skill and level, by being named, and by their own status at the moment of sending; a message for "only those Available right now" never appears for someone who was on Lunch at that time, not even later.

**Arrival of a message.** A short 880 Hz beep, a browser notification if allowed, and for a normal message a toast "New message: title". An urgent message opens a modal with the title, body and sender that Escape cannot close; the only way out is Mark as read. The modal returns on every page load until it is read, for 24 hours.

**Forgotten clock-out.** If the live status has been open for more than 16 hours, Home opens a modal: "You did not clock out. Your shift on Thursday 1 October (clocked in at 14:16) was not closed. What time did you stop working?" A date-time field defaults to the last status change, cannot go before it or after now, and the note says "Your team lead can see that this end time was entered afterwards." Saving writes a clock-out event flagged `m` and the day shows "End time entered afterwards" to the agent and the manager.

**Schedule.** A week bar (previous, next, This week) and seven rows "Monday 5 Oct — 09:00–17:30" or "No shift", today tinted, and a Total planned row in hours. Read only; the roster is the manager's.

**My hours.** A month bar and a table: Day, Clocked in, Clocked out, Worked, Of which Break and Lunch, and note chips: Still clocked in, Not clocked out (warning tint), End time entered afterwards, Corrected afterwards. A total row. The subtitle tells the agent to ask their team lead for corrections; the agent cannot edit anything here.

**Against the CMA's My day and My hours** (README: Roadmap step 2, live since 5 October). The CMA has the clock, End workday, and hours per day, week, month and range. Missing and worth taking from the demo: the status grid and the timer, the greeting and shift line, the header chip, the messages column, the Schedule screen, the break-and-lunch column and the note chips. One behaviour conflicts with a README decision: the demo lets the agent close a forgotten shift themselves (flagged), while 0002 leaves the day open for a manager's correction. See Decisions to confirm.

## The manager's perspective

Management mode has six tabs on a second header row, plus Admin for admins; every tab opens with a title and a one-sentence subtitle that says what the screen is for.

**Live** — "Who is on which status, right now." Four tiles count Available, Break or Lunch, Other status, Not clocked in. Filter chips for the same four plus All, a dropdown for language or skill and, once one is chosen, a minimum level. The table: Agent (initials and name), Status chip in the category colour, Duration ticking every second, Clocked in, Shift today from the roster, Languages and skills as chips with the level number. Sorted Available first, then pauses, then other, then not clocked in, alphabetical within. A status older than 16 hours shows as a warning chip "Not clocked out" with the date. Updates arrive live. Empty state points to Team: "No agents yet. Approve requests under Team; they will then appear here."

**Dashboard** — "How time was divided across statuses in the selected period." A period bar shared with Hours: Today, This week, Last week, This month, Last month, a from and to date, Refresh and "Updated at 21:34"; periods above one year are refused. Four tiles: Hours worked, Of which Available (%), Break and Lunch (%), Agents with hours. Three cards of horizontal bars: Time per status sorted by size with h:mm and percent; Hours worked per day; Per agent as a stacked bar in the three category colours with a legend. All figures are computed in the browser from the raw events.

**Hours and export** — "Clock-in and clock-out times per agent per day, ready to download for payroll. Times come from the clock on the agent's computer." The period bar, an agent filter, and three buttons: Add day, Download status changes, Download hours per day. The table: Date, Agent, Clocked in, Clocked out, Worked, Break, Lunch, Note chips (Still clocked in, Not clocked out, End time entered afterwards, Corrected afterwards) and a Correct link per row; a total row.

Two CSVs, both semicolon separated with a byte-order mark, dates as `dd-mm-yyyy`, decimals with a comma, and a guard against formula injection; made for Dutch Excel:

| File | Columns |
| --- | --- |
| `hours_<from>_<to>.csv` | Date; Agent; Clocked in; Clocked out; Times clocked in; Worked (h:mm); Worked (hours); one column per status in hours; Note |
| `status-changes_<from>_<to>.csv` | Shift date; Agent; Time; Status; Duration (h:mm:ss); Entered afterwards |

**Correct a day** (modal, wide). One row per status change: a date-time field, a status dropdown that includes Clocked out, and a remove button; Add row appends one minute after the last row, or 09:00 on an empty day. Rules: the first row cannot be Clocked out; no time may be in the future. Save replaces the whole day and stamps who corrected it and when; the day then carries "Corrected afterwards". **Add day** asks for an agent and a date up to today and opens the same editor, for someone who forgot to clock in entirely.

**Schedule** — "Type a shift per day, for example 9-17:30. Free text such as Off or Sick is fine too. Agents only see their own row." A week bar, Copy previous week and Save schedule; the Save button reads "Save schedule (unsaved changes)" while dirty, and changing week while dirty is refused with a toast. The grid is agents by seven days, one text field each, 24 characters. Typing `9-17:30`, `9.00–17.30` or `9h00-17h00` is normalised to `09:00–17:30` on blur; anything else stays as typed. One document per week, saved whole.

**Messages** — "A message appears straight away for recipients who have Pulse4all open. You choose who gets it: everyone, a language or skill, or specific agents." Left, the form: Title (80), Message (1000), Recipients (Everyone, By language or skill, Specific agents) revealing a skill and minimum level, or a checklist of agents; Status of the recipient (Any, Only those clocked in right now, Only those Available right now); an Urgent toggle explained as "Shows a pop-up with a sound that the agent has to confirm"; Send message. Right, Sent: each message with its Urgent chip, title, body, a plain-language target line ("Dutch, good or higher, only those who were Available at that moment"), "Today 14:11, Martin Bartels. Read by 1 of 3.", an expandable "Not yet read by 2" with names, and Delete with a four-second "Are you sure?" second tap. When a status condition was used the denominator is left out, because the audience cannot be known afterwards.

**Team** — "New agents request an account themselves on the sign-in page. Here you approve them and record which languages and skills someone has. Levels: 1 Basic, 2 Good, 3 Fluent." Three sections: Waiting for approval (Reject with second tap, Approve), Active as a table (Name, editable inline by admins; Email; Role, a dropdown for admins except on themselves; Languages and skills chips; Skills and Disable buttons), and Disabled (Enable again). The Skills modal lists every catalog entry with None, 1 Basic, 2 Good, 3 Fluent. A manager may only edit agents; an admin anyone.

**Admin** — "Settings only an admin can change: the list of languages and skills, and the connection that lets Make.com send messages. You change roles under Team." The skill catalog editor (name, type Language or Other skill, remove, Add, Save list) and the Make.com connection described in the Messaging section.

**Against the CMA.** None of these screens exists yet; the data for Live, Dashboard and Hours exists in 0002 (`time_event`, `time_interval`, `workday_summary`), corrections exist as `correct_time_event`, and Team maps to `app_user` and `user_role`. Roster, skills and messaging need their migrations (Roadmap steps 5 and 6).

## Time model: the demo against migration 0002

Both models are event based and agree on the shape of a day; they differ on who is trusted, what counts as worked time, and whether history survives a correction. The CMA keeps 0002 and takes four display rules from the demo.

| Rule | Demo | Migration 0002 (README: Data model, time model) | For the CMA |
| --- | --- | --- | --- |
| Storage | One array of `{status, time}` per day inside a month document | One `time_event` row per fact, append only, `occurred_at` and `recorded_at` | Keep 0002 |
| Clock | The agent's device, epoch milliseconds | The database clock; the app sends no time on start or end | Keep 0002 |
| Business day | Clock-in day in device local time; a shift over midnight stays on its start day | Day in the user's IANA zone, snapshotted when the day opens | Same outcome, keep 0002 |
| Duration of a status | Until the next event; an open status counts until now | `time_interval` view, same idea | Same |
| Worked | Sum of every status including Break and Lunch; the pauses are shown separately as "Of which Break and Lunch" | `working_seconds` counts only statuses with `is_working`; `paid`, `billable` and `productive` seconds are separate | Decide which number the agent sees (README open decision). The demo's "total, of which pauses" reads well and loses nothing |
| Colour of a status | Hardcoded category: ok, pause, busy | No display field; flags only | Derive: working and productive → green; working, not productive → rose; not working → light blue. No new column needed |
| Clock out and in again | Allowed any number of times; the export counts "Times clocked in" | An ended day stays ended; resuming is a correction (decision 5 Oct) | Keep 0002 and make Break and Lunch the way to pause; drop the demo's End of Shift status, which only exists because clock-out is separate |
| Forgotten clock-out | After 16 hours the day is stale, counts nothing after the last event, and the agent enters the end time themselves, flagged `m` | The day stays open, is flagged `needs_correction`, hours capped at the end of the business day; a manager corrects, later the scheduler | Decision: let the agent propose an end time that is stored as a correction awaiting a supervisor's approval, or keep manager only |
| Correction | Whole day overwritten, stamped `ed {by, at}`, no reason, no before image, any manager | New rows with reason and approver, one correction per event, superseded rows stay visible | Keep 0002; take the demo's editor UI and add a required reason |
| Add a missed day | Manager picks agent and date, enters rows | `correct_time_event` adds a missing event to an existing workday; opening a day for someone else is not a function yet | Gap: a correction that opens a past workday on behalf of a user (reason and approver as usual). Small addition to 0002 or part of 0003 |
| Status list | Fifteen hardcoded entries | `work_status` per tenant with flags, default ladder seeded | Seed Pulse4all's fifteen in `02_seed_pulse4all.sql`, not in a migration |
| Stale threshold | 16 hours, hardcoded | End of business day | Tenant setting if ever needed |

Two demo rules are worth stating explicitly in the CMA's copy, because agents will ask: the shift belongs to the day it started, and a change to the end time afterwards is always visible to both sides.

## Messaging and the Make.com connection

Messaging in the demo is one way, manager or automation to agents, with precise targeting and read receipts; the CMA keeps the targeting and the urgent pop-up and moves resolution and delivery to the server.

**Targeting.** A message carries any combination of: a skill with a minimum level (1 to 3), a list of user ids or email addresses, and a status condition (`available` or `clockedin`). An agent sees the message when every present condition matches them, with the status checked at the time the message was sent, against their own event history. The sender always sees their own messages. Only the newest 50 messages are loaded.

**Read receipts.** Mark as read writes the timestamp into the agent's live document; the Sent list counts readers against the audience it can compute (skill and named recipients) and lists who has not read it. For urgent messages, reading and confirming are the same click.

**Make.com.** An admin creates a connection from the Admin tab. The app creates a Firebase Auth user `make-<6 chars>@workspace-pulse4all.firebaseapp.com` with a 28-character random password shown once, and a user document with role `koppeling`; creating a new connection deactivates the old one. The screen then shows copy-ready instructions for two Make HTTP modules:

1. Sign in: `POST https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=<web api key>` with email, password and `returnSecureToken: true`; Make parses the `idToken`
2. Send: `POST https://firestore.googleapis.com/v1/projects/workspace-pulse4all/databases/(default)/documents/messages` with header `Authorization: Bearer <idToken>` and a Firestore `fields` body: `title`, `body`, `urgent`, `skill` (by name, for example German), `minLevel`, `status`, `emails`, plus `at`, `by` and `byName` that must stay as given

The worked example in the UI is the speed-to-lead case: "New lead ready. German-speaking lead. Open the CRM", urgent, German level 2 or higher, only those Available right now.

**For the CMA** (README: Features 4 and 7, decision of 3 October that Make writes only through the ingest API):

- Keep the three target types and the status condition; resolve them at send time into one `message_delivery` row per recipient. The denominator is then always known, and the audience is exact even after teams change
- Split `read_at` from `acknowledged_at`: urgent messages need the confirmation click to be its own fact
- Keep the urgent modal, the beep and the browser notification; deliver through the realtime service and the outbox, with a polling fallback for the first increment
- Make posts to `POST /api/v1/ingest/messages` with the tenant's key; targets by skill name, by CRM user id or by email, resolved through `app_user_external_id` and the skill catalog; a message that reaches nobody returns that fact
- Quiet hours and working time are enforced at delivery, not by the sender (Spain's right to disconnect)
- The demo's lead message is a plain message. README's speed to lead is an assignment with an accept click, an expiry and a CRM owner change. Build the message first, then the assignment on top of it; the demo's example should not be read as the speed-to-lead design

**Security of the demo's approach, for the record.** The web API key is public by design; the secret is the connection password, stored in Make. Any party holding it can post any message to everyone, and the Firestore rules decide what else it may do. The ingest API with a key per tenant, rate limits and an audit row per call is the right replacement, and the Admin screen's idea (create a connection, see the instructions once, rotate by creating a new one) carries over unchanged.

## Visual and interaction design

The demo follows the Pulse4all style guide closely and uses the marketing type scale; the CMA keeps the components and layout and applies the dense scale it adopted on 5 October.

**Tokens.** Sand `#FFFDF6` page, white surfaces, Inkt `#0B133D` text, Deep `#265BA4` for headings, primary buttons and active states, Denim `#3B6FB3` on hover, Light blue `#9ECFF5` for pauses and the idle timer, Bg blue `#EAF4FC` for the active tab, panel heads and hover rows, Green `#27AE6F` for Available, Rose `#F4D9D0` for every other working status, urgent chips, warnings and danger buttons. Borders are Denim at 30 percent. Focus is a 3 px light-blue ring. Montserrat 400 to 700 from Google Fonts; the CMA ships the font itself.

**Type.** Body 16 px at 1.6 line height; h1 32 to 40 px bold Deep; h2 24; h3 18; table headers 13 px semibold Deep; table cells 14; stat numbers 32 bold; the timer 56 to 64 bold with tabular numerals. Everything numeric uses tabular figures.

**Components, as specified in CSS**

| Component | Spec |
| --- | --- |
| Card | White, 1 px border, 15 px radius, no shadow |
| Button | 40 px high, 4 px radius, 14 px semibold; small 32 px, large 48 px with a chevron; primary Deep fill, secondary Deep outline, ghost text only, danger and soft Rose fill with Inkt text |
| Input, select, textarea | 40 px minimum, 4 px radius, 8 by 16 px padding; Deep border and ring on focus; textarea 120 px |
| Checkbox | 24 px custom box, Deep when checked |
| Chip | Pill, 13 px, Bg blue; category tints for ok, pause, busy; active filter chip Deep with white text |
| Status dot | 12 px circle, outlined when off, filled in the category colour |
| Status button | 40 px, outlined, dot plus label, two per row; the active one Deep fill, white text, dot with a white halo |
| Stat tile | Four across with 1 px dividers, 32 px number over a 14 px label; two by two below 760 px |
| Bar chart | 8 px track at 7 percent Inkt, fill in Denim or the category colour, label 136 px, value 112 px right aligned |
| Table | 56 px rows, thin Denim lines, header in Deep, hover tint, bold total in the footer, no zebra striping |
| Modal | Centred white card, wide variant for the day editor, Escape closes except the two that must be confirmed |
| Toast | Bottom, 3.5 s; errors 7 s |

**Layout.** Content 1280 px wide on an 8 px grid with 48 px above the title; the header is sticky and translucent with blur; Management tabs move to a second row. Home is a two-column grid with a 416 px sticky side panel; Messages is 440 px form plus list; Dashboard uses halves. Grids collapse at 1000 px, tiles at 760 px, and the phone view works, with the status panel first. The CMA is desktop only (decision 4 October), so the breakpoints can go, but the two-column Home with a sticky panel is right for a second screen.

**Copy.** English throughout, no capitals in labels, no exclamation marks in UI copy, a subtitle under every title that says what the screen does, button labels that name the outcome (Save correction, Send message, Enable again), one-line confirmations ("Schedule saved"), errors with the next step ("Saving your status failed. Please try again."), reassuring empty states. This matches the style guide's writing rules and tone and can be lifted into `copy.ts` as it stands. Two small leaks to fix on the way: raw error codes in sign-in messages, and setup instructions that mention a script name.

**Interaction patterns to keep**

- Two-step destructive actions inside the same button ("Are you sure?" for four seconds) instead of a confirm dialog
- A dirty-state guard on the roster, with the button label carrying the state
- Live counters updated in place every second, the full re-render only on data changes
- One queue for the user's own writes and one silent retry on a transient error
- Colour never carries meaning alone: every dot has a label, every chip a word
- Aria labels on icon buttons and inputs, autofocus in modals, reduced motion respected

## Feature mapping to the CMA

Of 24 demo features, 15 are adopted as they are, 6 with a change, and 3 are replaced or dropped. "Lives in" follows the README's four surfaces; "Source" names the table or system that feeds it.

| Demo feature | Decision | Lives in | Source | In the CMA today |
| --- | --- | --- | --- | --- |
| Email sign-in, password reset, request an account | Replace: IAP and `app_user`; keep the approval queue as a list of accounts that hit "no access yet" | Data | `app_user`, `user_role` | Login and "no access yet" live |
| Agent and Management mode switch | Adopt; derive from permissions; remember per user, not per browser | Agent, Live | `cma.user_permissions()` | No |
| Running status chip in the header | Adopt | Agent | current status view | No |
| Greeting and today's shift line | Adopt; shift from the roster when it exists | Agent | roster (step 5) | No |
| Clock in, status grid, timer, clock out | Adopt; statuses from `work_status`, colour from flags | Agent | `set_status`, `time_event` | Clock in and end only |
| Forgotten clock-out dialog | Adopt with change: the agent proposes, stored as a correction; who approves is a decision | Agent | `correct_time_event` | Manager only |
| Messages on Home, beep, browser notification | Adopt; polling first, realtime service later | Agent | `message_delivery` | No |
| Urgent pop-up that must be confirmed | Adopt; confirmation is `acknowledged_at`, separate from read | Agent | `message_delivery` | No |
| Schedule (own week, read only) | Adopt | Agent | roster | No |
| My hours with pauses column and note chips | Adopt; chips from `needs_correction`, `has_correction` | Agent | `workday_summary` | Hours without pauses or chips |
| Live board: tiles, filters, skill filter, table | Adopt; add team and market filters when they exist | Live | current status view, roster, skills | No |
| Dashboard: tiles, time per status, per day, per agent | Adopt as a report; later also in BigQuery | Report | `workday_summary`, `time_interval` | No |
| Hours and export, two CSVs | Adopt; add employer and the paid and billable seconds; separator and decimals as a tenant setting | Report | `workday_summary`, `time_interval` | No |
| Correct a day editor | Adopt the UI; each change becomes a correction row with a required reason; show before and after | Report | `correct_time_event` | Function exists, no UI |
| Add day for a missed clock-in | Adopt; needs a correction that opens a past day for another user | Report | 0002 addition | No |
| Roster planner with quick typing and copy week | Adopt as the first roster; structured start and end per cell, absence types for Off and Sick, keep the parser | Live | roster tables (step 5) | No |
| Message composer: three target types, status condition, urgent | Adopt; resolve at send time | Live | `message`, `message_delivery` | No |
| Sent list with read counts and not-yet-read names | Adopt | Live | `message_delivery` | No |
| Team: approve, roles, disable, inline rename | Adopt; roles from `app_role`; add employer; disable is a status | Data | `app_user`, `user_role`, `organisation` | Seeds only |
| Skills per person with three levels | Adopt as the language dimension; add work type and channel; level scale per tenant | Data | skill tables (step 5) | No |
| Admin: skill catalog editor | Adopt as tenant configuration; add the status catalog with its flags | Data | `work_status`, skill catalog | No |
| Admin: Make.com connection | Replace with ingest API key management; same screen idea | Data | ingest API (step 3) | No |
| Badges for unread and pending counts | Adopt | Agent, Live | derived | No |
| Phone layout | Drop; desktop only, minimum 1280 px | — | — | — |

Two things the demo has that the README does not name and should: the manager's own clock (a manager appears on the board when clocked in) and the shift line on Home. Both are cheap and both were clearly wanted.

## Gaps, risks and conflicts with the README

The demo is safe as a prototype and would not be safe as the system of record for pay; every item below is already answered by a README decision or belongs on the decision list.

**Security and integrity**

- Every rule runs in the browser. A signed-in user can call Firestore directly and post a status event with any time, which backdates a clock-in. The README's "the database clock decides" and the write functions of 0002 close this
- Managers overwrite a day without a reason or an approver, and the previous version is gone. 0002 refuses this by privilege: `cma_app` cannot update or delete `time_event`
- The Make.com connection is a shared password that can post any message to everyone. The ingest API with a key per tenant and an audit row per call replaces it (decision 3 October)
- Firestore security rules are not visible from the client. What they allow is inferred; nothing in this analysis depends on them

**Configurability** (Principle 1). Hardcoded in the demo and tenant configuration in the CMA: the fifteen statuses and their three categories, the four default languages, the three level names, the four role names, the 16-hour stale threshold, the 24-hour urgent window, the 50-message cap, the one-year period limit, `en-GB` date formatting, Dutch CSV conventions (semicolon, decimal comma, `dd-mm-yyyy`), and the time zone, which is whatever the device says.

**Multi-tenancy and employers** (Principle 2). One team, one skill list, one roster, no business line, no employer, no site or market. Hours per employer, the reason the README gives every user an organisation, cannot be produced from the demo's data.

**Time and reliability**

- Device clock and device local day: an agent whose laptop runs in the wrong zone or with a wrong clock produces wrong hours that nobody can detect
- `datetime-local` corrections are ambiguous during the autumn clock change
- Worked time includes breaks and lunch; the README says non-working statuses stop the clock. Which number is shown is an open README decision; the two must not be mixed in one export
- The dashboard reads one document per agent per month per refresh and aggregates in the browser; at 30 agents and a year that is 360 reads per view

**Data protection** (with Yordi, README open decisions on employee monitoring and retention). The demo shows managers every status change to the second, read receipts per message, and the email address of every user. None of it is customer data, which matches the README's rule, but all of it is staff monitoring data under Dutch and Spanish law: retention, purpose and what agents see about themselves need an answer before real agents are on it. The CMA's audit log makes the record more complete, not less, so the question is the same.

**Conflicts with README decisions**, where the demo and the README disagree:

| Topic | Demo | README | Proposal |
| --- | --- | --- | --- |
| Clock out and back in | Any number of sessions per day | An ended day stays ended (5 Oct) | Keep README; pauses are statuses |
| Forgotten clock-out | Agent enters the end time, flagged | Manager corrects; later the scheduler (5 Oct) | Decide: agent proposes, supervisor approves |
| Corrections | No reason, no approver, history lost | Reason, approver, superseded rows kept (5 Oct) | Keep README |
| Login | Email and password, self-registration | Google Workspace through IAP (4 Oct) | Keep README |
| Automation | Make writes to the database directly | Make only through the ingest API (3 Oct) | Keep README |
| Type scale and font | Marketing scale, Google Fonts | Dense scale, font shipped with the app (5 Oct) | Keep README |
| Screens | Phone layout works | Desktop only, 1280 px minimum (4 Oct) | Keep README |

**Missing against the README's V1 scope**, not a fault of the demo but the list of what the port does not get for free: teams, sites and markets; employers; channels; skills as work type and channel; roster coverage per market; speed to lead with accept and expiry; productivity from HubSpot and Aircall; gamification; the scheduler for auto-close; quiet hours; acknowledgement separate from read; a locale per user; the audit trail.

## Build order and effort

Demo parity on the CMA foundation is about five to six working weeks for one person at the current pace, in eight increments that each go to production when verified. The order follows the README roadmap: finish step 2, then the parts of step 5 the demo covers, then messaging ahead of the speed-to-lead work in step 6. Estimates include the verify script per increment and assume the data model decisions below are taken first.

| Order | Increment | What it delivers | Needs | Effort |
| --- | --- | --- | --- | --- |
| 1 | Agent day at parity | Status grid and timer on My day, header chip, greeting, pauses column and note chips on My hours; statuses from `work_status` with colour from flags | Nothing new in SQL; `set_status` exists | 2–3 days |
| 2 | Current status view and Live board | `cma.current_status` view (latest event per user today) and its `cma_read` face; the Live screen with tiles and filters | A small view addition, no migration | 1–2 days |
| 3 | Hours, export and corrections | Hours and export screen, both CSVs with tenant format settings, the day editor on `correct_time_event` with required reason, Add day | A correction that opens a past day for another user (0002 addition) | 3–4 days |
| 4 | Dashboard | Tiles and the three bar cards on `workday_summary` and `time_interval` | Nothing new | 2 days |
| 5 | Team and access queue | Team screen on `app_user`, `user_role`, `organisation`; the "no access yet" queue; admin versus manager permissions | Decision on the `admin` role | 2–3 days |
| 6 | Configuration screens | Status catalog with flags, skill catalog with three dimensions and a level scale, tenant settings for formats | Migration 0003: skills and user skills | 3–4 days |
| 7 | Roster | Migration for roster, shift and absence; planner with quick typing and copy week; agent Schedule; shift line on Home and Live | Migration 0004 | 4–5 days |
| 8 | Messaging | Migration for message, delivery and outbox; composer, sent list, Home list, urgent modal with acknowledgement; polling first; ingest endpoint for Make | Migration 0005; realtime service choice can wait | 5–7 days |

Increments 1 to 4 need no migration beyond one view and one function, so they can start tomorrow and already replace the demo for the team's own use. Increment 8 is the largest because delivery resolution, acknowledgement and the ingest endpoint are new ground; the realtime service (README open decision) is not needed for the first version, a 10-second poll on the open screen is fine for a dozen agents.

Risks to the estimate: the corrections editor is fiddly (date-time entry, validation against 0002's rules, before-and-after display), and the roster migration should be designed with coverage in mind even though coverage itself comes later. Both are better taken on the heaviest model tier.

## Decisions to confirm and README updates

Ten decisions follow from the demo, three of them before increment 1 can be built as proposed.

| # | Decision | Proposal | Before |
| --- | --- | --- | --- |
| 1 | Which hours the agent and the export show | Total worked with "of which pauses" as the demo shows it, backed by `working`, `paid` and `billable` seconds as separate columns; confirm with Arno and Kira | Increment 1 |
| 2 | Status colour | Derived from flags: productive green, working but not productive rose, not working light blue; no display column | Increment 1 |
| 3 | Pulse4all's status list | Seed the demo's fifteen minus End of Shift in `02_seed_pulse4all.sql`, with flags per status; confirm the flags with Arno | Increment 1 |
| 4 | Forgotten clock-out | The agent may propose an end time from the dialog; it is stored as a correction awaiting a supervisor's approval and shows as proposed until then. Alternative: manager only, as decided on 5 October | Increment 3 |
| 5 | Clock out and back in | Keep "an ended day stays ended"; Break and Lunch are the pauses; a second clock-in is a correction | Increment 1 |
| 6 | `admin` role on the ladder | Add it: configuration, user management and connections for admins; operations for managers; answers the open README item | Increment 5 |
| 7 | Urgent messages | Read and acknowledged are two facts; the urgent modal writes acknowledged | Increment 8 |
| 8 | Export format | Separator, decimal mark and date format as tenant settings; Pulse4all seeded to the demo's Dutch Excel conventions | Increment 3 |
| 9 | Skills | Languages with a configurable level scale now; work type and channel in the same migration so the roster can use them | Increment 6 |
| 10 | Roster cells | Structured start and end plus absence types, with the demo's quick-typing parser as the entry method | Increment 7 |

**README updates to make once these are confirmed**

- Decision log, 5 October: the demo at `contactcenter.pulse4all.app` is the UI and interaction blueprint for the CMA; its screens, flows, copy and behaviour rules are adopted; its Firebase data layer is not
- Features 1: the status grid, the timer, the header chip and the agent's day line; the shift belongs to the day it started
- Features 7: acknowledgement separate from read; the three target types and the status condition
- Roadmap step 5: the screen list from the Build order table
- Open decisions: add items 1, 4, 6 to 10 above; items 2, 3 and 5 can go straight to the decision log

I can produce the full updated README.md with these changes on request, in one piece for replacement.

**Sources.** The demo at [contactcenter.pulse4all.app](https://contactcenter.pulse4all.app) (page source, stylesheet and Firebase configuration, read 5 October 2026), its Firestore data read through the signed-in session, and README.md sections Architecture, Data model: time model, API, Users and roles, Features, Authentication, Roadmap, Decision log and Open decisions. Screenshots of all 21 captured screens are available on request.
