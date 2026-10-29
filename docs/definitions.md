# Definitions and naming

Part of the CMA documentation (README.md, Documentation map).

This file defines every term, data point and metric word the CMA uses, so the UI, the API, the SQL, the metric catalog and the docs say one word for one meaning. It starts with the call terms decided on 24 October 2026 and holds the legacy call terms and the review terms of 25 October 2026, the asset terms of 27 October 2026 and the subscription terms of 28 October 2026 (Proposed); the other domains follow term by term (Domains still to define). The metric catalog (`docs/metrics/catalog.json`) defines figures; this file defines words.

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
- **R2 Aircall is the truth for call figures**, as in convention 2. Acceptance: Friday 23 October 2026, Aircall Overview filtered on the 46 numbers (the 46-number filter), reproduced exactly (the reconciliation). Not Aircall's preset "Subscriptions": it filters on 14 users, so it drops missed calls without a user (docs/decisions.md, 25 Oct 2026, "Definitions: R2's scope").
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
| Scope | The tenant's telephony connection and its counted lines (R3). For Pulse4all Subscriptions the counted lines equal the 46-number filter in Aircall Analytics (the account's 57 numbers less 8 Invest and 3 inactive), not Aircall's preset "Subscriptions", which filters on 14 users and so drops missed calls without a user |
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
| Definition | A connected call with at least `calls.conversation_min_talk_seconds` of talk time (30 for Pulse4all Subscriptions) that carries no current tag whose meaning is "not reached" or "incorrect data". An untagged call is decided by talk time alone. It applies to both directions: an answered inbound call is a conversation under the same rule. It is logged on the deal and is the evidence for direct versus indirect orders. |
| Source | Aircall, the talk time and the current tags of a connected outbound or answered inbound call; the tag-meaning mapping of the telephony connection (CMA configuration) |
| Counts / does not count | Counts a connected outbound or an answered inbound call with at least `calls.conversation_min_talk_seconds` of talk and no current tag meaning "not reached" or "incorrect data", an untagged one included. Does not count a call under the threshold, a call carrying a tag meaning "not reached" (a voicemail box, a gatekeeper) or "incorrect data" (a wrong number, incorrect contact data), a call not connected or not answered, or a HubSpot call outcome (R1) |
| Unit and display | A count |
| Time rule | Day |
| Scope | As Call; on a deal or contact through the call link |
| Equivalent in the source system | Aircall Analytics with the minimum connected in-call time at 29 seconds and a tag filter that excludes the tags meaning not reached or incorrect data (for Pulse4all Subscriptions the "Not Reached", "Wrong Number" and "Incorrect Data" tags; Tag); untagged calls stay included (the outbound view; the inbound one to confirm against Aircall Analytics) |
| Not to use | reached (0008z); "spoken to lead"; "in contact" ("talk time in contact"); "Conversation" for an email thread (Gaps) |
| Status | Decided, for outbound and inbound calls; built in addition 0008zc, incorrect data in addition 0008zd |
| Decided | 24 October 2026 (Martin); docs/decisions.md, 24 Oct 2026, "Definitions: Conversation = connected call with ≥ 30 s talk and no tag meaning *not reached*"; incorrect data 25 October 2026 (Martin), docs/decisions.md, 25 Oct 2026, "Definitions: incorrect data as its own tag meaning". Evidence: the outbound connected calls of 1 to 23 October 2026 by talk-time band against the agents' "Not Reached" tags. The share of tagged connected calls tagged "Not Reached" per band: 0–9 s 98 %, 10–19 s 85 %, 20–29 s 72 %, 30–44 s 71 %, 45–59 s 42 %, 60–89 s 27 %, 90 s and more 4 %. Talk time alone at 30 s would count 35 % voicemails; the tag rule removes them while keeping 84 % of the real conversations. Inbound: decided the same day (Martin), under the same rule. Built in addition 0008zc ("Definitions: Connected and Conversation built, step 1") |
| Used by | `calls.conversations`, `calls.tag_bars`, `calls.tags_by_group`, `calls_per_agent.conversations`, `calls_per_agent.tag_split`, `calls_per_agent.total_row`, `attempts.conversation_share`, `attempts.outcomes.conversation_share`, `attempts.outcomes.avg_talk_conversation`, `attempts.first_conversation_per_attempt`, `attempts.list.conversations`, `attempts.list.first_conversation`, `attempts.list.talk_conversation`, `attempts.deal.conversation`, `attempts_per_agent.conversation_share`, `attempts_per_agent.talk_conversation`, `first_orders.*`, `orders_per_person.*`, `email.not_responding.*`; Reports → Calls, Calls per agent, Attempts per deal, Attempts per agent, First orders, Orders per person, Email |
| As built today | One helper, `cma.is_conversation` (`100`): connected outbound (`cma.is_connected`) or answered inbound, talk time of at least `calls.conversation_min_talk_seconds` (0 to 600; 30 by default and for Pulse4all, the value `attempts.reached_min_talk_seconds` held, which `100` retires), and no current tag whose meaning is `not_reached` or `incorrect_data` (`cma.call_not_reached_of`, `102`, which reads `cma.tag_meaning_excludes_conversation`, the one place that names the meanings that exclude a call; a tag that does not count still excludes). Read by `cma.calls_of` (Reports → Calls and Calls per agent), `cma.crm_call_conversation_of` (in place of 0008t's `cma.crm_call_connected_of`, which `100` drops: a CRM call is a conversation only through its linked telephony call; Email's not-responding deals, `cma.email_not_responding_of`), first orders (`cma.first_orders_of`, evidence `conversation`) and Attempts per deal and per agent (`cma.deal_attempts_of`, `cma.attempt_deal`, `cma_read.attempts_per_deal`: `conversation_attempts`, `first_conversation_attempt`, `talk_seconds_conversation`). No CRM call outcome decides it (R1). Until a tag of the connection has the meaning not reached, Conversation counts on talk time alone, and Configuration → Sources, Tags says so (that notice looks at not reached only). Matches the definition |

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
| Key | `tag`, `tags`; API `tagKey`; meaning `meaning` with the keys `not_reached`, `incorrect_data`, `call_type`, `courtesy_attempt`, `courtesy_completed_positive`, `courtesy_completed_neutral`, `courtesy_completed_negative` (API `meaning`) |
| Definition | Aircall's label on a call; it describes the call (type, outcome). It never decides Attempt or Connected; a tag with the meaning "not reached" or "incorrect data" excludes a call from Conversation. Its meaning comes from a tag-meaning mapping per telephony connection, configuration only, with at least the meanings not reached, incorrect data (the contact data is wrong: a wrong number, incorrect data), call type, courtesy attempt, and courtesy completed positive, neutral and negative. A tag keeps one meaning. |
| Source | Aircall, the call's current `tags` and the tag catalog; the meanings from the tag-meaning mapping (CMA configuration) |
| Counts / does not count | Counts the call's current tags. Does not count a tag removed from the call |
| Unit and display | The tag's name from Aircall; counts per tag |
| Time rule | The call's Day |
| Scope | Per telephony connection |
| Equivalent in the source system | Aircall's tags (the tags chart in the Analytics article on the tags and missed-call reasons charts) |
| Not to use | "call outcome" or "disposition" for an Aircall tag; a HubSpot call outcome in its place (R1) |
| Status | Decided; the tag-meaning mapping built in addition 0008zc, incorrect data in addition 0008zd |
| Decided | 24 October 2026; docs/decisions.md, 24 Oct 2026, "Definitions: R1", "Definitions: Conversation = connected call with ≥ 30 s talk and no tag meaning *not reached*" and "Definitions: tag meanings, one per tag, configuration only"; 25 October 2026 (Martin), docs/decisions.md, 25 Oct 2026, "Definitions: incorrect data as its own tag meaning"; the courtesy tags of the Subscriptions connection, docs/decisions.md, 25 Oct 2026, "The courtesy tags of the Subscriptions Aircall connection got their meanings in prod" |
| Used by | `calls.tag_bars`, `calls.tags_by_group`, `calls_per_agent.tag_split`, `intake.tagged_calls`, and through the meanings "not reached" and "incorrect data" every Conversation figure; the `meaning` of every Legacy call outcome; Reports → Calls, Calls per agent, Intake; Configuration → Sources, Tags |
| As built today | `cma.telephony_tag` holds each tag's name with `is_counted`, and `cma.telephony_call_tag` the tagging history (`34`). Since `100` each tag has one `meaning` (null or one of the seven keys; `incorrect_data` since `102`), set in Configuration → Sources, Tags by `cma.set_telephony_tag_meaning` (`tenant.configure`, audited, the same gate as `is_counted`); ingest never writes it and a catalog refresh keeps it. Only `not_reached` and `incorrect_data` are read, by Conversation (`cma.tag_meaning_excludes_conversation`, `102`), and `is_counted` has no effect on them; no figure counts the calls tagged incorrect data apart yet (Gaps, D32); the courtesy meanings and call type wait for their figures. The labels (Configuration → Sources, Tags, Meaning): None (Geen), Not reached (Niet bereikt), Incorrect data (Onjuiste gegevens), Call type (Gesprekstype), Courtesy attempt (Courtesy-poging), Courtesy completed, positive / neutral / negative (Courtesy afgerond, positief / neutraal / negatief; the Dutch proposed). Matches the definition |

