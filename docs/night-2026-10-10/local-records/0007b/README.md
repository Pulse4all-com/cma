# Local run of migration 0007b (commerce), 10 October 2026

Claude Code's local run for brief B3, not a release record: `records/0007b-dev-*` and `records/0007b-prod-*` come from Martin's real runs.

**Server:** PostgreSQL 18.4 (the `@embedded-postgres/linux-x64` 18.4.0 binaries from npm, as for 0007). Two fresh databases with the roles of `00_roles.sql`, scripts as the login `martin@pulse4all.com` (not a superuser), `00` as `postgres`.

**Order:** on both databases `00` to `33` in README order with the seed reruns (`02` before `14`, `02` and `03` before `22`, `27` after `30`), as for 0007. On the first database, `36` twice (it is rerunnable), `37` normal and provoked, then every earlier verify again; on the second, the same earlier verifies without 0007b, for comparison. 0007a (`34`, `35`) is not in the run: 0007b depends on 0007 only.

| File | What | Result |
|---|---|---|
| `36_commerce-first-run.txt`, `36_commerce-rerun.txt` | the migration, first run and rerun | both clean (`ON_ERROR_STOP=1`); the rerun records nothing new (`INSERT 0 0`) |
| `37_verify_commerce.txt` | blocks A to E | `PASS` for `pulse4all-invest` and `pulse4all-subscriptions` |
| `37_verify_commerce-provoked.txt` | the same with `verify.provoke` true, `ON_ERROR_STOP=0` | 5 FAIL lines (one per block: A1, B1, C1, D1, E1), `PROVOKED, NOT A PASS` twice |
| `*-after-0007b.txt` | `04` to `33` rerun after 0007b | unchanged against the same verifies on the second database at 0007 (ids and times masked): `12`, `14`, `16`, `18`, `20`, `22`, `25`, `27`, `29`, `31`, `33` identical. `04`, `07` and `10` differ only in catalog listings that now include the four new tables, their policies and the 0007b migration row. `04`, `07` and `12` end blocks in their expected errors (3, 7 and 1), the same messages as at 0007 |

**Mutation check (not kept as files):** nineteen deliberate breakages of 0007b, each applied inside a transaction that was rolled back, and each one stopped `37` in the block meant to catch it: the customer stale guard off (C2), a deletion keeping the locale (C3), a deleted customer coming back with a read at its deletion time (C4), lines never removed (D2), app ids ignored (D5), no count read as first (D1), the test flag dropped (D7), the store function without its permission check (E1), the store missing from `connection_config` (B4), the order stale guard off (D3), an order deletion keeping its page (D8), source names compared with case (D4), UTM not filtered (D1), tags not de-duplicated (D1), `raw` in the order view (A6), a delete grant on orders (A3), RLS off on customers (A2), the handle not unique (A4), the settings trigger dropped (A7).
