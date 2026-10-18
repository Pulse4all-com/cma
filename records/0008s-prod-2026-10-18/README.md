# Addition 0008s in prod, 18 October 2026

Addition 0008s, the follow-up snapshot (`a6db116`, "Follow-up snapshot (addition 0008s; IT audit of
17 October 2026, 5.6 continued): figures once a minute per tenant, one data call for the page",
`Pulse4all-com/cma#166`), steps 5 and 7 of `docs/RUNBOOK.md` section 7a and a measurement of the Live board,
run by Martin on 18 October 2026 in p4a-cma-prod (cma-prod-pg, the job and `cma-web`), after dev
(`records/0008s-dev-2026-10-18`). Written down by Claude Code on 18 October 2026 at Martin's request from his
report and the outputs he pushed to this folder; the values are his. Ids, counts, dates and times only: no key,
no secret and no personal data.

## Database (step 5)

| Script | File | Result |
|---|---|---|
| `80_follow_up_snapshot.sql` | `80.txt` | ends `INSERT 0 1`, `COMMIT`, `RESET`; line for line the same as dev's `80.txt` |

`81_verify_follow_up_snapshot.sql`, 0008s's verify, is dev only by its header: it refuses a database that does
not hold the dev seed's active test person, which prod never holds. So are `73` and `79`, which dev ran again
after `80`. Their runs are in `records/0008s-dev-2026-10-18`; this folder has none of them.

## The job (step 7) and its effect, from Martin's report

- The job `cma-refresh-follow-up` on the image `web:a6db116`, every minute; created on 18 October 2026 at
  09:17:59 UTC in dev and 09:18:39 UTC in prod. The prod build of `a6db116` and its revision are in
  `records/deploys-2026-10-18`.
- Subscriptions: 3,463 rows, 1.6 to 2.2 s per refresh.
- Database time per refresh: 8 s before, 0.1 s after.
- `/reports/follow-up`: 5.7 s before, 0.2 s after. The before lines are
  `records/speed-dev-2026-10-18/prod-follow-up-baseline.txt` (median 5708.4 ms total, 8180 ms database).
- No audit trigger on the snapshot tables (checked).

## The Live board after 0008s

Measured in prod on revision `cma-web-00075-2hj` (`a6db116`): the Live board open about 09:27 to 09:35 UTC,
its request lines read from Cloud Logging (`docs/RUNBOOK.md` section 6) into `live-after.txt` and
`live-after-summary.txt`.

| File | What it holds |
|---|---|
| `live-after-summary.txt` | `/live/board  n=46  total p50=157.7 p95=328.3  db p50=262.2` |
| `live-after.txt` | 42 request lines of `/live/board`, 2026-10-18 09:27:46 to 09:34:29 UTC, every one status `200`, severity `INFO`, RSC `True`, 8 transactions and 37 statements; total 140.7 to 473.9 ms |

`live-after.txt` was read with `--freshness=15m`. The summary was made later, with the same filter and
`--freshness=1h`: Martin's command is `gcloud logging read` with that filter and `--format=json`, piped into a
`jq` that groups the lines by route and takes p50 and p95 by sorted index. So it counts 46 polls, the file's 42
and 4 after 09:34:29 UTC. Martin's report: every poll 200, no `WARNING`; before 0008s a poll took 1.5 to
2.1 s. The first polls, 09:27:46 to 09:28:26 UTC (233.7 to
473.9 ms total in the file), are the warm-up after opening the page.

For readers: `DB_MS` is higher than `TOTAL_MS` because the board runs its reads as 8 transactions in parallel
(`TX` 8, `RT` 37 per poll) and `dbMs` sums their statement time; it is not wall time.

## Not in the report

- The time of `80` in prod and of the merge.
- The job's first executions (step 7) and its lines per tenant (step 8) beyond the Subscriptions figures,
  among them the invest tenant's.
- How the absence of the audit trigger was checked.
- Step 9's System health card for the refresh and Reports → Follow-up's "Updated …" line.
- The request lines behind 0.1 s, 0.2 s and the Live board's 1.5 to 2.1 s before 0008s.
- The four polls after 09:34:29 UTC line by line: the summary counts them, and no file in this folder holds
  them.