**Pulse4all Subscriptions mapping.** The tag meanings of the Subscriptions Aircall connection, set on Configuration → Sources, Tags (configuration, never code); a tag name with `*` stands for every tag whose name starts with it. Every other tag has the meaning None until a figure needs it. The meaning of the Data Issue Escalate tags is an Open decision (docs/open-decisions.md, the courtesy definitions).

| Aircall tags | Meaning |
|---|---|
| `1.1 Sales - Not Reached` and the other "Not Reached" tags | Not reached (`not_reached`) |
| `1.4 Sales - Wrong Number*`, `1.5 Sales - Incorrect Data*` | Incorrect data (`incorrect_data`) |
| `4.1 Courtesy - Not Reached` | Not reached (`not_reached`) |
| `4.2 Courtesy - Follow Up ∞`, `4.3 Courtesy - Data Issue Escalate*` | Courtesy attempt (`courtesy_attempt`) |
| `4.4 Courtesy - Completed Positive*` | Courtesy completed, positive (`courtesy_completed_positive`) |
| `4.5 Courtesy - Completed Neutral*` | Courtesy completed, neutral (`courtesy_completed_neutral`) |
| `4.6 Courtesy - Completed Negative*` | Courtesy completed, negative (`courtesy_completed_negative`) |

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

## Legacy call terms

Decided with addition 0008zg (25 October 2026). The calls a former telephony system made before the current one are not in `cma.telephony_call`; what that system recorded for them is imported once from its export as legacy call outcomes. The current telephony system's calls are never copied: they stay Calls and are read through the tag meanings (Tag).

### Legacy call outcome

