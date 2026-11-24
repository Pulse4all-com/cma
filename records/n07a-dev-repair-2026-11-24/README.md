# N07a's addition back in dev, after the 0009zr collision, 24 November 2026

Two open pull requests claimed addition 0009zr and the numbers 236/237:
- `Pulse4all-com/cma#319` (N07a, the minute jobs off the vCPU, `236_jobs_off_the_vcpu.sql`);
- `Pulse4all-com/cma#318` (B40b, the speed to lead cockpit, `236_speed_to_lead_cockpit.sql`).

On the evening of 24 November 2026 Martin ran #318's 236 in dev (cma-dev-pg) after N07a's. Prod was not touched (it was
at 0009zq). Martin decided that N07a merges first, and that #318 is rebased on main after it and renumbered after N07a's
stack (0009zu, 242/243).

## What went wrong in dev

#318's 236 changed `cma.speed_to_lead_row`: it dropped `first_call_*` and appended five columns. It also re-created
`cma.speed_to_lead_of` and `cma.open_leads_of` without N07a's `cma.speed_to_lead_rows_of`.

The gate itself, `cma.job_gate_of` and `cma.web_busy`, was not touched: the jobs call it, it is not inside those two
functions. But N07a's `cma.speed_to_lead_rows_of` still returns the row in 234's shape, so in dev:
- it errors when called;
- N07a's 236 cannot be rerun (it stops at its line 893, "return type mismatch … column 13", and rolls back);
- N07a's 237 cannot copy 234's definition.

## The repair, `dev_repair_n07a.sql` (dev only, one transaction)

**It drops what #318 added:**
- `cma.speed_to_lead_page`, `cma.speed_to_lead_deals_of`, `cma.speed_to_lead_figures` and `cma.speed_to_lead_view_check`;
- `cma.speed_to_lead_deals_from`, `cma.speed_to_lead_figures_from` and `cma.speed_to_lead_groups_from`;
- the types `cma.speed_to_lead_deal_row` and `cma.speed_to_lead_figures_row`;
- #318's `cma.speed_to_lead_summary`, which has more columns than 234's;
- the view `cma_read.speed_to_lead`.

**It restores the row type** `cma.speed_to_lead_row` to 234's columns in 234's order. Every column after `status` is
dropped and added again; the type itself stays, so nothing defined by older scripts is dropped.

**The two reruns that follow restore everything else.** `234_speed_to_lead_one.sql`, rerun from main, makes again 234's
summary, its view and `cma_read.speed_to_lead_rows()`. N07a's 236, rerun from #319's branch, makes again its
`cma.speed_to_lead_rows_of`, `cma.speed_to_lead_of` and `cma.open_leads_of`.

**It leaves these in place.** N07a and 234 read none of them, and #318 makes them again:
- the row 0009zr in `cma.schema_migration`;
- the settings `speed_to_lead.goal_within_target_pct`, `speed_to_lead.goal_before_cutoff_pct` and
  `speed_to_lead.stale_business_days`, with any tenant values for them;
- the extra range checks for those settings in `cma.check_tenant_setting()`;
- `jit = off` and `plan_cache_mode = force_custom_plan` on `cma.speed_to_lead_rows(date, date)`.

Between the repair and N07a's rerun, speed to lead's reads fail in dev for those minutes. A dev web running #318's branch
loses the cockpit page until #318's 242 runs; main's web reads 234's shape and works.

## Tested before this was committed (Claude Code, local, 24 November 2026)

**The test databases.** This is not a dev run: it ran on a local PostgreSQL 16 with every db/ script through 235 and the
dev seed.

- Database A had N07a's 236 alone.
- Database B had N07a's 236, then #318's 236, which is dev's state.

**On B before the repair:**
- N07a's 236 rerun stops at line 893 and rolls back.
- N07a's 237 stops with "return type mismatch".

**On B, after the repair, 234 and N07a's 236:**
- Every function, view, type, setting and migration row in `cma` and `cma_read` is the same as in A, apart from the four
  kept items listed above.
- N07a's 237 gives the same rows as on A: 9 OK, with F2 and F3 FAIL ("whole , scope 0"); provoked, 0 OK, 11 FAIL. Its
  speed to lead checks, L1 and L2, are OK.
- F2 and F3 fail on A too. The local database holds no renewal outcomes (a forced refresh stores 0), and the refresh after
  the test events answers "unchanged". N07a's own local run, with subscription data, had them OK (11 OK).
- These readers give the same verdict on A and on B (41 shows only its pass row):

  | Reader | Verdict |
  |---|---|
  | 211, 213, 217, 219, 221, 223, 225 | PASS |
  | 41 | PASS |
  | 73, 75, 81, 95, 99 | PASS |
  | 151, 155 | OK |
  | 179 | 0009o verified |
  | 191 (N07a's) | 0009u verified |
  | 235 (N07a's) | PASS 0009zq |

**The dev run.** Martin's results go in this folder from his own run (`dev-run.txt`), checked with
`node tools/check-records.mjs records/n07a-dev-repair-2026-11-24` before they are committed.
