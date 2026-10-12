# Local run of addition 0008e (sources, markets, alert rules, linked accounts), night of 12 to 13 October 2026

Claude Code's local run, not a release record: `records/0008e-dev-*` and `records/0008e-prod-*` come from Martin's real runs.

**Server:** PostgreSQL 18.4 (the `@embedded-postgres/linux-x64` 18.4.0 binaries from npm; the PostgreSQL apt repository was not reachable from the session, as on 10 October). Fresh databases with the roles of `00_roles.sql`, every script as the login `martin@pulse4all.com` (not a superuser), `00` as `postgres`.

**Order:** `00` to `53` in README order with the seed reruns (`order-of-the-fresh-database.txt`), so `52` and `53` ran on a database built exactly as dev was. A second database built to `51` gave the comparison.

| File | What | Result |
|---|---|---|
| `52_sources_configuration-first-run.txt`, `52_sources_configuration-rerun.txt` | the migration, first run and rerun | both clean (`ON_ERROR_STOP=1`); the rerun records nothing new (`INSERT 0 0`) |
| `53_verify_sources_configuration.txt` | blocks A (4 checks) and B (9 checks) | `13 PASS, 0 FAIL`, verdict `PASS` |
| `53_verify_sources_configuration-provoked.txt` | the same with `verify.provoke` true | A1, B1 and B8 `FAIL`, verdict `PROVOKED, NOT A PASS` |
| `53_verify_sources_configuration-refused-not-dev.txt` | a copy of the database with `agent.two@example.com` inactive | `REFUSED: the connected database is not dev`; every block stops at once and the verdict says `REFUSED: not dev`, also when the client carries on after the error |
| `*-after-0008e.txt` | `04` to `51` on the database at `53`, each compared with the same verify on the database at `51` (ids, times and dates masked) | identical, except `07` and `10`, which list the migration table and now show the `0008e` row; `04`, `07` and `12` end blocks in their expected errors (3, 7 and 1), the same messages as at `51` |
| `mutations.txt` | twelve deliberate breakages of `52`, each on a copy of the database (`create database … template`), with `53` run against the copy | every one caught: the kind check off (B1), `sources()` without its permission (B2), the oldest instead of the newest sample id (B3), markets without aliases and office hours with another separator (B4), rules without their alert count (B5), linked-account systems without held ids (B6), linked accounts without the directory's scope (B7), `set_user_external_id` back to `users.manage_all` (caught in block B, where the manager's first link raises) and without the People rule (B8), a reader executing `sources()` (A3), the reader view without the kind (A2) |
