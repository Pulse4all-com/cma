# KPIs and business case

Part of the CMA documentation (README.md, Documentation map). Moved verbatim from README.md on 20 October 2026.

## KPIs and steering for the Head of Call Center

This section is Pulse4all's configuration of the metric catalog: deal stages, closed-lost reasons, markets and GB rules are tenant settings, not product rules. Another customer defines its own.

Kira steers the call center on six outcomes: **conversion (speed to lead), indirect sales, reviews as high as possible, churn as low as possible, and complaints and vulnerability in the UK**. The metrics below are what she needs to steer on. Each area is tagged with where it lives:

- **Live**: real-time view or alert in the CMA (manager and supervisor)
- **Agent**: per-agent view for manager, supervisor and the agent's own dashboard
- **Report**: weekly or trend reporting from Postgres / BigQuery
- **Data**: prerequisite in HubSpot or Aircall, not something the CMA builds

| # | Area | Where | Sources |
|---|------|-------|---------|
| 1 | Conversion and speed to lead | Report, Live | HubSpot, Aircall, CMA |
| 2 | Indirect sales | Report, Agent | Shopify (via HubSpot), HubSpot |
| 3 | Reviews | Report, Live | Review platform (to decide), HubSpot |
| 4 | Churn and contract length | Report | HubSpot, Shopify / Juo |
| 5 | Reasons for not buying | Report, Agent | HubSpot, CMA result codes |
| 6 | Complaints and vulnerability (GB) | Live, Report | HubSpot tickets and contacts |
| 7 | Productivity per agent | Agent, Live | Aircall, HubSpot, CMA |
| 8 | Effectiveness per agent | Agent | Aircall, HubSpot, CMA |
| 9 | Live monitoring | Live | Aircall, HubSpot, CMA |
| 10 | Quality monitoring | Agent, Report | Aircall AI, HubSpot, CMA |
| 11 | Data first | Data | HubSpot, Aircall, every connected source |
| 12 | Cohorts | Report | HubSpot, Shopify / Juo, NetSuite, Asset Management Database, CMA |

### 1. Conversion and speed to lead
- Leads per day per country and source, excluding test deals.
- Speed to lead within office hours: median, % within 1 hour, % called before 12:00 the next working day.
- Open leads (not called, not ordered, not closed) per country and day of entry.
- Attempts per deal, reached, speed to lead per outcome: since addition 0008y (19 October 2026), for sales since addition 0008z (20 October 2026), on Reports → Attempts per deal: the sales deals' outbound Aircall calls until won, lost or the first order, reached by the outcome or the talk time, and won against lost with the attempts, the speed to lead and called before the next noon (Kira). Data prerequisites (KPIs 11): the Aircall–HubSpot call link (every Aircall call logged on the contact or the deal with its counterpart, so 0007a pairs them) and the outcome set by agents on every call (the page shows the share without one). To move to the queue engine's attempts with the agent desk (0011). It covers HubSpot's "Open deals by activity date" and "Open deals not contacted recently" (CMA-042's port rule: two weeks side by side before those reports go).
- Lead to order: conversion rate and time to order.

Speed to lead is defined in `docs/night-2026-10-10/DESIGN.md` §4.4 (night of 10 October 2026); office hours per market are tenant configuration. Since addition 0008p (brief B17d) a counted form's submission is a lead only when its form has no lead condition or the answer is one of the condition's values: Pulse4all's nine Contact forms count "No, I'm not a customer yet" and not existing customers or a missing answer (Decision log, 16 October 2026). The rule is live in prod since 17 October 2026: Intake's form submissions from 1 to 16 October went from 448 to 424, the 24 existing customers among the 43 Contact submissions; Kira was informed beforehand and agreed (Decision log, 17 October 2026; `records/b17d-prod-2026-10-17`). Migration 0007d computes it, with lead to order, intake per day and the data-quality checks of section 11 (see Data model: lead metrics); the Workspace reports follow.

The CMA's assignment, accept click and 5-minute rule (see Speed to lead) are the operational lever for these numbers; the assignment event log adds time to offer, time to accept and expiry rate per agent. With the agent desk, attempts and result codes are CMA facts, so reach rate and attempts per lead come from the queue engine.

