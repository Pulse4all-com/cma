# Plan B: when the Workspace is not available

What the contact center does when the CMA Workspace (`workspace.pulse4all.app`) does not load or does not
save, for an hour, a day or a week; how the hours are put back afterwards; and how the catch-up is checked.
Backlog CMA-032 (README Open decisions: "today: HubSpot and Aircall as they work now"). Roles, not names:
the call center manager, the agents, the CMA owner (Martin), compliance and data protection. Written for the
full IT audit of 17 October 2026; the agents' own short copy, in their language, is the manager's to make from
the sections "For the agents". The operator's side is `docs/OPERATIONS.md`.

## What the Workspace is, and is not

The Workspace keeps the agents' hours (clock-in, breaks, status changes, clock-out) and shows the manager's
day (Team hours, the Live board, the reports, Messages). Customer work was never in it: calls, notes, tasks
and outcomes live in HubSpot and Aircall, exactly as before the Workspace existed. The ingest service that
copies CRM, telephony and shop facts into the CMA is a separate service; it keeps running when the Workspace
is down, and when it is down the nightly reconcile and a backfill bring the facts in later
(`docs/OPERATIONS.md`, sections 5 and 6). Plan B is therefore about one thing: the hours.

## Who decides

- The CMA owner declares Plan B and declares it over, after the five-minute check of `docs/OPERATIONS.md`
  section 2. When the owner cannot be reached within 15 minutes, the call center manager declares it for the
  team and tells the owner at the first opportunity.
- The manager tells the agents, one message per team, and keeps the team informed. Agents tell their manager
  as soon as the Workspace does not load for them; one message per team is enough.
- The owner follows `docs/OPERATIONS.md`: section 2 (what is wrong), section 3 (roll back: `docs/RUNBOOK.md`
  section 10 for the web app), section 12 (who else is told). A question about staff data in the fallback
  (the sheets, their keeping) goes to compliance and data protection through the owner.

## The first hour

Agents: keep calling and keep logging in HubSpot and Aircall. Note the time the Workspace stopped for you and
every status change since, as hh:mm from the clock on your desk or phone. Retry the Workspace every quarter
of an hour; when it is back, check My day: if your day is still open, carry on; if it was closed, your manager
has it on the review list. No hours are lost in an hour: the day the Workspace knows stays open and the
manager corrects the gap afterwards (below).

Manager: tell the owner, tell the teams, hand out the sheet (below) to anyone who was not clocked in yet.

Owner: section 2 of OPERATIONS, then section 3. A web rollback takes seconds; the Version line bottom left and
`/api/health` show which version serves.

## A day

### For the agents: the sheet

The Workspace cannot record your day while it is away. Write your times down yourself, so your manager can
enter them later. One sheet per person and day:

| Field | Example |
|---|---|
| Date | 25 Oct 2026 |
| Start (clock-in) | 09:02 |
| Each break: start and end | 10:45 to 11:00; 13:00 to 13:30 |
| Each change of status and its time | 14:00 Available - Operations; 15:30 Coaching |
| End (clock-out) | 17:28 |
| Note | "Workspace unavailable"; anything your manager should know |

Write the time as hh:mm and note every change the moment it happens. Hand the sheet in at the end of the
day, or the next morning at the latest.

What not to do: do not clock in on a colleague's device or browser; do not sign in with someone else's
account or let anyone sign in with yours; do not try to catch up your own times afterwards (your manager
enters them from your sheet); do not stop logging your calls in HubSpot and Aircall.

### A day you could not close

If you were clocked in when the Workspace went away and could not clock out, the Workspace closes that day by
itself once the day's window has passed (Pulse4all: 22:00 plus an hour): at the end of your published shift if
you had one, otherwise at the tenant's default time (Pulse4all 17:00), never before your last change. It marks
the day for review and tells you and your manager. Your manager corrects it from your sheet to your real
clock-out. You do not need to do anything (README, Features 1).

### For the manager: entering the days

Once the Workspace is back: Time → Team hours → the person and date → Correct a day (for a day that was partly
recorded or closed by the rule) or Add day (for a day that was not recorded at all). Enter the rows from the
sheet: start, each status change, each break, end, in the day's own zone. Reason: "Workspace unavailable
<date>". One correction per person and day. The reason and your name stay with the change in the day's history,
so everyone can see later why the day was entered by hand. Days the Workspace closed by itself show on Team
hours as needing correction; correct them from the sheets first.

