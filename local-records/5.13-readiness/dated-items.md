# Dated items due within 60 days from 17 October 2026 (to 16 December 2026)

From README.md (Open decisions, Decision log, Environments) and the docs; written on 17 October 2026 by
the readiness subagent. "Source" names the README line (or file) the date comes from; "Due" is the date as
the source states it, or the estimate derived from it (marked ~). The lead checks each against the current
README before placing it.

| # | Item | Due | Source | Owner |
|---|---|---|---|---|
| 1 | **DST night**: the clock goes from 03:00 CEST back to 02:00 CET on Sunday 25 October 2026. The forgotten-day job runs hourly in UTC (`docs/scheduler/deploy.sh`, `0 * * * *`); corrected times carry an explicit offset because one local hour occurs twice; the day editor asks which 02:xx is meant; the reports' previous period crosses the change (`63`, `61`, `33` verify it). Decide from the 5.12 findings whether to pause `cma-close-forgotten-workdays-hourly` that night and run the job by hand on Sunday morning (OPERATIONS 3). | Sat 24 to Sun 25 October 2026 | README 1703 (Decision log, 6 Oct), 569, 876, 1182, 1214; `docs/scheduler/deploy.sh` | Martin (the lead's 5.12 finding) |
| 2 | **First monthly bill on the dedicated core**: prod's budget alert is €150 per month, "raise it when the first monthly bill shows the level" (the tier change was 7 October 2026). | ~1 to 5 November 2026 (the October bill) | README 145, 331 | Martin |
| 3 | **Cloud Armor rate limits review**: 600 per minute per IP (since 12 October 2026) and 2,400 on `/shopify/` (since 13 October 2026), "reviewed after the first month of real webhook volume in the prod records and the `cma-ingest 429` alerts". | ~12 to 13 November 2026 | README 2078 (Open decisions); 1870 (Decision log) | Martin |
| 4 | **Email deletions**: "to decide after a month in prod whether a deletion subscription for emails … or a nightly comparison is worth it" (the email poll ran in prod on 16 October 2026). | ~16 November 2026 | README 2119 (Open decisions); `PROD_RUNBOOK.md` phase 10 | Martin, Kira |
| 5 | **Shopify `read_all_orders` and the 60-day order window**: without the scope the API serves the last 60 days of orders, "enough for the backfill from 1 October 2026 until about 30 November 2026, after which an older backfill needs the scope"; how to get the scope is open. Related: the backfill window decision (customers all, orders 13 months). | ~30 November 2026 | README 2068, 2069 (Open decisions); 1813 (Decision log, amended 14 Oct); `docs/ingest/PROD_RUNBOOK.md` 9.2; `docs/ingest/README.md` Shopify | Martin, Kira |
| 6 | **Aggregation of agent data older than 1 year (CMA-026)**: "needed before January 2027, when the first imported days (batch `steam-2026`, from 2 January 2026) pass 12 months"; the imported days count like any other. Just outside the 60 days (2 January 2027 is day 77), but the build has to start inside them. | before 2 January 2027 | README 2018, 2047 (Open decisions); Decision log 12 Oct (1-year rule) | Martin, with Yordi (Arno for the imported days) |
| 7 | **Retention job (CMA-003)**: no retention job exists for call data, the keyed phone hashes, email metadata or the audit images; the README ties it to the aggregation above ("to build with the aggregation of agent data older than a year"). No own date; it rides on item 6. | with item 6 | README 2067, 2125, 977, 1961, 2104, 2115 | Martin, with Yordi |

Standing dates inside the window, not decisions:

| Item | When | Source |
|---|---|---|
| Cloud SQL maintenance window, prod: week 2 of the month, Sunday 02:00 UTC (dev: week 1), applied only when Google has an update, announced in the Console | Sun 8 November 2026 02:00 UTC and Sun 13 December 2026 02:00 UTC (prod); Sun 1 November and 6 December (dev) | README 143, 145 |
| `_Default` log bucket retention 30 days: anything older than a month is gone from Logging | rolling | README Decision log 12 Oct (1858) |
| Shopify API version `2026-10` is the pinned default, supported until 16 October 2027; `2027-01` is the release candidate in the window | outside the window (October 2027) | `docs/ingest/README.md`, Shopify |

Named in the brief but not dated in the repository (listed so the lead sees they were looked for):

- The task webhooks (CMA-067): "until the new app versions with the nine task subscriptions are uploaded
  and installed", no date (README 2137).
- The heads-up to Yordi of Roadmap step 2: drafted 7 October 2026, "whether it was sent is to be confirmed
  by Martin" (README 2010, 2011); the intake heads-up was sent on 10 October 2026 (README 2059).
- 2SV for the agents' unit: "to be checked in the Admin console now" (README 2051).
- The 108 imported days flagged for Arno's review (README 2048): no date.
- The backlog codes CMA-021, CMA-024, CMA-032, CMA-034, CMA-038 and CMA-026 named in the brief do not occur
  in README.md (only CMA-002, CMA-003, CMA-004, CMA-067 and CMA-068 do); CMA-024 and CMA-068 occur in
  `docs/audits/2026-10-17-full-audit/METHOD.md`. The items behind them are matched here by subject.
