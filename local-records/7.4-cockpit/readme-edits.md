# README edits: dashboard, cockpit, workspace (Martin's sharpening of 17 October 2026)

Drafted by the 7.4 subagent on 17 October 2026 for the lead to apply by hand. README.md was **not** edited. Line numbers are those of README.md at commit `main` of 17 October 2026 (2142 lines, 765,262 bytes, one paragraph per line). Every "current text" below was checked with `grep -c -F -f <anchor file>` against README.md and occurs **exactly once**, on the line named (the anchor files and the check are in `/var/tmp/7.4/`; the result table is at the end).

**Apply bottom-up** so the line numbers stay valid: edit 8 (line 2142), edit 7 (2021), edit 1 (after 2005), edit 6 (1621), edit 5 (1602), edit 4 (1377 and after it), edit 3 (after 1264), edit 2 (after 27). Net effect: +6 lines (three inserted paragraphs with their blank lines) and one new table row; 2142 becomes 2149.

Nothing here changes code, a migration, a permission key or a route. The permission keys named (`reports.view`, `performance.team`, `monitoring.live`, `roster.manage`, `workday.team`, `users.manage_agents`, `users.manage_all`, `messages.send`, `leads.manage`, `leads.accept`, `tenant.configure`, `workday.own`) and the write paths (`cma.roster_set_entry()`, `cma.send_message()`, `cma.correct_workday()`, `cma.set_person_skills()`, the owner write-back on 0009's outbox, 0011's queue engine) all exist in the README today (counts at the end).

## Notes for the lead (read before applying)

