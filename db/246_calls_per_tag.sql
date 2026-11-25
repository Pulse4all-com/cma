-- =============================================================================================
-- 246_calls_per_tag.sql: addition 0009zw, Calls per tag: every call in scope per current Aircall tag, by direction
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 244_auto_close_office_hours.sql
-- (0009zv). Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own IAM login: dev first, then
-- 247_verify_calls_per_tag.sql there (normal, then provoked), then prod in the same order. No function is re-created (the
-- two functions are new), so no earlier verify reads what changed and none needs running again; 131_time_all.sql's two
-- new rows (calls per tag {P}: the page's read, streamed after its first paint; calls api {P}, calls per tag with totals:
-- the API's) are read the next time Martin runs it.
-- No table, view, column or setting changes (the data map is unchanged), no seed need run again, nothing stored needs
-- computing: both functions compute when read.
--
-- Why (Martin, 25 November 2026; Decision log, 25 Nov 2026, "Definitions: Calls per tag"): Reports → Calls' Tags card
-- counts tags over the conversations only (cma.calls_tag_use_of filters on is_conversation), so the tags agents put on
-- outbound calls that never became a conversation (Not Reached, Wrong Number) and on short calls never show, though they
-- are the most used. Calls per tag counts every call in scope per current tag, as Aircall Analytics' tags chart does
-- (docs/definitions.md, Calls per tag).
--
-- What it adds
--   cma.calls_per_tag_of(tenant, from, to, market, line)
--                  per current tag (any tag, counted or not): the calls in scope carrying it, outbound, inbound and in
--                  all; tag_key the connection id ':' the tag ref (as the tag use), the catalog's name (the ref for a tag
--                  not in the catalog), meaning and is_counted (true for a tag not in the catalog, as a new tag joins it).
--                  A call with two tags counts under each. Then one Untagged row (tag_key, tag_name, meaning and
--                  is_counted null): the calls without a current tag, missed inbound calls included, which is
--                  cma.calls_figures_of's untagged. Tags by calls, most first, then name; Untagged last. The calls are
--                  cma.calls_of's with cma.calls_tag_use_of's window (a day on each side) and business-date filter,
--                  without its is_conversation filter, so the scope equals cma.calls_figures_of's calls (247 proves it).
--                  Whole period only: no grouping. One pass over cma.calls_of; jit off, as cma.calls_figures_of (132)
--   cma.calls_per_tag(from, to, market, line, totals)
--                  the application's read: reports.view or performance.team, the range and the filters checked as
--                  cma.calls_tag_use does; the rows of cma.calls_per_tag_of with row_kind 'tag' or 'untagged', then, when
--                  totals is true (the default), one 'total' row: cma.calls_figures_of's calls, inbound and outbound for
--                  the same period and filters (the calls in scope, not the sum of the rows). Reports → Calls passes
--                  false and uses the overview's total, which is that same row, so the page reads cma.calls_of once
--                  more, not twice, and streams the table after its first paint; /api/v1/reports/calls/tags passes true
--
-- Measured locally as the application, Postgres held to one CPU, three times prod's volume
-- (web/verify/perf-volume-fixture.sql, eight calls per session): the page's read 650-1,150 ms for a month, the tag use's own 650-790; the API's read (with the
-- total row) 1,500-3,700 ms. Both are over the 500 ms report-core budget at that volume, as the tag use already is, so
-- 131_time_all.sql's two new rows read FAIL there; prod's run of 131 decides whether the read needs a faster form.
-- SQLSTATEs as cma.calls_tag_use: CMA04 a range or filter refused, CMA06 not permitted.
--
-- Guard: scripts run under a personal IAM login so the audit trail names a person. postgres is
-- for emergencies only; to use it deliberately, run first:  set cma.emergency = 'on';
do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;

begin;
set local lock_timeout = '5s';
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0009zv') then
    raise exception 'addition 0009zv (244_auto_close_office_hours.sql) must run before 0009zw';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Calls per tag over a whole period
