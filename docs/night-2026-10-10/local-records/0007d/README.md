# Local run of migration 0007d (lead metrics and data quality), 10 October 2026

This is Claude Code's local run for brief B4. It is not a release record: `records/0007d-dev-*` and `records/0007d-prod-*` come from Martin's real runs.

**Server:** PostgreSQL 18.4, from the `@embedded-postgres/linux-x64` 18.4.0-beta.17 binaries on npm, as for 0007. A fresh database `cma` with the roles of `00_roles.sql`; scripts ran as the login `martin@pulse4all.com` (not a superuser), only `00` as `postgres`.

**Order:** `00`, the migrations `01` to `28`, the seeds `02` and `03`, the verifies `04` to `29` with the dev seeds `06` and `24` before the verifies that use them, then `30`, `27`, `29`, `31`, `32` to `37`, `42` and `43`: every verify passing, `04`, `07` and `12` with their expected errors. That database was copied twice. On the first copy: `40` twice (it is rerunnable), `41` normal and provoked, then every earlier verify. On the second copy, without 0007d: the same earlier verifies, for comparison.

| File | What | Result |
|---|---|---|
| `40_lead_metrics-first-run.txt`, `40_lead_metrics-rerun.txt` | the migration, first run and rerun | both clean (`ON_ERROR_STOP=1`); the rerun records nothing new (`INSERT 0 0`) |
| `41_verify_lead_metrics.txt` | blocks A to F | `PASS` for `pulse4all-invest` and `pulse4all-subscriptions` |
| `41_verify_lead_metrics-provoked.txt` | the same with `verify.provoke` true, `ON_ERROR_STOP=0` | 6 FAIL lines, one per block (A1, B1, C1, D1, E1, F1); `PROVOKED, NOT A PASS` twice |
| `*-after-0007d.txt` | `04` to `43` rerun after 0007d | compared with the same verifies on the copy without 0007d, ids and times masked. `12`, `14`, `16`, `18`, `20`, `22`, `25`, `27`, `29`, `31`, `33`, `35`, `37` and `43` are identical. `04` and `07` differ only in the listing of `cma_read` views (the three new views and the fifteen `dq_` views), `07` and `10` in the 0007d migration row. `04`, `07` and `12` end blocks in their expected errors (3, 7 and 1), with the same messages as without 0007d |

**Mutation check (not kept as files):** twenty-four deliberate breakages of `40`. Each was applied to a fresh copy without 0007d as a changed `40`, and each stopped `41` in the block meant to catch it:

| Breakage | Stopped at |
|---|---|
| the pre-window ignored | B1 |
| the linked telephony start ignored | B1 |
| removed associations still counting | B1 |
| calls on the deal itself ignored | B1 |
| holidays ignored in business time | B1 |
| business time placed in UTC instead of the market's zone | B1 |
| the aliases not read again (a deal's market as written) | B1 |
| no fallback to the contact's country | B1 (and D1) |
| pipelines that are not lead pipelines counted | B1 (and C2, F4) |
| an inbound call measured as the first call | B1 |
| a deal not yet called marked outside the target too early | B1 |
| no fallback to the deal owner's person | B2 |
| the 92-day bound lifted | B13 |
| test orders counted for lead to order | C1 |
| cancelled orders counted | C1 |
| `lead_to_order.max_days` ignored | C1 |
| only ref slot 1 read | C1 |
| calls on uncounted lines counted | D1 |
| calls with an uncounted tag counted as tagged | D1 |
| the Ingest user's refresh counted as a review of a pipeline | E1 |
| telephony calls counted as unlinked before 24 hours | E1 |
| the speed-to-lead read without its permission check | F1 |
| a readers' function without `reader_sees` | F4 |
| a readers' function executable by everyone | A3 |
