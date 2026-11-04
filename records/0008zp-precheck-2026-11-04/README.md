# Split shifts' pre-check of stored days, 4 November 2026 (addition 0008zp)

A read-only query of the stored workdays against the shape that addition 0008zp's `cma.refresh_workday` enforces
(`db/126_workday_sessions.sql`, `Pulse4all-com/cma#217`), run by Martin in Cloud SQL Studio on p4a-cma-dev (`cma-dev-pg`)
and p4a-cma-prod (`cma-prod-pg`) on 4 November 2026, before 126 ran on either. Written down by Claude Code at Martin's
request from his report of the runs (4 November 2026); the values below are his. Times UTC, "about" as he gave them.
Tenant slugs and counts only, as reported: no key, no secret, no personal or customer data.

## Why

`126` replaces `cma.refresh_workday`, which every write to a day calls. It accepts a day whose effective events, in the
order the time views take them (`occurred_at`, `recorded_at`, `id`), read start, (status)*, end, start, (status)*, end,
...: the first event a start; a later start directly after an end and strictly after it; no status directly after an
end; no two ends in a row. That shape is stricter than 0003's at one point (build choice B1): two events at one instant
are taken in the views' order, so a status recorded after an end at the end's own instant, or a status or end recorded
before the start at the start's own instant, is refused now. `126` does not validate the days already stored; a day
that broke the shape would surface only at its next write (a correction, or the sweep), as `CMA04`. The query counts
such days per tenant before 126 runs, so none is a surprise.

## The query (Cloud SQL Studio, as Martin ran it)

It reads `cma.time_event_effective_all` (every tenant), not `cma.time_event_effective`: that face filters on
`cma.current_tenant_id()`, which Studio does not set, so it reads empty there.

```sql
set role cma_owner;
with e as (select tenant_id, workday_id, kind, occurred_at, lag(kind) over w as prev_kind, lag(occurred_at) over w as prev_at, row_number() over w as n from cma.time_event_effective_all window w as (partition by tenant_id, workday_id order by occurred_at, recorded_at, id))
select t.slug, count(distinct e.workday_id) as days_refused_by_0008zp, min(e.occurred_at)::date as first_day, max(e.occurred_at)::date as last_day from e join cma.tenant t on t.id = e.tenant_id
where (e.n = 1 and e.kind <> 'start') or (e.kind = 'start' and e.n > 1 and (e.prev_kind <> 'end' or e.occurred_at <= e.prev_at)) or (e.kind = 'status' and e.prev_kind = 'end') or (e.kind = 'end' and e.prev_kind = 'end')
group by t.slug order by 1;
select t.slug, count(distinct e.workday_id) as days_with_events from cma.time_event_effective_all e join cma.tenant t on t.id = e.tenant_id group by t.slug order by 1;
reset role;
```

Result 1 lists, per tenant, the days the new shape refuses; Result 2 the days with at least one effective event, the
population it checked.

## (a) Dev, `cma-dev-pg`, about 13:10

- Result 1: no rows (no day refused).
- Result 2: `pulse4all-subscriptions` 98.

## (b) Prod, `cma-prod-pg`, about 13:12

- Result 1: no rows (no day refused).
- Result 2: `pulse4all-subscriptions` 1633.

## Outcome

No stored day breaks the shape of 0008zp's `cma.refresh_workday`, B1 included: dev 98 days, prod 1,633 days, 0
refused. Martin confirmed the night defaults N1 to N7 and the build choices B1 to B7 as built the same day (Decision
log, 4 November 2026, #217).