Keep the sheets until the days are entered and checked, then follow the usual rule for paper with staff times.

### Checking a day

- Team hours for the date: one row per person who worked, the totals as the sheets say, nothing left as
  needing correction.
- Download the status changes CSV for the date (Team hours → the export): every entered row with "Workspace
  unavailable <date>" as the reason, entered by the manager.
- The owner's side: the five-minute check passed, System health green, the daily check of OPERATIONS section
  10 the next morning.

## A week

A week of sheets for a whole team is too much for Correct a day. The legacy time import (`docs/import/README.md`,
addition 0008d) loads a batch of login and logout sessions as workdays in one go and can withdraw the whole
batch as a unit if something is wrong. It was built for the hours before the CMA existed and fits an outage
the same way, with these rules:

- The manager types the sheets into one spreadsheet, exported as a CSV in the import tool's layout
  (`tools/legacy-sessions-to-staging.mjs`: a person id, the person's name as the sheet shows it, login, logout
  and a session id per row; the column names and the date format are options). One row per uninterrupted
  stretch of work: a break is the gap between two rows, so a day with two breaks is three rows. The person id
  is anything stable per person (the sheet's number); the map file links it to the person's work email, and
  the CMA matches the email to a person at load time. The file never enters the repository and is deleted
  after the load (import README, steps 1 and 11).
- The owner runs the import from the Chromebook and Studio exactly as the import README says, with a batch
  key `outage-<first date>` and the zone `Europe/Amsterdam` (or the person's zone). What it does with the file
  is fixed: a session without a logout ends at the default close time (17:00), every session is clipped to the
  window (07:00 to 22:00), overlapping sessions are merged, a date the CMA already has a day for is skipped,
  and a day closed by the rule or clipped is flagged for review.
- What is lost: the status detail. Every imported stretch carries the import status (Steam session) and the
  gaps the gap status (Break); "Operations" versus "Coaching" is not in the import. If the team needs the
  status detail for the week, the manager enters it with Correct a day on the imported days afterwards (the
  imported history stays visible as "Imported from an earlier system, batch <key>").
- Days the Workspace already holds (an agent clocked in before the outage; a day the forgotten-day close
  ended) are skipped by the import and corrected by hand from the sheet.

### Checking the week

- The load's counts (import README, step 9): `days_written` equals the person-days on the sheets minus
  `days_skipped_existing`; `accounts_skipped` is 0; `days_closed_by_rule` and `days_clipped` are the days to
  review.
- Team hours for the week: each imported day as a normal day; Correct a day shows the batch key in its
  history; the review list only holds the days the counts named.
- The status changes CSV for the week names "Import" under Entered by.
- If the counts are wrong, the owner withdraws the batch (the void in the import README) and loads a corrected
  file; nothing is deleted, the history stays.

## Telephony, CRM, messages and reports meanwhile

- Calls and the CRM: nothing changes; HubSpot and Aircall are the source of truth and the CMA mirrors them
  later. Nothing waits for the Workspace.
- Messages to agents (the Workspace's Messages and the automations' alerts) do not arrive while it is down:
  the manager uses the team's usual channel outside the Workspace for the day.
- The Live board, the reports and the exports are unavailable; the figures catch up by themselves once the
  Workspace is back, because the ingest kept writing. If the database itself was down, the nightly reconcile
  covers 26 hours and anything longer is a backfill (`docs/OPERATIONS.md`, sections 5 and 6).

## How everyone knows it is back

Open the Workspace. It is back when the page loads, shows your name at the top and the line "Version …"
bottom left. Agents clock in as usual. The manager confirms to the owner that it is back for everyone and
whether anything is still missing; the owner confirms with the five-minute check and the System health page.

## Rollback runbook

The owner's steps to put the previous version back are `docs/RUNBOOK.md` section 10 (the web app, in
seconds) and `docs/OPERATIONS.md` section 3 (the ingest service, the jobs, the forgotten-day job; a database
migration is never rolled back, a mistake is a new migration). Plan B stays in force until the owner declares
it over.
