# Local run of migration 0007c (outbox and CRM contact write-back), 10 October 2026

This is Claude Code's local run for brief B13. It is not a release record: `records/0007c-dev-*` and `records/0007c-prod-*` come from Martin's real runs.

**Server:** PostgreSQL 18.4, from the `@embedded-postgres/linux-x64` 18.4.0-beta.17 binaries on npm, as for 0007 to 0008. The database was a fresh `cma` with the roles of `00_roles.sql`. Scripts ran as the login `martin@pulse4all.com` (not a superuser); only `00` ran as `postgres`.

**Order:** `00` to `37`, `42` and `43` in README order, with the seed reruns (`02` after `05`, `13`, `17` and `21`; `03` after `17` and `21`; `27` after `30`), so the database stood where dev and prod stand (0008 included). That database was copied twice. On the first copy: `38` twice (it is rerunnable), `39` normal and provoked, then every earlier verify. On the second copy, without 0007c: the same earlier verifies, for comparison.

| File | What | Result |
|---|---|---|
| `38_outbox-first-run.txt`, `38_outbox-rerun.txt` | the migration, first run and rerun | both clean (`ON_ERROR_STOP=1`); the rerun records no new migration row (`INSERT 0 0`) |
| `39_verify_outbox.txt` | blocks A to F | `PASS` for `pulse4all-invest` and `pulse4all-subscriptions` |
| `39_verify_outbox-provoked.txt` | the same with `verify.provoke` true, `ON_ERROR_STOP=0` | 6 FAIL lines, one per block (A1, B1, C1, D1, E1, F1); `PROVOKED, NOT A PASS` twice |
| `*-after-0007c.txt` | `04` to `37` and `43` rerun after 0007c | compared against the same verifies on the copy without 0007c, with ids and times masked. `12`, `16`, `18`, `20`, `22`, `25`, `27`, `29`, `31`, `33`, `35`, `37` and `43` are identical. `04`, `07` and `10` differ only in catalog listings, which now include the two new tables, their policies and the 0007c migration row; `14` only in the settings list, which now includes `outbox.max_attempts = 8 (default)`. `04`, `07` and `12` end blocks in their expected errors (3, 7 and 1), with the same messages as without 0007c |
| `two-sessions/` | the two-session claim test: the scripts and their output `two_sessions.txt` | see below |

**Two sessions (`two-sessions/two_sessions.txt`).** A Studio session is one session, so `39` proves the claim's `FOR UPDATE SKIP LOCKED` from the function's source and the no-double-claim rule in one session; the real concurrency was run here with two `psql` sessions on a copy with 0007c (a throwaway tenant, committed in that local copy only). Every claim runs with a 2-second statement timeout, so a claim that waited on a lock would fail.
- Case 1: worker A claims 2 of 4 pending actions and holds its transaction open 4 seconds; worker B, one second later, claims the other 2 in 0.01 s. After both commit, each action is in flight at attempt 1: no double claim, no waiting.
- Case 2: worker C claims the 2 new pending actions and holds them; worker D, one second later, claims nothing in 0.01 s.
- Case 3: two ingest calls enqueue different values for one contact at the same time; the second waits for the first (the per-contact lock, 2.0 s) and supersedes it, leaving one pending action.

**Mutation check (not kept as files):** 28 deliberate breakages of 0007c. Each was applied to a fresh copy without 0007c as a changed `38`, and each stopped `39`:

| Breakage | Stopped at |
|---|---|
| the claim without `SKIP LOCKED` | A8 |
| disabled fields kept | C1 |
| unknown fields accepted | C2 |
| no dedupe | C4 |
| no supersede | C5 |
| the totals kept without the customer id | C3 |
| no retirement of an earlier action's key | C7 (the unique key refuses the insert) |
| no backoff | D1 |
| a dead claim never returns | D4 |
| a claim while the same contact is in flight | D5 |
| overtaken claims not superseded | D5 |
| failures never park | D7 |
| an expired claim at the maximum not parked | D8 |
| finish touches any state | D2 |
| no state trigger | A8 |
| final states may change | D9 |
| a retry without the person | E1 |
| a retry despite a newer action | E3 |
| resolve in any state | E3 |
| the status without a permission check | E5 |
| delete granted to the application | A3 |
| whole-row update granted | A3 |
| the dedupe hash in the view | A6 |
| the slot mode for any field | B3 |
| configuration without its permission | F1 |
| enqueue without its permission | F1 |
| the write-back fields missing from `connection_config` | B5 |
| `outbox.max_attempts` ignored | D7 |
