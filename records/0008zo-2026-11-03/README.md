# Flash watch cadence in dev and prod, 3 November 2026 (addition 0008zo)

Addition 0008zo (`db/125_flash_watch_cadence.sql`, `Pulse4all-com/cma#216`), run by Martin in p4a-cma-dev
(`cma-dev-pg`) and p4a-cma-prod (`cma-prod-pg`) on 3 November 2026, from #216's branch `claude/cool-darwin-cpcj8b`,
with `123_verify_flash.sql` from the same branch. Written down by Claude Code at Martin's request from his report of
the runs (3 November 2026); the values below are his. Times UTC, "about" where he gave them so. Counts, times and
milliseconds only, as reported: no key, no secret, no customer data.

## (a) Dev

- `125_flash_watch_cadence.sql` in Cloud SQL Studio, about 16:33: 84.7 ms, no error.
- `123_verify_flash.sql` in Studio: 40 ok, 0 FAIL, 4 skip (B28 ok).
- `123` provoked: 0 ok, 40 FAIL, 4 skip.

## (b) Prod

- `125_flash_watch_cadence.sql` in Studio, about 16:43: 32.7 ms, no error.
- `123_verify_flash.sql` in Studio: 40 ok, 0 FAIL, 4 skip (B28 ok), in 7.0 s.

## (c) The false findings of 0008zn's first take: not observed yet

The 15 false `source_stale` findings of the first prod take (business date 2026-11-02, run
`cma-snapshot-flash-rk8fh`; `records/0008zn-prod-2026-11-03`, (i)) are to resolve at the next take: business date
2026-11-03, taken by the snapshot job's run at 00:20 UTC on 4 November (01:20 in Amsterdam). Martin checks it on
4 November (#216, step 5). This record holds no result of that take yet; it is added as its own section once he
reports it.
