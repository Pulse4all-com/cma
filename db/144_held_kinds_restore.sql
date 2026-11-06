-- =============================================================================================
-- 144_held_kinds_restore.sql: addition 0008zx, the reviews, assets and subscriptions kinds back in
-- cma.connection_held_kinds_of, and the Live board's inbound poll at volume
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 142_reviews_all_order_kinds.sql (0008zw) and after the two indexes below. Rerunnable, forward-only, in one transaction
-- with a lock timeout. Run as your own IAM login: dev first (the indexes, this script, then 145_verify_held_kinds_restore.sql,
-- then 105_verify_reviews.sql, 113_verify_assets.sql, 115_verify_asset_sync.sql, 119_verify_subscriptions.sql,
-- 61_verify_inbound_service.sql and 133_verify_perf.sql again: each reads what this changes; 133 as edited by this
-- change), then prod in the same order without 119 (dev and local only, as 118 says), then 131_time_all.sql part a.
-- No table, view, column or setting changes, and no seed need run again; the web and the ingest of main run unchanged on
-- it (every function keeps its name, arguments and columns; one function is added).
--
-- First, from the Terminal (never Studio: Studio wraps a script in a transaction, which a concurrent build refuses), on
-- cma.telephony_call, a busy table (CLAUDE.md, Performance): dev, then prod, each index its own statement with
-- set role cma_owner, lock_timeout '5s' and statement_timeout '10min' given as separate commands of the same session (one
-- command holding several statements runs them in one transaction, which the build refuses), then pg_index.indisvalid
-- checked (t; an f: drop index concurrently, then create it again). The PR's Terminal blocks give them ready to run. The
-- script refuses to run until both exist and are valid:
--   create index concurrently if not exists telephony_call_missed_inbound_idx on cma.telephony_call (tenant_id, started_at)
--     where direction = 'inbound' and answered_at is null and source_deleted_at is null;
--   create index concurrently if not exists telephony_call_callback_idx on cma.telephony_call (tenant_id, counterpart_hash, started_at)
--     where counterpart_hash is not null and source_deleted_at is null and (direction = 'outbound' or (direction = 'inbound' and answered_at is not null));
-- The first holds the inbound calls not answered (the missed inbound calls, and those still waiting until they end): the
-- lookback's missed calls without reading its answered and outbound ones (2,000 rows instead of 10,000 at three times
-- prod's volume). The second holds each caller's callbacks (an outbound call, or an answered inbound one) in time order:
-- telephony_call_hash_idx (34) has no time, so a caller's lookback was read through the whole history from the table
-- (25,000 buffers at three times prod's volume); here the lookback's callbacks of a caller are one index range. Their
-- cost: an index entry per inbound call not answered and per outbound or answered
-- call with a caller; at prod's 1,100 calls a day, a write the ingest does not notice.
--
-- Why, the kinds (Decision log, 6 November 2026): 132_perf.sql (0008zr) made the function again from the definition of
-- 70_crm_tasks.sql (0008n), not from the latest one before it, 118_subscriptions.sql's (0008zl). It lost what 104 (0008ze:
-- reviews, from review_channel and review), 112 and 114 (0008zi, 0008zj: assets, from device and from the connection
-- fields of entity device or device_component, which no longer count as crm) and 118 (0008zl: subscriptions, from
-- subscription and subscription_event) had added. 133_verify_perf.sql compared the rewrite with 70's definition too, so
-- the two agreed and the loss went unseen. Since 0008zr a connection holding only reviews, devices or subscriptions holds
-- no kind, and one holding device fields holds crm. That matters wherever a connection's kind is not set (kind null),
-- where the CMA reads the kind from the rows: Sources and Flash's sources (the kind shown), cma.set_connection_kind
-- (the CMA03 refusal of a kind other than the rows'), the device-field trigger and the asset, review and subscription
-- loads' guards and settings checks (which kind of connection it is). 105 (A8, B2), 113, 115 and 119 fail on 0008zr.
--
-- Why, the poll (Decision log, 6 November 2026): in prod on 6 November 2026 (131 part a) cma.missed_callbacks_of, the
-- missed-callbacks summary and cma.inbound_now() took 29.8 to 38.4 ms against the poll's 20 ms, as the call volume grew.
-- Measured first, locally on web/verify/perf-volume-fixture.sql at three times prod's volume (about 1,960 callers listed),
-- with EXPLAIN (ANALYZE, BUFFERS) and auto_explain on PostgreSQL 16: (a) a generic plan of cma.inbound_calls_of read every
-- call of the tenant (its bounds written as coalesce(<argument>, ...) are not taken by the index under row-level
-- security), 40 ms per call, three calls per poll; (b) the list read every call of the lookback (10,000 rows) to find
-- the missed ones (2,000), and every listed caller's whole history (25,000 buffers) for a callback; (c)
-- cma.business_seconds_of, a function of three statements, once per listed caller (72 ms for 1,970). Now each read gives
-- the same answer (145 proves it against 0008zr's definitions, kept inside it): the bounds as scalar subqueries; the
-- missed calls from their own index; the callbacks from theirs, within the lookback only; per caller the newest missed
-- call needing a callback, whether one followed and how many missed calls since the one before, in one sorted pass
-- that carries each call's columns; the callbacks probed per caller; the office seconds from each market's open windows,
-- computed once. No step joins two sets of the list's size: a plan cached for another tenant's few rows ran such a join
-- as a loop over every pair (434 ms for the join back to the missed calls, 2.3 s for the callbacks against the callers,
-- both found while timing and removed). 131 part a's four statements locally at three times prod's volume, best of
-- five (the lower figure with a fresh plan, the higher with the plans cached for the other tenant first, as 145 runs):
-- inbound today 46 to 3 ms, the summary 87 to 15-28 ms, the missed callbacks with their record links 125 to 29-46 ms,
-- cma.inbound_now() 247 to 54-66 ms. What remains of the list and inbound_now is the about 1,960 listed callers
-- themselves: a record link per row through cma.record_url (about 9 ms), the office seconds per row (about 10 ms) and
-- the list's JSON (about 18 ms); 20 ms at that size would need the poll to return less. At prod's own volume the ratio
-- of 132's prod times to its local ones puts all four at about 10 ms or under; 131 part a in prod is the proof.
--
-- What it changes (functions only, and the two indexes above):
--   cma.connection_held_kinds_of(tenant, connection)  the six kinds of 0008zl, in its order (crm, telephony, commerce,
--                      reviews, assets, subscriptions), each from the same tables and conditions as 0008zl's, in
--                      0008zr's form: a big table is asked min(<the first column after (tenant_id, connection_id) in its
--                      unique key>) is not null, which the planner answers with one index step whether or not a row
--                      exists; a catalog table (a handful of rows per connection) keeps exists(). Of the tables 0008zr
--                      left out, review, device, subscription and subscription_event are big (min(source_id), each
--                      column not null in the unique key (tenant_id, connection_id, source_id)); review_channel and
--                      connection_field are catalogs. Same signature, owner (cma_owner), security (invoker, no setting)
--                      and grants as 0008zr's
--   cma.inbound_calls_of(tenant, from, to)  0008zr's, its bounds as scalar subqueries; jit off kept
--   cma.missed_callbacks_of(tenant)  0008zr's rows, columns and order, as above; the caller's hash stays inside it
--   cma.anonymous_missed_calls_of(tenant, from)  new: how many missed inbound calls needing a callback from p_from on
--                      came from an anonymous caller (an integer); the application's only
--   cma.missed_callbacks_summary_of(tenant), cma.inbound_now()  0008i's and 0008zr's answers; the anonymous count from
--                      cma.anonymous_missed_calls_of
-- The rule this restores (Decision log): a rewrite for speed starts from the latest definition before it, and its verify
-- compares against that same definition.
-- SQLSTATEs: none raised but the guards'.
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
  if not exists (select 1 from cma.schema_migration where version = '0008zw') then
    raise exception 'addition 0008zw (142_reviews_all_order_kinds.sql) must run before 0008zx';
  end if;
  if (select count(*) from pg_index i join pg_class c on c.oid = i.indexrelid
      where c.relnamespace = 'cma'::regnamespace and i.indrelid = 'cma.telephony_call'::regclass and i.indisvalid
        and c.relname in ('telephony_call_missed_inbound_idx', 'telephony_call_callback_idx')) <> 2 then
    raise exception 'the indexes telephony_call_missed_inbound_idx and telephony_call_callback_idx must exist and be valid first: create them concurrently from the Terminal (this script''s header)';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The kinds a connection holds: 0008zl's six, answered from the indexes
-- ---------------------------------------------------------------------------------------------
-- As 0008zl (118): the same tables, conditions, kinds and order; in 0008zr's (132) form: min() of the first column after
-- (tenant_id, connection_id) in each big table's unique key in place of exists(), so the planner answers it with one index
-- step (every such column is not null, so min() is null exactly when the table holds no row of the connection). The
-- catalog tables keep exists(); the connection fields count as assets for the entities device and device_component and
-- as crm for every other entity (0008zj)
create or replace function cma.connection_held_kinds_of(p_tenant_id uuid, p_connection_id uuid)
returns text[]
language sql stable
as $$
  select array_remove(array[
    case when (select min(x.record_type) from cma.crm_record x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or (select min(x.source_id) from cma.crm_contact x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or (select min(x.source_id) from cma.crm_call x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or exists (select 1 from cma.connection_pipeline x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_form x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_call_outcome x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_field x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id
                        and x.entity not in ('device', 'device_component'))
           or exists (select 1 from cma.writeback_field x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_inbox x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_inbox_channel x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_email_rule x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or (select min(x.source_kind) from cma.email_message x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or (select min(x.source_id) from cma.email_thread x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or (select min(x.source_id) from cma.crm_task x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or exists (select 1 from cma.connection_task_status x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_task_type x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'crm' end,
    case when (select min(x.source_id) from cma.telephony_call x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or exists (select 1 from cma.telephony_tag x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.telephony_number x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'telephony' end,
    case when exists (select 1 from cma.commerce_store x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or (select min(x.source_id) from cma.commerce_customer x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or (select min(x.source_id) from cma.commerce_order x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
         then 'commerce' end,
    case when exists (select 1 from cma.review_channel x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or (select min(x.source_id) from cma.review x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
         then 'reviews' end,
    case when (select min(x.source_id) from cma.device x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or exists (select 1 from cma.connection_field x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id
                        and x.entity in ('device', 'device_component'))
         then 'assets' end,
    case when (select min(x.source_id) from cma.subscription x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or (select min(x.source_id) from cma.subscription_event x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
         then 'subscriptions' end], null)
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. The Live board's inbound poll at volume
-- ---------------------------------------------------------------------------------------------
-- As 0008zr (132): the same rows, columns and order; the period's bounds as scalar subqueries. Under row-level security a
-- generic plan cannot use a bound written as coalesce(<argument>, ...) on the index (the planner counts the expression as
-- one that could leak a row before the policy's own condition), so it read every call of the tenant on every call of
-- this function whose plan was generic (40 ms at three times prod's volume, PostgreSQL 16 locally); a scalar subquery is
-- evaluated once into a parameter the index takes. jit off repeated: a create or replace drops a function's settings
create or replace function cma.inbound_calls_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns table(call_id uuid, connection_id uuid, source_system text, source_id text, line_key text, line_ref text, line_name text,
              market text, zone text, started_at timestamptz, business_date date, local_hour integer, is_answered boolean,
              is_waiting boolean, answer_seconds numeric, reason_code text, reason_label text, needs_callback boolean,
              in_service_level boolean)
language sql stable
as $$
  with s as (
    select t.timezone as tenant_zone,
           greatest(0, cma.setting_of(t.id, 'telephony.waiting_max_minutes')::integer) as waiting_max
    from cma.tenant t where t.id = p_tenant_id
  ),
  c as (
    select tc.*, n.name as n_name, m.code as m_code, coalesce(m.time_zone, (select s.tenant_zone from s)) as z,
           (tc.answered_at is null and tc.ended_at is null
            and tc.started_at >= now() - make_interval(mins => (select s.waiting_max from s))) as waiting
    from cma.telephony_call tc
    left join cma.telephony_number n
      on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
    left join cma.market m on m.tenant_id = tc.tenant_id and m.code = n.market
    where tc.tenant_id = p_tenant_id
      and tc.direction = 'inbound'
      and tc.source_deleted_at is null
      and tc.started_at is not null
      and coalesce(n.is_counted, true)
      and tc.started_at >= (select coalesce(p_from, '-infinity'::timestamptz))
      and tc.started_at < (select coalesce(p_to, 'infinity'::timestamptz))
  )
  select c.id, c.connection_id, c.source_system, c.source_id,
         c.connection_id::text || ':' || coalesce(c.number_ref, ''),
         c.number_ref, coalesce(c.n_name, c.number_ref), coalesce(c.m_code, 'unknown'), c.z,
         c.started_at, (c.started_at at time zone c.z)::date, extract(hour from c.started_at at time zone c.z)::integer,
         c.answered_at is not null,
         c.waiting,
         case when c.answered_at is not null then greatest(0, extract(epoch from c.answered_at - c.started_at)) end,
         case when r.unanswered then r.code end,
         case when r.unanswered then coalesce(mr.label, r.code) end,
         case when r.unanswered then coalesce(mr.needs_callback, true) end,
         c.answered_at is not null or (r.unanswered and coalesce(mr.counts_in_service_level, true))
  from c
  cross join lateral (select c.answered_at is null and not c.waiting as unanswered,
                             coalesce(nullif(btrim(c.missed_reason), ''), 'unknown') as code) r
  left join cma.telephony_missed_reason mr
    on mr.tenant_id = c.tenant_id and mr.source_system = c.source_system and mr.code = r.code
$$;
alter function cma.inbound_calls_of(uuid, timestamptz, timestamptz) set jit = off;

-- The missed inbound calls (docs/definitions.md) needing a callback from p_from on whose caller is anonymous (no hash),
-- counted: the summary's anonymous_count and inbound_now()'s, as 0008i counts them over cma.inbound_calls_of (reason_code
-- set: not answered and not waiting; needs_callback; no counterpart_hash). Read by telephony_call_missed_inbound_idx.
-- A count only: the caller's hash is never returned by any function (Decision log, 14 October 2026)
create or replace function cma.anonymous_missed_calls_of(p_tenant_id uuid, p_from timestamptz)
returns integer
language sql stable
as $$
  select count(*)::integer
  from cma.telephony_call tc
  left join cma.telephony_number n
    on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
  left join cma.telephony_missed_reason mr
    on mr.tenant_id = tc.tenant_id and mr.source_system = tc.source_system and mr.code = coalesce(nullif(btrim(tc.missed_reason), ''), 'unknown')
  where tc.tenant_id = p_tenant_id
    and tc.direction = 'inbound'
    and tc.answered_at is null
    and tc.source_deleted_at is null
    and tc.started_at is not null
    and tc.counterpart_hash is null
    and coalesce(n.is_counted, true)
    and coalesce(mr.needs_callback, true)
    and tc.started_at >= (select coalesce(p_from, '-infinity'::timestamptz))
    and tc.started_at < 'infinity'::timestamptz
    and not (tc.ended_at is null
             and tc.started_at >= now() - make_interval(mins => (select greatest(0, cma.setting_of(t.id, 'telephony.waiting_max_minutes')::integer)
                                                                 from cma.tenant t where t.id = p_tenant_id)))
$$;

-- As 0008zr (132): the same rows, columns and order. The lookback's missed calls read once, by the partial index of the
-- missed inbound calls; the callers' callbacks by the partial index of the callbacks, within the lookback only (a
-- callback after a caller's newest missed call lies within it, being later; one before it changes the count only when it
-- lies within it, every missed call counted being later than the lookback's start); per caller the newest missed call
-- needing a callback, whether a callback followed it and how many missed calls since the callback before it, in one
-- sorted pass of window functions over the missed calls and the callbacks together (no join between two sets of the
-- size of the list, whose plan a misestimate turns into a pass per row); the office seconds waited from each market's
-- open windows of the lookback, computed once (cma.business_seconds_of's rule: the market's own hours, else '*', its
-- holidays and '*''s excluded, each day placed in the market's zone), not by a function call per row
create or replace function cma.missed_callbacks_of(p_tenant_id uuid)
returns table (
  call_id                   uuid,
  connection_id             uuid,
  source_id                 text,
  line_ref                  text,
  line_name                 text,
  market                    text,
  reason_code               text,
  reason_label              text,
  started_at                timestamptz,
  missed_count              integer,
  waiting_seconds           integer,
  waiting_business_seconds  integer
)
language sql stable
as $$
  with s as materialized (
    select now() - make_interval(days => greatest(0, cma.setting_of(t.id, 'telephony.callback_lookback_days')::integer)) as w_from
    from cma.tenant t where t.id = p_tenant_id
  ),
  -- the lookback's missed calls of a known caller, as cma.inbound_calls_of answers them where reason_code is set (not
  -- answered and not waiting: the call ended, or started longer ago than telephony.waiting_max_minutes), read by
  -- telephony_call_missed_inbound_idx; the hash stays inside this function (never returned: Decision log, 14 October 2026)
  m as materialized (
    select tc.id as call_id, tc.connection_id, tc.source_id, tc.number_ref as line_ref, coalesce(n.name, tc.number_ref) as line_name,
           coalesce(mk.code, 'unknown') as market, r.code as reason_code, coalesce(mr.label, r.code) as reason_label,
           coalesce(mr.needs_callback, true) as needs_callback, tc.started_at, tc.counterpart_hash
    from cma.telephony_call tc
    left join cma.telephony_number n
      on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
    left join cma.market mk on mk.tenant_id = tc.tenant_id and mk.code = n.market
    cross join lateral (select coalesce(nullif(btrim(tc.missed_reason), ''), 'unknown') as code) r
    left join cma.telephony_missed_reason mr
      on mr.tenant_id = tc.tenant_id and mr.source_system = tc.source_system and mr.code = r.code
    where tc.tenant_id = p_tenant_id
      and tc.direction = 'inbound'
      and tc.answered_at is null
      and tc.source_deleted_at is null
      and tc.started_at is not null
      and tc.counterpart_hash is not null
      and coalesce(n.is_counted, true)
      and tc.started_at >= (select s.w_from from s)
      and tc.started_at < 'infinity'::timestamptz
      and not (tc.ended_at is null
               and tc.started_at >= now() - make_interval(mins => (select greatest(0, cma.setting_of(t.id, 'telephony.waiting_max_minutes')::integer)
                                                                   from cma.tenant t where t.id = p_tenant_id)))
  ),
  -- the lookback's callbacks of the callers with a missed call needing one: an outbound call, or an answered inbound one;
  -- one range of telephony_call_callback_idx per caller (offset 0 keeps the lateral a probe per caller: pulled up into a
  -- join, a plan made for another tenant's few rows compared every callback of the lookback with every caller)
  cb as materialized (
    select mh.counterpart_hash, o.started_at
    from (select distinct m.counterpart_hash from m where m.needs_callback) mh
    cross join lateral (
      select o.started_at
      from cma.telephony_call o
      where o.tenant_id = p_tenant_id
        and o.counterpart_hash = mh.counterpart_hash
        and o.source_deleted_at is null
        and (o.direction = 'outbound' or (o.direction = 'inbound' and o.answered_at is not null))
        and o.started_at >= (select s.w_from from s)
      offset 0
    ) o
  ),
  -- both per caller in time order (a callback after a missed call of the same instant: neither before nor after it); a
  -- missed call carries its own columns, so the list needs no join back to m (a join a plan made for another tenant's
  -- few rows would run as a loop over every pair)
  u as (
    select m.counterpart_hash as h, m.started_at, 0 as kind, m.call_id, m.needs_callback,
           m.connection_id, m.source_id, m.line_ref, m.line_name, m.market, m.reason_code, m.reason_label
    from m
    union all
    select cb.counterpart_hash, cb.started_at, 1, null::uuid, null::boolean,
           null::uuid, null::text, null::text, null::text, null::text, null::text, null::text
    from cb
  ),
  -- m_upto: the caller's missed calls up to and at a row's instant
  u1 as (
    select u.*,
           count(*) filter (where u.kind = 0) over (partition by u.h order by u.started_at range between unbounded preceding and current row) as m_upto
    from u
  ),
  -- per caller: the newest missed call needing a callback (rn 1), the newest callback, all missed calls, and the missed
  -- calls up to the latest callback before the row
  u2 as (
    select u1.*,
           count(*) filter (where u1.kind = 0) over (partition by u1.h) as m_all,
           max(u1.started_at) filter (where u1.kind = 1) over (partition by u1.h) as cb_last,
           max(u1.m_upto) filter (where u1.kind = 1) over (partition by u1.h order by u1.started_at, u1.kind, u1.call_id
                                                           rows between unbounded preceding and 1 preceding) as m_upto_cb,
           row_number() over (partition by u1.h order by (u1.kind = 0 and u1.needs_callback) desc, u1.started_at desc, u1.call_id desc) as rn
    from u1
  ),
  -- the callers still waiting: no callback after their newest missed call needing one; missed since the callback before it
  k as (
    select u2.call_id, u2.connection_id, u2.source_id, u2.line_ref, u2.line_name, u2.market, u2.reason_code, u2.reason_label,
           u2.started_at, (u2.m_all - coalesce(u2.m_upto_cb, 0))::integer as missed
    from u2
    where u2.rn = 1 and u2.kind = 0 and u2.needs_callback and not coalesce(u2.cb_last > u2.started_at, false)
  ),
  -- each market's open windows from the lookback's first day to today, in its zone (materialized: computed once, never
  -- once per listed caller, whatever the plan)
  bz as materialized (
    select mk.code as market, mk.time_zone as zone, d.opens, d.closes, d.days
    from cma.market mk
    cross join lateral (
      select array_agg((dd.day + h.opens_at) at time zone mk.time_zone) as opens,
             array_agg((dd.day + h.closes_at) at time zone mk.time_zone) as closes,
             array_agg(dd.day) as days
      from (select g.ts::date as day
            from generate_series(((select s.w_from from s) at time zone mk.time_zone)::date, (now() at time zone mk.time_zone)::date,
                                 interval '1 day') g(ts)) dd
      join cma.business_hours h
        on h.tenant_id = p_tenant_id and h.weekday = extract(isodow from dd.day)
       and h.market = case when exists (select 1 from cma.business_hours h2 where h2.tenant_id = p_tenant_id and h2.market = mk.code)
                           then mk.code else '*' end
      where not exists (select 1 from cma.business_holiday b where b.tenant_id = p_tenant_id and b.market in (mk.code, '*') and b.day = dd.day)
    ) d
    where mk.tenant_id = p_tenant_id and mk.time_zone is not null
  )
  select k.call_id, k.connection_id, k.source_id, k.line_ref, k.line_name, k.market, k.reason_code, k.reason_label, k.started_at,
         k.missed,
         greatest(0, floor(extract(epoch from now() - k.started_at)))::integer,
         -- cma.business_seconds_of(tenant, nullif(market, 'unknown'), started_at, now()): null for no market or one without a
         -- zone, 0 for a call not begun, else the windows' overlap from the call's own local day on
         case when nullif(k.market, 'unknown') is null or z.zone is null then null
              when now() <= k.started_at then 0
              else (select coalesce(sum(greatest(0, extract(epoch from least(w.c, now()) - greatest(w.o, k.started_at)))), 0)::integer
                    from unnest(z.opens, z.closes, z.days) w(o, c, d)
                    where w.d >= (k.started_at at time zone z.zone)::date) end
  from k
  left join bz z on z.market = k.market
  order by k.started_at, k.source_id
$$;

-- As 0008i (60): the same row; the anonymous missed calls counted by cma.anonymous_missed_calls_of
create or replace function cma.missed_callbacks_summary_of(p_tenant_id uuid)
returns table (listed integer, anonymous_count integer, lookback_days integer)
language sql stable
as $$
  with s as (
    select greatest(0, cma.setting_of(t.id, 'telephony.callback_lookback_days')::integer) as lookback
    from cma.tenant t where t.id = p_tenant_id
  )
  select (select count(*)::integer from cma.missed_callbacks_of(p_tenant_id)),
         cma.anonymous_missed_calls_of(p_tenant_id, now() - make_interval(days => s.lookback)),
         s.lookback
  from s
$$;

-- As 0008zr (132): the same answer; the anonymous missed calls counted by cma.anonymous_missed_calls_of
create or replace function cma.inbound_now()
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_list   jsonb;
begin
  perform cma.assert_permission('monitoring.live');
  select coalesce(jsonb_agg(to_jsonb(m) || jsonb_build_object('record_url', cma.record_url(m.connection_id, 'call', m.source_id)) order by m.started_at, m.source_id), '[]'::jsonb)
    into v_list
  from cma.missed_callbacks_of(v_tenant) m;
  return jsonb_build_object(
    'today', (select to_jsonb(x) from cma.inbound_today_of(v_tenant) x),
    'callbacks', v_list,
    'summary', (select jsonb_build_object('listed', jsonb_array_length(v_list),
                                          'anonymous_count', cma.anonymous_missed_calls_of(v_tenant, now() - make_interval(days => s.lookback)),
                                          'lookback_days', s.lookback)
                from (select greatest(0, cma.setting_of(t.id, 'telephony.callback_lookback_days')::integer) as lookback
                      from cma.tenant t where t.id = v_tenant) s));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. Grants, the addition
-- ---------------------------------------------------------------------------------------------
-- The application's only, as before (a create or replace keeps a function's grants; said again here)
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.connection_held_kinds_of(uuid,uuid)', 'cma.inbound_calls_of(uuid,timestamptz,timestamptz)', 'cma.anonymous_missed_calls_of(uuid,timestamptz)',
    'cma.missed_callbacks_of(uuid)', 'cma.missed_callbacks_summary_of(uuid)', 'cma.inbound_now()'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

insert into cma.schema_migration (version, description)
values ('0008zx', 'The kinds a connection holds restored and the Live board''s inbound poll at volume: cma.connection_held_kinds_of answers 0008zl''s six kinds again (crm, telephony, commerce, reviews, assets, subscriptions; the connection fields of entity device or device_component as assets, not crm), which 0008zr had rebuilt from 0008n''s definition and lost, in 0008zr''s form; cma.inbound_calls_of with its bounds as scalar subqueries (an index under row-level security in a generic plan too), cma.missed_callbacks_of from the missed inbound calls and the callers'' callbacks by two partial indexes on cma.telephony_call (telephony_call_missed_inbound_idx, telephony_call_callback_idx, created concurrently first) in one sorted pass with the office seconds computed once, the summary and cma.inbound_now() counting the anonymous missed calls with the new cma.anonymous_missed_calls_of (a count; the caller''s hash is returned by no function); every answer as before (145 proves it)')
on conflict (version) do nothing;

commit;
reset role;
