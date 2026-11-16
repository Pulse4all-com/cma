-- =============================================================================================
-- tools/perf/follow-up-diff.sql: what changes between two computations of the follow-up's items (after 178, addition
-- 0009o; Martin, 13 November 2026: prod's refresh writes 2,000 to 3,200 rows a minute in office hours)
-- =============================================================================================
-- Read-only: nothing is written but two temporary tables of this session, gone when it ends. Run by Martin in his own
-- terminal, as his own IAM login, against the database to look at (after 178):
--
--   cd ~/cma && cma_db prod && psql "$PGCONN" -X -f tools/perf/follow-up-diff.sql > /tmp/follow-up-diff.txt 2>&1
--
-- The tenant by slug (psql variable tenant_slug, default pulse4all-subscriptions); the gap between the two computations
-- in seconds (gap_s, default 60, the job's minute). Each computation is the one cma.refresh_follow_up_of (178) makes,
-- the same three reads and the same columns, as the application acting as the tenant's Scheduler user under row-level
-- security, each in a transaction of its own (now() differs between them as between two runs of the job). About
-- 70 seconds with the default gap.
--
-- Output: kinds, column and key names, market codes, counts and seconds only; no id, name, number or value of an item.
--
-- Parts
--   0  the two computations' instants and item counts; the stored items' age (the job's last write)
--   1  per kind: items in both, only in the first or the second, items whose fingerprint differs (what the refresh
--      deletes and inserts again) and the rows it would write for them (deleted + inserted)
--   2  per column of the item (sort_key, market, owner_user_id, state): matched items whose value differs
--   3  per key of the item's row (jsonb): matched items whose value differs as a value; items where only its text
--      differs (the same jsonb value printed otherwise: a scale, a key order); the key on one side only; json null
--      against a missing key
--   4  items whose fingerprint differs while every column and every key is equal as a value (a representation artefact)
--   5  the changed tickets and leads per market (are they the markets in office hours now?)
--   6  the stored items (the job's last write) against the first computation, by fingerprint, per kind
-- =============================================================================================
\set ON_ERROR_STOP on
\pset pager off
\if :{?tenant_slug}
\else
  \set tenant_slug pulse4all-subscriptions
\endif
\if :{?gap_s}
\else
  \set gap_s 60
\endif

begin;
set local role cma_owner;
select (select t.id from cma.tenant t where t.slug = :'tenant_slug') as tid \gset
select (select x.user_id from cma.app_user_external_id x
        where x.tenant_id = :'tid' and x.system = 'scheduler' and x.external_id = 'scheduler') as uid \gset
drop table if exists pg_temp.fu_a;
drop table if exists pg_temp.fu_b;
create temporary table fu_a (kind text, sort_key integer, item_id uuid, market text, owner_user_id uuid, state text, row jsonb, at timestamptz);
create temporary table fu_b (like fu_a);
grant select, insert on pg_temp.fu_a, pg_temp.fu_b to cma_app;
commit;

-- the computation of cma.refresh_follow_up_of (178), its three reads and columns, into the first table
begin;
set local statement_timeout = '60s';
select set_config('app.tenant_id', :'tid', true) is not null as tenant_set, set_config('app.user_id', :'uid', true) is not null as user_set;
set local role cma_app;
insert into fu_a
select 'lead', o.ordinality::integer, o.deal_id, coalesce(nullif(o.market, ''), 'unknown'), o.owner_user_id,
       case when o.past_target then 'past_target' when o.past_target is false then 'within_target' else 'no_hours' end,
       to_jsonb(o) - 'tenant_id' - 'ordinality', now()
from cma.open_leads_of(cma.current_tenant_id()) with ordinality o
union all
select 'ticket', o.ordinality::integer, o.ticket_id, coalesce(nullif(o.market, ''), 'unknown'), o.owner_user_id, o.sla_state,
       to_jsonb(o) - 'tenant_id' - 'ordinality', now()
from cma.open_tickets_of(cma.current_tenant_id()) with ordinality o
union all
select 'task', o.ordinality::integer, o.task_id, coalesce(nullif(o.market, ''), 'unknown'), o.owner_user_id, o.due_state,
       to_jsonb(o) - 'tenant_id' - 'ordinality', now()
from cma.open_tasks_of(cma.current_tenant_id()) with ordinality o;
commit;

select pg_sleep(:gap_s);

-- the same, a gap later, into the second
begin;
set local statement_timeout = '60s';
select set_config('app.tenant_id', :'tid', true) is not null as tenant_set, set_config('app.user_id', :'uid', true) is not null as user_set;
set local role cma_app;
insert into fu_b
select 'lead', o.ordinality::integer, o.deal_id, coalesce(nullif(o.market, ''), 'unknown'), o.owner_user_id,
       case when o.past_target then 'past_target' when o.past_target is false then 'within_target' else 'no_hours' end,
       to_jsonb(o) - 'tenant_id' - 'ordinality', now()
from cma.open_leads_of(cma.current_tenant_id()) with ordinality o
union all
select 'ticket', o.ordinality::integer, o.ticket_id, coalesce(nullif(o.market, ''), 'unknown'), o.owner_user_id, o.sla_state,
       to_jsonb(o) - 'tenant_id' - 'ordinality', now()
from cma.open_tickets_of(cma.current_tenant_id()) with ordinality o
union all
select 'task', o.ordinality::integer, o.task_id, coalesce(nullif(o.market, ''), 'unknown'), o.owner_user_id, o.due_state,
       to_jsonb(o) - 'tenant_id' - 'ordinality', now()
from cma.open_tasks_of(cma.current_tenant_id()) with ordinality o;
commit;

begin;
set local role cma_owner;
select set_config('app.tenant_id', :'tid', true) is not null as tenant_set;

\echo
\echo ==== 0. The two computations and the stored items ====
select (select min(at) from fu_a) as first_at, (select min(at) from fu_b) as second_at,
       round(extract(epoch from (select min(at) from fu_b) - (select min(at) from fu_a))) as gap_seconds,
       (select count(*) from fu_a) as first_items, (select count(*) from fu_b) as second_items,
       (select round(extract(epoch from now() - m.computed_at)) from cma.follow_up_marker m where m.tenant_id = :'tid') as stored_age_seconds;

\echo
\echo ==== 1. Per kind: matched, only one side, fingerprint changed, rows the refresh would write ====
select coalesce(a.kind, b.kind) as kind,
       count(*) filter (where a.item_id is not null and b.item_id is not null) as matched,
       count(*) filter (where b.item_id is null) as only_first,
       count(*) filter (where a.item_id is null) as only_second,
       count(*) filter (where a.item_id is not null and b.item_id is not null
                          and cma.follow_up_item_print(a.sort_key, a.market, a.owner_user_id, a.state, a.row)
                              <> cma.follow_up_item_print(b.sort_key, b.market, b.owner_user_id, b.state, b.row)) as changed,
       2 * count(*) filter (where a.item_id is not null and b.item_id is not null
                          and cma.follow_up_item_print(a.sort_key, a.market, a.owner_user_id, a.state, a.row)
                              <> cma.follow_up_item_print(b.sort_key, b.market, b.owner_user_id, b.state, b.row))
         + count(*) filter (where a.item_id is null or b.item_id is null) as rows_written
from fu_a a full join fu_b b on b.kind = a.kind and b.item_id = a.item_id
group by 1 order by 1;

\echo
\echo ==== 2. Per column: matched items whose value differs ====
select a.kind,
       count(*) filter (where a.sort_key is distinct from b.sort_key) as sort_key,
       count(*) filter (where a.market is distinct from b.market) as market,
       count(*) filter (where a.owner_user_id is distinct from b.owner_user_id) as owner_user_id,
       count(*) filter (where a.state is distinct from b.state) as state,
       count(*) filter (where a.row is distinct from b.row) as row_any_key
from fu_a a join fu_b b on b.kind = a.kind and b.item_id = a.item_id
group by 1 order by 1;

\echo
\echo ==== 3. Per key of the row: value differs, only the text differs, on one side only, json null against missing ====
with k as (
  select a.kind, x.key, a.row -> x.key as va, b.row -> x.key as vb, a.row ? x.key as in_a, b.row ? x.key as in_b
  from fu_a a join fu_b b on b.kind = a.kind and b.item_id = a.item_id
  cross join lateral (select jsonb_object_keys(a.row) as key union select jsonb_object_keys(b.row)) x
)
select kind, key,
       count(*) filter (where in_a and in_b and va is distinct from vb) as value_differs,
       count(*) filter (where in_a and in_b and va = vb and va::text <> vb::text) as text_only_differs,
       count(*) filter (where in_a <> in_b) as one_side_only,
       count(*) filter (where in_a <> in_b and coalesce(va, vb) = 'null'::jsonb) as null_against_missing
from k
group by 1, 2
having count(*) filter (where in_a and in_b and va is distinct from vb) > 0
    or count(*) filter (where in_a and in_b and va = vb and va::text <> vb::text) > 0
    or count(*) filter (where in_a <> in_b) > 0
order by 1, 3 desc, 2;

\echo
\echo ==== 4. Fingerprint differs while every column and every key is equal as a value (a representation artefact) ====
select a.kind, count(*) as items
from fu_a a join fu_b b on b.kind = a.kind and b.item_id = a.item_id
where cma.follow_up_item_print(a.sort_key, a.market, a.owner_user_id, a.state, a.row)
      <> cma.follow_up_item_print(b.sort_key, b.market, b.owner_user_id, b.state, b.row)
  and a.sort_key = b.sort_key and a.market = b.market and a.owner_user_id is not distinct from b.owner_user_id
  and a.state = b.state and a.row = b.row
group by 1 order by 1;

\echo
\echo ==== 5. Changed tickets and leads per market (open, changed, of which only sort_key) ====
select a.kind, a.market, count(*) as items,
       count(*) filter (where cma.follow_up_item_print(a.sort_key, a.market, a.owner_user_id, a.state, a.row)
                              <> cma.follow_up_item_print(b.sort_key, b.market, b.owner_user_id, b.state, b.row)) as changed,
       count(*) filter (where a.sort_key <> b.sort_key and a.row = b.row and a.state = b.state) as only_sort_key
from fu_a a join fu_b b on b.kind = a.kind and b.item_id = a.item_id
where a.kind in ('ticket', 'lead')
group by 1, 2 order by 1, 4 desc, 2;

\echo
\echo ==== 6. The stored items (the last write of the job) against the first computation, by fingerprint ====
select coalesce(s.kind, a.kind) as kind,
       count(*) filter (where s.item_id is not null and a.item_id is not null
                          and cma.follow_up_item_print(s.sort_key, s.market, s.owner_user_id, s.state, s.row)
                              = cma.follow_up_item_print(a.sort_key, a.market, a.owner_user_id, a.state, a.row)) as same,
       count(*) filter (where s.item_id is not null and a.item_id is not null
                          and cma.follow_up_item_print(s.sort_key, s.market, s.owner_user_id, s.state, s.row)
                              <> cma.follow_up_item_print(a.sort_key, a.market, a.owner_user_id, a.state, a.row)) as differs,
       count(*) filter (where a.item_id is null) as only_stored,
       count(*) filter (where s.item_id is null) as only_computed
from (select * from cma.follow_up_item where tenant_id = :'tid') s
full join fu_a a on a.kind = s.kind and a.item_id = s.item_id
group by 1 order by 1;
rollback;