### 2. Indirect sales
- Orders linked to leads with order time: was there contact before the order, yes or no.
- A unique link per deal, so an order placed from a different email address still counts.
- Orders per agent.
- **As built (night run N19-A, addition 0008u; merged 19 October 2026 as `997749c`):** Reports → First orders splits the new customers' first orders into self-service and call center by evidence levels in the tenant's order (lead deal, conversation, email, phone match, attempt, known contact; else self-service), the first four assisted, within a 90-day window, a known contact at least 60 minutes old, the store order matched within 1,440 minutes; all five are tenant settings with these proposed defaults, for Kira to confirm (Open decisions, Indirect sales). Renewals, repeat orders, the store's not-first orders and orders without a contact are counted apart, never attributed; the credited person owns the latest assisted touch (Orders per person, off until Yordi confirms it).
- **Needs:** Shopify orders in the CMA: since brief B10 (13 October 2026) read per store with their kind, the customer's CRM contact kept in the CMA (addition 0008h, B10.1; nothing written back to HubSpot), and a keyed hash of the order's phone (addition 0008g) for matching to earlier calls; the rules that make an order indirect are an Open decision (Kira). Data prerequisite: in the NL store's first read (14 October 2026) 339 of 501 orders carried the hash; the rest have the phone only in the shipping address, which the adapter never reads (Open decisions, Indirect sales).

### 3. Reviews
- Score and number of reviews per country per week.
- Reviews following deal stage 4.4 Completed Happy.
- Negative review flagged within one day (live alert).

### 4. Churn and contract length
- Cancellations per country per week, with Cancellation Reason (the ticket property `cancellation_reason`, Dropdown select, 11 options, in the live portal since Joshua's task: Martin, 21 October 2026). Since brief B17d (addition 0008p) the cancellation forms' submissions per market and week, with the answers of `cancellation_reason`, are on Reports → Forms; since addition 0008zb (brief N21) Reports → Cancellations counts the cancellation requests (the tickets of the kind `reports.cancellation_kind` names, by a pipeline or category rule on Configuration → Sources) per market and per ISO week or day, open and closed with the median days to close and the tickets' Cancellation Reason (a dropdown only). It counts requests, not contracts; cancellations as contract events come with the subscription data later.
- Cancellations before the minimum term, reported separately.
- Active contracts older than 12, 24 and 36 months.
- CCL confirmed vs. not confirmed (a later phase, split off CMA-049 on 20 October 2026: Decision log), churn per cohort.

### 5. Reasons for not buying
- Closed Lost Reason per country, source, agent and week; top 3 per country. Since addition 0008zb (brief N21) on Reports → Funnel, Lost reasons: the real reasons with their share, per market and per source with the top 3, per ISO week or day, and per deal owner in Deals per person (behind `reports.per_person` holding `deals`, off for Pulse4all until Yordi agrees); the reason from the deals' dropdown property only, never free text. The same page shows how the deals move through their stages (entered, still there, moved on, days in stage, reached won, from HubSpot's own stage history, addition 0008za) and the win rate by close date, with a link per pipeline to Attempts per deal.
- Closed Lost Reason mandatory (Open decisions). Garbage, Duplicate, Wrong Phone and Accidentally Signed Up count as data quality, not as lost sales: a reason is flagged so on Configuration → Sources and Reports → Funnel shows those deals apart from the real lost reasons.
- Defined on the scoped result-code catalog (business line, call type, code), so Invest's Sleepnet is never counted as Subs' Nurturing.

Callbacks kept (KPIs and steering, row 5): since the night of 16 October 2026 (addition 0008n) the CRM's tasks reach the Workspace without their text and a task type can be marked a callback on Sources, and `tasks.callback_window_minutes` (240) is a setting (0008o); since the night run N19-A (addition 0008w; merged 19 October 2026 as `997749c`) the figure is computed: a callback kept when a call with the task's contact, in either direction, starts within the window of its due time, on the Dashboard's Intake row and per ISO week and per person on Reports → Follow-up, with the definition proposed in Open decisions for Kira to confirm. Reports → Follow-up shows the open callback tasks with a badge.

### 6. Complaints and vulnerability (GB)
- Complaints per country: number, subject, time to resolve, still open.
- GB: vulnerable customers, type, follow-up, agreements kept. OPC and collections for vulnerable customers reported separately.
- Alert when a complaint or vulnerable case is open longer than 1 working day.
- **Needs:** vulnerability field on the contact, complaint as a ticket category.
- Vulnerability data is sensitive. Alerts in the CMA show case status and a link to HubSpot, not the customer's details; on the desk the flag shows only for GB records, as in the Subs agent UI. Handling is agreed with Yordi.
- The FCA compliance monitor for UK consumers starts as a journey placeholder on Campaign monitoring (night run N19-A, addition 0008v): every UK consumer customer through every required communication and step, with drill-down per customer and an audit pack, once its prerequisites are in place (KPIs 11) and its step list is agreed (Gemma and Kira, checked by Yordi).