1. **"Workspace" already means the whole app.** The README uses "Workspace" 66 times for the application at workspace.pulse4all.app ("the Workspace Welcome", "the Workspace combines the CRM, telephony, …", "the Workspace talks only to Postgres"). Martin's concept uses it for the agent's surface, which the README calls the **Agent desk** (Feature 8, Roadmap step 8). The edits below keep Martin's word and avoid the clash by saying "three postures of one application" and "The **Workspace** is the agent's: the directive screen (Feature 8 …)". If Martin would rather keep the app's name unambiguous, the one-word swap is "Workspace" → "Agent desk" in edits 1, 2, 3 and 5; the rest stands.
2. **"Live, Report and Data stay the groups."** That is the README's own phrase for the management screens (Out of scope, line 1617: "Live, Report and Data show no customer data"); the rail's groups are named Time, Live, Reports, Team and Configuration elsewhere (lines 1206, 1593). The edits use the lead's wording, as asked; if the lead prefers the rail's names, change the sentence in edits 1 and 4 only.
3. **"the IT audit of 17 October 2026."** The README does not yet name the audit or its report path. Edits 2 and 4 say "the IT audit of 17 October 2026"; if the report lands under a path (for example `docs/audit/…`), put it in brackets there.
4. **Speed targets are new to the README** (`p95` occurs 0 times today). They are written as "proposed by the IT audit of 17 October 2026 … to confirm with Martin", the README's phrase for an unconfirmed derived choice ("to confirm with Martin" occurs 10 times).
5. **`leads.manage`** occurs once in the README (line 669, the alert rules' fallback permission). Using it as the cockpit's permission for "assign an owner" follows the lead's brief; 0009 may define a sharper key later, and then the Users and roles sentence (edit 3) names it.
6. **Rule 9 check (README decisions are settled): nothing below reopens a decision.** Checked against the Decision log and `local-records/readme-index/decisions-index.md`:
   - 7 Oct 2026, "Dashboard gated by `performance.team` (supervisor, manager, analytics); the Dashboard stays a Report page" (index 1729, 1739): unchanged; the Dashboard remains a page, "dashboard" the posture of a reader.
   - 7 Oct 2026, "Per person sorted by name, no ranking; analytics holds no `workday.team`" (index 1734): consistent, analytics stays read-only.
   - 7 Oct 2026, `admin` a superset of `manager`, `tenant.configure` left the manager row (Users and roles, Admin row): consistent, the Configuration handles follow `tenant.configure`.
   - 6 Oct 2026, directive contact-center suite; Callpit and the Subs agent UI as input, not code (Decision log; Out of scope): consistent, the Workspace surface is Feature 8 as written.
   - Open decisions line 2021 (`monitoring.live` for analytics): **already open**; edit 7 reframes it as the dashboard-versus-cockpit line and decides nothing.
   - Open decisions line 2037 (one-click dial through `POST /v1/users/:id/calls`, to verify on a live account): **already open**; edit 2 points to it and decides nothing.
   - Open decisions line 2055 (build versus buy check) and line 2012 (tenant picker, the "all business lines" view): untouched.
   - Out of scope, "Offering the CMA to other companies": nuance only; the substance (not sold, not licensed) is unchanged, as the lead asked.
   - Cross-references to "Roadmap step 9 … the one view of all KPIs and metrics" at lines 1186, 1261, 1378 and 1739 stay valid: edit 5 keeps "Kira's KPI dashboards as the one view of all KPIs and metrics" in step 9.

---

## Edit 1: Decision log, one new row dated 17 October 2026

**README line:** insert **after line 2005** (the table's last row) and **before line 2006** (`---`). The table header at line 1627 is `| Date | Decision | Why |`; rows end the decision cell with the person in brackets, dates read `17 Oct 2026`.

**Anchor (current text, last row, start of line 2005, occurs once):**

```
| 17 Oct 2026 | The runbooks derive a form's market from its name's two-letter prefix against the tenant's markets (`cma.market`), with no fixed list:
```

**New text (one line, inserted after line 2005):**

```
| 17 Oct 2026 | Three surfaces in one application, each derived from the viewer's permissions, never from a role key: the Dashboard for analytics (Kira, Peter, Bas: monitoring and steering on data and reports with read permissions only, `reports.view`, `performance.team`, the aggregates across business lines through `cma_read` and BigQuery; look), the Cockpit for the call center manager and the supervisor (the same signals, and next to each signal the handle to act on it from the same seat; look and act), the Workspace for agents (the directive screen of Feature 8: the next task served, the outcome in one press, Aircall embedded; do). The design rule of the management screens is "every signal has a handle": a signal with no write path behind it is a dashboard view; which handles appear follows the permissions (`roster.manage`, `workday.team`, `users.manage_agents`, `messages.send`, `leads.manage`, `tenant.configure`), so a tenant turns a supervisor into a cockpit or a dashboard by a grant. The information architecture does not change: Live, Report and Data stay the groups, the cockpit is a posture, not a page. Always standalone, bespoke for Pulse4all and copyable; selling or licensing stays out of scope (Martin's sharpening, 17 October 2026) | Pro-active steering of the workforce is the point of the management layer: the manager who sees a coverage gap, a lead past the target or a forgotten clock-out fixes it where they see it, through the write paths that exist (`roster_set_entry`, `send_message`, `correct_workday`, `set_person_skills`) or are planned (the owner write-back on 0009's outbox, 0011's queue engine), audited and permission-gated like every other write; a reader sees the same figures without the handles, so nothing is built twice. Deriving the surface from permissions keeps the ladder tenant configuration (Guiding principles 1 and 6), and naming the three surfaces gives every management screen one check: which signals, which handles, who holds them |
```

---

## Edit 2: "What we are building, in plain words", one added paragraph after the one-sentence description

**README line:** the one-sentence description is **line 26**; line 27 is blank; line 28 is `**Why we believe it works** (assessment of 6 October 2026, to be revisited with the business case below):`. Insert **after line 27** the new paragraph **followed by a blank line**, so `**Why we believe it works**` moves from line 28 to line 30.

**Anchor (current text, line 26, occurs once; the new paragraph goes after this sentence and its blank line):**

```
**In one sentence:** "We're building our own operating system for the Pulse4all contact center: it hands every agent their next call, keeps the clock, and shows management who's productive and which customers stay." Shorter still: air traffic control for our call center. Technically it is a workforce, productivity and management layer on top of CRM plus telephony, built as standalone technology. Contactcenter-Management-App is a working title; the final name is chosen with Mark.
```

**New text (one line, then one blank line):**

```
**Three surfaces, one application (Martin, 17 October 2026).** Who looks, who acts and who does the work get three postures of one application, each derived from the viewer's permissions, never from a role key (Users and roles). The **Dashboard** is for analytics (Kira, Peter, Bas): monitoring and steering on data and reports, read permissions only (`reports.view`, `performance.team`, the aggregates across business lines through `cma_read` and BigQuery); look. The **Cockpit** is for the call center manager and the supervisor: the same signals, and next to each signal the handle to act on it from the same seat: a coverage gap → add or move a shift, message the team; a lead past the speed-to-lead target → assign an owner, push an alert; a missed call waiting → hand it to an agent; an idle agent → push a message, later serve the next task; a forgotten clock-out → correct the day, add the day, send a notice; a ticket at 75 % of its response time (`tickets.sla_warning_pct`) → reassign; a skill gap → edit skills; look and act. Every handle uses a write path the CMA has or plans (`roster_set_entry`, `send_message`, `correct_workday`, `set_person_skills`, the owner write-back on 0009's outbox, 0011's queue engine), audited and gated by its permission; pro-active steering of the workforce is the point. The **Workspace** is the agent's: the directive screen (Feature 8; Roadmap steps 7 and 8): the next task served, the outcome in one press, Aircall embedded, and in time dialing from the screen as the AgentUI trial and Steam Connect did it; do. The ceiling on dialing is Aircall's: one-click dial is plausible (`POST /v1/users/:id/calls`, to verify on the live account, Open decisions); a power or predictive dialer is nothing Aircall exposes, so the queue engine gives a progressive dialer: serve, dial, book, next. Always standalone, bespoke for Pulse4all and copyable: built for Pulse4all's own business lines and run from configuration, so another company on a CRM plus Aircall could run a copy from configuration alone (Guiding principles 1 and 6; the cockpit's signals, thresholds and handles are tenant configuration too), while selling or licensing stays outside this project (Out of scope). Speed and UX are part of the concept, not a finish: a cockpit nobody waits for and a workspace that answers every click at once; the targets proposed by the IT audit of 17 October 2026 (server time to first byte p75 ≤ 300 ms and p95 ≤ 800 ms on the agent pages and the Live board, p75 ≤ 600 ms and p95 ≤ 1.5 s on reports; the shell paints within 200 ms; click feedback within 100 ms; to confirm with Martin) are how that is kept true.
```

---

## Edit 3: "Users and roles", role → surface derived from permissions

**README line:** the paragraph `Roles and permissions are tenant-aware: …` is **line 1263**; line 1264 is blank; line 1265 starts `**Preview as role (16 October 2026, N16-A).**`. Insert **after line 1264** the new paragraph **followed by a blank line**, so `**Preview as role**` moves from line 1265 to line 1267.

**Anchor (current text, the end of line 1263, occurs once; the new paragraph follows this sentence and its blank line):**

```
the worker kind for AI agents joins `kind` later.
```

**New text (one line, then one blank line):**

```
**Role and surface (17 October 2026).** Which of the three surfaces a person gets (What we are building) follows from their permissions, never from the role key: read permissions alone (`reports.view`, `performance.team`, `monitoring.live`) give the Dashboard, the figures and signals without handles; a write permission next to them (`roster.manage`, `workday.team`, `users.manage_agents`, `messages.send`, `leads.manage`, `tenant.configure`) turns the same screens into the Cockpit, each handle shown to the person who holds its permission and checked by the database like every write; `workday.own` with the agent's permissions (`leads.accept`, later the queue's) gives the Workspace. In the default ladder analytics is a dashboard, the supervisor and the manager a cockpit, the agent a workspace; a tenant moves a role from one surface to the other by a grant, as with every permission here, and Preview as role below shows an admin what each one sees.
```

---

## Edit 4: Features 9, new title and an intro paragraph on the design rule

**README line:** the heading is **line 1377**; the first line after it is **line 1378** (`- **Welcome:** …`, no blank line between them). Replace line 1377 and insert **after it** the intro paragraph **followed by a blank line** (Feature 8 at lines 1364 to 1367 has the same shape: heading, paragraph, blank, bullets), so `- **Welcome:**` moves from line 1378 to line 1380.

**Current heading (line 1377, occurs once):**

```
### 9. Management screens (from the demo, 6 October 2026)
```

**New heading:**

```
### 9. Cockpit: the management screens (from the demo, 6 October 2026; the cockpit since 17 October 2026)
```

**Current first line after the heading (start of line 1378, occurs once; unchanged, it moves down two lines):**

```
- **Welcome:** the landing page for everyone with a role, blocks per permission: updates,
```

**New intro paragraph (one line, then one blank line, between the heading and the Welcome bullet):**

```
The manager's and the supervisor's surface, the Cockpit since 17 October 2026 (What we are building; Users and roles, Role and surface). The screens below show the signals of the day, and the design rule is that every signal has a handle: next to a figure that asks for action sits the action, on the same screen, through a write path the CMA has or plans, audited and gated by its permission like every other write; a signal with no write path behind it is a dashboard view, and a person without the handle's permission sees the signal without the handle. The handles today: Correct a day and Add day on Team hours (`correct_workday`, `workday.team`), the planner's cells (`roster_set_entry`, `roster.manage`), the composer (`send_message`, `messages.send`), a person's teams and skills on People (`set_person_skills`, `users.manage_agents` or `users.manage_all`), the thresholds, alert rules and settings on Configuration (`tenant.configure`); the ones to come: an owner for a lead past the target, pushed to them (0009's offers and the owner write-back on the outbox), a missed caller handed to an agent and an idle agent served the next task (0011's queue engine), a ticket at risk reassigned (Roadmap step 9). Needs attention on Welcome and Follow-up now on the Live board already link each count to where it is acted on; the cockpit brings the action to the count. Live, Report and Data stay the groups: the cockpit is a posture, not a page, and the IT audit of 17 October 2026 checks every management screen against the rule (the manager's first week: which signals, which handles, who holds them).
```

(No other line in the README refers to this section by its title: `Features 9` and `Feature 9` occur 0 times, `Management screens` once, the heading itself.)

---

## Edit 5: Roadmap step 9, split into cockpit actions and dashboard views

**README line:** **line 1602**, replaced by one line (the list numbering 7, 8, 9, 10 at lines 1600 to 1603 is unchanged).

**Current text (line 1602, occurs once):**

```
9. **Manager and analytics views.** Productivity (Total Calls Today first, then talk time per worked hour, Prepare and Finish time), benchmarking, effectiveness, coverage, gamification, live and quality monitoring, Kira's KPI dashboards and the first cohort reports (retention and payment behaviour per entry cohort from HubSpot, Shopify and NetSuite).
```

**New text (one line):**

```
9. **Cockpit actions and dashboard views.** One step in two halves (What we are building, 17 October 2026). *Cockpit actions*, for the manager and the supervisor: the handle next to each signal that has none yet: an owner for a lead past the target, pushed to them (0009's offers and the owner write-back on the outbox); a missed caller handed to an agent and an idle agent served the next task (0011's queue engine); a shift added or moved from the coverage gap and a message to the team from the Live board (`roster_set_entry`, `send_message`); Correct a day from the forgotten clock-out (`correct_workday`); a ticket at risk reassigned; skills edited from the skill gap (`set_person_skills`); each through its existing or planned write path, audited and gated by its permission. *Dashboard views*, for analytics and every management layer: productivity (Total Calls Today first, then talk time per worked hour, Prepare and Finish time), benchmarking, effectiveness, coverage, gamification, live and quality monitoring, Kira's KPI dashboards as the one view of all KPIs and metrics, and the first cohort reports (retention and payment behaviour per entry cohort from HubSpot, Shopify and NetSuite). A view is built once and shown to both: the cockpit adds the handles, the dashboard shows the same figures without them.
```

---

## Edit 6: Out of scope, "Offering the CMA to other companies"

**README line:** **line 1621**, replaced by one line.

**Current text (line 1621, occurs once):**

```
- **Offering the CMA to other companies.** The CMA is built for Pulse4all's own business lines. It is developed as standalone technology, but selling or licensing it is not part of this project.
```

**New text (one line):**

```
- **Offering the CMA to other companies.** The CMA is built for Pulse4all's own business lines. It is developed as standalone technology, and built so that a copy runs from configuration alone (Guiding principles 1 and 6: another company on a CRM plus Aircall would configure its tenants, adapters, markets, skills, thresholds, cockpit signals and handles, not change code; What we are building, 17 October 2026), but selling or licensing it is not part of this project.
```

---

## Edit 7: Open decisions, the analytics / `monitoring.live` bullet, reframed as the dashboard-versus-cockpit line

**README line:** **line 2021**, replaced by one line. The existing text is kept in full (the history with Yordi and the Gemini audit belongs to it); the reframing is appended as three sentences, and the question stays open.

**Current text (line 2021, occurs once):**

```
- The employee-monitoring point with Yordi now covers the Live board too: live per-person status to supervisors, managers and analytics, besides the Dashboard's per-person time. Whether analytics (Kira, Peter, Bas) should hold `monitoring.live` is part of the ladder review with Arno and Kira; the board checks the permission, so changing that later is a grant, not code. Raised again by the seventh Gemini audit (13 October 2026): agents are live since 12 October, and Yordi's answers of that day cover processing, informing the agents and retention, not explicitly live per-person status; to confirm with Yordi. Settled for the per-person call figures (14 October 2026, brief B16): Reports → Calls per agent shows each person's calls, talk time and split by counted tag to `performance.team`, sorted by name and never ranked, as Yordi agreed (reported by Martin; Decision log); the Live board's live per-person status stays to confirm. Next: the per-person email figures of brief B17 (Reports → Email per agent in B17c: sends, replies, closes and first reply times per person and by hour of day, through the linked accounts) fall under the same point, to confirm with Yordi before that page goes live in prod. Yordi's answer of 15 October 2026 on email metadata, the scopes and the held contacts (Decision log) leaves this point as it is until Martin says it is settled.
```

**New text (one line):**

```
- The employee-monitoring point with Yordi now covers the Live board too: live per-person status to supervisors, managers and analytics, besides the Dashboard's per-person time. Whether analytics (Kira, Peter, Bas) should hold `monitoring.live` is part of the ladder review with Arno and Kira; the board checks the permission, so changing that later is a grant, not code. Raised again by the seventh Gemini audit (13 October 2026): agents are live since 12 October, and Yordi's answers of that day cover processing, informing the agents and retention, not explicitly live per-person status; to confirm with Yordi. Settled for the per-person call figures (14 October 2026, brief B16): Reports → Calls per agent shows each person's calls, talk time and split by counted tag to `performance.team`, sorted by name and never ranked, as Yordi agreed (reported by Martin; Decision log); the Live board's live per-person status stays to confirm. Next: the per-person email figures of brief B17 (Reports → Email per agent in B17c: sends, replies, closes and first reply times per person and by hour of day, through the linked accounts) fall under the same point, to confirm with Yordi before that page goes live in prod. Yordi's answer of 15 October 2026 on email metadata, the scopes and the held contacts (Decision log) leaves this point as it is until Martin says it is settled. Since 17 October 2026 this is also the dashboard-versus-cockpit line (What we are building; Users and roles, Role and surface): the Live board is a cockpit screen for the manager and the supervisor, and the open question for analytics is whether Kira, Peter and Bas see it as a dashboard view, the same tiles, strip and rows without the handles (`monitoring.live` granted, no write permission beside it), or not at all (`monitoring.live` not granted, the same signals reaching them through Reports → Follow-up and the Dashboard). Kira, as Head of Call Center, uses live monitoring (Users and roles; KPIs 9), so the answer may differ per person; either way it is a grant in the ladder review with Arno and Kira, not code, and the point with Yordi above stands.
```

---

## Edit 8: the "Last updated" line, a new pass note

**README line:** **line 2142** (8,579 characters). Only its **prefix** changes: the current pass becomes the first "Before it, 17 October 2026: …" segment, in the same form the line already uses for the earlier passes (at offset 2224 the line reads `Before it, 17 October 2026: the records of night run N16-B in dev and prod, … from Martin's report, and what they settle (no migration): Architecture (…)`). Everything after the prefix is unchanged.

**Current text (the prefix of line 2142, occurs once):**

```
*Last updated 17 October 2026 (the records of brief B17d in dev and prod, `records/b17d-dev-2026-10-17` and `records/b17d-prod-2026-10-17`, from Martin's report, and what they settle (no migration)): Architecture (Working on the code
```

**New text (replaces exactly that prefix; the rest of the line follows unchanged):**

```
*Last updated 17 October 2026 (dashboard, cockpit, workspace: Martin's sharpening of the concept, 17 October 2026; no migration, no code): What we are building (the three surfaces in one paragraph after the one-sentence description), Users and roles (Role and surface: derived from permissions, never from the role key), Features 9 (retitled Cockpit: the management screens, with the design rule "every signal has a handle"), Roadmap step 9 (Cockpit actions and dashboard views), Out of scope (a copy runs from configuration; selling or licensing stays out), one Decision log row of 17 October 2026 (the three surfaces and the rule) and Open decisions (the Live board for analytics as the dashboard-versus-cockpit line). Before it, 17 October 2026: the records of brief B17d in dev and prod, `records/b17d-dev-2026-10-17` and `records/b17d-prod-2026-10-17`, from Martin's report, and what they settle (no migration): Architecture (Working on the code
```

---

## Verification of the anchors

Run on 17 October 2026 against `/home/user/cma/README.md` (2142 lines). Each anchor was saved as one fixed string in `/var/tmp/7.4/<name>.txt` and counted with `grep -c -F -f /var/tmp/7.4/<name>.txt README.md`; the line was found with `grep -n -F -f …`.

| Anchor | Edit | Count | Line |
|---|---|---|---|
| line 26 in full (the one-sentence description) | 2 | 1 | 26 |
| `**Why we believe it works** (assessment of 6 October 2026, to be revisited with the business case below):` | 2 (the line that moves) | 1 | 28 |
| `the worker kind for AI agents joins \`kind\` later.` | 3 | 1 | 1263 |
| `**Preview as role (16 October 2026, N16-A).**` | 3 (the line that moves) | 1 | 1265 |
| `### 9. Management screens (from the demo, 6 October 2026)` | 4 | 1 | 1377 |
| `- **Welcome:** the landing page for everyone with a role, blocks per permission: updates,` | 4 (the line that moves) | 1 | 1378 |
| line 1602 in full (Roadmap step 9) | 5 | 1 | 1602 |
| line 1621 in full (Offering the CMA to other companies) | 6 | 1 | 1621 |
| `\| 17 Oct 2026 \| The runbooks derive a form's market from its name's two-letter prefix against the tenant's markets (\`cma.market\`), with no fixed list:` | 1 | 1 | 2005 |
| line 2021 in full (the `monitoring.live` bullet) | 7 | 1 | 2021 |
| `*Last updated 17 October 2026 (the records of brief B17d … (no migration)): Architecture (Working on the code` | 8 | 1 | 2142 |

Identifiers used in the new text and their occurrences in README.md today (so none is invented): `reports.view` 37, `performance.team` 59, `monitoring.live` 24, `roster.manage` 10, `workday.team` 28, `users.manage_agents` 17, `messages.send` 10, `leads.manage` 1, `leads.accept` 5, `tenant.configure` 48, `roster_set_entry` 2, `send_message` 5, `correct_workday` 10, `set_person_skills` 2, `fn_serve_next` 2, `users/:id/calls` 2 (Feature 8 and Open decisions line 2037), `sla_warning_pct` 4, `Head of Call Center` 2, `Steam Connect` 7. Words new to the README: `Cockpit` (0 today; `cockpit` once, in Out of scope for the AgentUI trial's cockpits), `posture` 0, `progressive` 0, `predictive` 0, `p95` 0, `every signal has a handle` 0.