-- ---------------------------------------------------------------------------------------------
-- New. The calls as cma.calls_tag_use_of (100) reads them, without its is_conversation filter: the scope of
-- cma.calls_figures_of. The call set is read once (materialized) and feeds both the tag rows and the Untagged row
create or replace function cma.calls_per_tag_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_line text)
returns table (
  tag_key     text,
  tag_name    text,
  meaning     text,
  is_counted  boolean,
  outbound    integer,
  inbound     integer,
  calls       integer
)
language sql stable
rows 50
set jit = off
as $$
  with s as (select t.timezone as zone from cma.tenant t where t.id = p_tenant_id),
  c as materialized (
    -- a day on each side, so a line in another zone than the tenant's keeps its whole dates (as cma.calls_figures_of)
    select x.connection_id, x.direction, x.tag_refs, x.is_tagged from s
    cross join lateral cma.calls_of(p_tenant_id, (p_from - 1)::timestamp at time zone s.zone,
                                    (p_to + 2)::timestamp at time zone s.zone, p_market, p_line) x
    where x.business_date between p_from and p_to
  ),
  r as (
    -- per current tag: a call with two tags counts under each (calls_of's tag_refs hold each current tag once)
    select c.connection_id, tr.ref,
           (count(*) filter (where c.direction = 'outbound'))::integer as o,
           (count(*) filter (where c.direction = 'inbound'))::integer as i,
           count(*)::integer as n
    from c
    cross join lateral unnest(c.tag_refs) as tr(ref)
    group by c.connection_id, tr.ref
  )
  select x.tag_key, x.tag_name, x.meaning, x.is_counted, x.o, x.i, x.n
  from (
    select r.connection_id::text || ':' || r.ref as tag_key, coalesce(tg.name, r.ref) as tag_name, tg.meaning,
           coalesce(tg.is_counted, true) as is_counted, r.o, r.i, r.n, 0 as part
    from r
    left join cma.telephony_tag tg
      on tg.tenant_id = p_tenant_id and tg.connection_id = r.connection_id and tg.tag_ref = r.ref
    union all
    -- Untagged: one row, also for a period without calls
    select null, null, null, null,
           (count(*) filter (where c.direction = 'outbound'))::integer,
           (count(*) filter (where c.direction = 'inbound'))::integer,
           count(*)::integer, 1
    from c
    where not c.is_tagged
  ) x
  order by x.part, x.n desc, x.tag_name, x.tag_key
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. The application's read
-- ---------------------------------------------------------------------------------------------
-- New, in the shape of cma.calls_tag_use (62): the permission, the range and the filters first
create or replace function cma.calls_per_tag(p_from date, p_to date, p_market text, p_line text, p_totals boolean default true)
returns table (
  row_kind    text,
  tag_key     text,
  tag_name    text,
  meaning     text,
  is_counted  boolean,
  outbound    integer,
  inbound     integer,
  calls       integer
)
language plpgsql stable
rows 50
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.calls_filters_check(p_market, p_line);
  return query
    select case when p.tag_key is null then 'untagged' else 'tag' end, p.tag_key, p.tag_name, p.meaning, p.is_counted,
           p.outbound, p.inbound, p.calls
    from cma.calls_per_tag_of(v_tenant, p_from, p_to, p_market, p_line) p;
  if coalesce(p_totals, true) then
    -- the calls in scope, as Reports → Calls counts them: cma.calls_figures_of's total row
    return query
      select 'total'::text, null::text, null::text, null::text, null::boolean, f.outbound, f.inbound, f.calls
      from cma.calls_figures_of(v_tenant, p_from, p_to, p_market, p_line, 'day') f
      where f.group_key is null;
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. Grants: the application only, as the calls reads (62, 100)
-- ---------------------------------------------------------------------------------------------
revoke execute on function cma.calls_per_tag_of(uuid, date, date, text, text),
  cma.calls_per_tag(date, date, text, text, boolean) from public;
grant execute on function cma.calls_per_tag_of(uuid, date, date, text, text),
  cma.calls_per_tag(date, date, text, text, boolean) to cma_app;

insert into cma.schema_migration (version, description)
values ('0009zw', 'Calls per tag: cma.calls_per_tag_of(tenant, from, to, market, line) counts every call in scope per current tag (any tag, counted or not) by direction, a call with two tags under each, with one Untagged row (cma.calls_figures_of''s untagged), over the whole period; cma.calls_per_tag(from, to, market, line, totals) the application''s read (reports.view or performance.team) with cma.calls_figures_of''s calls, inbound and outbound as the total row')
on conflict (version) do nothing;

commit;
reset role;
