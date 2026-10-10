# Local run of migration 0007a (telephony), 10 October 2026

Claude Code's local run for brief B2. This is not a release record: `records/0007a-dev-*` and `records/0007a-prod-*` come from Martin's real runs.

**Server:** PostgreSQL 18.4, from the `@embedded-postgres/linux-x64` 18.4.0-beta.17 binaries on npm (the same server build as B1's run). It ran in a fresh database `cma` with the roles of `00_roles.sql`. The scripts ran as the login `martin@pulse4all.com`, which is not a superuser; only `00` ran as `postgres`.

**Order:** `00`, then the migrations `01` to `32` in README order, then the seeds `02`, `03`, `06` and `24`. After that, `34` ran twice (it is rerunnable), `35` ran normal and provoked, and every earlier verify ran again. A second database `base`, built the same way but stopped at 0007, ran the same earlier verifies so the outputs could be compared.

| File | What | Result |
|---|---|---|
| `34_telephony-first-run.txt`, `34_telephony-rerun.txt` | the migration, first run and rerun | both clean (`ON_ERROR_STOP=1`); the rerun records nothing new (`INSERT 0 0`) |
| `35_verify_telephony.txt` | blocks A to F | `PASS` for `pulse4all-invest` and `pulse4all-subscriptions`, no errors |
| `35_verify_telephony-provoked.txt` | the same with `verify.provoke` true, `ON_ERROR_STOP=0` | 6 FAIL lines, one per block (A1, B1, C1, D1, E1, F1), and `PROVOKED, NOT A PASS` twice |
| `*-after-0007a.txt` | `04` to `33` rerun after 0007a | compared with the same verifies on `base` at 0007, ids and times masked. `12`, `14`, `16`, `18`, `20`, `22`, `25`, `27`, `29`, `31` and `33` are identical. `04`, `07` and `10` differ only in catalog listings that now include the five new tables, their policies and the 0007a migration row. `04`, `07` and `12` end blocks in their expected errors (3, 7 and 1), with the same messages as at 0007 |

**Mutation check (not kept as files):** 19 deliberate breakages of 0007a, each applied to a copy of the database (`create database … template cma`, then the mutated `34`), with `35` run against the copy. 18 stopped `35` in the block meant to catch them:

- B: the stale guard off; the raw payload unfiltered; a deletion keeping the hash
- C: tags never closed; no new row on re-tagging; the tag catalog refresh overwriting `is_counted`; the line refresh dropping the market
- D: the link ignoring the direction; a window of 300 s instead of 120 s; not nearest first; re-linking a retired pair; ignoring the start time; `unlink_call` without its permission check
- E: forget keeping the telephony hash; forget clearing only current links
- A and F: a delete grant on `call_link`; RLS off on `telephony_tag`; a reporting view showing a hash

The one breakage `35` cannot see is `link_calls` ignoring `source_deleted_at` on the CRM call. 0007's `ingest_upsert_calls` already clears the hash when a call is deleted, so a deleted call has no hash to match, and the guard stays as a second line.
