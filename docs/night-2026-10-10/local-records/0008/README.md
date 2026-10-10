# Local run of migration 0008 (messaging core and record alerts), 10 October 2026

This is Claude Code's local run for brief B5. It is not a release record: `records/0008-dev-*` and `records/0008-prod-*` come from Martin's real runs.

**Server:** PostgreSQL 18.4, from the `@embedded-postgres/linux-x64` 18.4.0-beta.17 binaries on npm, as for 0007. The database was a fresh `cma` with the roles of `00_roles.sql`. Scripts ran as the login `martin@pulse4all.com` (not a superuser); only `00` ran as `postgres`.

**Order:** `00` to `32` in README order, with the seed reruns (`02` after `05`, `13`, `17` and `21`; `03` after `17` and `21`). That database was copied twice at 0007. On the first copy: `42` twice (it is rerunnable), `43` normal and provoked, then every earlier verify. On the second copy, still at 0007: the same earlier verifies, for comparison.

| File | What | Result |
|---|---|---|
| `42_messaging-first-run.txt`, `42_messaging-rerun.txt` | the migration, first run and rerun | both clean (`ON_ERROR_STOP=1`); the rerun records nothing new (`INSERT 0 0`) |
| `43_verify_messaging.txt` | blocks A to E | `PASS` for `pulse4all-invest` and `pulse4all-subscriptions` |
| `43_verify_messaging-provoked.txt` | the same with `verify.provoke` true, `ON_ERROR_STOP=0` | 5 FAIL lines, one per block (A1, B1, C1, D1, E1); `PROVOKED, NOT A PASS` twice |
| `*-after-0008.txt` | `04` to `33` rerun after 0008 | compared against the same verifies on the copy at 0007, with ids and times masked. `12`, `14`, `16`, `18`, `20`, `22`, `25`, `27`, `29`, `31` and `33` are identical. `04`, `07` and `10` differ only in catalog listings, which now include the three new tables, their policies and the 0008 migration row. `04`, `07` and `12` end blocks in their expected errors (3, 7 and 1), with the same messages as at 0007 |

**Mutation check (not kept as files):** sixteen deliberate breakages of 0008. Each was applied to a fresh copy at 0007 as a changed `42`, and each stopped `43`:

| Breakage | Stopped at |
|---|---|
| any workday counts as clocked in, ended ones too | B2 |
| the language level ignored | B2 |
| inactive people receive alerts | B2 |
| no fallback when nobody matches | B4 |
| the age limit ignored | B8 |
| pipelines that are not counted alert | B10 |
| an http link template accepted | the table's own `ref_url` check refuses the alert (second guard) |
| a poll delivers other people's copies | C1 |
| expired messages returned | C1 |
| marking read touches other people's rows | C4 |
| acknowledging a message that is not yours | C5 |
| delivery times may change once set | C6 |
| `onlyClockedIn` ignored | D2 |
| team membership history ignored | D2 |
| the stats without a permission check | D9 |
| delete granted to the application | A3 |
