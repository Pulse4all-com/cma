# Definitions and naming

Part of the CMA documentation (README.md, Documentation map).

This file defines every term, data point and metric word the CMA uses, so the UI, the API, the SQL, the metric catalog and the docs say one word for one meaning. It starts with the call terms decided on 24 October 2026; the other domains follow term by term (Domains still to define). The metric catalog (`docs/metrics/catalog.json`) defines figures; this file defines words.

## Conventions

1. **One term, one meaning, everywhere:** UI labels, column headers, hints, API fields, SQL names, settings, catalog entries, docs. A word with a meaning here is never used for another meaning.
2. **The owning system's word and definition.** Where an external system owns a measure, the CMA uses that system's word and that system's definition. For calls the telephony system is the truth: for the same scope, period and time zone, the Workspace shows the same figure as Aircall Analytics. A difference is a bug, never a choice.
3. **Each term has these fields:**
   - **Term**: the English label, plus the Dutch label from `web/src/lib/copy.ts` where one exists.
   - **Key**: snake_case for settings and catalog keys, camelCase for API fields.
   - **Definition**: one or two sentences.
   - **Source**: the system and its fields.
   - **Counts / does not count**.
   - **Unit and display**.
   - **Time rule**: the zone and which day a record belongs to.
   - **Scope**.
   - **Equivalent in the source system**: its name and the help article.
   - **Not to use**: retired words and synonyms.
   - **Status**: Decided, Pending (naming the open question), Proposed or Retired.
   - **Decided**: the date and the docs/decisions.md row.
   - **Used by**: catalog keys and pages.
   - **As built today**: what the code does now, with any gap against the definition.
4. **No history here.** Each change is a docs/decisions.md row starting "Definitions:" plus a CHANGELOG.md line; a term shows only its current definition with its Decided pointer.
5. **Figures and words.** The metric catalog defines figures; this file defines words. A catalog entry's definition uses only terms defined here; a term lists the catalog keys that use it.
6. **Copy.** Copy follows `docs/style/Pulse4all-Style.md` (sentence case, tone of voice). A label that differs from the source system's label for the same measure is not allowed.

**Statuses.** Decided: settled, and the code follows it or the gap is listed below (Gaps against the definitions). Pending: settled in part; the field names the open question, and nothing pending is built as if settled. Proposed: a proposal, not yet a decision. Retired: never used again, see Retired words.

## Rules decided on 24 October 2026

Martin decided these on 24 October 2026; Kira and Yordi cleared them. Each is a docs/decisions.md row of that date starting "Definitions:".

- **R1 Calling comes from the telephony system only.** Attempts, connected, talk time, tags, users, lines and times come from Aircall. No HubSpot call outcome (`hs_call_disposition`), status or duration is used anywhere in the CMA. The CMA is brand-agnostic and these outcomes belong to HubSpot's own calling feature.
- **R2 Aircall is the truth for call figures**, as in convention 2. Acceptance: Friday 23 October 2026, Aircall Overview with the Subscriptions preset, reproduced exactly (the reconciliation).
- **R3 Scope.** The Subscriptions tenant's call figures equal Aircall's Subscriptions account without the Invest lines. The Invest lines are left out. Invest gets its own HubSpot portal and Aircall account; this supersedes the Open decision on an Invest connection on the same Aircall company.
- **R4 Per-person figures are cleared by Yordi and Kira** for the cockpit and the reports.

## Call terms

The keys below follow convention 3. Where the code uses another name today, As built today names it and Gaps against the definitions lists it; a key settles with the code change that adopts it.

The Aircall help articles named below (Aircall Help Center, en-gb) were found and read through web search results on 24 October 2026; their pages could not be opened from the build session, so each wording is checked against Aircall Analytics before a figure relies on it. The reconciliation of 23 October 2026 found the General Performance figures identical (Call, Talk time, Untagged, Day):

- Analytics: Terms, article 13399649077277 (`https://support.aircall.io/hc/en-gb/articles/13399649077277-Analytics-Terms`)
- Analytics: Metrics, article 13400715237277 (`https://support.aircall.io/hc/en-gb/articles/13400715237277-Analytics-Metrics`)
- Analytics: Outbound Dashboard, article 13862663466141 (`https://support.aircall.io/hc/en-gb/articles/13862663466141-Analytics-Outbound-Dashboard`)
- the Analytics article on the tags and missed-call reasons charts, article 10375395266205 (`https://support.aircall.io/en-gb/articles/10375395266205`)
- the article on missed-call reasons, article 10375354440221 (`https://support.aircall.io/en-gb/articles/10375354440221`)

### Call

| Field | Value |
|---|---|
| Term | Call (nl: Gesprek; `calls.calls` "Gesprekken") |
| Key | `call`, `calls`; API `calls` |
| Definition | Any inbound or outbound call on a counted line, internal calls excluded (Aircall). A transferred call is one call, attributed to its last participant. |
| Source | Aircall, the call object (`id`, `direction`, `started_at`, `user`, `number`), through the webhook and the read-back into `cma.telephony_call` (0007a) |
| Counts / does not count | Counts every inbound and outbound call on a counted line, connected or not, answered or not, archived calls included. A missed inbound call without a user counts in the totals, not per person. Does not count internal calls between users of the account, calls on a line that does not count (R3: the Invest lines) or deleted calls |
| Unit and display | A count |
| Time rule | Day |
| Scope | The tenant's telephony connection and its counted lines (R3). For Pulse4all Subscriptions the counted lines equal Aircall's preset "Subscriptions" (46 numbers on 24 October 2026) |
| Equivalent in the source system | Aircall Analytics' calls: any inbound or outbound call made or received, internal calls (between users of the same company) excluded (Analytics: Terms) |
| Not to use | "CRM call" or "HubSpot call" for a call fact (Retired words) |
| Status | Decided (R2; the reconciliation of 23 October 2026). Pending, untested because that day had none: the attribution of a transferred call to its last participant, and whether internal calls are excluded |
| Decided | 24 October 2026; docs/decisions.md, 24 Oct 2026, "Definitions: R2"; evidence: "Definitions: Aircall reconciliation 23 Oct 2026 identical on every General Performance figure" |
| Used by | `calls.total`, `calls.chart`, `calls.inbound`, `calls.outbound`, `dashboard.intake.calls`, `intake.calls_in`, `intake.calls_out`; Reports → Calls, Calls per agent, Intake, Dashboard |
| As built today | `cma.calls_of` (`100`; first in `62`): a telephony call, not deleted, with a start, on a counted line (a line not yet in the catalog counts), either direction; archived calls are not filtered out, which matches. A person's calls are their answered inbound and outbound calls (`cma.calls_per_person_of`, `62`), so a missed inbound call without a user counts in the totals and in no person's row, which matches. Internal calls are not excluded: neither the Aircall adapter (`ingest/src/adapters/aircall/map.mjs`) nor the SQL recognises one, so every call Aircall returns with direction inbound or outbound is stored and counted. A call is attributed to Aircall's `user` of the call object, not to a last participant (Gaps). A line Aircall adds arrives counted (`cma.telephony_number.is_counted` defaults to true), and no screen shows how many lines count (Gaps) |

### Attempt

