# Gates skeleton: what stands between today and the soft launch

Written on 17 October 2026 by the readiness subagent from README.md (Roadmap step 2, Open decisions,
Decision log). The "class" column is blank: the lead fills it (blocker / should-have / follow-up) against
this definition of the soft launch:

> Arno, the call center manager, works in the Workspace every day (Team hours and corrections, People and
> linked accounts, the roster planner, the Live board, the reports he steers on, Messages); the Newco
> agents keep clocking their day in it as they have since 12 October 2026; development continues in
> parallel. Not part of it: the agent desk, Invest, the final name, the repository going private.

"Status" is what README states, with the line; nothing here was checked against the Console or the Admin
console. The backlog codes in brackets are the brief's; most do not occur in README.md (see dated-items.md).

## A. Roadmap step 2's own conditions (README line 1593, "Before the first real agent uses it")

| # | Item | README reference | Status as README states it | Who answers | Class |
|---|---|---|---|---|---|
| A1 | The app's user check and IAP token verification | 1593; Authentication 1561 to 1588 | Done 5 October 2026 (`proxy.ts`, `iap.ts`, `verify/iap-token.mjs`) | Martin | |
| A2 | Prod on a dedicated core with high availability, `min-instances=1` | 1593, 145, 1859 | Done 7 October (HA) and 12 October 2026 (`min-instances=1` on `cma-web`) | Martin | |
| A3 | Heads-up to Yordi before real agent hours | 1593, 2010, 2011 | Drafted 7 October 2026 (four questions); "whether it was sent is to be confirmed by Martin"; the Open decisions bullet still says "send it now, before the first Newco agent". The Newco conditions themselves were confirmed by Yordi on 12 October 2026 (1860) and the intake heads-up was sent 10 October (2059) | Martin (confirms), Yordi | |
| A4 | Spain's daily working-time registration and Wet DBA confirmed by Yordi before real agent hours | 1713, 1860 | Settled 12 October 2026: Newco agents are employees, the CMA is Pulse4all's own tool, not Newco's register; processing covered by the Newco agreement; agents informed (Martin, confirmed by Yordi) | Yordi, Martin | |
| A5 | The gate opens from `cma@` to the pulse4all.com domain | 1593, 1859 | Done 12 October 2026 (the agent go-live with Arno) | Martin | |
| A6 | Joshua in prod as admin, Finn to `agent` | 1593, 1724, 1725, 2016 | "Remaining" in the Roadmap text; Open decisions (2016) still describe the sequence; no README line says it was done | Martin | |
| A7 | Review of the web dependencies (`npm audit`: 5 high, one chain under `eslint-config-next`) | 1593, 2010 | Open: devDependency only, nothing ships in the image, no fix exists, reviewed with every Next.js update; never `npm audit fix --force` | Martin | |
| A8 | Baselines for business-case KPIs 1, 3, 5 and 7; the ten targets confirmed | 1593, 2056 | Open: "confirm the ten targets with Arno, Kira and Peter … who takes and records the baselines, and when the first quarterly review is" | Arno, Kira, Peter (Martin) | |
| A9 | The exact portal addresses for the app links; the Steam sample (hours columns, duration format); which hours the agent sees | 1593, 2026 ff. | App links: generic until Martin provides the addresses (Open decisions); the hours columns to settle with the Steam sample (Open decisions) | Martin, Arno | |

## B. Open decisions tied to gates

| # | Item | README reference | Status as README states it | Who answers | Class |
|---|---|---|---|---|---|
| B1 | 2-Step Verification for the Newco unit, and Context-Aware Access / IAP session length [CMA-021] | 2051; 1887 (G-03); 1916 (FIND-06) | Open: "both depend on the Google Workspace edition. 2SV enforcement for the agents' unit to be checked in the Admin console now, the gate is open to the domain since 12 October" | Martin (Workspace admin check); the edition question with Mark | |
| B2 | Container vulnerability scanning in Artifact Registry (fifth audit FIND-08) | 2052; 1916 | Open decision on cost: "billed per scanned image, one per merge; automatic scanning or an on-demand scan before a release" | Martin | |
| B3 | A PR check trigger (typecheck, lint, build, pure verifiers, no deploy) [CMA-024] | 2017 | Open: "when a second person commits"; `web/verify/**` is out of the deploy trigger since 7 October; a build-only trigger for branch images "belongs to the same step" | Martin | |
| B4 | A dev-only web build path [CMA-068] | 2138; 1990 | Open since 16 October 2026: `cloudbuild.yaml` always deploys, so a branch's web image is seen in dev only after its merge; "a build that only builds and pushes an image, where it is tagged and who may start it, is to decide" | Martin | |
| B5 | Retention job for call data, phone hashes, email metadata, audit images, staff data, invitations [CMA-003] | 2067, 2104, 2115, 2125, 977, 1961 | Open: no retention job exists for any of these; "to build with the aggregation"; the audit log keeps the images meanwhile; the Yordi decisions on retention (FIND-05, 2074) pending | Martin, Yordi | |
| B6 | Aggregation of agent data older than 1 year [CMA-026] | 2018, 2047 | Open: needed before January 2027 (the imported days of batch `steam-2026` from 2 January 2026) | Martin, Yordi (Arno for the imported days) | |
| B7 | The repository public until launch, then private [CMA-038] | 157, 1801, 1932, 2031 | Decided 8 October 2026: public until launch so a build chat can read `main`; Open decisions: "while it is public, the README and `records/` name staff … tell Yordi, and strip or keep as he says". The brief says CMA-038 proposes flipping it now; by the soft-launch definition the flip is not part of the soft launch | Martin, Yordi (the staff names) | |
| B8 | The final name instead of the working title | 2054, 1643, 26 | Open, with Mark; not part of the soft launch by definition | Mark (Martin) | |
| B9 | The Yordi heads-ups: step 2 (A3), the intake track (sent 10 October; prod BigQuery waits for his answer), the second heads-up plus the processor view and who-saw-what audit before the mirror (step 3) and the desk (step 8) | 2010, 2011, 2059, 1595, 1601 | Step 2: to confirm sent (A3). Intake: sent, "prod for that waits for his answer" (the BigQuery prod connection, `bq_reader` prod password not set, 297). Second heads-up: not due before the mirror and the desk, which are outside the soft launch | Martin, Yordi | |
| B10 | Plan B for agents if the CMA is down [CMA-032] | 2100 | Open: "today: HubSpot and Aircall as they work now"; this audit drafts it (`PLAN_B.draft.md`), Arno's copy follows | Arno (content), Martin | |

