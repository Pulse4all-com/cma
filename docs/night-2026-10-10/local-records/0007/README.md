# Local run of migration 0007 (intake core), 10 October 2026

Claude Code's local run for brief B1, not a release record: `records/0007-dev-*` and `records/0007-prod-*` come from Martin's real runs.

**Server:** PostgreSQL 18.4 (the `@embedded-postgres/linux-x64` 18.4.0 binaries from npm; the PostgreSQL apt repository was not reachable from the session). It ran in a fresh database `cma` with the roles of `00_roles.sql`, scripts as the login `martin@pulse4all.com` (not a superuser), `00` as `postgres`.

**Order:** `00` to `31` in README order with the seed reruns, `02` before `14`, `02` and `03` before `22`. Then `32` twice (it is rerunnable), `33` normal and provoked, then every earlier verify again.

| File | What | Result |
|---|---|---|
| `32_intake_core-first-run.txt`, `32_intake_core-rerun.txt` | the migration, first run and rerun | both clean (`ON_ERROR_STOP=1`); the rerun records nothing new (`INSERT 0 0`) |
| `33_verify_intake_core.txt` | blocks A to F | `PASS` for `pulse4all-invest` and `pulse4all-subscriptions` |
| `33_verify_intake_core-provoked.txt` | the same with `verify.provoke` true, `ON_ERROR_STOP=0` | 6 FAIL lines (one per block: A1, B1, C1, D1, E1, F1), `PROVOKED, NOT A PASS` twice |
| `*-after-0007.txt` | `04` to `31` rerun after 0007 | unchanged against the same verifies on a second database at 0006 (ids and times masked): `12`, `16`, `18`, `20`, `22`, `25`, `27`, `29`, `31` identical. `04`, `07`, `10` and `14` differ only in catalog listings that now include the eleven new tables, their policies, the 0007 migration row and the eight new settings. `04`, `07` and `12` end blocks in their expected errors (3, 7 and 1), the same messages as at 0006 |

**Mutation check (not kept as files):** twelve deliberate breakages of 0007, each applied inside a transaction that was rolled back, and each one stopped `33` in the block meant to catch it. The breakages were: holidays ignored, no alias lookup, kept values not filtered, the association stale guard off, forget keeping the hash, any external id system allowed, a delete grant on `crm_call`, RLS off on `sync_run`, the call stale guard off, the settings key check off, business time without daylight saving, and ref slots ignored.