| Field | Value |
|---|---|
| Term | Attempt (nl: Poging) |
| Key | `attempt`, `attempts`; API `attempts` |
| Definition | Every outbound call an agent places: each press on Call, whatever happens next. Connected or not, conversation or not, any tag. |
| Source | Aircall, the outbound call (`direction` outbound, `user`, `started_at`) |
| Counts / does not count | Counts every outbound call (Call) an agent places. Does not count inbound calls, internal calls, calls on a line that does not count, or a call logged in the CRM without an Aircall call (R1) |
| Unit and display | A count |
| Time rule | Day, by the call's start |
| Scope | As Call. Which attempts a figure counts (a deal's, a person's, a period's) is the figure's rule in the metric catalog |
| Equivalent in the source system | Aircall Analytics' outbound calls: any call a user places to an external recipient, connected or not; internal calls excluded (Analytics: Terms) |
| Not to use | "CRM call" or "logged call" as an attempt (R1); "Call attempt" and, in Dutch, "belpoging" next to "poging" (proposed; both appear today, see Gaps) |
| Status | Decided |
| Decided | 24 October 2026; docs/decisions.md, 24 Oct 2026, "Definitions: Attempt" |
| Used by | `attempts.*` (among them `attempts.per_deal`, `attempts.attempted_share`, `attempts.list.attempts`, `attempts.deal.n`), `attempts_per_agent.attempts`, `attempts_per_agent.avg_attempts`, `calls.outbound`, `calls_per_agent.outbound_calls`, and the first attempt of `speed_to_lead.*`; Reports → Attempts per deal, Attempts per agent, Calls, Calls per agent, Speed to lead |
| As built today | Attempts per deal (`cma.deal_attempts_of`, `94`): under `attempts.source` `telephony` (the default, and Pulse4all's) an outbound telephony call on a counted line, not deleted, with a start, linked to a CRM call associated with the deal or its contacts; under `crm` every outbound CRM call so associated (R1 gap). Attempts per agent counts the attempts on the deals a person owns in the CRM, by whoever placed them. Reports → Calls counts every outbound call as Outbound, which matches. Speed to lead takes the first outbound CRM call, linked or not (`cma.speed_to_lead_of`, `40`). First orders' evidence "attempt" is an outbound telephony call linked to a CRM call with the contact (`100`), which matches |

### Connected

| Field | Value |
|---|---|
| Term | Connected (nl: Verbonden) |
| Key | `connected`; setting `telephony.connected_min_seconds`; API `connected` |
| Definition | Aircall's connected: an outbound call answered by the recipient or their voicemail, any duration (`answered_at` set). `telephony.connected_min_seconds` is 0, the default and Pulse4all Subscriptions' value; a tenant that sets it above 0 adds a talk-time condition. |
| Source | Aircall, `answered_at` of an outbound call |
| Counts / does not count | Counts an outbound call with `answered_at` set, also when a voicemail box or an automated responder answered, at any talk time. Does not count an outbound call that was not answered (Not connected) or an inbound call (Answered inbound call, Missed inbound call) |
| Unit and display | A count; as a share, Connected rate |
| Time rule | Day |
| Scope | As Call |
| Equivalent in the source system | Aircall Analytics' connected outbound calls: the recipient or their voicemail system was reached (Analytics: Outbound Dashboard); "connected with a recipient or automated responder" (Analytics: Metrics). The Outbound+ dashboard's minimum talk-time filter defaults to 0 seconds |
| Not to use | connected at 10 seconds of talk (0008j); "answered" for an outbound call; "technically answered"; connected as a HubSpot call outcome (R1) |
| Status | Decided; built in addition 0008zc |
| Decided | 24 October 2026; docs/decisions.md, 24 Oct 2026, "Definitions: Connected" (retires the 10-second rule of 14 October 2026, 0008j); built in addition 0008zc ("Definitions: Connected and Conversation built, step 1") |
| Used by | `calls.outbound`, `calls.outbound_connected`, `calls.outbound_connected_rate`, `calls.outbound_talk`, `calls.outbound_talk_avg`, `calls_per_agent.connected`, `calls_per_agent.outbound_talk_avg`, `calls_per_agent.outbound_talk_total`, `api.calls_per_agent.outbound_talk_seconds_total`, `attempts.deal.connected`, `data_quality.telephony_call_unlinked`; Reports → Calls, Calls per agent, Attempts per deal, Data quality |
| As built today | `cma.is_connected` (`100`): outbound with `answered_at` set; with `telephony.connected_min_seconds` above 0 also that much talk time. `cma.calls_of`, `cma.calls_figures_of` and `cma.calls_per_person_of` read it (columns `is_connected_outbound`, `connected`, `connected_rate`), and so do `cma.deal_calls_of` (`is_connected` from the linked telephony call only, never the CRM call outcome) and one deal's attempts (`connected`). The setting defaults to 0, and `100` moves a tenant value of 10 to 0. The data-quality check `telephony_call_unlinked` skips an outbound call without `answered_at` and without a tag, its own rule (`100`). Matches the definition |

### Not connected

| Field | Value |
|---|---|
| Term | Not connected (nl: Niet verbonden) |
| Key | `not_connected`; API `notConnected` |
| Definition | An attempt that is not connected. |
| Source | Aircall, an outbound call without `answered_at` |
| Counts / does not count | Counts every attempt without `answered_at`. Does not count inbound calls |
| Unit and display | A count |
| Time rule | Day |
| Scope | As Call |
| Equivalent in the source system | Aircall Analytics' outbound calls that did not connect (Analytics: Terms counts outbound calls "connected or not") |
| Not to use | "not reached", "no answer" or "busy" as a HubSpot call outcome (R1) |
| Status | Decided |
| Decided | 24 October 2026; docs/decisions.md, 24 Oct 2026, "Definitions: Connected" |
| Used by | No catalog entry shows it on its own; it is attempts minus connected (`calls.outbound` and `calls.outbound_connected`) |
| As built today | Not shown as a figure. Under `cma.is_connected` (`100`) an outbound call without `answered_at` is not connected, which matches. The label "Not connected" ("Niet verbonden") is ready in `docs/definitions.md` for the first figure that shows it |

### Connected rate

| Field | Value |
|---|---|
| Term | Connected rate (nl: Verbindingspercentage) |
| Key | `connected_rate`; API `connectedRate` |
| Definition | Connected ÷ attempts (Aircall's "Connected rate"). |
| Source | Aircall, as Connected and Attempt |
| Counts / does not count | Numerator: connected attempts. Denominator: every attempt |
| Unit and display | A percentage, with its denominator in the detail line |
| Time rule | Day |
| Scope | As Call |
| Equivalent in the source system | Aircall Analytics' "Connected rate" (the label as decided on 24 October 2026; the article to confirm against Aircall Analytics) |
| Not to use | "connected share", "Aandeel verbonden" (convention 6) |
| Status | Decided; built in addition 0008zc |
| Decided | 24 October 2026; docs/decisions.md, 24 Oct 2026, "Definitions: Connected" |
| Used by | `calls.outbound_connected_rate`; Reports → Calls |
| As built today | `connected_rate` of `cma.calls_figures_of` (`100`): connected ÷ all outbound calls, rounded to one decimal, null without an outbound call; labelled "Connected rate" ("Verbindingspercentage"), API `connectedRate`. Matches the definition |

### Conversation

| Field | Value |
|---|---|
| Term | Conversation (nl: Gevoerd gesprek; `calls.conversations` "Gevoerde gesprekken") |
| Key | `conversation`, `conversations`; API `conversations`; setting `calls.conversation_min_talk_seconds` (it replaces `attempts.reached_min_talk_seconds`) |
| Definition | A connected call with at least `calls.conversation_min_talk_seconds` of talk time (30 for Pulse4all Subscriptions) that carries no current tag whose meaning is "not reached". An untagged call is decided by talk time alone. It applies to both directions: an answered inbound call is a conversation under the same rule. It is logged on the deal and is the evidence for direct versus indirect orders. |
| Source | Aircall, the talk time and the current tags of a connected outbound or answered inbound call; the tag-meaning mapping of the telephony connection (CMA configuration) |
| Counts / does not count | Counts a connected outbound or an answered inbound call with at least `calls.conversation_min_talk_seconds` of talk and no current tag meaning "not reached", an untagged one included. Does not count a call under the threshold, a call carrying a tag meaning "not reached" (a voicemail box, a gatekeeper), a call not connected or not answered, or a HubSpot call outcome (R1) |
| Unit and display | A count |
| Time rule | Day |
| Scope | As Call; on a deal or contact through the call link |
| Equivalent in the source system | Aircall Analytics with the minimum connected in-call time at 29 seconds and a tag filter that excludes the "Not Reached" tags; untagged calls stay included (the outbound view; the inbound one to confirm against Aircall Analytics) |
| Not to use | reached (0008z); "spoken to lead"; "in contact" ("talk time in contact"); "Conversation" for an email thread (Gaps) |
| Status | Decided, for outbound and inbound calls; built in addition 0008zc |
| Decided | 24 October 2026 (Martin); docs/decisions.md, 24 Oct 2026, "Definitions: Conversation = connected call with ≥ 30 s talk and no tag meaning *not reached*". Evidence: the outbound connected calls of 1 to 23 October 2026 by talk-time band against the agents' "Not Reached" tags. The share of tagged connected calls tagged "Not Reached" per band: 0–9 s 98 %, 10–19 s 85 %, 20–29 s 72 %, 30–44 s 71 %, 45–59 s 42 %, 60–89 s 27 %, 90 s and more 4 %. Talk time alone at 30 s would count 35 % voicemails; the tag rule removes them while keeping 84 % of the real conversations. Inbound: decided the same day (Martin), under the same rule. Built in addition 0008zc ("Definitions: Connected and Conversation built, step 1") |
| Used by | `calls.conversations`, `calls.tag_bars`, `calls.tags_by_group`, `calls_per_agent.conversations`, `calls_per_agent.tag_split`, `calls_per_agent.total_row`, `attempts.conversation_share`, `attempts.outcomes.conversation_share`, `attempts.outcomes.avg_talk_conversation`, `attempts.first_conversation_per_attempt`, `attempts.list.conversations`, `attempts.list.first_conversation`, `attempts.list.talk_conversation`, `attempts.deal.conversation`, `attempts_per_agent.conversation_share`, `attempts_per_agent.talk_conversation`, `first_orders.*`, `orders_per_person.*`, `email.not_responding.*`; Reports → Calls, Calls per agent, Attempts per deal, Attempts per agent, First orders, Orders per person, Email |
| As built today | One helper, `cma.is_conversation` (`100`): connected outbound (`cma.is_connected`) or answered inbound, talk time of at least `calls.conversation_min_talk_seconds` (0 to 600; 30 by default and for Pulse4all, the value `attempts.reached_min_talk_seconds` held, which `100` retires), and no current tag whose meaning is `not_reached` (`cma.call_not_reached_of`; a tag that does not count still excludes). Read by `cma.calls_of` (Reports → Calls and Calls per agent), `cma.crm_call_conversation_of` (in place of 0008t's `cma.crm_call_connected_of`, which `100` drops: a CRM call is a conversation only through its linked telephony call; Email's not-responding deals, `cma.email_not_responding_of`), first orders (`cma.first_orders_of`, evidence `conversation`) and Attempts per deal and per agent (`cma.deal_attempts_of`, `cma.attempt_deal`, `cma_read.attempts_per_deal`: `conversation_attempts`, `first_conversation_attempt`, `talk_seconds_conversation`). No CRM call outcome decides it (R1). Until a tag of the connection has the meaning not reached, Conversation counts on talk time alone, and Configuration → Sources, Tags says so. Matches the definition |

### Talk time

| Field | Value |
|---|---|
| Term | Talk time (nl: Gesprekstijd) |
| Key | `talk_seconds`; API `talkSeconds` |
| Definition | Aircall's talk time for the call: from the answer to the end. An average of talk time is over the answered calls (talk time present). |
| Source | Aircall, `answered_at` and `ended_at` |
| Counts / does not count | Counts the seconds from the answer to the end; ringing and the menu never count. A call not answered or not yet ended has no talk time and is left out of an average |
| Unit and display | Seconds; the screens show a duration |
| Time rule | The call's Day |
| Scope | As Call |
| Equivalent in the source system | Aircall Analytics' "In call time (outbound)": the time users spent talking with outbound recipients on connected calls, the outbound leg of a transfer to an external number attributed to the transferring user (Analytics: Metrics); its averages |
| Not to use | duration (Aircall's `duration` includes ringing); "talk in contact" |
| Status | Decided |
| Decided | 24 October 2026; evidence: docs/decisions.md, 24 Oct 2026, "Definitions: Aircall reconciliation 23 Oct 2026 identical on every General Performance figure" |
| Used by | `calls.avg_talk`, `calls.talk_total`, `calls.outbound_talk`, `calls.outbound_talk_avg`, `calls_per_agent.inbound_talk_avg`, `calls_per_agent.outbound_talk_avg`, `calls_per_agent.inbound_talk_total`, `calls_per_agent.outbound_talk_total`, `api.calls_per_agent.inbound_talk_seconds_total`, `api.calls_per_agent.outbound_talk_seconds_total`, `attempts.deal.talk_seconds`, `attempts.list.talk_conversation`, `attempts.outcomes.avg_talk_conversation`, `attempts_per_agent.talk_conversation`; Reports → Calls, Calls per agent, Attempts per deal, Attempts per agent |
| As built today | `cma.telephony_call.talk_seconds` is generated by the database: ended − answered in whole seconds, null while unanswered (`34`), which matches. Reports → Calls' total and average run over the answered calls with talk time, in and out (`cma.calls_figures_of`, `100`), which matches; Calls per agent averages per answered inbound and per connected outbound call; Attempts per deal and per agent add the talk time of the attempts that were a conversation. The copy no longer says talk time is shorter than the phone system's own duration on purpose (`calls.intro`, `hints.callsAvgTalk`); the catalog's `calls.avg_talk` still does (Gaps, C6) |

### Inbound call

| Field | Value |
|---|---|
| Term | Inbound call (nl: Inkomend gesprek; `calls.inbound` "Inkomend") |
| Key | `inbound_call`, `inbound`; API `inbound` |
| Definition | A call to a counted Aircall number from an external caller (Aircall). |
| Source | Aircall, `direction` inbound and `number` |
| Counts / does not count | Counts every inbound call on a counted line: answered, missed or still ringing. Does not count internal calls or outbound calls |
| Unit and display | A count |
| Time rule | Day |
| Scope | As Call |
| Equivalent in the source system | Aircall Analytics' inbound calls, internal calls excluded (Analytics: Terms); Aircall tracks an outbound call successfully transferred to another agent as inbound (to confirm against Aircall Analytics) |
| Not to use | "Offered" (proposed; Reports → Inbound uses it today, see Gaps) |
| Status | Decided (R2) |
| Decided | 24 October 2026; docs/decisions.md, 24 Oct 2026, "Definitions: R2" |
| Used by | `calls.inbound`, `intake.calls_in`, `inbound.*`, `live.inbound.*`; Reports → Calls, Inbound, Intake; Live board |
| As built today | Direction inbound, not deleted, with a start, on a counted line (`cma.calls_of`; `cma.inbound_calls_of`, `60`, `76`). Internal calls are not excluded (as Call). Reports → Inbound labels them "Offered" ("Aangeboden") |

### Answered inbound call

| Field | Value |
|---|---|
| Term | Answered inbound call (nl: Aangenomen) |
| Key | `answered_inbound`; API `answeredInbound` |
| Definition | An inbound call where a user connected with the caller (Aircall). |
| Source | Aircall, `answered_at` of an inbound call |
| Counts / does not count | Counts an inbound call with `answered_at` set. Does not count a missed call or a call still ringing |
| Unit and display | A count |
| Time rule | Day |
| Scope | As Call |
| Equivalent in the source system | Aircall Analytics' answered inbound calls (Analytics: Terms; the label to confirm against Aircall Analytics) |
| Not to use | "Answered" for an outbound call (Connected) |
| Status | Decided (R2) |
| Decided | 24 October 2026; docs/decisions.md, 24 Oct 2026, "Definitions: R2" |
| Used by | `calls.answered_inbound`, `calls_per_agent.answered_inbound`, `inbound.answered`, `inbound.answered_within_target`, `live.inbound.answered`, `live.inbound.answered_within_target`; Reports → Calls, Calls per agent, Inbound; Live board |
| As built today | Inbound with `answered_at` set (`cma.calls_of`, `cma.inbound_calls_of`), which matches |

### Missed inbound call

| Field | Value |
|---|---|
| Term | Missed inbound call (nl: Gemist gesprek; `live.missedTitle` "Gemist, niet teruggebeld") |
| Key | `missed_inbound`; API `missedInbound` |
| Definition | An inbound call that was not answered, with Aircall's missed reason. |
| Source | Aircall, `answered_at` empty and `missed_call_reason` |
| Counts / does not count | Counts an inbound call that ended unanswered. Does not count a call still ringing or in the menu: it has no outcome yet |
| Unit and display | A count, and the count per missed reason |
| Time rule | Day |
| Scope | As Call |
| Equivalent in the source system | Aircall Analytics' missed calls with their missed-call reasons (the article on missed-call reasons; the missed-call reasons chart in the Analytics article on the tags and missed-call reasons charts) |
| Not to use | "unanswered" (proposed; Reports → Inbound and the Live board use it today, see Gaps) |
| Status | Decided (R2) |
| Decided | 24 October 2026; docs/decisions.md, 24 Oct 2026, "Definitions: R2" |
| Used by | `inbound.unanswered_share`, `live.inbound.unanswered_share`, `live.inbound.unanswered_count`, `live.missed.*`, `welcome.needs_attention.missed_callbacks`; Reports → Inbound; Live board; Welcome |
| As built today | `cma.inbound_calls_of` (`60`, `76`): unanswered is inbound, not answered and not waiting (not ended and at most `telephony.waiting_max_minutes` old); the reason is Aircall's `missed_call_reason` (`unknown` without one), with labels and switches in `cma.telephony_missed_reason`. Reports → Inbound says "Unanswered" ("Niet aangenomen"), the Live board's list says "Missed" ("Gemist") |

### Tag

| Field | Value |
|---|---|
| Term | Tag (nl: Tag) |
| Key | `tag`, `tags`; API `tagKey`; meaning `meaning` with the keys `not_reached`, `call_type`, `courtesy_attempt`, `courtesy_completed_positive`, `courtesy_completed_neutral`, `courtesy_completed_negative` (API `meaning`) |
| Definition | Aircall's label on a call; it describes the call (type, outcome). It never decides Attempt or Connected; a tag with the meaning "not reached" excludes a call from Conversation. Its meaning comes from a tag-meaning mapping per telephony connection, configuration only, with at least the meanings not reached, call type, courtesy attempt, and courtesy completed positive, neutral and negative. |
| Source | Aircall, the call's current `tags` and the tag catalog; the meanings from the tag-meaning mapping (CMA configuration) |
| Counts / does not count | Counts the call's current tags. Does not count a tag removed from the call |
| Unit and display | The tag's name from Aircall; counts per tag |
| Time rule | The call's Day |
| Scope | Per telephony connection |
| Equivalent in the source system | Aircall's tags (the tags chart in the Analytics article on the tags and missed-call reasons charts) |
| Not to use | "call outcome" or "disposition" for an Aircall tag; a HubSpot call outcome in its place (R1) |
| Status | Decided; the tag-meaning mapping built in addition 0008zc |
| Decided | 24 October 2026; docs/decisions.md, 24 Oct 2026, "Definitions: R1", "Definitions: Conversation = connected call with ≥ 30 s talk and no tag meaning *not reached*" and "Definitions: tag meanings, one per tag, configuration only" |
| Used by | `calls.tag_bars`, `calls.tags_by_group`, `calls_per_agent.tag_split`, `intake.tagged_calls`, and through the meaning "not reached" every Conversation figure; Reports → Calls, Calls per agent, Intake; Configuration → Sources, Tags |
| As built today | `cma.telephony_tag` holds each tag's name with `is_counted`, and `cma.telephony_call_tag` the tagging history (`34`). Since `100` each tag has one `meaning` (null or one of the six keys), set in Configuration → Sources, Tags by `cma.set_telephony_tag_meaning` (`tenant.configure`, audited, the same gate as `is_counted`); ingest never writes it and a catalog refresh keeps it. Only `not_reached` is read, by Conversation, and `is_counted` has no effect on it; the courtesy meanings and call type wait for their figures. The labels (Configuration → Sources, Tags, Meaning): None (Geen), Not reached (Niet bereikt), Call type (Gesprekstype), Courtesy attempt (Courtesy-poging), Courtesy completed, positive / neutral / negative (Courtesy afgerond, positief / neutraal / negatief; the Dutch proposed). Matches the definition |

### Untagged

| Field | Value |
|---|---|
| Term | Untagged (nl: Zonder tag) |
| Key | `untagged`; API `untagged` |
| Definition | A call without a current tag; a tag removed makes the call untagged (Aircall). Its share is over all calls in scope, missed inbound calls included. |
| Source | Aircall, the call's current `tags` |
| Counts / does not count | Counts a call without any current tag, missed inbound calls included. Does not count a call with any tag |
| Unit and display | A count and its share of all calls in scope |
| Time rule | Day |
| Scope | As Call |
| Equivalent in the source system | Aircall Analytics' untagged calls: the first bar of the tags chart; a call whose tag is removed is untagged again (the Analytics article on the tags and missed-call reasons charts) |
| Not to use | "Untagged conversations" as the measure (As built today) |
| Status | Decided; built in addition 0008zc |
| Decided | 24 October 2026; docs/decisions.md, 24 Oct 2026, "Definitions: R2"; evidence: "Definitions: Aircall reconciliation 23 Oct 2026 identical on every General Performance figure"; built with step 1, "Definitions: Untagged and the talk-time average built with step 1" |
| Used by | `calls.untagged_share`, `calls_per_agent.untagged`; Reports → Calls, Calls per agent |
| As built today | `untagged` of `cma.calls_figures_of` (`100`): the calls without a current tag, counted or not, missed inbound calls included; `untaggedPct` (`web/src/lib/reports.ts`) divides it by all calls in scope ("{untagged} of {calls} calls"). Calls per agent counts a person's own calls without a tag. The tag use and the tags per person have no untagged row. API `untagged`. Matches the definition |

### Last participant

| Field | Value |
|---|---|
| Term | Last participant (no Dutch label in `copy.ts`) |
| Key | `last_participant`; API `lastParticipant` |
| Definition | The user or line a call is attributed to: the last one involved (Aircall). |
| Source | Aircall, the call's participants; which field holds the last one is confirmed on a day with a transferred call |
| Counts / does not count | One user (or line) per call |
| Unit and display | A person on People through the linked account (`<adapter>_user`, 0008e); never a telephony user id on screen |
| Time rule | Not applicable |
| Scope | As Call |
| Equivalent in the source system | Aircall Analytics' user attribution; the outbound leg of a transfer to an external number goes to the transferring user (Analytics: Metrics) |
| Not to use | None yet |
| Status | Decided (R2); Pending for transferred calls, untested in the reconciliation of 23 October 2026 because that day had none; as built the CMA uses `call.user`, a gap to fix |
| Decided | 24 October 2026; docs/decisions.md, 24 Oct 2026, "Definitions: R2" |
| Used by | `calls_per_agent.*`, `attempts.deal.agent_name`; Reports → Calls per agent, Attempts per deal |
| As built today | `userRef` is Aircall's `call.user.id` (`ingest/src/adapters/aircall/map.mjs`), stored as `cma.telephony_call.user_ref` and mapped to a person in `cma.calls_per_person_of` (`62`) and `cma.attempts_of_deal` (`94`). On 23 October 2026, a day without transfers, every person's total, inbound and outbound equalled Aircall's; whether `user` is the last participant of a transferred call is not verified |

### Line

| Field | Value |
|---|---|
| Term | Line (nl: Lijn) |
| Key | `line`; API `line`, `lineKey` |
| Definition | The Aircall number of the call; for a routed call the last number (Aircall). |
| Source | Aircall, the call's `number` and the number catalog |
| Counts / does not count | One line per call; a line that does not count keeps its calls out (R3) |
| Unit and display | The line's name from Aircall; never its digits in a report |
| Time rule | Not applicable |
| Scope | Per telephony connection |
| Equivalent in the source system | Aircall's number (line) filter in Analytics |
| Not to use | None yet |
| Status | Decided (R2); Pending: verify the last number of a routed call |
| Decided | 24 October 2026; docs/decisions.md, 24 Oct 2026, "Definitions: R2" |
| Used by | The line grouping and filter of `calls.*` and `inbound.*`, `live.missed.*`; Reports → Calls, Inbound; Live board; Configuration → Sources, Lines |
| As built today | `numberRef` is Aircall's `call.number.id` (`map.mjs`), stored as `number_ref`; the line key is the connection id ':' the number ref (`62`). Whether `number` is the last number of a routed call is not verified |

### Day

| Field | Value |
|---|---|
| Term | Day (nl: Dag) |
| Key | `day` (group key); SQL `business_date` |
| Definition | A call belongs to the date of its start in the tenant's time zone (Europe/Amsterdam for Pulse4all), as in Aircall's time zone filter. |
| Source | Aircall, `started_at`; the tenant's `timezone` (CMA) |
| Counts / does not count | Every call on one date; the hour and the ISO week follow the same zone |
| Unit and display | A date |
| Time rule | The tenant's time zone |
| Scope | Every call figure |
| Equivalent in the source system | Aircall Analytics' time zone filter |
| Not to use | None yet |
| Status | Decided (R2; the reconciliation of 23 October 2026, in Europe/Amsterdam); as built, Reports → Calls uses each line's market zone, a gap to fix |
| Decided | 24 October 2026; docs/decisions.md, 24 Oct 2026, "Definitions: R2"; evidence: "Definitions: Aircall reconciliation 23 Oct 2026 identical on every General Performance figure" |
| Used by | `calls.*`, `calls_per_agent.*` (`calls_per_agent.first_last_call` by time of day), `inbound.*`, `intake.calls_in`, `intake.calls_out`; Reports → Calls, Calls per agent, Inbound, Intake |
| As built today | `cma.calls_of` and `cma.inbound_calls_of` date (and hour) each call in its line's market zone, else the tenant's, so a GB line's call at 23:30 in London lands a day earlier than in Amsterdam; `cma.telephony_history_start_of` (`64`) does the same. Intake (`cma.intake_per_day`) dates calls in the tenant's zone, which matches. The Calls page's like-for-like label uses the viewer's zone (audit finding MA-004) |

### Speed to lead

| Field | Value |
|---|---|
| Term | Speed to lead (nl: Snelheid tot lead) |
| Key | `speed_to_lead`; API `speedToLead`; settings `speed_to_lead.creation_sources`, `speed_to_lead.target_minutes`, `speed_to_lead.pre_window_minutes` |
| Definition | From the creation of an automatically created lead deal to its first Attempt, in business minutes of the deal's market. One definition and one function serve Reports → Speed to lead, the Dashboard tile, Attempts and the cockpit. |
| Source | The deal and its creation from the CRM (HubSpot owns deals); its creation source from the CRM's record-source fields, mapped per CRM connection (HubSpot: `hs_object_source` and `hs_created_by_user_id`, to verify); the first attempt from Aircall through the call link; office hours and holidays from Configuration → Markets (CMA) |
| Counts / does not count | **Deals:** every deal created in a lead pipeline (configured; Pulse4all: Sales Pipeline – Subscriptions) whose creation source counts (`speed_to_lead.creation_sources`; Pulse4all: form, automation), test deals excluded. The creation source is a neutral value per deal: form, automation, user, import or unknown. **Shown apart, out of the measures:** deals created by hand, as "Created by hand, not in speed to lead"; a deal closed (won or lost, for example by a Self Serve order) before any attempt, as closed before first call. **Not called yet:** an open deal without an attempt, shown with its age. The measure Created deals keeps counting every new deal |
| Unit and display | Median business minutes over the called deals, shown with the count not called yet; % within `speed_to_lead.target_minutes` (60); % called before 12:00 the next working day; the count not called yet. A deal not called yet counts as late in "% within 1 hour" once past the target, and in "% before 12:00 next working day" once past that moment |
| Time rule | **Start:** the deal's creation; outside the office hours of the deal's market the clock starts at the next opening; holidays from Markets; measured in business minutes. **End:** the first Attempt linked to the deal or its contacts (Call link); a call within `speed_to_lead.pre_window_minutes` before the creation counts as 0 minutes. The deal's business date is its creation in the tenant's zone |
| Scope | The tenant's lead pipelines. **Per person:** the person who placed the first attempt (the call's Last participant, Aircall); a view by deal owner follows with Assignments (0009). This is the basis for the gamification of speed to lead |
| Equivalent in the source system | None: a CMA measure joining the CRM's deal and Aircall's call |
| Not to use | "Mediane speed to lead" and "Speed to lead" in Dutch copy next to "Snelheid tot lead" (one Dutch label; see Gaps); "Open, not called" for Not called yet (proposed) |
| Status | Decided |
| Decided | 24 October 2026 (Martin); docs/decisions.md, 24 Oct 2026, "Definitions: Speed to lead = from creation of an automatically created lead deal to its first attempt, in business minutes; uncalled deals count as late; one function for all pages (closes MA-003)" |
| Used by | `speed_to_lead.*`, `api.speed_to_lead.*`, `dashboard.intake.speed_to_lead`, `follow_up.leads_open_not_called`, `follow_up.leads_past_target`, `attempts.median_speed_to_lead`, `attempts.outcomes.median_speed`, `attempts.list.speed_to_lead`, `attempts.win_rate_by_speed`, `attempts_per_agent.median_speed`; Reports → Speed to lead, Follow-up, Attempts per deal, Attempts per agent; Dashboard; Live board |
| As built today | **Reports → Speed to lead** (`cma.speed_to_lead_of`, `40`; the Dashboard tile computes the same rows in the web). **Deals:** every deal of a counted lead pipeline created from `intake.start_date` (`cma.lead_deals_of`, `76`); deals carry no creation source and no test flag, so neither filter exists. **End:** the first outbound CRM call associated with the deal or its contacts; its start is the linked Aircall call's, else the CRM call's own time, so a call logged in HubSpot without an Aircall call counts (R1). There is no window end. **Uncalled deals:** an uncalled deal, open or closed, is left out of the percentages until the target's business time (or the next noon) has passed, and then counts as late; a deal closed before its first call is therefore not shown apart (audit findings MA-015, MA-016). **Cutoff:** 12:00 is hardcoded in `cma.next_business_noon_of` (`40`). **Per person:** the first call's CRM owner, else the deal's owner. **Elsewhere:** Attempts per deal (`94`) measures to the first attempt within the deal's window, and Follow-up (`72`, `80`) reads the same target on its own, so the pages can differ (MA-003) |

### Call link

| Field | Value |
|---|---|
| Term | Call link (no Dutch label in `copy.ts`; Data quality says "Telefoongesprekken zonder gelogd gesprek") |
| Key | `call_link`; methods `external_id`, `hash_time`, `phone_match` |
| Definition | How a call is tied to a contact and deal. Proposed order: `external_id` (the integration's logged call carries the Aircall call id, to verify), then `hash_time` (as built), then `phone_match` (keyed hash of the E.164 number against the contact's phone slots; a value that is not E.164 is not hashed and shows in Data quality). From the CRM's logged call only its associations are used, never its outcome, time or duration. |
| Source | Aircall's call; the CRM's logged call (its associations; for `hash_time` the pairing only) |
| Counts / does not count | One current link per call |
| Unit and display | Not shown as a figure; Data quality counts calls without one |
| Time rule | Not applicable |
| Scope | Per tenant |
| Equivalent in the source system | None: the CMA's own join |
| Not to use | The logged call's outcome, time or duration as a call fact (R1) |
| Status | Proposed |
| Decided | Not yet (Proposed) |
| Used by | Every figure that ties a call to a deal or contact: `attempts.*`, `speed_to_lead.*`, `first_orders.*`, `orders_per_person.*`, `email.not_responding.*`, `callbacks.*`, `data_quality.telephony_call_unlinked` |
| As built today | `cma.call_link` with `method` `hash_time` only (`34`): the equal keyed hash of the other party's number, the same direction, at most 120 seconds apart, nearest first, each side once; the CRM call's time and direction are used for that pairing. The hash normalises a number with a default region (the line's or market's country) before it is hashed, so a national-format number is hashed too, and a number that is not a possible phone number gets none (`ingest/src/core/hash.mjs`). The HubSpot adapter reads no Aircall call id from the logged call (`CALL_PROPERTIES`) |

## Retired words

Status: Retired. A retired word is never introduced again; where it still appears, Gaps against the definitions lists the place.

| Retired | Use instead | Note | Where it appears today |
|---|---|---|---|
| connected (≥ 10 s talk, 0008j) | Connected (Aircall) | The 10 s threshold goes | Nowhere since addition 0008zc; `telephony.connected_min_seconds` stays as an optional talk condition, 0 by default and for Pulse4all |
| reached (0008z) | Conversation | Dutch "bereikt" goes with it. The tag meaning "not reached" (the agents' Aircall tag "Not Reached") is a defined meaning of Tag and stays | Nowhere as a call term since addition 0008zc; Reports → Funnel's "Reached won" is another word with its own row (W20, D16, C17) |
| spoken to lead | Conversation | | Not found in the repository (searched on 24 October 2026); the nearest wording is the catalog's "spoke with (or called)" in `follow_up.leads.last_call_days` and `callbacks.week.kept` |
| answered (for outbound calls) | Connected | "Answered" stays for inbound calls only | The data-quality skip value `outbound_unanswered_untagged` of a telephony connection's `dq_unlinked_skip` setting (`72`, `100`; `web/src/lib/follow-up.ts`), a stored value (Gaps, D30); nowhere else since addition 0008zc (one deal's attempts say Connected, API `connected`) |
| CRM call / HubSpot call as a call fact | Attempt / Call (telephony) | R1 | `attempts.source` `crm` (`94`); `cma.lead_calls_of` and `cma.speed_to_lead_of` (`40`); callbacks kept (`88`); copy `attempts.noteCrm`; catalog `speed_to_lead.*`, `follow_up.leads*`, `callbacks.*`. Since addition 0008zc Conversation, Connected and first orders' evidence come from the linked telephony call only |
| call outcome (HubSpot) | Tag (Aircall) | R1 | Ingest `hs_call_disposition` (`CALL_PROPERTIES`, `outcomeRef`) and the outcome catalog (`/calling/v1/dispositions`); `cma.connection_call_outcome.is_connected` and `cma.set_call_outcome` (`32`, stored and read by no figure since addition 0008zc); Configuration → Sources, Call outcomes (the list; its connected switch went in 0008zc); copy `attempts.colCallOutcome`, `attempts.withoutOutcome`; catalog `attempts.without_outcome_share`, `attempts.deal.outcome_label` |

## Domains still to define

Status: Pending for every term below; none is defined yet. Each is added term by term, with a docs/decisions.md row starting "Definitions:".

### Leads and deals
Lead, deal, lead pipeline, order pipeline, created deal, open deal, closed won, closed lost, lost reason, test deal, lead source.

### Customers and orders
Contact, customer, new customer, first order, direct order, indirect order, B2B, B2C, subscription, cancellation, minimum term.

### Tickets and tasks
Ticket, complaint, vulnerable case, owner, without owner, overdue, response time.

### Email
Email sent, mailbox, inbox, first reply.

### Time and people
Workday, clocked in, hours worked, status, working status, business minutes, office hours, market.

### Periods
Yesterday, Today, This week (ISO, Monday), This month, Custom range, previous period, like for like.

### Other
Forms, reviews, AED maintenance, data quality.

## Gaps against the definitions

Where the code or the catalog says something else than this file: every retired word and every Decided term whose As built today differs from its definition, in `web/`, `db/`, `ingest/` and `docs/metrics/catalog.json` on `main` of 24 October 2026. Step 1 of the definitions brief (addition 0008zc: tag meanings, Connected and Conversation, with Untagged and the talk-time average) closed the rows it fixed, and they are gone from the tables below; the rest come with the later steps. The plain English verb "reached" in code comments (a database or a cursor reached) is no term and is left out. Script numbers name the file in `db/` that holds the function's current definition.

### web/

| # | File | Key or label | Says | Should say |
|---|---|---|---|---|
| W7 | `web/src/lib/copy.ts` | `inbound.intro` | Each call's day and hour in the time zone of its line's market | In the tenant's time zone (Day) |
| W8 | `web/src/lib/copy.ts` | `inbound.unansweredPct`, `live.inboundUnanswered`, `hints.unansweredPct` ("Unanswered", "Niet aangenomen") | Unanswered, while the Live board's list says Missed | Missed (proposed: one word for Missed inbound call) |
| W9 | `web/src/lib/copy.ts` | `inbound.offered`, `hints.offered` ("Offered", "Aangeboden") | Offered for the inbound calls | Inbound calls (proposed; Aircall's label to confirm against Aircall Analytics) |
| W12 | `web/src/lib/copy.ts` | `attempts.colCallOutcome` "Call outcome", `attempts.noOutcome`, `attempts.withoutOutcome`, `attempts.qualityIntro`, `hints.atWithoutOutcome` | The HubSpot call outcome, set by agents on every call | No HubSpot call outcome (R1); a description of the call is its Tag |
| W13 | `web/src/lib/copy.ts` | `attempts.noteCrm` | Attempts are outbound calls logged in the customer records | Attempts come from the telephony system only (R1) |
| W17 | `web/src/lib/copy.ts` | `speedToLead.intro` "first outbound call"; Dutch `speedToLead.intro`, `speedToLead.minutesNote` "belpoging"; Dutch `attempts.speed`, `attempts.colMedianSpeed`, `attempts.speedTitle`, `attempts.speedCol`, `hints.atOutcomes` "speed to lead" | The first outbound (CRM) call; two Dutch labels for one term | The first attempt; one Dutch label, "Snelheid tot lead", and one Dutch word for attempt, "poging" |
| W18 | `web/src/lib/copy.ts` | `email.conversation`, `email.opened` "Conversations opened" ("Gesprekken geopend"), `email.waitingIntro`, `emailPerAgent.intro`, hints `emailOpened`, `emailOpenedCol`, `emailClosedCol`, `emailWait*`, `emailAgentReplies`, `emailAgentClosed` | Conversation for an inbox thread | Another word for the email thread: Conversation is a call term (to settle when Email is defined) |
| W19 | `web/src/lib/copy.ts`; `web/src/app/api/v1/reports/first-orders/route.ts`, `callbacks-kept/route.ts`; `web/src/app/reports/orders-per-person/page.tsx` | `reports.noTelephony` "No telephony connected", `noShop`, `noEmail`, `noOrders`, `noTelephonyHint`, `noShopHint`, `noFormsHint`; the API field `connected` of First orders, Callbacks kept and Orders per person | Connected for a source that is set up | Another word, to choose in the definitions brief (for example "set up"): Connected is a call term |
| W20 | `web/src/lib/copy.ts`; `web/src/lib/csv.ts` | `funnel.colReachedWon`, `funnelFile.reachedWon`, `hints.fnColReachedWon` ("Reached won", "Gewonnen bereikt"); API `reachedWon` | Reached for a deal won now | A word that is not retired (for example "Won now") |
| W21 | `web/src/lib/data/types.ts` | API fields `unanswered`, `unansweredByReason` (Inbound) | 0008i's words (the Calls, Calls per agent and Attempts per deal fields took the terms' keys in addition 0008zc) | The term's camelCase key (`missedInbound`) |
| W25 | `web/src/components/configuration/SourceConfig.tsx` (Configuration → Sources, Lines); the Data quality page | The number of counted lines | Not shown: Lines lists each line with its Counted switch, and a line Aircall adds arrives counted | Data quality or Configuration → Sources shows the number of counted lines, so the list can be compared with Aircall's preset "Subscriptions" (46 numbers on 24 October 2026) after a line is added in Aircall |
| W27 | `web/src/lib/copy.ts` | `hints.agent` (Speed to lead's grouping by agent) | "The person behind the first outbound call, else the deal's owner" (its CRM owner) | The person who placed the first attempt (the call's last participant, Aircall) |
| W28 | `web/src/lib/copy.ts` | `speedToLead.openNotCalled` "Open, not called", `speedToLead.openTitle`, `hints.withinTarget`, `hints.openNotCalled`; no group for deals created by hand or closed before the first call | "Deals closed without a call count as missed; deals still open and not called are left out until they are called or closed" | "Not called yet" with its age, late once past the target or the cutoff; "Created by hand, not in speed to lead" and closed before first call shown apart, out of the measures |

### db/

| # | File | Key or label | Says | Should say |
|---|---|---|---|---|
| D4 | `db/76_audit_hardening.sql` (`cma.calls_of`, `cma.inbound_calls_of`); `db/62_calls_overview.sql` (`cma.calls_per_person_of`); `db/64_calls_history_start.sql` | `business_date`, week, hour and time of day | In the line's market zone, else the tenant's | In the tenant's zone (Day) |
| D5 | `db/62_calls_overview.sql` (`cma.calls_per_person_of`); `db/94_attempts_for_sales.sql` (`cma.attempts_of_deal`) | The person behind `user_ref` | Aircall's `call.user` | The last participant |
| D9 | `db/100_definitions_calls.sql` (`cma.deal_calls_of`, which `cma.lead_calls_of` reads) | `effective_at`, `direction` | The CRM call's time and direction when unlinked (`is_connected` comes from the linked telephony call since addition 0008zc) | The call's time and direction from Aircall (R1) |
| D10 | `db/40_lead_metrics.sql` (`cma.speed_to_lead_of`, `cma.lead_calls_of`) | The end of speed to lead | Reports → Speed to lead reads HubSpot calls: the first outbound CRM call, linked or not, with no window end (R1) | The first Attempt linked to the deal or its contacts through the call link; a call in the pre-window counts as 0 minutes |
| D12 | `db/94_attempts_for_sales.sql` | `attempts.source` value `crm` | Every outbound CRM call is an attempt | Attempts from the telephony system only (R1) |
| D13 | `db/32_intake_core.sql` | `cma.connection_call_outcome.is_connected`, `cma.set_call_outcome` | Which HubSpot call outcomes count as connected (a conversation) | Retired (R1) |
| D14 | `db/88_callbacks_kept.sql` (`cma.callbacks_kept_of`) | The call that keeps a callback | Its start: the linked Aircall call's, else the CRM call's time | The Aircall call, tied through the call link (R1) |
| D15 | `db/88_callbacks_kept.sql` (`cma.callbacks_kept_connected`) | `connected` | Whether the tenant counts a callback type | Another word: Connected is a call term |
| D16 | `db/98_funnel.sql` | `reached_won` | Of the deals that entered, those won now | A word that is not retired |
| D17 | `db/60_inbound_service.sql` (`cma.inbound_service_of`, `cma.inbound_today_of`) | `unanswered`, `unanswered_by_reason` | Unanswered | Missed (proposed, as W8) |
| D22 | `db/74_forms_reporting.sql` (`cma.data_quality_of`) | A check: tag inconsistent with talk time | No such check | Proposed: a call with a tag meaning "not reached" and 90 seconds or more of talk, or with another tag and under 10 seconds; on 1 to 23 October 2026 about 20 and about 50 calls |
| D24 | `db/30_ingest_crm_records.sql` (`cma.crm_record`); `db/32_intake_core.sql` (settings) | A deal's creation source and `speed_to_lead.creation_sources` | Deals carry no creation source, and the setting does not exist | A neutral creation source per deal (form, automation, user, import, unknown), mapped per CRM connection; `speed_to_lead.creation_sources` (Pulse4all: form, automation) |
| D25 | `db/76_audit_hardening.sql` (`cma.lead_deals_of`) | Test deals | Deals carry no test flag; every deal of a lead pipeline counts | Test deals excluded from speed to lead |
| D26 | `db/40_lead_metrics.sql` (`cma.speed_to_lead_of`) | The person of a deal's speed to lead | The first CRM call's owner, else the deal's owner | The person who placed the first attempt (its last participant) |
| D27 | `db/40_lead_metrics.sql` (`cma.speed_to_lead_of`, `cma.speed_to_lead_summary`) | Deals without a call in the percentages | An uncalled deal, open or closed, is null until the target's business time (or the next noon) passes, then late; a deal closed before its first call counts the same way | An open deal not called yet counts as late once past the target or the cutoff; a deal closed before its first call is shown apart and stays out of the measures |
| D28 | `db/40_lead_metrics.sql` (`cma.next_business_noon_of`) | The cutoff of "% before 12:00 next working day" | 12:00 hardcoded | A tenant setting (12:00 for Pulse4all) |
| D29 | `db/40_lead_metrics.sql`; `db/94_attempts_for_sales.sql`; `db/72_follow_up.sql`, `db/80_follow_up_snapshot.sql`; the Dashboard tile in `web/src/lib/reports.ts` | Where speed to lead is computed | Separately for Reports → Speed to lead, Attempts per deal and Follow-up, and in the web for the Dashboard tile (MA-003) | One definition and one function for Reports → Speed to lead, the Dashboard tile, Attempts and the cockpit |
| D30 | `db/72_follow_up.sql`, `db/100_definitions_calls.sql` (`cma.data_quality_of`); `web/src/lib/follow-up.ts` (`DQ_UNLINKED_SKIP_DEFAULT`) | The skip value `outbound_unanswered_untagged` of the connection setting `dq_unlinked_skip` | "unanswered" for an outbound call (the rule itself is the term's since addition 0008zc: no answer and no tag) | A value named by Not connected (for example `outbound_not_connected_untagged`), the stored settings moved with it |

### ingest/

| # | File | Key or label | Says | Should say |
|---|---|---|---|---|
| I1 | `ingest/src/adapters/hubspot/map.mjs` | `CALL_PROPERTIES` (`hs_call_disposition`, `hs_call_status`, `hs_call_duration`); `callFromObject`'s `outcomeRef`, `status`, `durationSeconds` | The logged call's outcome, status and duration are read and stored | R1: from the logged call only its associations (and, while `hash_time` pairs calls, its hash, time and direction for the pairing) |
| I2 | `ingest/src/adapters/hubspot/read.mjs`; `ingest/src/core/store.mjs` | The outcome catalog (`GET /calling/v1/dispositions` into `cma.ingest_upsert_call_outcomes`) | HubSpot's call outcomes are read hourly with the catalogs | Retired (R1) |
| I3 | `ingest/src/adapters/aircall/map.mjs` | `userRef: call.user.id` | The call's user | The last participant (the field to confirm) |
| I4 | `ingest/src/adapters/aircall/map.mjs` | `numberRef: call.number.id` | The call's number | The last number of a routed call (to verify) |
| I5 | `ingest/src/adapters/aircall/map.mjs` | `callFromObject` | Every inbound or outbound call is stored, internal ones included | Internal calls left out (how Aircall marks one, to verify) |
| I6 | `ingest/src/adapters/hubspot/map.mjs` | A deal's record-source fields | Not read: a deal brings its pipeline, stage, owner and times (and configured fields) only | The creation source mapped per CRM connection from the record-source fields (HubSpot: `hs_object_source` and `hs_created_by_user_id`, to verify) |

### docs/metrics/catalog.json

| # | Entries | Says | Should say |
|---|---|---|---|
| C6 | `calls.avg_talk` (notes, definition) | Shorter than Aircall's own duration on purpose | Aircall's talk time (R2); Connected is Aircall's since addition 0008zc |
| C7 | The `time` field of `calls.*`, `calls_per_agent.*`, `inbound.*` | Each call's date in its line's market zone, else the tenant's | The tenant's zone (Day) |
| C10 | `attempts.without_outcome_share`, `attempts.deal.outcome_label` | The HubSpot call outcome | Retired (R1) |
| C11 | Every `attempts.*` and `attempts_per_agent.*` formula | `attempts.source` `crm` takes every outbound CRM call | Attempts from the telephony system only |
| C12 | `speed_to_lead.*`, `api.speed_to_lead.*`, `dashboard.intake.speed_to_lead`, `follow_up.leads_open_not_called`, `follow_up.leads.last_call_days`, and through the follow-up snapshot `live.follow_up_now.leads_open_not_called` | The first (or last) outbound CRM call, linked or not | The first attempt; calls from Aircall (R1) |
| C15 | `callbacks.week.kept`, `callbacks.week.not_kept`, `callbacks.week.pending`, `callbacks.week.kept_share`, `callbacks.per_person.kept`, `callbacks.per_person.not_kept`, `callbacks.per_person.pending`, `callbacks.per_person.kept_share`, `dashboard.intake.callbacks_kept`, `follow_up.leads.last_call_days` | "spoke with (or called)"; the CRM call's time when unlinked | A Call (telephony) through the call link; "spoke with" only for a Conversation |
| C16 | `inbound.unanswered_share`, `live.inbound.unanswered_share`, `live.inbound.unanswered_count` | Unanswered | Missed (proposed) |
| C17 | `funnel.stage.reached_won`, `export.funnel_stages_csv.reached_won` | Reached won | A word that is not retired |
| C20 | `speed_to_lead.deals`, `speed_to_lead.within_target_pct`, `speed_to_lead.before_next_noon_pct`, `speed_to_lead.open_not_called`, `dashboard.intake.speed_to_lead` | Every lead deal; a deal closed without a call counts as missed once past the target or the noon | The deals by creation source, test deals out; closed before first call and created by hand apart; Not called yet late once past |

**Catalog entries that change meaning** once the later steps follow the definitions:

- Speed to lead: `speed_to_lead.*`, `api.speed_to_lead.*`, `dashboard.intake.speed_to_lead` and the speed-to-lead entries of `attempts.*`, `attempts_per_agent.*` and `follow_up.*` (one function; the deals by creation source; the first attempt; closed before first call apart).
- Attempts from the telephony system only: every `attempts.*` and `attempts_per_agent.*` entry while `attempts.source` `crm` exists (C11).
- The call outcome read no more (step 4): `attempts.without_outcome_share`, `attempts.deal.outcome_label` (C10).

**Count per area:** `web/` 13, `db/` 18, `ingest/` 6, `docs/metrics/catalog.json` 9; 46 in all.
