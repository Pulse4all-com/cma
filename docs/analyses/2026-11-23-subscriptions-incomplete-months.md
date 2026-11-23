# Customers → Subscriptions: months whose source is incomplete (options, not built)

Prepared on 23 November 2026 for Martin, on PR #308 (addition 0009zh, brief B39d), while the merge is held. Labels: **Studio** (the instance named), **File** (a repository path).

## Decision (Martin, 23 November 2026): Step 0

The cause is known (the #309 session): the subscription app changed its event shape on 28 January 2026, and the adapter dropped every move in the old shape. The app still holds those events, so the route is Step 0:
- a new PR reads the old shape;
- it backfills `subscription_event` with `--again`;
- it recomputes the facts.

Its acceptance is PROD_RUNBOOK 19.18 reading near 1 before February 2026. Options A, B and C are not built. #308 stays on hold until then, and is merged as it is: no mark, and no later start on the page. The options below are kept as prepared.

## What is known

From Martin's message of 23 November 2026, reporting the #309 session:
- The CMA reads no exits and no pauses before about 27 to 28 January 2026, in every store, while the subscription app counts them.
- In DE, canceled is missing until 20 May 2026.

What this reaches on the page as built:
- **Rate lines.** The rates start at each store's `rate_start_month` (`cma.subscription_store_start`): GB and NL 2025-06; DE, FR, BE and SE 2025-07; AT 2026-06; DK and IE 2026-07. GB, NL, DE, FR, BE and SE therefore draw seven or eight months before February 2026 on Churn rate and Failed rate. DE's Churn rate is also affected up to May 2026.
- **One flag behind every rate.** Every rate reads the month take's `complete` flag (`cma.subscription_month_take`):
  - the page's rates per market and month;
  - the months' complete parts;
  - the Churn rate and Failed rate tiles;
  - Customers → Active's Churn rate card;
  - `cma_read.subscription_churn_month`.

  So any fix in that flag reaches them all at once. Flash's Churn overview does not read the take: it counts the events per date. Its dates before February 2026 are as low, and no option here changes them (see the last point of Option A).
- **Movements by month.** The view outside the rates shows churned, moved to failed and paused as counts. These counts are too low in the same months, whatever the rates do.
- **A question for #309.** Where does a subscription whose exit event is missing land? It ends in canceled or failed in the mirror. If the CMA places its exit at the first event it holds, January or February 2026 may show a step up in churned that is the missing months arriving late. The sizing query below shows it per store and month.

## Step 0: the cause decides the route

| Cause #309 finds | Route |
|---|---|
| The app holds the events and the CMA missed them (an import window, a cursor, a filter) | Read them again (a backfill of the events). The take recomputes, and the page needs no mark. Preferred: the numbers become right instead of explained. |
| The app does not serve them (its event history starts late January 2026; DE's canceled events were not written) | One of the options below. The months stay wrong, so the page must not present them as complete. |

## Option A: start the lines later (recommended if the events cannot be read)

- **The rule.** A store's rates start at the later of today's rule and the first month that begins on or after a date from which its events are complete:
  - today's rule is the month after its last migration month, else its first complete month;
  - with 27 to 28 January 2026, that gives 2026-02 for every store, and 2026-06 for DE if its canceled events decide.
- **Data, not code.** The date is tenant configuration per store. Precedents:
  - `courtesy.start_date`, set by hand because Shopify served only 60 days;
  - the telephony history start of B16.1;
  - Martin's migration rule of 20 November 2026, which already moves `rate_start_month`.

  It would live in a small tenant table, `cma.subscription_events_complete_from` (tenant, connection, date, a reason code such as `source_history`), with `cma.setup_tenant_table`. It is audited, written in Studio until a configuration screen exists, and readable as `cma_read.subscription_store_start` gains the date and its reason.
- **Where it acts.** In the facts refresh that sets `rate_start_month` and `complete` (212's function, re-created with `-- based on: 212_subscription_facts_speed.sql`). Every reader of the take follows without a change of its own: the page, Active's card and `cma_read`. Flash's Churn overview reads the events, not the take. For dates before a store's date it would need the same note, or a history start like B16.1's, as its own small change.
- **The page.**
  - "Where each store's rates start" names the reason: "rates from Feb 2026: the subscription app's events are complete from 28 Jan 2026".
  - The movements by month mark the churned, moved-to-failed and paused counts of a store's months before its date with the same note, because those counts are shown even where no rate is.
  - A new copy key in en and nl, and a term in docs/definitions.md ("Events complete from", nl proposed with Kira).
- **DE, one date or two.**
  - With one date per store, DE starts in 2026-06 for both rates, and its Failed rate of February to May 2026, which its events support, is lost.
  - Two dates (one for churn, one for moved to failed) keep it, but `complete` is one flag today. Two flags means a column on the month take, `complete_failed`, and every rate reader picks its own. That is a larger change.

  Recommendation: one date, unless Martin wants DE's Failed rate for those four months.
- **Cost.**
  - A migration that re-creates the facts refresh, with reruns of 211 and 213 (B39c), 217 (this page) and the verifies `grep -lw` finds.
  - A new table in docs/datamap/catalog.json.
  - A row in docs/decisions.md plus a 'Definitions:' row.
  - The refresh gains a join on a few rows, expected to be small against its 10,000 ms budget; it is measured when built.
- **What is lost.** GB and NL lose June 2025 to January 2026 from the lines. Each market still has at least nine complete months by October 2026, more than open-decisions' three-month minimum per store.

## Option B: keep the months and mark them per store and month

- **The data.** The same table, but as a range per store and measure (from, to, which of churned, moved to failed and paused). This also expresses DE's canceled-only gap.
- **The page.**
  - The rate lines keep their points. A month touched by a store's range gets a hollow point and a dashed segment, plus a footnote mark in the table: "Source incomplete: {stores}" (nl "Bron onvolledig: {stores}"). The mark is never the colour alone (Pulse4all-Style, Footnote Grey for the note).
  - A market's pooled rate is marked when one of its stores is.
  - The movements by month mark the affected counts the same way.
- **The cost of being consistent.**
  - Active's card and Flash's churn would need the same mark, or they show the low rates unmarked.
  - `cma_read.subscription_churn_month` would need a column saying so.
  - That is three surfaces and a view against Option A's one rule.
- **The risk.** A rate line is read as a trend. A low stretch with a footnote still reads as "churn was lower last year", and so does a pasted screenshot without its footnote.

## Option C: find the incomplete months from the data (with A or B, not instead)

- **The source.** B39b already stores the app's own `exits` (dims `status` canceled, failed, expired) and `pauses` per store and day. The backfill object `source_figure` reads them from each connection's earliest held event (PROD_RUNBOOK phase 19).
- **The check.** A store-month is incomplete when the CMA's events into those statuses fall below the app's by more than the `source_figures` tolerances.
- **How to use it.** As a Data quality check, or as the Studio query below, it sets the dates of Option A, or the ranges of Option B, from the data instead of from a conversation. It also catches a future gap.
- **Not live.** Not as a live mark on the page: it marks whatever the app says, and the app's history may itself start late.

## Recommendation

1. Follow #309's cause first. If the events can be read again, read them, and nothing is marked.
2. If not, use Option A, with one date per store set from Option C's comparison. It keeps the page, Active's card and `cma_read` agreeing, draws no rate known to be too low, and is one row per store of configuration.
3. Option B only if seeing the months before February 2026 matters more than drawing them right.

Until it is decided, this PR changes nothing. If #308 merges first, the lines before February 2026 show as they are today. If the merge waits for this choice, the chosen option is its own addition after 0009zh, never an edit of 216, which has run in prod.

## Sizing query

Counts per store connection id and month, no customer data. It shows where the CMA's exits and pauses fall away against the app's.
- Exits are events while churned counts subscriptions once, so compare the size month by month, not equality.
- A month where the CMA's count is near zero while the app's is not is the gap.
- A month where the CMA's count jumps is where the missing ones may have landed.

**Studio** (instance cma-prod-pg)
```sql
with cma_m as (
  select m.tenant_id, m.connection_id, m.month,
         sum(m.subscriptions) filter (where m.kind = 'churned') as churned,
         sum(m.subscriptions) filter (where m.kind = 'moved_to_failed') as moved_to_failed,
         sum(m.subscriptions) filter (where m.kind = 'paused') as paused
    from cma.subscription_month_take m
   where m.currency = '' and m.month between date '2025-05-01' and date '2026-06-01'
   group by 1, 2, 3
), app_m as (
  select f.tenant_id, f.connection_id, date_trunc('month', f.business_date)::date as month,
         sum(f.value) filter (where f.figure_key = 'exits' and f.dims ->> 'status' in ('canceled', 'expired')) as app_exits_ended,
         sum(f.value) filter (where f.figure_key = 'exits' and f.dims ->> 'status' = 'failed') as app_exits_failed,
         sum(f.value) filter (where f.figure_key = 'pauses') as app_pauses
    from cma.source_figure f
   where f.figure_key in ('exits', 'pauses') and f.business_date between date '2025-05-01' and date '2026-06-30'
   group by 1, 2, 3
)
select coalesce(c.connection_id, a.connection_id) as connection_id, coalesce(c.month, a.month) as month,
       c.churned, a.app_exits_ended, c.moved_to_failed, a.app_exits_failed, c.paused, a.app_pauses
  from cma_m c
  full join app_m a on a.tenant_id = c.tenant_id and a.connection_id = c.connection_id and a.month = c.month
 order by 1, 2;
```

Expected:
- One row per store and month from May 2025 to June 2026.
- Before February 2026, `churned` and `paused` are low or empty, while `app_exits_ended` and `app_pauses` are not, if the backfill of the figures reached those months. Empty `app_*` columns mean it did not.
- In DE, `churned` stays low against `app_exits_ended` until May 2026.

Tested locally on the volume fixture (183 rows, no figures there).