## C. The employee-monitoring point: per-person figures Yordi has not cleared

README 2021 (Open decisions): "The employee-monitoring point with Yordi now covers the Live board too: live
per-person status to supervisors, managers and analytics, besides the Dashboard's per-person time … Settled
for the per-person call figures (14 October 2026, brief B16) … the Live board's live per-person status stays
to confirm … the per-person email figures of brief B17 (B17c) fall under the same point, to confirm with
Yordi before that page goes live in prod. Yordi's answer of 15 October 2026 … leaves this point as it is
until Martin says it is settled."

| # | Figure | Where | README reference | Status as README states it | Who answers | Class |
|---|---|---|---|---|---|---|
| C1 | Live per-person status (who is in which status now) | Live → Live board (`/live/board`, `monitoring.live`), live in prod since 7 October, agents since 12 October | 2021, 1190 | "Stays to confirm" with Yordi; Yordi's 12 October answers cover processing, informing the agents and retention, "not explicitly live per-person status" (seventh Gemini audit). Whether analytics should hold `monitoring.live` is part of the ladder review with Arno and Kira | Yordi (Martin reports); Arno, Kira for the grant | |
| C2 | Calls per agent (calls, talk time, split by counted tag per person) | Reports → Calls per agent (`performance.team`) | 2021, 898 | **Settled 14 October 2026**: sorted by name, never ranked, "as Yordi agreed (reported by Martin; Decision log)" | done | |
| C3 | Follow-up per person (what is waiting per mapped person) | Reports → Follow-up (`follow_up_by_owner`, `performance.team` only) | 989; Decision log 16 Oct ("per-person figures under the employee-monitoring point"); backlog line CMA-046 in `docs/night-2026-10-16/NIGHT_NOTES.md` | Built (0008o); README places it "under the employee-monitoring point with Yordi, like Calls per agent": not separately confirmed | Yordi (Martin reports) | |
| C4 | The Dashboard's per-person time (hours and status time per person) | Reports → Dashboard (`performance.team`), since 7 October | 2021, 1190, 1734 | "Besides the Dashboard's per-person time": named in the point since 7 October, to confirm; per person sorted by name, no ranking (Decision log 7 Oct) | Yordi (Martin reports) | |
| C5 | Email per agent (B17c: sends, replies, closes, first reply times per person) | not built | 2021 | "To confirm with Yordi before that page goes live in prod" | Yordi | |
| C6 | Benchmarking agents across employers and countries; what agents see of each other; what the partner's HR sees; retention of per-agent history | not built | 2040, 1333 | Open, with Yordi (NL and Spain monitoring rules) | Yordi, Arno | |

## D. Other open items that touch the soft-launch surface (for the lead to class or drop)

| # | Item | README reference | Status | Who answers | Class |
|---|---|---|---|---|---|
| D1 | The 108 imported days of `steam-2026` flagged for review (closed by the 17:00 rule or clipped); then clear the staged Steam account names | 2048, 2046 | Open: Arno reviews them on Team hours (needs correction) | Arno | |
| D2 | Prod admin access from a personal device (the Chromebook) and Google Cloud session control | 2050, 2049 | Open since 16 October 2026 | Martin, Yordi (device policy) | |
| D3 | The task webhooks (CMA-067): until the app versions are installed, tasks arrive by backfill and the 02:30 reconcile, deletions unseen; Follow-up, Waiting for you and Welcome's tasks overdue incomplete | 2137, 1990 | Accepted as a data prerequisite (Decision log 16 Oct); closes with the GitHub Actions upload route | Martin | |
| D4 | The Aircall call link template (`record_url_call`): the Live board's missed calls have no link icon | 2109 | Not set at the 14 October go-live; the address to verify in Aircall's dashboard | Martin | |
| D5 | Email deletions: a deletion subscription or a nightly comparison, to decide after a month in prod | 2119 | Open, ~16 November 2026 | Martin, Kira | |
| D6 | Tenant picker: needed before anyone works for two tenants | 2012 | Open; not needed while only Subs is live | Martin | |
| D7 | Notifications and quiet hours ("not clocked in means quiet"; must-acknowledge broadcasts) | 2035 (the "28:" bullet of the Open decisions), 2104 | Question for Martin, with Yordi on the Spanish rule | Martin, Yordi | |
| D8 | NocoDB: "decide which `cma_read` columns the team may see before handing out workspace roles" (agent hours are personal data) | `docs/nocodb/README.md`, Status | Open since 9 October 2026 | Martin, Yordi | |
