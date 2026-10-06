# Subs agent UI analysis: p4a-agent-ui-subs-dev.netlify.app and the shortlist for the CMA

Oct 5, 2026 · @Martin

## Summary

The Subs agent UI is the same cockpit as Callpit with the Subs campaign switched on, and it is the one of the three that already carries CMA features: a My account panel with clock in, clock out, teams, skills and worked hours, a Total Calls Today report per agent, a queue counter in English, and the Pulse4all theme. It is live at `p4a-agent-ui-subs-dev.netlify.app` without a login on mock data; the handover's note that this site had never deployed is out of date.

What it covers: the Subs sales screen in English and Pulse4all colours, a contact block with Country, Language and a GB-only Vulnerable flag, a product block (#HS1, #FRx, expected order date, message lead, free text), a quotation block, ten dispositions with keys 1 to 0, four product-email processors with keys Q to R (Buurt AED enabled only for nl-NL), HubSpot and Shopify deep links, and the tools Script and Q&A, Send an e-mail, Reports, Search, Account, Open calls and an assistant shell. The My account panel is already named in the README as input for Roadmap step 2, and this analysis confirms what it does.

The verdict:

- Take into the CMA now: the My account panel's structure and copy for My day and My hours (clocked in at login, clock out, read-only details, teams and skills, hours per period), the Total Calls Today table as the first productivity view on the Live surface, the queue counter's English copy and four figures, the GB-only Vulnerable handling as the model for the UK vulnerability alert, the per-campaign copy and theme switch as the pattern for per-tenant locale and brand, and the crash copy that reassures the agent that the call is still connected
- Take as rules: a disposition that requires something asks for exactly that; processors are blocked with a plain reason when a field is missing; a product email is enabled by country
- Leave with the cockpit or HubSpot: the contact and product form, dispositions, quotes, product emails, memo and search. Customer work stays out of the CMA (README: Out of scope)
- Two things found live that the handover predicted: the Subs codes still book against the Invest registry (Not Interested opens a Dutch dialog asking for Bezwaar, Deal Won asks for Propositie), and Request Quote is configured but never rendered

The teams-and-skills model on this screen (team = market and language, skill = call type) differs from the README's three skill dimensions; that is the one modelling decision to settle before the My account panel's Teams and Skills rows are built on `app_user`.

## How this was done

Same method as for Callpit, because it is the same code base with another campaign: a read of the beautified bundle plus a headless walkthrough of every overlay, checked against the handover's Subs Sales Agent UI section. 5 October 2026, around 22:30 CEST:

1. Fetched the page: Next.js, `lang="en"`, Montserrat loaded from the site's own `/fonts` folder, the `logo-p4a.svg` mark, title and description still those of the Invest PoC
2. Downloaded and beautified the page chunk (134 KB, 6,134 lines) and read the configuration: the Invest and Subs campaign configs side by side, the Subs result codes and button grid, the five processors with their gating, the 16 mock agents with Aircall refs, teams and skills, the field definitions including the GB-only Vulnerable checkbox, the two copy files (Dutch for Invest, English for Subs) and the two themes (Steam and Pulse4all)
3. Rendered the screen at 1920 × 1000 and opened every tool: Account, Reports, Script, E-mail, Search, Open calls, the agent profile with its switcher, the assistant bubble; pressed Follow Up, Not Interested and Deal Won as far as their dialogs; pressed Philips HS1; simulated an incoming call with `?p4atest`; set Country to GB to reveal the Vulnerable field
4. Compared with the handover's Subs section: what differs from Invest, the decisions already taken, the deployment state

Nothing was booked or sent. Mock data only: the contact Johan de Vries from the Invest build with Subs fields added, sixteen agents with example.com-style addresses, placeholder hours and call counts that the panels themselves label as placeholders. Fifteen screenshots are in the sandbox and can be attached on request.

## What is live and what changed since the handover

The site deploys and runs the Subs campaign, so the handover's Deployment state ("never had a successful published deploy") is resolved; the build also carries the Invest campaign, the Steam theme and the Dutch copy, selected by a `byCampaign` switch at build time.

| Aspect | Found |
| --- | --- |
| Campaign | `subs-sales`: banner "AED Subscription Sales", one Leads tab, shared queue model, objection emphasis prominent, field blocks `names`, `contact`, `campaign`, `product`, `mergeText`, `quote` |
| Theme | Pulse4all: page `#EAF4FC`, chrome Deep `#265BA4`, banner Light blue `#9ECFF5`, titles `#2E61A6`, pauses and negatives Rose `#F4D9D0` with Inkt text, Deal Won Green `#27AE6F`, processors Light blue, required marks `#C4553C`, 4 px radius; Montserrat served from `/fonts` |
| Copy | English, with `en-GB` dates; one copy file with `nl` and `en` branches; the disposition dialogs and the incoming-call pop still render Dutch strings from the Invest branch |
| Tools enabled | Script, E-mail, Reports and Account on; Formulier off (the reverse of Invest, where Reports and Account are off) |
| Agents | 16 mock agents with Aircall refs, teams as locale codes (`en-GB`, `nl-NL`, …) and skills as call types (`Sales`); Arno as Callcenter Manager, Martin as System Admin with eight teams |
| API routes | Same mock routes as Callpit; `/api/lookup-by-number` fails from the incoming-call pop ("Lookup failed. The number is shown above.") |
| Outbound | Processors and the e-mail tool post to the same Make webhook as Callpit, from the browser |
| Aircall | "Phone disabled in this environment": the softphone is not mounted on this site |
| Title and description | Still "CRM Pulse4all - Agent" and "P4A Call Center Agent UI - Invest PoC" |

**Gaps found live**

- Not Interested opens "Nog nodig om af te boeken · 200 · Geen interesse" asking for Bezwaar; Deal Won opens "600 · Deal" asking for Propositie and Bedrag. The Subs grid books against the Invest registry, exactly the collision the handover warns about (`200` Not Interested versus Geen interesse, `600` Deal Won versus Deal); the Subs catalog has not been seeded
- Request Quote (code 106) is configured with `renderIn: quotePanel` but the grid filter drops it and the quotation block has no button, so a quote cannot be requested
- Lead is Customer (301) and Email Only (302) have no registry entry at all; pressing them would book an unknown code
- The Vulnerable checkbox appears only when Country is GB and is marked required with an asterisk, but nothing enforces it
- The assistant bubble is a shell with three suggested questions and a note that it is not connected

## The screen, element by element

The layout is Callpit's: one screen, call bar on top, banner, context strip, objection on the left, form in the middle, buttons and memo on the right. Where the Invest cockpit is dark purple and Dutch, this one is Pulse4all blue and English.

**Call bar.** Phone | Mobile toggle, the staged number, the phone status ("Phone disabled in this environment" here), a CRM Pulse4all card with the agent name that opens the agent profile (details plus a dev-only Switch agent list of all sixteen, with the note "Switching is a test aid. With a real login the agent comes from the session."), the result-code dropdown with ten Subs codes, the memo badge (23), and six tools: Script, E-mail, Reports, Search, Account and Open calls ("37 open today").

**Banner and context strip.** Pulse4all logo, "AED Subscription Sales", then "Callback appointment, scheduled by you · Attempt 5 of 6 · 12 attempts on this ticket · Ticket TCK-24019 · Last called Tue, 25 Aug, 14:12 · 500".

**Left column.** Objection dropdown with the required edge, given more room than in Invest (objection emphasis prominent). No softphone dock on this site.

**Form.** First Name and Last Name as pill labels; Phone, Mobile, Email; Organization, Target Group (14 options from General to Outdoor Cabinet); Country (15 codes) and Language (11 codes) as separate fields; Open HubSpot and Open Shopify; Vulnerable, only for GB; Lead Created, Source (a HDYHAU list of 15), Advertorial, HDYHAU; Message Lead; #HS1 and #FRx (1 to 15); Expected Order Date; Free Text with newlines allowed. Below, a Quotation card: Date Of Issue, Due Date, Type (Philips HS1 or FRx), Quantity, Apply Discount.

**Button grid.** Not Reached (1) in Denim, Follow Up (2) and Follow Up Prio (3) in Deep, Not Interested (4), No Cooperation (5), Nurturing (6), Wrong Phone (7), Lead is Customer (8), Email Only (9) in Rose, Deal Won (0) in Green; then four light-blue processors with a mail icon: Philips HS1/FRx (Q), Philips HS1 (W), Philips FRx (E), Buurt AED (R, enabled only when Country is nl-NL, reason shown as "Netherlands only"). Each processor requires an email address and refuses with "Cannot send - fill in first: Email".

**Memo** with the prefilled ` dd-mm-yyyy hh:mm Agent:  ` line and the history behind the badge.

**Overlays.** Search ("Search opens the record outside the queue. Your current task stays yours."), Open calls (Scheduled for me 12, From the shared pool 25, Total 37, Handled today 46; periods Today, Tomorrow, This week, From – to), Callback time (the Callpit picker in English: Mo to Su, ISO weeks, Reset, Confirm), Script and Q&A (Opening, Understanding the need, Closing, with placeholders and an Open helpdesk link), Send an e-mail (Subject, "Dear Johan,", body, signature from the agent record), the incoming-call pop, the assistant bubble, and the two described next: My account and Total Calls Today.

**Against Callpit.** Same bones, three real additions (Account, Reports, Vulnerable), a cleaner grid with shortcut keys for all ten dispositions, English copy and the house style. The crash screen's copy is new and good: "Your call is still connected. Tell your supervisor the ticket number and reload the screen - unsaved changes on this record will be lost."

## My account and Total Calls Today

These two overlays are CMA features living inside the cockpit; the README already names the My account panel as input for Roadmap step 2, and both map onto data the CMA holds or will hold.

**My account** (820 px modal, Pulse4all header). Three blocks:

1. Clock block: the agent's name, "Clocked in at login · 09:12" or "Not clocked in", and one button that reads Clock out (Rose) when clocked in and Clock in (Green) when not
2. Details, read only, two columns: First name, Last name, Email, Phone, Job title, Aircall ref, Teams (`en-GB`), Skills (`Sales`), and the line "Details are maintained by your administrator."
3. Worked hours: period chips Today, This week, This month, From – to; a table Date, In, Out, Total with a total row ("Thu 03 Sep 09:12 — 4:44" for the open day); two notes: "If you forget to clock out, the system closes your shift at 23:00 using the time of your last disposition." and "Placeholder data - clocking in and out is not saved yet."

| Panel rule | CMA today (README: Roadmap step 2, migration 0002) | Take |
| --- | --- | --- |
| Clocked in at login | Login opens the workday (Features 1); My day shows the clock | Same; the copy "Clocked in at login · 09:12" is better than a bare time |
| One Clock out button, no statuses | Clock and End workday exist; statuses from `work_status` are the next increment | Keep the panel's clock block as the header of My day; the status grid from the first demo sits under it |
| Details read only, maintained by the administrator | `app_user`, employer, role; Aircall ref is `app_user_external_id` (`aircall_user`) | Same, plus employer |
| Teams as locale codes, skills as call types | README: teams and markets are configuration; skills have language, work type and channel | Show both rows; the model behind them is the decision below |
| Hours per day with In, Out, Total and periods | My hours has today, week, month, custom range | Same table; add pauses and the note chips from the first demo |
| Forgotten clock-out closed at 23:00 at the last disposition | 0002 leaves the day open, caps it at the end of the business day and flags it; the scheduler rule is an open decision, with "last Aircall or HubSpot activity" as a candidate | This panel states the rule as copy; the CMA can adopt it as the scheduler rule once dispositions or Aircall events are synced, and the copy should then say so to the agent |

**Total Calls Today** (Reports). "Per agent, across all campaigns. All calls count." A table Agent, Total Calls, Inbound, Outbound for sixteen agents, sorted by total, with a total row (304, 19, 285) and a note that the figures are placeholders. Visible to every agent, not only managers.

For the CMA this is the first productivity view (README: Features 5, KPI 7) and it belongs on the Live surface, fed by the Aircall sync into Postgres, with talk time rather than call count as the second measure and a filter by team once teams exist. Whether agents see each other's numbers is a gamification choice (Features 6) and a question for Arno; the cockpit shows the whole table to everyone.

## Subs result codes, processors and the collision

Ten Subs dispositions reuse Invest's code numbers with different meanings, and nothing has been seeded for Subs; the live dialogs show what that does.

| Key | Code | Subs label | Invest label on the same code | Registry entry found | What happens on press today |
| --- | --- | --- | --- | --- | --- |
| 1 | 400 | Not Reached | Geen gehoor | yes, retry 48 h, ceiling 6 | books as Geen gehoor |
| 2 | 500 | Follow Up | Terugbellen | yes, requires callback | English callback picker, then books as Terugbellen |
| 3 | 501 | Follow Up Prio | Terugbellen met prio | yes, ceiling 10 | same |
| 4 | 200 | Not Interested | Geen interesse | yes, requires Bezwaar | Dutch dialog asking for Bezwaar |
| 5 | 201 | No Cooperation | Geen medewerking | yes | books |
| 6 | 202 | Nurturing | Sleepnet | yes, long-term pool | books |
| 7 | 300 | Wrong Phone | Foutief nummer | yes | books |
| 8 | 301 | Lead is Customer | — | no | unknown code |
| 9 | 302 | Email Only | — | no | unknown code |
| 0 | 600 | Deal Won | Deal | yes, requires Propositie and amount | Dutch dialog asking for Propositie and Bedrag |

Processors: 102 Philips HS1/FRx (Q), 103 Philips HS1 (W), 104 Philips FRx (E), 105 Buurt AED (R, nl-NL only), 106 Request Quote (configured for the quotation panel, not rendered). All four email processors require an email address; a press posts the agent, contact, campaign and merge texts to the Make webhook and writes a system line into the memo.

The handover's decision stands and the screen confirms why: one `result_codes` table with a `call_type` scope, seeded only once Kira confirms semantics, priorities, retry intervals and do-not-call flags for Subs. For the CMA the relevant part is the shape, not the codes: outcome metrics will be defined on a scoped catalog (business line, call type, code), and the KPI definitions in the README (conversion, reasons for not buying, attempts per lead) need that scope to avoid counting Invest's Sleepnet as Subs' Nurturing.

## Elements for the CMA

Twelve elements go into the CMA, more than from either other mockup, because this build already contains the agent-side CMA features; the customer screen itself stays out.

| Element | Decision | Lives in | Source | Notes |
| --- | --- | --- | --- | --- |
| My account clock block: "Clocked in at login · 09:12", one Clock out button, state colours Green and Rose | Adopt as the header of My day | Agent | `workday` | Already named as input in Roadmap step 2 |
| Read-only details with employer, teams, skills, Aircall ref and the administrator line | Adopt | Agent | `app_user`, `organisation`, `app_user_external_id`, roles and skills | Skills and teams rows follow the model decision below |
| Worked hours table with period chips and a From – to range | Adopt; already built in My hours | Agent | `workday_summary` | Add pauses and note chips from the first demo |
| Auto-close copy that tells the agent the rule | Adopt the practice of stating the rule on screen; the rule itself is the scheduler decision | Agent | `work_status`, scheduler | Copy must match what 0002 does, not what the cockpit promised |
| Total Calls Today per agent, inbound and outbound | Adopt as the first productivity view; add talk time | Live, Report | Aircall sync | Visibility to agents is a gamification decision |
| Queue counter: Scheduled for me, From the shared pool, Total, Handled today, with periods | Adopt the copy and shape for open work and speed-to-lead | Live, Agent | lead assignment events (Roadmap step 6) |  |
| Vulnerable only for GB, marked required | Adopt the conditional pattern; in the CMA the alert shows case status and a HubSpot link, never the flag's context | Live | HubSpot sync | README: KPI 6 and the vulnerability rule |
| Per-campaign copy file (`nl`, `en`) and per-campaign theme | Adopt as per-tenant locale and brand; the CMA's `copy.ts` already has `en` and `nl` | Agent, Live | tenant configuration | Locale per user is an open README decision |
| Agent switcher as a dev-only aid with an on-screen note | Already the CMA's mock-identity approach | — | — | The note's wording is worth copying |
| Processor gating by field (needs email) and by country (Buurt AED nl-NL) with a shown reason | Adopt the pattern for any blocked action | Agent | configuration | Same shape as "needed to book" |
| Crash screen copy ("Your call is still connected…") | Adopt | Agent | — |  |
| Keyboard keys 1–9 and 0 for a ten-item grid, Q–R for actions, F2 search | Adopt for status buttons on My day | Agent | — | Confirm with Arno |
| Contact and product form, Country and Language fields, dispositions, quotation, product emails, memo, search, assistant | Leave with the cockpit or HubSpot | — | — | Customer work; out of scope for the CMA |

One cockpit decision to carry over as a CMA rule: Team = market and language, skill = call type, both hard filters, both on the campaign. The README has the same intent (skills drive rostering and assignment) with a richer shape; the next section says where they differ.

## Conflicts with the README and risks

The Subs build adds one modelling conflict to the ones already noted for Callpit, and it is the one that matters most because it decides how `app_user`, teams and skills are shaped.

**Teams and skills.** The cockpit: team = market and language (`en-GB`, `nl-NL`), skill = call type (Sales, Courtesy, Open Payment, FCA), both hard filters on the campaign, junction tables per agent, no proficiency. The README: skills along three dimensions, language, work type and channel, each with proficiency and validity, and teams, sites and markets as separate configuration (Features 3, Target scope). The cockpit's model is simpler and proven at 2.6 ms for 5,000 tasks; the README's is needed for coverage depth and for channels beyond phone. They reconcile if a market is a team attribute, a language is a skill with a level, a call type is a work-type skill, and the queue's hard filters are derived from skills at level 1 or higher. The My account panel's Teams and Skills rows then read from that model. Decide before increment 6 of the first demo's build order.

**Forgotten clock-out.** The panel promises "the system closes your shift at 23:00 using the time of your last disposition". 0002 keeps the day open, caps it at the end of the business day and flags it; the scheduler rule is open (roster end time, last Aircall or HubSpot activity). The cockpit's rule is a reasonable candidate once dispositions or Aircall events are synced, but the CMA must not show this sentence until it is true.

**Result-code collision, live.** The Subs grid books Invest codes and shows Dutch dialogs for them. Harmless on mock data; on the real engine it would set Invest-shaped follow-ups on Subs contacts. The handover's fix (scoped `result_codes`, seed only after Kira confirms) is right; the CMA's KPI definitions depend on the same scope.

**Already noted for Callpit and unchanged here.** Callpit is parked and the CMA shows no customer data; tasks and dispositions need an owner in Source of truth; the site is public with mock data; the Make webhook URL is in the bundle and personal data would leave the browser without an audit trail; Aircall's client-side `call_ended` is not a record.

**Smaller risks**

- The Vulnerable flag is required by label only; nothing enforces it, and the duty-of-care consequence (who sees it, what changes in handling) is undefined on screen
- Lead is Customer and Email Only have no registry entries; a press books an unknown code
- Request Quote cannot be reached, so the quotation block is a form without an action
- Title and description still say Invest PoC; Dutch strings leak into English dialogs
- Total Calls Today shows every agent's numbers to every agent; fine for a mock, a decision for real use

## Decisions to confirm and README updates

Six decisions, of which the first shapes the people model and should be taken with Arno and Kira before the Team and configuration increments.

| # | Decision | Proposal | Before |
| --- | --- | --- | --- |
| 1 | Teams and skills model | Market is an attribute of a team; language is a skill with a level; call type is a work-type skill; channel is the third dimension; the queue's hard filters are derived from skills at level 1 or higher. One model serves the cockpit's eligibility and the CMA's coverage | Increment 5 (Team) and 6 (configuration) |
| 2 | My day header | The My account clock block ("Clocked in at login · 09:12", one Clock out button) above the status grid from the first demo | Increment 1 |
| 3 | Scheduler rule for forgotten clock-outs | Candidate from the panel: close at a tenant-configured hour using the last disposition or Aircall activity; until Sync exists, keep 0002's open-and-flagged behaviour and show copy that matches it | Roadmap step 3 (Sync), then the scheduler in step 5 |
| 4 | Total Calls Today | First productivity view on Live, per agent, inbound and outbound plus talk time, from the Aircall sync; whether agents see colleagues' numbers is decided with Arno under gamification | Roadmap step 7 |
| 5 | Scoped result-code catalog as KPI vocabulary | The CMA's KPI definitions reference (business line, call type, code); confirm with Kira together with the Subs seed | Roadmap step 4 (Data first) |
| 6 | Locale and brand per tenant | The per-campaign copy and theme switch becomes tenant configuration; a locale per user stays a separate open decision | Increment 6 |

**README updates to make once confirmed**

- Roadmap step 2: the My account panel's clock block and copy are adopted for My day; note that the panel's auto-close sentence is not adopted until the scheduler exists
- Features 3: the reconciliation of the cockpit's team-and-skill model with the three dimensions (decision 1)
- Features 5: Total Calls Today as the first productivity view, with talk time
- KPIs, Data first: the scoped result-code catalog as a prerequisite for KPIs 1, 5 and 7
- Out of scope, the Neon/Netlify trial: record that `p4a-agent-ui-subs-dev.netlify.app` now deploys the Subs build, so the handover's deployment note is superseded
- Open decisions: add 1, 3, 4 and 6 above

I can produce the full updated README.md with the changes from all three analyses on request.

**Sources.** [p4a-agent-ui-subs-dev.netlify.app](https://p4a-agent-ui-subs-dev.netlify.app) (page, client bundle, copy and theme, mock API routes, read 5 October 2026); the platform handover in this project (Subs Sales Agent UI, Data model and queue engine, Deployment state); README.md sections Features, Target scope, KPIs, Roadmap, Out of scope and Open decisions; the two earlier analyses in this project for the shared findings. Fifteen screenshots are available on request.
