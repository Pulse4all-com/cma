# Flash in dev, 2 and 3 November 2026 (addition 0008zn, phase 16.1 and 16.2)

Phase 16.1 and 16.2 of `docs/ingest/PROD_RUNBOOK.md` (briefs B21a and B21b, addition 0008zn, `Pulse4all-com/cma#213`), run
by Martin in p4a-cma-dev (`cma-dev-pg`, a shared-core db-g1-small) on 2 and 3 November 2026. Written down by Claude Code
at Martin's request from his reports of the runs (3 November 2026); the values below are his. Counts, dates and times
only, as reported: no key, no secret, no customer data.

## (a) The migration

- `122_flash.sql` applied on 2 November 2026, about 18:18 UTC.

## (b) The first attempts at `123`, 3 November 2026

- In Cloud SQL Studio, `123` stopped at Studio's 300-second limit.
- Through the Auth Proxy with psql, its block C (speed at a generated volume) ran for over an hour on the shared core
  until the connection was lost. Nothing stayed behind: dev held its 2 tenants and the additions 0008zm and 0008zn as
  before.
- With `verify.volume` forced to `false`: 38 ok, 1 FAIL, 4 skip, in 5.6 s. B3's only difference from its expected text
  was row order: dev's collation sorts `renewal/GB/renewed` before `renewal/GB/renew_failed`, where a C collation sorts
  them the other way; the values were identical.
- What followed (Decision log, 3 Nov 2026): `123` compares text in collate "C" and runs block C in local databases
  only, with `verify.volume` off by default; Flash's speed on real data is `124_time_flash.sql`'s, in prod.

## (c) `123` and `124`, 3 November 2026

- `123_verify_flash.sql`: `0008zn verified | 123_verify_flash: 39 ok, 0 FAIL, 4 skip` (block C off).
- `123` provoked: `PROVOKED, NOT A PASS | 123_verify_flash: 0 ok, 39 FAIL, 4 skip`.
- `124_time_flash.sql`: `PASS | 124_time_flash: 23 ok, 0 FAIL, 1 skip`; the skip is `pulse4all-invest` (no person with
  `reports.view`); worst 340.3 ms (the customers overview). In dev for information only: the shared core.

## (d) The reruns after `122`

- `121_verify_lead_cohorts.sql`: 22 PASS.
- `113_verify_assets.sql`: 25 ok.
- `95_verify_attempts_for_sales.sql`: 36 PASS.
- `41_verify_lead_metrics.sql`: PASS for both tenants.
- `119_verify_subscriptions.sql`: 23 PASS.
- `105_verify_reviews.sql`: 27 PASS.
- `81_verify_follow_up_snapshot.sql`: 19 PASS.

## (e) The data map

- The schema snapshot from dev after 0008zn, committed by Martin to #213's branch (`c3dfab4`): 102 tables, 158 views.

## (f) The second round, 3 November 2026 (16.1 again and 16.3)

From Martin's report of 3 November 2026, after #213's change of that day (the NetSuite requirements empty for Pulse4all,
seed `02`); the values below are his.

- `122_flash.sql` again: 6.3 s; the addition's insert 0 rows (0008zn already recorded).
- `123_verify_flash.sql`: `39 ok, 0 FAIL, 4 skip`. Provoked: `0 ok, 39 FAIL, 4 skip`.
- `02_seed_pulse4all.sql`: exit 0. The nine settings rows as expected; `assets.required_refs` and
  `commerce.required_contact_refs` both empty.
- `124_time_flash.sql`, through psql: `PASS`, 23 ok, 1 skip; worst 225.5 ms (the customers overview).
- The reruns: `121` 22, `113` 25, `95` 36, `41` PASS for both tenants, `119` 23, `105` 27, `81` 19.
- 16.3, the ingest:
  - `cma-ingest` on `dea123f` deployed: revision `cma-ingest-00016-h2q`, health ok.
  - The jobs on `dea123f`. Four were created in dev for the first time: `ingest-poll-reviews`, `ingest-poll-assets`
    (paused), `ingest-poll-subscriptions` (paused) and `ingest-import-legacy-calls`. The bucket
    `gs://cma-import-p4a-cma-dev` does not exist; it is not needed.
  - HubSpot, the app CMA ingest dev: the `contact_netsuite_id` property change active; contact subscriptions 13 of 13.
  - Linked contacts: `linked` 0, `linked_not_held` 0.
  - The backfill `ingest-backfill-g2t97` completed. Its log line was not captured.

## (g) `124` in Studio, on `6658e5d`, 3 November 2026

From Martin's report of 3 November 2026; the values are his. `124_time_flash.sql` in Cloud SQL Studio on dev's
PostgreSQL 18, on #213's `6658e5d` (the script that runs its reads in a read-only subtransaction rolled back): `PASS`,
23 ok, 1 skip; worst 190.4 ms.