| Field | Value |
|---|---|
| Term | Legacy call outcome (no Dutch label in `copy.ts`; nothing shows it yet) |
| Key | `legacy_call_outcome`; tables `cma.legacy_call_outcome` and `cma.legacy_call_batch`; the match methods `email_phone`, `email`, `phone`, `customer_id`, `none`, `conflict`, `forgotten` (the key list below) |
| Definition | What a former telephony system recorded for one of its calls, imported once from its export as a fact of its own: the call's date, the tag meaning of the former system's tag text and, when exactly one CRM contact is found, that contact's id. It is neither an Aircall call nor a HubSpot call outcome; the compound name is Martin's decision. |
| Source | A file exported from the former telephony system (for Pulse4all Subscriptions Steam: the courtesy completions of 14 May 2025 to 31 August 2026), read once by the job `ingest-import-legacy-calls` from a private EU bucket into memory, never stored. The tag meaning of each of the file's tag texts is an argument of the job (the tag meanings of Tag). The contact is found in the CRM by the file's email, phone or customer id, which are never stored or logged |
| Counts / does not count | Counts one row per imported row of a former-system call in a batch that is not withdrawn, matched or not, for volume and outcome; only a row with a contact counts for coverage. Does not count a row of the current telephony system (the import only reconciles those against the Aircall calls and stores nothing), a row of a withdrawn batch, or a row the job refused (dated on or after the cutover date, a date that does not read, a tag text without a meaning) |
| Note | A tenant may import matched rows only (job option `--unmatched skip`, Pulse4all's choice, docs/decisions.md, 26 Oct 2026): then no row of the batch is `none` or `conflict`, and the former system's rows that matched no single contact are not in the CMA at all |
| Unit and display | A count of rows, per meaning and per match method; nothing shows it yet (readers: `cma_read.legacy_call_batch` and `cma_read.legacy_call_outcome`) |
| Time rule | The date the file writes, taken as the tenant's local date (Europe/Amsterdam for Pulse4all); no time of day is kept. A row is dated before the batch's cutover date, the first day of the current telephony system (1 September 2026 for Pulse4all's courtesy calls) |
| Scope | Per tenant and the batch's CRM connection; one live batch per file |
| Equivalent in the source system | The former system's tag on the call (Steam: the tag text); none in Aircall |
| Not to use | "call outcome" alone or "disposition": a HubSpot call outcome is the retired word of R1 and its Retired words row stays as it is; "tag" for the former system's text (Tag is Aircall's label); "call" for a legacy call outcome (Call is Aircall's) |
| Status | Decided; the courtesy figures built on it wait for the courtesy definitions (docs/open-decisions.md) |
| Decided | 25 October 2026 (Martin); docs/decisions.md, 25 Oct 2026, "Steam's courtesy history is imported as legacy call outcomes", "A legacy call outcome is matched to a HubSpot contact by email and phone first", "Legacy call outcomes that match no contact are imported without one" (superseded for Pulse4all on 26 October 2026 by the row "Pulse4all imports only the legacy call outcomes matched to exactly one HubSpot contact") and "Definitions: Legacy call outcome is a new term" |
| Used by | No figure yet: the courtesy definitions are open (docs/open-decisions.md). No catalog key and no page; the tables `cma.legacy_call_batch` and `cma.legacy_call_outcome` and their `cma_read` views |
| As built today | Addition 0008zg (`108`): `cma.legacy_call_outcome` holds per row its batch, the file's row number, `occurred_on`, `meaning` (one of the seven keys of `cma.telephony_tag.meaning`), `source_label` (the former system's tag text, at most 100 characters, never an @), the batch's CRM connection, `crm_contact_source_id`, `match_method` and `matched_at` (set exactly with a contact). The job matches each former-system row to at most one contact (the email, the primary then the additional emails; the phone, E.164 only, confirmed by its full number; then the customer id of at least `--min-customer-id-digits` digits, 10 by default) and writes it through `cma.legacy_call_outcomes_upsert`; a rerun never changes a stored row's date, meaning or label and never refills a forgotten row. The CRM's privacy deletion of a contact sets its rows to `forgotten`. No email, phone, name or customer id is stored or logged. Nothing reads the rows yet: no screen, API field or catalog entry. Matches the definition |

**Match methods** (`match_method`; a stored row has exactly one, and a contact exactly when it is one of the first four):

- `email_phone`: the email and the phone each found exactly one contact, the same one.
- `email`: the email found exactly one contact (the primary email, else an additional one) and the phone did not find exactly one, or the row has no phone.
- `phone`: the phone found exactly one contact (searched by its national number, confirmed by the full number) and the email did not find exactly one, or the row has no email.
- `customer_id`: neither found exactly one contact and the customer id did, first among the store customers the CMA already linked (addition 0008h), then in the CRM connection's contact ref fields.
- `none`: no key found exactly one contact; the row is stored without a contact, unless the tenant imports matched rows only (job option `--unmatched skip`).
- `conflict`: the email and the phone each found exactly one contact, but different ones; the row is left unlinked (not stored with `--unmatched skip`).
- `forgotten`: the CRM deleted the contact for privacy; the link is removed and a rerun never sets it again.

## Review terms

Decided with addition 0008ze (brief B18, 25 October 2026). The review platform owns its reviews and the CMA reads them: for Pulse4all Subscriptions that is Trusted Shops (the eTrusted API). The CMA holds no reviewer's name, email or phone and no review title or text (docs/decisions.md, 25 Oct 2026, "Data protection (hard rules)"). A tenant's flag for having a reviews connection is "set up" (`isSetUp`, `is_set_up`), never "connected": Connected is a call term (W19).

### Review

| Field | Value |
|---|---|
| Term | Review (nl: Review) |
| Key | `review`, `reviews`; API `reviews`; settings `reviews.negative_max_rating`, `reviews.history_start_date` |
| Definition | A review the review platform holds of one of the tenant's review channels. It counts when the platform has published it and its review channel is counted. |
| Source | The review platform; for Pulse4all Subscriptions Trusted Shops, the eTrusted API, polled hourly into `cma.review` (the channels into `cma.review_channel`). The adapter decides published from the platform's state (eTrusted: APPROVED), so no vendor word is in SQL |
| Counts / does not count | Counts a published review of a counted review channel. Does not count an unpublished review or one of a channel that is not counted; both stay stored. A review of a counted channel without a market counts, its market unknown. The reviewer and the review's title and text are never stored |
| Unit and display | A count; each review has a rating from 1 to 5 |
| Time rule | Day: the date of the review's submission in the tenant's zone |
| Scope | The tenant's reviews connection and its counted review channels; another business line's channels stay out by their Counted switch |
| Equivalent in the source system | A review in Trusted Shops' eTrusted account; its rate limits and `ignoreStatements` are still to confirm (docs/open-decisions.md) |
| Not to use | The reviewer, the reviewer's email or the review's text in any figure, label, alert or log |
| Status | Decided |
| Decided | 25 October 2026; docs/decisions.md, 25 Oct 2026, "A review counts when the platform has published it" and "Definitions: review, review channel, average rating (review score), negative review, linked review and link level" |
| Used by | `reviews.count`, `reviews.average_rating`, `reviews.negative`, `reviews.linked`, `reviews.distribution`, `reviews.by_market`, `reviews.by_period`, `reviews.link_levels`, `reviews.invite_events`, `reviews.by_channel`, `reviews.market_states`; Reports → Reviews (`/reports/reviews`) |
| As built today | `cma.reviews_of` (`104`): a review with `is_published` of a counted `cma.review_channel`, its market the channel's else unknown, its business date the submission's in the tenant's zone, its rating a number (a whole star is the rating rounded up). Matches the definition |

### Published review

| Field | Value |
|---|---|
| Term | Published review (nl: no Dutch label in copy.ts) |
| Key | `is_published` (`cma.review.is_published`); the adapter's `isPublished` |
| Definition | A review whose state on the review platform is APPROVED. The CMA counts and alerts on published reviews of counted review channels only. |
| Source | The platform's state, decided by the adapter (eTrusted: APPROVED), so no vendor word is in SQL |
| Counts / does not count | Counts a review in the state APPROVED. Does not count one in MODERATION, REJECTED or any other state; those stay stored and neither count nor alert |
| Unit and display | A flag on each review; no figure of its own |
| Time rule | Day of the review's submission, as Review |
| Scope | As Review |
| Equivalent in the source system | The state APPROVED. The platform's own counts and score follow other rules (Platform facts below) |
| Not to use | A vendor's state word (APPROVED, MODERATION, REJECTED) in SQL; "published" for a review the platform counts but has not approved |
| Status | Decided |
| Decided | 25 October 2026; docs/decisions.md, 25 Oct 2026, "Definitions: "published review" is a review in the platform's state APPROVED" |
| Used by | `reviews.count`, `reviews.average_rating`, `reviews.negative`, `reviews.linked`, `reviews.distribution`, `reviews.by_market`, `reviews.by_period`, `reviews.link_levels`, `reviews.by_channel`, `reviews.market_states`; the alert trigger `review_submitted` and the rule "Negative review"; Reports → Reviews |
| As built today | `cma.review.is_published`, set by the adapter from the state APPROVED; `cma.reviews_of` (`104`) takes published reviews of counted review channels only, and the alert takes published reviews only. Matches the definition |

### Review channel

| Field | Value |
|---|---|
| Term | Review channel (nl: Reviewkanaal) |
| Key | `review_channel`; API `byChannel`, `channel` |
| Definition | A shop or a country the review platform collects reviews for. Its market and its counted switch are configuration (Configuration → Sources); a new channel arrives without a market and not counted. |
| Source | The platform's channel catalog (eTrusted channels), read hourly into `cma.review_channel` (name, language and country, whether the platform still lists it); the market and the counted switch are people's |
| Counts / does not count | Counts a channel the platform lists, mapped to a market or not. A channel that is not counted is read and its reviews are stored, but they count nowhere and cannot alert (another business line's channels, test channels) |
| Unit and display | A count per market; a channel is shown by its name at the platform and its market. A channel the platform no longer lists shows "Gone at the platform", a new one "New, choose a market" |
| Time rule | Not applicable |
| Scope | Per tenant's reviews connection |
| Equivalent in the source system | A channel of the Trusted Shops account (to confirm on the live account) |
| Not to use | "Channel" alone, which is a customer contact channel (phone, email, chat; the `channel` table); "shop" or "country" for the channel |
| Status | Decided |
| Decided | 25 October 2026; docs/decisions.md, 25 Oct 2026, "A review counts when the platform has published it" and "Definitions: review, review channel, average rating (review score), negative review, linked review and link level" |
| Used by | `reviews.by_channel`, `reviews.market_states`, `data_quality.review_channel_unmapped`, `data_quality.market_without_review_channel`; Reports → Reviews, Data quality; Configuration → Sources (Review channels), Alert rules (Every counted review channel) |
| As built today | `cma.review_channel` (`104`): `market` and `is_counted` (default false), set by `cma.set_review_channel` (`tenant.configure`; `PUT /api/v1/configuration/sources/{id}/review-channels`); the ingest writes only name, language and deletion, so a catalog read keeps both. Data quality lists unmapped channels and active markets without a counted one. Matches the definition |

### Average rating

| Field | Value |
|---|---|
| Term | Average rating (nl: Gemiddelde score), also the review score |
| Key | `average_rating`; API `averageRating` |
| Definition | The mean rating, from 1 to 5, of the counted reviews of the scope and period, rounded to two decimals. |
| Source | The ratings of the counted reviews (`cma.review.rating`) |
| Counts / does not count | Counts the published reviews of counted review channels. Does not count unpublished reviews or those of a channel that is not counted. Without a review there is no average |
| Unit and display | A number from 1 to 5 with two decimals ("Out of 5") |
| Time rule | Day of the review's submission |
| Scope | The tenant, the period, optionally one market; per market, per day or week and per review channel |
| Equivalent in the source system | None read: the CMA computes it from the counted reviews; the Control Centre's score is another figure (Platform facts below) |
| Not to use | An average over unpublished reviews or reviews of a channel that is not counted |
| Status | Decided; which window the review score KPI means is open for Kira (Open decisions), the report uses the page's period |
| Decided | 25 October 2026; docs/decisions.md, 25 Oct 2026, "Definitions: review, review channel, average rating (review score), negative review, linked review and link level" |
| Used by | `reviews.average_rating` and the averages of `reviews.by_market`, `reviews.by_period` and `reviews.by_channel`; KPI 3; Reports → Reviews |
| As built today | `cma.review_figures` (`104`): the mean of the ratings of `cma.reviews_of`, rounded to two decimals over the page's period. Matches the definition |

### Negative review

| Field | Value |
|---|---|
| Term | Negative review (nl: Negatieve review) |
| Key | `negative`; setting `reviews.negative_max_rating`; API `negative`; the alert rule's `max_rating` |
| Definition | A counted review rated at or below `reviews.negative_max_rating` (1 to 4, default 2). |
| Source | The review's rating and the tenant setting, set on Configuration → Sources (Review settings) |
| Counts / does not count | Counts a counted review whose rating, decimals included, is at or below the setting. Does not count unpublished reviews or those of a channel that is not counted |
| Unit and display | A count, with its share of the reviews |
| Time rule | Day of the review's submission |
| Scope | The tenant's setting; the alert rule "Negative review" starts from it as its highest rating |
| Equivalent in the source system | None |
| Not to use | A threshold of the alert rule other than its own Ratings that alert: the rule's highest rating can differ and never changes what the report counts as negative |
| Status | Decided; the threshold (default 2) and the alert audience are for Kira to confirm before the rule is switched on (Open decisions) |
| Decided | 25 October 2026; docs/decisions.md, 25 Oct 2026, "A review counts when the platform has published it" and "Reports → Reviews shows team figures only" |
| Used by | `reviews.negative`; the alert rule "Negative review" and its highest rating; Reports → Reviews; Configuration → Alert rules |
| As built today | `cma.reviews_of` flags `is_negative` against the setting, validated 1 to 4 (`cma.check_tenant_setting`, `104`); seed `02` adds the rule "Negative review" switched off with the setting's value as its highest rating. Matches the definition |

### Link level

| Field | Value |
|---|---|
| Term | Link level (nl: Koppelniveau; `reviews.linkCard` "Koppelniveaus") |
| Key | `link_level` with the values `order`, `contact` and `none`; `reviews.link_levels`; API `linkLevels` |
| Definition | How a review is tied to the tenant's own records: order (its transaction reference names exactly one of the tenant's orders), contact (no order; the reviewer's email, in memory only, finds exactly one CRM contact) or none. |
| Source | The review's transaction reference against the orders' name, else their source id (a Klaviyo invite's reference is the Shopify order's id, to confirm with the first real data); the CRM contact search by the reviewer's email, the email never stored. The reference itself is kept only when the connection's `transaction_ref_pattern` accepts it and it holds no @; otherwise it is left out and counted as `ref_dropped` |
| Counts / does not count | One level per review. The contact search runs only for reviews without an order or contact and respects the CRM connection's `api_daily_floor_pct`. A reference or an email that finds none or more than one links to nothing. A contact's privacy deletion clears a review's contact link; an order link stays |
| Unit and display | A count per level, as bars: To an order, To a contact, Not linked |
| Time rule | Day of the review's submission |
| Scope | Per tenant: its orders and its CRM contacts |
| Equivalent in the source system | None: the CMA's own join (Call link is the call terms' join, another term) |
| Not to use | The reviewer's name, email or the transaction reference as a shown value |
| Status | Decided |
| Decided | 25 October 2026; docs/decisions.md, 25 Oct 2026, "A review links to an order when its transaction reference names exactly one of the tenant's orders" |
| Used by | `reviews.link_levels`, `reviews.linked`; Reports → Reviews |
| As built today | `cma.review.link_level` (`104`), set by `cma.ingest_upsert_reviews` (the order, through `cma.review_order_of`) and `cma.set_review_contact` (the contact), cleared by `cma.forget_review_contact_links`; check constraints keep an order id only with `order` and a contact only with `contact`. Matches the definition |

### Linked review

| Field | Value |
|---|---|
| Term | Linked review (nl: Gekoppelde review; `reviews.linked` "Gekoppelde reviews") |
| Key | `linked`; API `linkedOrder`, `linkedContact`, `unlinked` |
| Definition | A counted review whose link level is order or contact. |
| Source | The review's link level |
| Counts / does not count | Counts counted reviews linked to an order or a contact. A review with the level none is not linked |
| Unit and display | A count, with its share of the reviews ("to an order or a contact") |
| Time rule | Day of the review's submission |
| Scope | As Review |
| Equivalent in the source system | None |
| Not to use | "Connected" for a link or for a tenant's reviews connection ("set up", W19); Call link is another term |
| Status | Decided |
| Decided | 25 October 2026; docs/decisions.md, 25 Oct 2026, "A review links to an order when its transaction reference names exactly one of the tenant's orders" and "Definitions: review, review channel, average rating (review score), negative review, linked review and link level" |
| Used by | `reviews.linked`; Reports → Reviews |
| As built today | `cma.review_figures` (`104`) counts the levels order and contact (`linkedOrder`, `linkedContact`) and none (`unlinked`); the tile shows the first two together with their share. Matches the definition |

### Platform facts

Facts about the review platform's own figures, recorded so nobody mistakes them for CMA metrics (docs/decisions.md, 25 Oct 2026, "Definitions: "published review" is a review in the platform's state APPROVED"). Trusted Shops' Control Centre counts the reviews in the states APPROVED and MODERATION and leaves out REJECTED; its score is the simple average of the APPROVED reviews submitted in the last 12 months, apparently cut to two decimals. Reports → Reviews' average rating is per selected period (Average rating), so the two differ by design; which one the review score KPI means is an Open decision for Kira.

## Asset terms

Decided with addition 0008zi (27 October 2026). The tenant's asset register owns its devices: for Pulse4all Subscriptions the Airtable base "Airtable 2.0", whose rows carry NetSuite ids (which system owns which field is an Open decision). The CMA mirrors it read-only through the register's API, read by the ingest (addition 0008zj, 27 October 2026: the records changed every `assets_poll_interval_minutes`, default 15, and a full snapshot nightly), with a snapshot of the register's CSV export (docs/import/devices.md) as the fallback, and forecasts what comes due on Reports → Maintenance. A device holds ids, statuses, dates and codes only, never a customer's name, email, phone or address. A tenant's flag for having an asset register is "set up" (`isSetUp`, `is_set_up`), never "connected", as for reviews.

### Device

| Field | Value |
|---|---|
| Term | Device (nl: Apparaat) |
| Key | `device`; API `devices`, `deviceId`; SQL `cma.device`, `cma_read.device` |
| Definition | One record of the tenant's asset register: a serial-numbered unit with its model, market, device status, references and dates. It is tracked when its device status is tracked and the latest full snapshot holds it. |
| Source | The asset register; for Pulse4all Subscriptions the Airtable base "Airtable 2.0", read through its API by the ingest (addition 0008zj: the changed records by the poll, the full snapshot nightly) and loaded in chunks by `cma.ingest_load_device_chunk`, a full snapshot reading the whole table, never a view, and ending with `cma.ingest_mark_devices_missing` in slices (addition 0008zk), or through its CSV export by a person with `cma.load_device_snapshot` (the fallback); both run the one load, `cma.device_rows_apply`, into `cma.device` (one row per register record id and connection) |
| Counts / does not count | Reports → Maintenance counts tracked devices only: a device in a tracked device status that the latest full snapshot holds. A device missing from the latest full snapshot (`source_deleted_at`) and one in a status that is not tracked stay stored and are not forecast |
| Unit and display | A count (`maintenance.devices`, "{n} tracked devices"); the list shows a device by its serial number and its register record id, never a customer's name |
| Time rule | None of its own; a device's dates are dates as the register writes them |
| Scope | The tenant's asset register connections; the filters market, model and scope (in the field, in stock, every tracked device) |
| Equivalent in the source system | A record of the register's device table (Airtable: one row; its record id is `source_id`) |
| Not to use | "Asset" for one unit in a label (the asset register is the system); "AED" in a label or a key (the model is configuration) |
| Status | Decided |
| Decided | 27 October 2026; docs/decisions.md, 27 Oct 2026, "The device register is owned by the tenant's asset register", "The asset register is read by scheduled API polling" (addition 0008zj), 28 Oct 2026, "The asset sync reads no view", "A full snapshot's final step runs in slices" and "The Airtable adapter's chunks adapt to the database" (addition 0008zk) and "Definitions: Device" |
| Used by | `maintenance.devices`, `maintenance.list.*`; the data-quality checks `device_serial_missing`, `device_serial_duplicate`, `device_model_unmapped`, `device_status_unmapped`, `device_market_unmapped`, `device_customer_ref_invalid`, `field_device_without_subscription_ref`; Reports → Maintenance (`/reports/maintenance`) |
| As built today | `cma.device` (`112`) with `cma.maintenance_items_of` taking the devices of a status with `is_tracked` and no `source_deleted_at`; filled by `cma.device_rows_apply` (`116`, set-based) from the API in chunks, from `assets_load_chunk` rows and halved while a call is slow (`cma.ingest_load_device_chunk`, then `cma.ingest_mark_devices_missing` in slices for a full snapshot, which reads the whole table: `cma.set_connection_settings` refuses `view_id` on an asset register) or, through `cma.device_snapshot_apply`, from a file. Matches the definition |

### Component

| Field | Value |
|---|---|
| Term | Component (nl: Onderdeel) |
| Key | `component`, `component_key`; API `components`, `componentKinds`; SQL `cma.device_component`, `cma.device_component_kind` |
| Definition | A part of a device that comes due on its own, of a kind from the tenant's catalog (Pulse4all: pads and battery), with its serial and its recorded expiry. A component, or the device itself at its end of life (the reserved kind `device`), is a due item. |
| Source | The register's component columns, mapped per kind into `cma.device_component`: by the asset register connection's `device_component` fields for the API read (addition 0008zj; the kind in `ref_system`, each property the Airtable field's id since addition 0008zk) and by the import's map (`docs/import/devices-map.example.json`) for the file import; the kinds are tenant configuration (`cma.device_component_kind`, seed `02` for Pulse4all) |
| Counts / does not count | A due item counts for every active kind the device carries, its model has a maintenance rule for, or every kind while the model is unknown; and the device itself when the register records its end of life. A replaced component (`replaced_at`) does not count, but a kind the register emptied (serial and expiry both empty), whose component is closed with none current, counts as a due item without a due date (basis `unknown`), also when its model has no rule for it, until the register holds the kind again |
| Unit and display | A count per kind (`maintenance.components`); the list names the kinds due ("Components due"); the device's own item reads "Device, end of life" |
| Time rule | Its due date and action date (below) |
| Scope | As Device |
| Equivalent in the source system | The register's component columns (Airtable: `pads_sn`, `pads_expiry_date_calculated`, `battery_sn`, `battery_expiry_date_calculated`) |
| Not to use | "Part" or "consumable" in a label; a vendor's own component word in a key |
| Status | Decided |
| Decided | 27 October 2026; docs/decisions.md, 27 Oct 2026, "A component serial that differs from the previous snapshot's is an observed replacement" and "Definitions: Component"; 28 Oct 2026, "The Airtable adapter maps by field id", "A component kind whose serial and expiry the register both empties closes the device's current component", "A kind the register holds again after emptying it" and "Definitions: Due date and Component" (addition 0008zk) |
| Used by | `maintenance.components`, `maintenance.by_month`, `maintenance.list.components`; `component_due_unknown`; `cma_read.device_component`, `cma_read.maintenance_due`; Reports → Maintenance |
| As built today | `cma.device_component` (`112`): at most one current row per device and kind; a serial that differs from the stored one closes the old row (`replaced_at`) and inserts a new one (counted in `components_replaced`). A kind the register emptied (serial and expiry both empty) closes the current row with no new one (`cma.device_rows_apply`, `116`; counted in `components_closed`, which counts these closures only); when the register holds the kind again with none current, the same serial (or a missing one on either side) reopens that row (`replaced_at` cleared, the same row) and a different serial inserts a new one; a kind the source does not stage is left as it is. `cma.maintenance_items_of` builds the due items. Matches the definition |

### Device status

| Field | Value |
|---|---|
| Term | Device status (nl: Apparaatstatus) |
| Key | `device_status`, `device_status_key`; API `deviceStatus`; flags `is_in_field`, `is_in_stock`, `is_tracked` |
| Definition | The register's state of a device, mapped to the tenant's catalog of device statuses, each with the flags in the field (at a customer), in stock and tracked (forecast for maintenance). Reporting reads the flags, never a status name. |
| Source | The register's status column, mapped through the catalog's aliases (`cma.device_status_key_of`); the catalog is tenant configuration (`cma.device_status`, seed `02` for Pulse4all) |
| Counts / does not count | Only devices in a tracked status are forecast; the scope filter takes in the field or in stock from the flags. A label no alias holds leaves the device without a status (`device_status_unmapped`), not forecast |
| Unit and display | The status's name from the catalog |
| Time rule | As of the latest read (the poll or the nightly snapshot, or a loaded file); no history is kept |
| Scope | As Device |
| Equivalent in the source system | The register's operational status (Airtable: `aed_operational_status`) |
| Not to use | A status name in SQL or code; "connected" or "active" for a device's state |
| Status | Decided |
| Decided | 27 October 2026; docs/decisions.md, 27 Oct 2026, "Device status is a catalog with the flags" and "Definitions: Device status" |
| Used by | `maintenance.devices`, `maintenance.list.device_status`, the scope filter; `device_status_unmapped`, `field_device_without_subscription_ref`; Reports → Maintenance |
| As built today | `cma.device_status` (`112`), its flags read by `cma.maintenance_items_of` and `cma.maintenance_bucketed_of`. Matches the definition |

### Due date

| Field | Value |
|---|---|
| Term | Due date (nl: Vervaldatum) |
| Key | `due_on`, `basis`; API `dueOn`, `bases`; basis values `recorded`, `rule`, `unknown` |
| Definition | The date a due item comes due: the component's recorded expiry (basis `recorded`), else the anchor date plus the maintenance rule's interval for the model and kind (basis `rule`), else none (basis `unknown`). The anchor is the day the current component was first seen when it replaced another of its kind on the device (a replacement restarts the rule), else the device's last shipment, else its first. A kind whose component the register emptied (serial and expiry both empty), closed with none current, has no anchor: its due date is none (basis `unknown`), also when the model has no rule for the kind, until the register holds the kind again; then the same serial back reopens the component and keeps its anchor, and another serial is a replacement and restarts the rule. A device's end of life is its recorded date (basis `recorded`). |
| Source | The register's expiry and shipment dates; for a replacement, when the import first saw its serial (`cma.device_component.first_seen_at` of a component with a replaced predecessor); the rule's interval (`cma.maintenance_rule.interval_months`, tenant configuration) |
| Counts / does not count | Every due item has one basis. An item of basis `unknown` has no due date, no action date and no exchange; it is counted apart (`maintenance.unknown_items`, `component_due_unknown`); a kind the register emptied is one of these until the register holds the kind again. A replacement's anchor is the day an import first saw its serial, so its rule-based due date lags the physical swap by up to the time between reads (since addition 0008zj the poll reads the changed records every `assets_poll_interval_minutes`, 15 for Pulse4all Subscriptions) |
| Unit and display | A date in the tenant's date format; the basis as "Recorded expiry", "By rule" or "No due date" |
| Time rule | A date as the register writes it; a replacement's first sighting as a date in the tenant's zone; a month added as Postgres adds months (the 31st of a month plus one month is the last day of the shorter month) |
| Scope | As Device |
| Equivalent in the source system | The register's calculated expiry dates (Airtable: `pads_expiry_date_calculated`, `battery_expiry_date_calculated`) |
| Not to use | "Expiry" for a date the rule worked out; "deadline" |
| Status | Decided |
| Decided | 27 October 2026; docs/decisions.md, 27 Oct 2026, "A due item's due date is the recorded expiry" and "Definitions: Due date"; 28 Oct 2026, "A component kind whose serial and expiry the register both empties closes the device's current component", "A kind the register holds again after emptying it" and "Definitions: Due date and Component" (addition 0008zk) |
| Used by | `maintenance.list.due_date`, `maintenance.list.basis`, `maintenance.unknown_items`; `component_due_unknown`; `cma_read.maintenance_due`; Reports → Maintenance |
| As built today | `cma.maintenance_items_of` (`112`): the anchor is `first_seen_at` in the tenant's zone for a current component with a replaced row of the same device and kind, else the shipment. Components of the first load keep the shipment. A kind with a closed component and none current is an item of basis `unknown` (`116`; its model's rule or none); a reopened component keeps its `first_seen_at`, so it keeps its anchor. Matches the definition |

### Action date

| Field | Value |
|---|---|
| Term | Action date (nl: Actiedatum) |
| Key | `action_on`; API `actionOn` |
| Definition | The due date less the maintenance rule's lead days for the model and kind: the day to act on a due item. A due item without a rule, and a device's end of life, have no lead days. The month of a due item on Reports → Maintenance is its action date's month. |
| Source | The due date and `cma.maintenance_rule.lead_days` (tenant configuration; 60 for Pulse4all, to confirm, docs/open-decisions.md) |
| Counts / does not count | Every due item with a due date has one; an item of basis `unknown` has none |
| Unit and display | A date in the tenant's date format |
| Time rule | Its month is the calendar month of the date; the current month is the tenant's, in its zone |
| Scope | As Device |
| Equivalent in the source system | None: the register holds no action date |
| Not to use | "Due date" for the action date; "reminder date" |
| Status | Decided |
| Decided | 27 October 2026; docs/decisions.md, 27 Oct 2026, "A due item's due date is the recorded expiry" and "Definitions: Action date" |
| Used by | `maintenance.by_month`, `maintenance.list.action_date`; `cma_read.maintenance_due`, `cma_read.maintenance_per_month`; Reports → Maintenance |
| As built today | `cma.maintenance_items_of` (`112`). Matches the definition |

### Past due

| Field | Value |
|---|---|
| Term | Past due (nl: Achterstallig) |
| Key | `past_due`; API bucket `past_due` |
| Definition | A due item whose action date lies before the first day of the tenant's current month. On Reports → Maintenance the Past due column comes before the months; a planned exchange is past due when its first action date is. |
| Source | The action date and the tenant's date today in its zone (`cma.tenant_today_of`) |
| Counts / does not count | Counts every past-due item of a tracked device that the latest full snapshot holds, whatever the horizon. An item stays past due until a later read (the poll, the nightly snapshot or a loaded file) gives it a later due date: a recorded expiry, a replacement (the rule restarts from the day the new serial was first seen) or a later last shipment for the rule |
| Unit and display | A count in the Past due column (`maintenance.past_due`) |
| Time rule | The tenant's current month, in its zone |
| Scope | As Device |
| Equivalent in the source system | None |
| Not to use | "Overdue" (undefined: it is still to define for tasks and tickets, Domains still to define); "late" or "expired" for a past-due item |
| Status | Decided |
| Decided | 27 October 2026; docs/decisions.md, 27 Oct 2026, "Definitions: Past due" |
| Used by | `maintenance.past_due`, the bucket `past_due` of `/api/v1/reports/maintenance/rows`; `cma_read.maintenance_due`, `cma_read.maintenance_per_month` (`past_due`); Reports → Maintenance |
| As built today | `cma.maintenance_items_of` (`112`): `past_due` when the action date is before the month of the tenant's today. Matches the definition |

### Exchange (planned)

| Field | Value |
|---|---|
| Term | Planned exchange (nl: Geplande wissel) |
| Key | `exchange_key`, `exchange_on`, `exchanges`; API `exchanges`, view `exchanges` |
| Definition | The due items of one device whose action dates fall within the bundling window of the earliest one: one exchange, counted once, in the month of that earliest action date. The next item beyond the window starts the device's next planned exchange. |
| Source | The due items' action dates and the setting `assets.bundle_window_days` |
| Counts / does not count | Counts each planned exchange once, in its first action date's month (or Past due). An item of basis `unknown` belongs to no exchange |
| Unit and display | A count (`maintenance.exchanges`), the grid's default view "Planned exchanges" |
| Time rule | The month of the exchange's first action date |
| Scope | As Device |
| Equivalent in the source system | None |
| Not to use | "Exchange" alone for this term: the exchange form is service intake (docs/decisions.md, 12 Oct 2026) and Exchange is a journey of Campaign monitoring (docs/open-decisions.md); "swap", "visit" |
| Status | Decided |
| Decided | 27 October 2026; docs/decisions.md, 27 Oct 2026, "A due item's due date is the recorded expiry" and "Definitions: Exchange (planned)" |
| Used by | `maintenance.exchanges`, `maintenance.by_month`, `maintenance.total`; `cma_read.maintenance_due`, `cma_read.maintenance_per_month`; Reports → Maintenance |
| As built today | `cma.maintenance_items_of` (`112`): one ordered pass per device in action-date order. Matches the definition |

### Bundling window

| Field | Value |
|---|---|
| Term | Bundling window (nl: Bundelvenster) |
| Key | `assets.bundle_window_days`; API `bundleWindowDays` |
| Definition | The days after a device's earliest action date within which its other due items join the same planned exchange. |
| Source | Tenant setting `assets.bundle_window_days`, a whole number from 0 to 365, default 0 (only items with the same action date bundle); 90 for Pulse4all Subscriptions (seed `02`, to confirm, docs/open-decisions.md) |
| Counts / does not count | An item whose action date is at most the window after the exchange's first action date joins it; a later one starts a new exchange |
| Unit and display | Days ("bundling window {days} days") |
| Time rule | Calendar days |
| Scope | The tenant |
| Equivalent in the source system | None |
| Not to use | "Grace period" |
| Status | Decided |
| Decided | 27 October 2026; docs/decisions.md, 27 Oct 2026, "Definitions: Bundling window" |
| Used by | `maintenance.exchanges`, `maintenance.devices` (the devices line); Reports → Maintenance |
| As built today | `cma.check_tenant_setting` and `cma.maintenance_items_of` (`112`). Matches the definition |

## Subscription terms

Proposed with addition 0008zl (28 October 2026), for Kira to confirm. The tenant's subscription app owns a store's subscriptions and their events: for Pulse4all Subscriptions that is Juo on each Shopify store, one connection and one key per store, the GB store first. The CMA mirrors them read-only, read by the ingest by polling only (Juo has no webhook topic for a failed renewal), so that it can report churn (KPI 4) and each subscription's payment state; no page shows them yet. A subscription holds ids, statuses, codes, counts, amounts and times only, never a customer's name, email, phone, address, payment detail or free-text reason. Payment state is Juo's renewal state of a subscription, not a payment in NetSuite: payments, days to pay and dunning stages stay NetSuite's (README, Source of truth).

### Subscription

| Field | Value |
|---|---|
| Term | Subscription (no Dutch label for the term in `copy.ts`; the connection kind says "Abonnementen") |
| Key | `subscription`; SQL `cma.subscription`, `cma_read.subscription`; columns `source_id`, `customer_source_id`, `status`, `current_cycle`, `next_billing_at`, `billing_interval`, `billing_interval_count`, `amount_per_cycle`, `currency`, `payment_instrument_type`; no API field yet |
| Definition | One subscription of a store's subscription app (Juo), one row per subscription and connection: its store customer's id, status, cycle, next billing time, billing interval, amount per cycle and currency, the type of its payment instrument and its times. A subscription the latest full read no longer returns stays stored and is marked missing (`source_deleted_at`). |
| Source | The subscription app; for Pulse4all Subscriptions Juo's Admin API (`GET /subscriptions`, the payment method expanded for its instrument's type only), read by `ingest-poll-subscriptions` (the subscriptions the store's events touched, every `subscriptions_poll_interval_minutes`, default 5) and by the nightly full read in `ingest-reconcile` (also `ingest-backfill --object subscription`), written by `cma.ingest_upsert_subscriptions`. The store customer's id joins `cma.commerce_customer.source_id` of the store whose handle is the connection's account id up to its first dot. Only whitelisted fields are read: a name, email, phone, address, payment detail or custom attribute never reaches a row |
| Counts / does not count | Counts one row per subscription and connection that the latest full read still returns (`source_deleted_at` empty). A subscription missing from the latest full read stays stored and is not counted. The amount per cycle is the sum of the total prices of the items Juo has not canceled, as Juo states them, in the subscription's currency. A subscription whose customer the store's customers do not hold is still counted (the run's `customers_unmatched`) |
| Unit and display | A count of subscriptions; an amount in the subscription's currency (two decimals); no page shows one yet, and a page shows a subscription by its Juo id and its status, never a customer's name or email |
| Time rule | Instants as Juo writes them (`source_created_at`, `next_billing_at`, `canceled_at`, `source_updated_at`); `paused_at` is when the current pause began (Juo's time, else the latest pause event; empty unless paused). The day a report puts a subscription on is decided with the first report |
| Scope | The tenant's connections of the kind `subscriptions`, one per store (the GB store is the pilot). The store is the tenant's commerce store whose handle is the connection's account id up to its first dot; a connection whose handle has no store is refused (`store_not_configured`) |
| Equivalent in the source system | A subscription of Juo's Admin API (`GET /subscriptions`; Juo's admin shows the counts per status). Juo's help article: not checked (juo.dev was out of reach when built) |
| Not to use | "Subscription" for a webhook subscription (Shopify's `webhookSubscriptions`, Aircall's webhook): say webhook, as System health's label "Shop webhooks check" does (Gaps D33, I7); Pulse4all Subscriptions is a business line's name, not this term |
| Status | Proposed (for Kira to confirm) |
| Decided | 28 October 2026 (Proposed); docs/decisions.md, 28 Oct 2026, "Juo is read directly by the ingest for a store's subscriptions and their events", "One Juo connection and one Admin API key per store", "The Juo connection's store is the tenant's commerce store", "No personal data and no free-text reason is read from Juo", "Definitions: the System health label of Shopify's webhook check" and "Definitions: Subscription, Subscription status, Payment state and Failed renewal" (addition 0008zl) |
| Used by | No catalog key and no page yet; `cma.subscription`, `cma_read.subscription`, `cma.ingest_upsert_subscriptions`, `cma.ingest_mark_subscriptions_missing`; the job `subscriptions_poll`; the connection kind `subscriptions`; the data map's domain `subscriptions` (`docs/datamap/catalog.json`) |
| As built today | `cma.subscription` (`118`): one row per `source_id` and connection, unique per tenant; `status` one of the seven of Subscription status; `amount_per_cycle` numeric(14,2); `payment_instrument_type` `card`, `paypal` or `other`, empty when Juo did not expand the payment method; `raw` a fixed set of keys with scalar values and no @ (`cma.subscription_raw_ok`); ids checked by `cma.subscription_id_ok`; the application never deletes a row. `cma.ingest_upsert_subscriptions` takes at most 500 (a stale guard on Juo's update time) and a full read ends with `cma.ingest_mark_subscriptions_missing` in slices. `119`'s Z1 reads every row for an email pattern. Matches the definition |

### Subscription status

| Field | Value |
|---|---|
| Term | Subscription status (no Dutch label in `copy.ts`) |
| Key | `status` of `cma.subscription`; `status_from` and `status_to` of `cma.subscription_event`; values `active`, `paused`, `canceled`, `expired`, `failed`, `merged`, `never-subscribed` |
| Definition | Juo's own status of a subscription, in Juo's words (convention 2): active, paused, canceled, expired, failed, merged or never-subscribed. The CMA stores it as Juo gives it, Juo's `cancelled` written `canceled` and `NEVER_SUBSCRIBED` written `never-subscribed`. |
| Source | Juo's `status` on a subscription (lower case) and on a status event (upper case: `previousStatus`, `data.status` and `data.input.status`), read by the poll and the nightly full read; Juo's own move to failed arrives as an update from active to failed by the system |
| Counts / does not count | Every subscription has one status. A subscription with status merged or never-subscribed is stored and has no payment state. The status is Juo's fact: no CMA rule changes it, and a subscription the latest full read no longer returns keeps its last status with `source_deleted_at` set. When Juo sets failed, and whether its retries continue, is an Open decision |
| Unit and display | Juo's word in lower case; no label rewords it |
| Time rule | As of the latest read of the subscription (the poll when an event touched it, else the nightly full read); the events `canceled`, `paused`, `resumed`, `reactivated` and `status_changed` hold the moves (`status_from`, `status_to`, `occurred_at`) |
| Scope | As Subscription |
| Equivalent in the source system | Juo's subscription `status` (Admin API) |
| Not to use | "Cancelled" (Juo's spelling) in a key or a label: the CMA says canceled; Cancellation is another term, still to define (Reports → Cancellations counts cancellation requests, not statuses); "active" for a device's state (Device status) |
| Status | Proposed (for Kira to confirm) |
| Decided | 28 October 2026 (Proposed); docs/decisions.md, 28 Oct 2026, "Juo is read directly by the ingest for a store's subscriptions and their events" and "Definitions: Subscription, Subscription status, Payment state and Failed renewal" (addition 0008zl) |
| Used by | `cma.subscription.status`, `cma.subscription_event.status_from` and `status_to`, `cma_read.subscription`, `cma_read.subscription_event`, `cma.subscription_payment_state_of`; no catalog key and no page yet |
| As built today | `cma.subscription.status` written by `cma.ingest_upsert_subscriptions`, which refuses a status outside the seven (`CMA04`); the events `canceled`, `paused`, `resumed` and `reactivated` carry `status_from` and `status_to`, a `status_changed` has both (an update without a status, or with the same one, is no event of the CMA). Matches the definition |

### Payment state

| Field | Value |
|---|---|
| Term | Payment state (no Dutch label in `copy.ts`) |
| Key | `payment_state`; values `paid`, `in_retry`, `failed`, `paused`, `canceled` (`awaiting_payment` reserved); `retry_cycle`, `retry_since`, `last_attempt`; SQL `cma.subscription_payment_state_of`, `cma_read.subscription_payment_state`; no API field yet |
| Definition | Per subscription, Juo's renewal state of it, one of six: Paid (status active, no open failed renewal), In retry (status active, with a failed renewal of a cycle that no renewal of that cycle or a later one follows), Failed (status failed), Paused (status paused), Canceled (status canceled or expired) and Awaiting payment (Pending: a renewal by draft order, Mollie, not paid yet; not built). It is Juo's renewal state, not a payment in NetSuite, which still owns payments, days to pay and dunning stages. |
| Source | `cma.subscription` and `cma.subscription_event` only, computed at read time by `cma.subscription_payment_state_of(tenant)` with no call to Juo: the subscription's status and its `renewed` and `renew_failed` events. Where either event lacks its cycle, a renewal after the failure closes it |
| Counts / does not count | One state per subscription the latest full read still returns (`source_deleted_at` empty) whose status is active, paused, canceled, expired or failed; a subscription with status merged or never-subscribed has none, and neither has one missing from the latest full read. Canceled covers the statuses canceled and expired and is kept apart from Cancellation: Reports → Cancellations counts cancellation requests, and Cancellation and Minimum term stay under Domains still to define. Paid is not a NetSuite payment: an invoice's payment status, days to pay and dunning stage are NetSuite's (README, Source of truth) |
| Unit and display | A count per state; In retry also gives the open failure's cycle, its first failure and its highest attempt; no page shows it yet |
| Time rule | As of now: computed from the stored rows at each read, with no state history (the events are the history). A subscription is as fresh as its last read: every `subscriptions_poll_interval_minutes` (default 5) when an event touched it, else the nightly full read |
| Scope | As Subscription |
| Equivalent in the source system | None: the CMA's own derivation from Juo's status and its renewal events |
| Not to use | "Payment status" and "dunning stage" (NetSuite's words for invoices and payments; README, Source of truth); "paid" for a payment in NetSuite, since Paid here is Juo's renewal state |
| Status | Proposed (for Kira to confirm); Awaiting payment is Pending: whether a renewal by draft order is a payment state of its own, per store (docs/open-decisions.md), and nothing is built as if settled |
| Decided | 28 October 2026 (Proposed); docs/decisions.md, 28 Oct 2026, "Each subscription has a payment state, one of six" and "Definitions: Subscription, Subscription status, Payment state and Failed renewal" (addition 0008zl) |
| Used by | `cma.subscription_payment_state_of`, `cma_read.subscription_payment_state`; no catalog key and no page yet (KPI 4 and the device's subscription status come later: docs/open-decisions.md) |
| As built today | `cma.subscription_payment_state_of(tenant)` (`118`): Failed for status failed, Paused for paused, Canceled for canceled or expired, In retry for active with an open failed renewal (also `retry_cycle`, the latest open cycle, `retry_since`, its first failure, and `last_attempt`, its highest attempt), else Paid; `cma_read.subscription_payment_state` reads it through a `SECURITY DEFINER` reader function. Awaiting payment is not built: no subscription has it. Matches the definition apart from Awaiting payment (Pending) |

### Failed renewal

| Field | Value |
|---|---|
| Term | Failed renewal (no Dutch label in `copy.ts`) |
| Key | `renew_failed` (`cma.subscription_event.event_type`); `cycle_index`, `attempt`, `error_code`, `reason_code` |
| Definition | A renewal attempt of a subscription that Juo reports as failed, with its cycle, its attempt, an error code and a reason code (Juo's event `subscription:renew-failed`, stored as `renew_failed`). The error message is never read. |
| Source | Juo's event `subscription:renew-failed`, read by the poll (`GET /events` for the category subscription, after its cursor less five minutes) and by `ingest-backfill --object subscription_event`: `cycleIndex`, `attempt`, `errorCode` (upper case, kept as a code), `reason` (kept only as a code of a fixed list, today `billing-attempt-failed`), the event's id and time |
| Counts / does not count | One row per event, append-only. A failed renewal is open until a renewal of that cycle or a later one follows it, and an open one on an active subscription makes it In retry. On a subscription whose status is not active it changes no payment state: Failed, Paused and Canceled show their status. The error message, a free-text reason and any detail of the payment are not read |
| Unit and display | A count of events per type and cycle; a code shows as the code, never a message; no page shows it yet |
| Time rule | `occurred_at`, the instant Juo reports; the poll reads again from five minutes before its cursor, so the overlap stores nothing twice |
| Scope | As Subscription |
| Equivalent in the source system | Juo's event `subscription:renew-failed` (severity problem); HubSpot's copy of Juo's events stays as it is and is not read for this |
| Not to use | "Failed" alone for it (Failed is the payment state of status failed: a failed renewal on an active subscription is In retry); "failed payment" and "dunning" (NetSuite's words, README, Source of truth) |
| Status | Proposed (for Kira to confirm) |
| Decided | 28 October 2026 (Proposed); docs/decisions.md, 28 Oct 2026, "The ingest polls Juo and takes no webhooks from it", "No personal data and no free-text reason is read from Juo" and "Definitions: Subscription, Subscription status, Payment state and Failed renewal" (addition 0008zl) |
| Used by | `cma.subscription_event` (`event_type` `renew_failed`), `cma_read.subscription_event`, `cma.subscription_payment_state_of` (In retry with `retry_cycle`, `retry_since` and `last_attempt`); no catalog key and no page yet |
| As built today | `cma.subscription_event` (`118`): `event_type` `renew_failed` with `cycle_index`, `attempt`, `error_code` (a code of letters, digits and `_`) and `reason_code` (a lower case code, at most 60), written by `cma.ingest_upsert_subscription_events` (an event already held is left as it is, and the application never updates or deletes one); the adapter reads no error message and counts a reason outside its fixed list as `reason_dropped`. Matches the definition |

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
Contact, customer, new customer, first order, direct order, indirect order, B2B, B2C, cancellation, minimum term. Subscription, Subscription status, Payment state and Failed renewal are defined under Subscription terms (addition 0008zl); cancellation stays here, apart from Payment state's Canceled.

### Tickets and tasks
Ticket, complaint, vulnerable case, owner, without owner, overdue, response time.

### Email
Email sent, mailbox, inbox, first reply.

### Time and people
Workday, clocked in, hours worked, status, working status, business minutes, office hours, market.

### Periods
Yesterday, Today, This week (ISO, Monday), This month, Custom range, previous period, like for like.

### Other
Forms, data quality. Maintenance is defined under Asset terms (addition 0008zi).

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
| W19 | `web/src/lib/copy.ts`; `web/src/app/api/v1/reports/first-orders/route.ts`, `callbacks-kept/route.ts`; `web/src/app/reports/orders-per-person/page.tsx` | `reports.noTelephony` "No telephony connected", `noShop`, `noEmail`, `noOrders`, `noTelephonyHint`, `noShopHint`, `noFormsHint`; the API field `connected` of First orders, Callbacks kept and Orders per person | Connected for a source that is set up | Another word, to choose in the definitions brief (for example "set up"): Connected is a call term. Reports → Reviews already says "set up" (`isSetUp`, `is_set_up`; Review terms) |
| W20 | `web/src/lib/copy.ts`; `web/src/lib/csv.ts` | `funnel.colReachedWon`, `funnelFile.reachedWon`, `hints.fnColReachedWon` ("Reached won", "Gewonnen bereikt"); API `reachedWon` | Reached for a deal won now | A word that is not retired (for example "Won now") |
| W21 | `web/src/lib/data/types.ts` | API fields `unanswered`, `unansweredByReason` (Inbound) | 0008i's words (the Calls, Calls per agent and Attempts per deal fields took the terms' keys in addition 0008zc) | The term's camelCase key (`missedInbound`) |
| W25 | `web/src/components/configuration/SourceConfig.tsx` (Configuration → Sources, Lines); the Data quality page | The number of counted lines | Not shown: Lines lists each line with its Counted switch, and a line Aircall adds arrives counted | Data quality or Configuration → Sources shows the number of counted lines, so the list can be compared with the 46-number filter in Aircall Analytics (Call, Scope) after a line is added in Aircall |
| W27 | `web/src/lib/copy.ts` | `hints.agent` (Speed to lead's grouping by agent) | "The person behind the first outbound call, else the deal's owner" (its CRM owner) | The person who placed the first attempt (the call's last participant, Aircall) |
| W28 | `web/src/lib/copy.ts` | `speedToLead.openNotCalled` "Open, not called", `speedToLead.openTitle`, `hints.withinTarget`, `hints.openNotCalled`; no group for deals created by hand or closed before the first call | "Deals closed without a call count as missed; deals still open and not called are left out until they are called or closed" | "Not called yet" with its age, late once past the target or the cutoff; "Created by hand, not in speed to lead" and closed before first call shown apart, out of the measures |

### db/

| # | File | Key or label | Says | Should say |
|---|---|---|---|---|
| D4 | `db/100_definitions_calls.sql` (`cma.calls_of`, `cma.calls_per_person_of`); `db/76_audit_hardening.sql` (`cma.inbound_calls_of`); `db/64_calls_history_start.sql` | `business_date`, week, hour and time of day | In the line's market zone, else the tenant's | In the tenant's zone (Day). Acceptance after step 2: Friday 23 October 2026 gives 199 calls, 20 inbound, 179 outbound and untagged 12.1 %, as Aircall's 46-number filter; the missed inbound call on UK Sales at 00:05 Amsterdam time on 24 October (23:05 London time), dated 23 October today, moves to 24 October (`docs/definitions-2026-10/records/step1-dev-prod-2026-10-25.md`) |
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
| D31 | `db/100_definitions_calls.sql` (`cma.calls_of` with `cma.call_not_reached_of`, read by `cma.calls_overview` and `cma.calls_per_person`) | The speed of Reports → Calls and Calls per agent | About 565 ms for 1 to 25 October 2026 in prod as `cma_app` (`calls_overview` 565.6 ms, `calls_per_person` 564.7 ms), twice 0008zb's: Conversation reads each call's tags; a quarter's range would pass 1000 ms (`docs/definitions-2026-10/records/step1-dev-prod-2026-10-25.md`) | Under 1000 ms for a quarter's range; fixed with the step 2 work: an index on the current tags by call, or the tag rule computed once per call |
| D32 | `db/74_forms_reporting.sql` (`cma.data_quality_of`) | The calls tagged incorrect data | Not counted apart: a call with a current tag meaning "incorrect data" is only kept out of Conversation (`102`) | Definitions step 2 (data quality checks): the calls with a current tag meaning "incorrect data" reported apart, a data-quality figure (to define with step 2) |
| D33 | `db/118_subscriptions.sql` (the `sync_run.job` check, first made in `db/32_intake_core.sql`) | The job value `subscriptions_check` (stream `webhooks`) | "Subscriptions" for the webhook subscriptions of a shop (Shopify's nightly webhook check) | Another word, for example `webhooks_check`, the stored runs moved with it: Subscription is a subscription of a store's subscription app (Subscription terms). System health's label already says "Shop webhooks check" since addition 0008zl |

### ingest/

| # | File | Key or label | Says | Should say |
|---|---|---|---|---|
| I1 | `ingest/src/adapters/hubspot/map.mjs` | `CALL_PROPERTIES` (`hs_call_disposition`, `hs_call_status`, `hs_call_duration`); `callFromObject`'s `outcomeRef`, `status`, `durationSeconds` | The logged call's outcome, status and duration are read and stored | R1: from the logged call only its associations (and, while `hash_time` pairs calls, its hash, time and direction for the pairing) |
| I2 | `ingest/src/adapters/hubspot/read.mjs`; `ingest/src/core/store.mjs` | The outcome catalog (`GET /calling/v1/dispositions` into `cma.ingest_upsert_call_outcomes`) | HubSpot's call outcomes are read hourly with the catalogs | Retired (R1) |
| I3 | `ingest/src/adapters/aircall/map.mjs` | `userRef: call.user.id` | The call's user | The last participant (the field to confirm) |
| I4 | `ingest/src/adapters/aircall/map.mjs` | `numberRef: call.number.id` | The call's number | The last number of a routed call (to verify) |
| I5 | `ingest/src/adapters/aircall/map.mjs` | `callFromObject` | Every inbound or outbound call is stored, internal ones included | Internal calls left out (how Aircall marks one, to verify) |
| I6 | `ingest/src/adapters/hubspot/map.mjs` | A deal's record-source fields | Not read: a deal brings its pipeline, stage, owner and times (and configured fields) only | The creation source mapped per CRM connection from the record-source fields (HubSpot: `hs_object_source` and `hs_created_by_user_id`, to verify) |
| I7 | `ingest/src/adapters/shopify/reconcile.mjs` and `index.mjs` (`checkSubscriptions`); `ingest/src/adapters/shopify/map.mjs` (`SUBSCRIPTION_TOPICS`); `ingest/src/jobs/reconcile.mjs` | `checkSubscriptions`, `SUBSCRIPTION_TOPICS`, the job value `subscriptions_check` it writes and the run errors `subscriptions_recreated`, `subscriptions_missing`, `subscriptions_recreate_failed` | "Subscriptions" for Shopify's `webhookSubscriptions`, the shop's webhook subscriptions | Another word (for example webhooks): Subscription is a subscription of a store's subscription app; moves with D33 |

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

**Count per area:** `web/` 13, `db/` 21, `ingest/` 7, `docs/metrics/catalog.json` 9; 50 in all.