### 7. Productivity per agent
- Calls in and out per day per campaign, calls per hour.
- Talk time (`ended_at − answered_at`; Aircall's `duration` includes ring time), available, break and wrap-up time, alongside the CMA's own statuses and time clock.
- Prepare and Finish time: from a served task to the first dial, and from call end to the booked result.
- First and last call of the day.
- Tickets handled, tickets with an owner. Since 16 October 2026 (addition 0008o) Reports → Follow-up's Per person (`performance.team`) shows per person the open tickets, the ones at risk or over their response time, the open leads and the tasks overdue or due today, right now; the per-period figures follow.

Built 14 October 2026 (brief B16, addition 0008j; not yet in prod): Reports → Calls (calls in and out per day, ISO week, market or line, conversations, talk time without ringing, the previous period's totals) and Reports → Calls per agent (per person, sorted by name: answered inbound and outbound calls, the connected ones, their talk time, untagged conversations, the first and last call of the period's days). Not yet per campaign, per hour or per worked hour. Data prerequisites: every Aircall user linked to a person on People (the calls of users without one show as a single not-linked row), and tagging discipline.

### 8. Effectiveness per agent
- % reached per campaign.
- Results: quotes, orders, CCL confirmed, OPC agreements, courtesy happy.
- Speed to lead, callbacks within 4 hours.
- Calls without outcome, calls without contact.

Built 14 October 2026 (brief B16, addition 0008j; not yet in prod): the connected share of outbound calls (talk time of at least `telephony.connected_min_seconds`, 10 for Pulse4all, to confirm with Kira) in total and per person, each person's conversations per counted tag, and untagged conversations as the first measure of calls without an outcome. Data prerequisites as in 7; what each tag means stays an Open decision.

### 9. Live monitoring
- Missed calls not yet called back, with waiting time. Built 14 October 2026 (brief B15, addition 0008i): the Live board's Missed, not called back, one row per caller over the last `telephony.callback_lookback_days` (3), waiting in office time; called back means any later call to the caller or answered call from them. Live in prod since 14 October 2026.
- New leads not called after 1 hour. Built 16 October 2026 (night run N16-B, addition 0008o; in prod since 16 October 2026): the Live board's Follow-up now strip and Reports → Follow-up show the leads not called and the ones past `speed_to_lead.target_minutes`, with their age groups.
- Tickets about to breach the 4-hour SLA. Built 16 October 2026 (0008o): `tickets.sla_minutes` (240) and `tickets.sla_warning_pct` (75) as tenant settings, a ticket pipeline's own response time on Sources, business minutes of the ticket's market; the open tickets at risk and over their response time on the Live board, Reports → Follow-up and Welcome's Needs attention. Whether HubSpot's own SLA properties should feed the response time is an open end (Open decisions).
- Priority 1: quote requests and exchanges after a resuscitation.
- Who is calling, who is available, queue depth, overdue callbacks, expired leases.

### 10. Quality monitoring
- Scorecard: 5 calls per agent per week.
- Aircall AI (transcript, sentiment, playbook results) to choose which calls to listen to.
- Tag accuracy check (for example: 119 of 237 courtesy calls landed on 4.6 Negative).
- GB (FCA): check on calls about money, % checked per agent.
- First time right: reopened tickets, repeat contact within 7 days.
- Sample of email replies.
- Short satisfaction question after a call or closed ticket.
- Complaints about an agent, coaching agreements and score over time.

### 11. Data first
These are prerequisites in HubSpot, Aircall and every source that joins later. Without them the metrics above are unreliable, so they run in parallel with the foundation work. For a future customer the same list becomes the onboarding checklist for their CRM, telephony and channels.
- Every channel event carries the agent's identity in that system and a timestamp, or it cannot be attributed: Aircall user, HubSpot owner, Gmail sender, chat and SMS agent id, Customer App handler. The shared mailbox attribution to individual agents (open decision) is the prerequisite for email productivity.
- Every customer-facing record carries the customer key the cohorts need: entry date, country, source or campaign, proposition, converting deal and owner; payments in NetSuite and devices in the asset database linked to that customer.
- Outcome mandatory on every call; old values removed from the list (Busy, Connected, retired ids). With the desk, the CMA's result code lands in a HubSpot custom property on every call engagement; until then agents log it in HubSpot.
- The Subs result-code catalog (semantics, priorities, retry intervals, do-not-call flags) confirmed by Kira before anything is seeded; the Subs codes collide with Invest's on the same numbers.
- Every call linked to a contact and a deal.
- Country and owner on every ticket. Since 16 October 2026 (addition 0008o) the data-quality checks `ticket_no_owner` and `ticket_no_market` list the open tickets missing them, per pipeline, once the tenant has configured a response time; `crm_task_owner_unlinked` the open tasks whose owner is not linked on People (0008n).
- `contact_country` (the contact's country as an ISO code, the property the CMA maps as country slot 1) filled on every contact: a HubSpot workflow fills it from `country_dropdown`; the CMA never writes it (one writer per property). In the Subscriptions portal on 15 October 2026, of 36,498 contacts created since 1 January 2026, `contact_country` held a value on 1 and `country_dropdown` on 34,690; until the workflow has filled it, `country_dropdown` is read as slot 2 (addition 0008m; since brief B17b the ingest reads every slot and the HubSpot app is subscribed to `country_dropdown` changes), and once it is "all set", slot 2 is removed by configuration. Owners: Martin and Kira.
- SLAs set up in HubSpot. The Workspace counts a ticket's response time from its own settings since 16 October 2026 (0008o); whether HubSpot's SLA properties should feed `connection_pipeline.sla_minutes` is an open end.
- No test deals in the live pipeline.
- Aircall opening hours equal to team hours (lines currently appear to close at 17:00). Since addition 0008i (14 October 2026) this is visible: Reports → Inbound by hour shows the unanswered calls with the reason `out_of_opening_hours` (Outside opening hours) per hour of the day, so calls Aircall turns away while the team works stand out. The first week of real data (12 to 14 October 2026) shows it for the UK: the UK lines appear to close at 17:00 Amsterdam time (16:00 UK), so the last UK hour shows as outside opening hours (12 of GB's 49 calls). Owners: Arno and Kira.
- Aircall routing of inbound calls: in the first week of real data (12 to 14 October 2026) inbound calls arrive on outbound lines ("Germany Outbound = Sales" 83 % and "UK Sales" 88 % unanswered), so those lines need a routing decision in Aircall; DE has 81 % of its inbound calls unanswered, mostly with the reason No agent available. Owners: Arno and Kira.
- Aircall per-number settings (origin registration, call tagging, the native HubSpot integration on or off) on an add-a-number checklist.
- Every Aircall user linked to a person on People, and every conversation tagged in Aircall: since brief B16 (14 October 2026) Reports → Calls per agent shows the calls of unlinked users as one row (with a link to Data quality) and Reports → Calls the untagged share. Owners: Arno and Kira.
- Returns and exchanges tracked in one system.
- For the first orders (addition 0008u): the Self Serve pipeline marked as the order pipeline on Configuration → Sources; deal stages whose probability says won or lost (a stage set otherwise is corrected there and kept); the old CRM's created date on contacts as a HubSpot property, mapped as a `created_at` slot, so a long-known customer counts as known (Kira); the order's phone on Shopify orders for phone matching (KPIs 2).
- For email per mailbox (addition 0008t): the conversations' channel accounts named in HubSpot (a name that is an address shows its id until labelled on Sources), and which inboxes, channels and mailboxes count (Arno and Kira).
- For the callbacks kept (addition 0008w): every callback task typed as a callback in HubSpot, the type marked on Sources, with a due time and the contact associated.
- For the funnel and the lost reasons (additions 0008za and 0008zb): HubSpot's calculated stage properties present for the counted pipelines' stages (HubSpot fills `hs_v2_date_entered_<stage id>` and `hs_v2_date_exited_<stage id>` only where the pipeline's stage calculated properties are switched on (Settings → Objects → Pipelines, column "Stage calculated properties"), per pipeline and per stage; once switched on, it fills them retroactively, and a new stage may come without them. The gap query of `docs/funnel-2026-10/RUNBOOK.md`, step 16, finds such stages; prod's of 21 October 2026 are in Open decisions); the Closed Lost Reason as a dropdown filled on every lost deal (Reports → Funnel counts the lost deals without a reason, and lists them with their links); the data-quality reasons flagged on Sources; the source channel on the deals. For the cancellations: the rule that marks a cancellation ticket set on Sources, and the tickets' Cancellation Reason filled. Owners: Kira and Joshua; the rule with Arno.
- For the FCA journey (addition 0008v): a consumer or business flag on every GB contact, the agreement date on the contract, a call tag that proves the welcome call, template ids on the journey's emails, the call-recording consent decided (the journey's prerequisites on Campaign monitoring).

### 12. Cohorts
A cohort is a group of customers (or agents) that share an entry point; the report follows the group over time instead of reporting a period. Cohort definitions are tenant configuration in the metric catalog; Kira and Peter confirm Pulse4all's.
- **Customer cohorts** by entry month, country, source or campaign, proposition (Subs: HS1, FRx, Buurt AED; Invest: 10K, 100K), employer of the converting agent, converting agent or team.
- **How long they stay:** retention curve per cohort (active after 3, 6, 12, 24, 36 months), churn before and after the minimum term, cancellation reasons per cohort; the cohort view of KPI 4.
- **How they pay:** days to pay the first and later invoices, share paid on time, late payments and dunning stages, Open Payment call outcomes and collections results, write-offs; from NetSuite joined to the CRM customer.
- **How they behave:** reviews per cohort, complaints, Customer App use, service events and replacements from the asset database, upsell and extra devices.
- **What they cost and bring:** contact attempts and talk time per customer over their lifetime, cost per acquired customer per cohort, revenue per cohort (NetSuite).
- **Agent cohorts:** agents by hiring month and employer: ramp-up time to the team median, productivity and conversion over tenure, retention of agents; the human factor applied to the staff itself.
- **Needs:** the customer keys from Data first on every record, payments and subscriptions synced, the asset database connected; cohort reports run from BigQuery on `cma_read` and appear in the Workspace's Report surface.

---

## Business case and how we prove it

The CMA is justified by four effects: more talk time per paid hour, more conversions from leads and callbacks that are no longer late or forgotten, correct hours and cost per employer, and steering on cohorts rather than periods. Each effect has a KPI, a baseline taken before the related increment reaches agents, and a target to review after three months of use. The values are per business line; at the copy to Invest the same table becomes Invest's scorecard.

| # | KPI | Definition | Baseline source (before) | Target after 3 months | Proves |
|---|---|---|---|---|---|
| 1 | Talk time per paid hour | Aircall talk time (`ended_at − answered_at`) ÷ paid seconds from `workday_summary`, per agent and team | Aircall export + Steam or current hours, 4 weeks before the desk | +20 % | Desk productivity |
| 2 | Prepare and Finish time per call | served task → first dial; call end → booked result, medians | AgentUI trial analysis; first measured by the desk itself | −30 % versus the first desk month | Desk productivity |
| 3 | Calls per productive hour | attempts ÷ productive seconds, per campaign | Aircall + current hours | +15 % | Desk productivity |
| 4 | Speed to lead | median time from lead creation to first attempt within office hours; % within 1 hour | HubSpot timestamps via BigQuery after Sync | median < 15 min, > 80 % within 1 hour | Routing and queue |
| 5 | Callbacks kept | % of callback appointments attempted within the promised window; missed callbacks per week | HubSpot tasks today (incomplete by nature) | > 95 %, missed < 2 per week | No task forgotten |
| 6 | Lead conversion per cohort | leads → orders per entry-month cohort, controlled for country and source | HubSpot via BigQuery | +10 % relative on comparable cohorts | Revenue effect |
| 7 | Hours disputes and corrections | disputes with the partner per month; corrected days ÷ worked days | Arno's current reconciliation | disputes → 0 per month, corrections < 2 % | Time model, billing |
| 8 | Reconciliation effort | hours from export to approved invoice basis, per month | Arno and finance, time spent today | −75 % | Billing module |
| 9 | Desk adoption | % of attempts booked through the desk; agent satisfaction (short monthly question) | n/a; measured from the first desk week | > 90 % of attempts; satisfaction ≥ 4 of 5 | Whether Newco needs the desk |
| 10 | Cost of the CMA | cloud cost per month; team days per increment | Budget alerts, release notes | cloud < €500 per month at Pulse4all scale | Cost side |

The ROI line, reviewed quarterly: paid hours × hourly rate × talk-time lift (KPI 1) + conversion delta × margin per order (KPI 6) + reconciliation hours saved (KPI 8), minus cloud and team cost (KPI 10). Baselines 1, 3, 5 and 7 can be taken now from Aircall exports, HubSpot and Arno's records; 4 and 6 need Sync and BigQuery (Roadmap steps 3 and 4), so taking them is part of Data first. The targets are proposals to confirm with Arno, Kira and Peter; a target that turns out wrong is changed in this table, not argued over later. Baseline values are filled in here once taken.
