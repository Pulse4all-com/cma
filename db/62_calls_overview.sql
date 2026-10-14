-- =============================================================================================
-- 62_calls_overview.sql: addition 0008j, calls overview and calls per agent
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 60_inbound_service.sql (0008i). Rerunnable, forward-only, in one transaction. Run as your own IAM
-- login, dev first, then prod; then rerun 02_seed_<customer>.sql for the customer's threshold, then
-- 63_verify_calls_overview.sql (dev), then 35_verify_telephony.sql, 41_verify_lead_metrics.sql,
-- 55_verify_uncounted_lines.sql and 61_verify_inbound_service.sql again.
--
-- Brief B16 (backlog CMA-055 and CMA-044; README Decision log, 14 October 2026): the telephony
-- system's General Performance, Outbound and User Activity views in the CMA.
--
-- What it adds
--   setting            telephony.connected_min_seconds (10): an outbound call with at least this
--                      much talk time is connected
--   calls overview     cma.calls_overview(from, to, market, line, group): per day, ISO week, market or
--                      line the calls, inbound and outbound, answered inbound, connected outbound and
--                      its share, conversations, their total and average talk time (and the connected
--                      outbound calls' own) and the untagged ones, then a total row, then the same
--                      totals over the previous equal period (reports.view or performance.team)
--   tag use            cma.calls_tag_use(from, to, market, line, group): per group and per current tag
--                      the conversations carrying it, and the untagged conversations; then the same
--                      over the whole period (reports.view or performance.team)
--   per person         cma.calls_per_person(from, to, market, line): the same figures per person,
--                      through the linked accounts of 0008e (<adapter>_user); the calls of telephony
--                      users not linked to a person as one row with the count of those users, never
--                      their ids; then a total row (performance.team)
--   tags per person    cma.calls_per_person_tags(from, to, market, line): per person and per counted
--                      tag the conversations carrying it, and the person's untagged conversations
--                      (performance.team)
--
-- Definitions (one place: cma.calls_of, which every read here uses)
--   call               a telephony call, not deleted, with a start time, on a counted line (0008f
--                      stores no other; a line not yet in the catalog counts), either direction
--   talk time          ended_at - answered_at in whole seconds (telephony_call.talk_seconds, 0007a):
--                      no ringing, unlike the telephony system's duration, so these figures differ from
--                      its own on purpose; null while a call is unanswered or not ended
--   answered inbound   an inbound call with answered_at
--   connected outbound an outbound call with talk time >= telephony.connected_min_seconds (at least,
--                      so a call at exactly the threshold is connected); a negative value counts as 0
--   conversation       an answered inbound call or a connected outbound call. Talk time totals and
--                      averages are over conversations only (a conversation not ended yet has none)
--   tagged, untagged   tagged: the call has a current tag, any tag, counted or not; untagged: a
--                      conversation without a current tag. Tags per person show counted tags only
--   date, week, time   a call's business date and time of day are in its line's market zone, else the
--                      tenant's (as 0008i); its week is the ISO week (Monday) of that date
--   person             the person linked to the call's telephony user (app_user_external_id, system
--                      '<source system>_user', 0008e); a person's calls are their answered inbound and
--                      their outbound calls. First and last call: the earliest and the latest time of
--                      day of a call of theirs on any day of the period
--   filters            p_market (a catalog market code, 'unknown' for a line without one, or null for
--                      all) and p_line (connection id ':' line ref, as the line groups, or null) narrow
--                      every read the same way, before anything is counted
--
-- Nothing personal: no function returns a call id, the hash or a number, and the application's reads
-- return no telephony user id either (the users without a person are a count). Per-person figures are
-- staff data, sorted by name and never ranked (README Decision log, 7 and 14 October 2026).
--
-- How the rows are made once (as 0007d and 0008i): each read is a function of an explicit tenant
-- (cma.*_of) in the caller's rights; the application's functions check the permission and call it for
-- the current tenant under row-level security. Everything here is SECURITY INVOKER and executable by
-- the application only. The measures have no reader view.
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid,
-- CMA06 not permitted.
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
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0008i') then
    raise exception 'addition 0008i (60_inbound_service.sql) must run before 0008j';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The setting
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('telephony.connected_min_seconds', 'integer', null, '10',
     'An outbound call with at least this many seconds of talk time (from the answer to the end, no ringing) counts as connected')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- ---------------------------------------------------------------------------------------------
-- 2. The calls of a tenant, one row each (no call id, no hash, no number)
-- ---------------------------------------------------------------------------------------------
-- Calls started in [p_from, p_to) (null: unbounded) on counted lines, narrowed by market and line,
-- with their line, market, zone, business date, week and time of day, the telephony user, the
-- classification of the definitions above and the call's current tags (refs of its connection's
-- catalog, sorted). Every read of this addition counts from these rows.
create or replace function cma.calls_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz, p_market text, p_line text)
returns table (
  connection_id         uuid,
  source_system         text,
  direction             text,
  line_key              text,
  line_name             text,
  market                text,
  zone                  text,
  started_at            timestamptz,
  business_date         date,
  week_start            date,
  local_time            time,
  user_ref              text,
  is_answered_inbound   boolean,
  is_connected_outbound boolean,
  is_conversation       boolean,
  talk_seconds          integer,
  tag_refs              text[],
  is_tagged             boolean
)
language sql stable
as $$
  with s as (
    select t.timezone as tenant_zone,
           greatest(0, cma.setting_of(t.id, 'telephony.connected_min_seconds')::integer) as connected_min
    from cma.tenant t where t.id = p_tenant_id
  ),
  c as (
    select tc.connection_id, tc.source_system, tc.direction, tc.source_id, tc.started_at, tc.answered_at, tc.talk_seconds,
           tc.user_ref, tc.connection_id::text || ':' || coalesce(tc.number_ref, '') as lk,
           coalesce(n.name, tc.number_ref) as ln, coalesce(m.code, 'unknown') as mk, coalesce(m.time_zone, s.tenant_zone) as z,
           s.connected_min
    from cma.telephony_call tc
    cross join s
    left join cma.telephony_number n
      on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
    left join cma.market m on m.tenant_id = tc.tenant_id and m.code = n.market
    where tc.tenant_id = p_tenant_id
      and tc.source_deleted_at is null
      and tc.started_at is not null
      and coalesce(n.is_counted, true)
      and (p_from is null or tc.started_at >= p_from)
      and (p_to is null or tc.started_at < p_to)
  )
  select c.connection_id, c.source_system, c.direction, c.lk, c.ln, c.mk, c.z, c.started_at,
         (c.started_at at time zone c.z)::date,
         date_trunc('week', (c.started_at at time zone c.z)::date::timestamp)::date,
         (c.started_at at time zone c.z)::time,
         c.user_ref,
         k.answered_in, k.connected_out, k.answered_in or k.connected_out,
         c.talk_seconds,
         coalesce(tg.refs, '{}'::text[]), tg.refs is not null
  from c
  cross join lateral (
    select c.direction = 'inbound' and c.answered_at is not null as answered_in,
           c.direction = 'outbound' and coalesce(c.talk_seconds >= c.connected_min, false) as connected_out) k
  left join lateral (
    select array_agg(ct.tag_ref order by ct.tag_ref) as refs
    from cma.telephony_call_tag ct
    where ct.tenant_id = p_tenant_id and ct.connection_id = c.connection_id and ct.call_source_id = c.source_id
      and ct.untagged_at is null) tg on true
  where (p_market is null or c.mk = p_market)
    and (p_line is null or c.lk = p_line)
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The figures per group and in total (the overview), and the tag use
-- ---------------------------------------------------------------------------------------------
-- Per group of the business dates [p_from, p_to] (each call's date in its own zone): day (the date),
-- week (the Monday of the ISO week), market (the line's market or 'unknown') or line (connection:line
-- ref, labelled with the line's name); then the total over every call as the last row, with group_key
-- and group_label null (averages and shares do not add up across groups, so the total is computed,
-- not summed; it is there even for a period without calls).
create or replace function cma.calls_figures_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_line text, p_group text)
returns table (
  group_key               text,
  group_label             text,
  calls                   integer,
  inbound                 integer,
  outbound                integer,
  answered_inbound        integer,
  connected_outbound      integer,
  connected_pct           numeric,
  conversations           integer,
  talk_seconds_total      bigint,
  talk_seconds_avg        numeric,
  outbound_talk_seconds     bigint,
  outbound_talk_avg       numeric,
  untagged_conversations  integer
)
language sql stable
as $$
  with s as (select t.timezone as zone from cma.tenant t where t.id = p_tenant_id),
  c as (
    -- a day on each side, so a line in another zone than the tenant's keeps its whole dates
    select x.* from s
    cross join lateral cma.calls_of(p_tenant_id, (p_from - 1)::timestamp at time zone s.zone,
                                    (p_to + 2)::timestamp at time zone s.zone, p_market, p_line) x
    where x.business_date between p_from and p_to
  )
  select g.k, g.l,
         count(*)::integer,
         (count(*) filter (where c.direction = 'inbound'))::integer,
         (count(*) filter (where c.direction = 'outbound'))::integer,
         (count(*) filter (where c.is_answered_inbound))::integer,
         (count(*) filter (where c.is_connected_outbound))::integer,
         round(100.0 * count(*) filter (where c.is_connected_outbound) / nullif(count(*) filter (where c.direction = 'outbound'), 0), 1),
         (count(*) filter (where c.is_conversation))::integer,
         coalesce(sum(c.talk_seconds) filter (where c.is_conversation), 0)::bigint,
         round(avg(c.talk_seconds) filter (where c.is_conversation), 1),
         coalesce(sum(c.talk_seconds) filter (where c.is_connected_outbound), 0)::bigint,
         round(avg(c.talk_seconds) filter (where c.is_connected_outbound), 1),
         (count(*) filter (where c.is_conversation and not c.is_tagged))::integer
  from c
  cross join lateral (
    select case p_group when 'day' then c.business_date::text
                        when 'week' then c.week_start::text
                        when 'market' then c.market
                        else c.line_key end as k,
           case p_group when 'day' then c.business_date::text
                        when 'week' then c.week_start::text
                        when 'market' then c.market
                        else coalesce(c.line_name, 'unknown') end as l) g
  group by grouping sets ((g.k, g.l), ())
  order by grouping(g.k), case when p_group = 'line' then g.l end, g.k
$$;

-- The overview: the groups and the total of the period ('current'), then the total of the previous
-- equal period ('previous': the same number of business dates just before p_from), for the deltas
create or replace function cma.calls_overview_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_line text, p_group text)
returns table (
  period                  text,
  group_key               text,
  group_label             text,
  calls                   integer,
  inbound                 integer,
  outbound                integer,
  answered_inbound        integer,
  connected_outbound      integer,
  connected_pct           numeric,
  conversations           integer,
  talk_seconds_total      bigint,
  talk_seconds_avg        numeric,
  outbound_talk_seconds     bigint,
  outbound_talk_avg       numeric,
  untagged_conversations  integer
)
language sql stable
as $$
  select x.period, x.group_key, x.group_label, x.calls, x.inbound, x.outbound, x.answered_inbound, x.connected_outbound,
         x.connected_pct, x.conversations, x.talk_seconds_total, x.talk_seconds_avg, x.outbound_talk_seconds, x.outbound_talk_avg,
         x.untagged_conversations
  from (
    select 'current'::text as period, 1 as part, f.*
    from cma.calls_figures_of(p_tenant_id, p_from, p_to, p_market, p_line, p_group) with ordinality f
    union all
    select 'previous', 2, f.*
    from cma.calls_figures_of(p_tenant_id, p_from - (p_to - p_from + 1), p_from - 1, p_market, p_line, p_group) with ordinality f
    where f.group_key is null
  ) x
  order by x.part, x.ordinality
$$;

-- Per group and per current tag (any tag, counted or not): the conversations carrying it, tag_key the
-- connection id ':' tag ref, with the catalog's name and is_counted; tag_key null for the untagged
-- conversations. Then the same over the whole period with group_key null. A conversation with two
-- tags counts under each. Groups as cma.calls_figures_of; within a group the most used tag first,
-- the untagged row last.
create or replace function cma.calls_tag_use_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_line text, p_group text)
returns table (
  group_key      text,
  group_label    text,
  tag_key        text,
  tag_name       text,
  is_counted     boolean,
  conversations  integer
)
language sql stable
as $$
  with s as (select t.timezone as zone from cma.tenant t where t.id = p_tenant_id),
  c as (
    select x.* from s
    cross join lateral cma.calls_of(p_tenant_id, (p_from - 1)::timestamp at time zone s.zone,
                                    (p_to + 2)::timestamp at time zone s.zone, p_market, p_line) x
    where x.business_date between p_from and p_to and x.is_conversation
  ),
  t as (
    select g.k, g.l, case when tr.ref is not null then c.connection_id::text || ':' || tr.ref end as tk,
           tg.name as tn, tg.is_counted as tc
    from c
    cross join lateral (
      select case p_group when 'day' then c.business_date::text
                          when 'week' then c.week_start::text
                          when 'market' then c.market
                          else c.line_key end as k,
             case p_group when 'day' then c.business_date::text
                          when 'week' then c.week_start::text
                          when 'market' then c.market
                          else coalesce(c.line_name, 'unknown') end as l) g
    cross join lateral unnest(case when c.is_tagged then c.tag_refs else array[null::text] end) as tr(ref)
    left join cma.telephony_tag tg
      on tg.tenant_id = p_tenant_id and tg.connection_id = c.connection_id and tg.tag_ref = tr.ref
  )
  select t.k, t.l, t.tk, t.tn, t.tc, count(*)::integer
  from t
  group by grouping sets ((t.k, t.l, t.tk, t.tn, t.tc), (t.tk, t.tn, t.tc))
  order by grouping(t.k), case when p_group = 'line' then t.l end, t.k, t.tk is null, count(*) desc, t.tn, t.tk
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Per person
-- ---------------------------------------------------------------------------------------------
-- A person's calls of the period with the person they belong to: the telephony user's linked person,
-- else none (row_kind 'not_linked'). A person's calls are their answered inbound and outbound calls.
create or replace function cma.calls_people_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_line text)
returns table (
  row_kind              text,
  user_id               uuid,
  display_name          text,
  user_ref              text,
  direction             text,
  local_time            time,
  is_answered_inbound   boolean,
  is_connected_outbound boolean,
  is_conversation       boolean,
  talk_seconds          integer,
  connection_id         uuid,
  tag_refs              text[],
  is_tagged             boolean
)
language sql stable
as $$
  with s as (select t.timezone as zone from cma.tenant t where t.id = p_tenant_id)
  select case when u.id is null then 'not_linked' else 'person' end, u.id, u.display_name, x.user_ref,
         x.direction, x.local_time, x.is_answered_inbound, x.is_connected_outbound, x.is_conversation, x.talk_seconds,
         x.connection_id, x.tag_refs, x.is_tagged
  from s
  cross join lateral cma.calls_of(p_tenant_id, (p_from - 1)::timestamp at time zone s.zone,
                                  (p_to + 2)::timestamp at time zone s.zone, p_market, p_line) x
  left join cma.app_user_external_id xi
    on xi.tenant_id = p_tenant_id and xi.system = x.source_system || '_user' and xi.external_id = x.user_ref
  left join cma.app_user u on u.tenant_id = p_tenant_id and u.id = xi.user_id
  where x.business_date between p_from and p_to
    and (x.is_answered_inbound or x.direction = 'outbound')
$$;

-- One row per person with calls in the period ('person', by name), then the calls of telephony users
-- without a person and of calls without a user ('not_linked', with the number of such users, never
-- who they are), then the total over every call ('total'). Talk time totals and averages per
-- direction over the conversations (answered inbound; connected outbound).
create or replace function cma.calls_per_person_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_line text)
returns table (
  row_kind                text,
  user_id                 uuid,
  display_name            text,
  unlinked_users          integer,
  answered_inbound        integer,
  inbound_talk_seconds    bigint,
  inbound_talk_avg        numeric,
  outbound_calls          integer,
  connected_outbound      integer,
  outbound_talk_seconds   bigint,
  outbound_talk_avg       numeric,
  conversations           integer,
  untagged_conversations  integer,
  first_call_time         time,
  last_call_time          time
)
language sql stable
as $$
  select coalesce(p.row_kind, 'total'), p.user_id, p.display_name,
         case when p.row_kind = 'not_linked' then (count(distinct p.user_ref))::integer end,
         (count(*) filter (where p.is_answered_inbound))::integer,
         coalesce(sum(p.talk_seconds) filter (where p.is_answered_inbound), 0)::bigint,
         round(avg(p.talk_seconds) filter (where p.is_answered_inbound), 1),
         (count(*) filter (where p.direction = 'outbound'))::integer,
         (count(*) filter (where p.is_connected_outbound))::integer,
         coalesce(sum(p.talk_seconds) filter (where p.is_connected_outbound), 0)::bigint,
         round(avg(p.talk_seconds) filter (where p.is_connected_outbound), 1),
         (count(*) filter (where p.is_conversation))::integer,
         (count(*) filter (where p.is_conversation and not p.is_tagged))::integer,
         min(p.local_time), max(p.local_time)
  from cma.calls_people_of(p_tenant_id, p_from, p_to, p_market, p_line) p
  group by grouping sets ((p.row_kind, p.user_id, p.display_name), ())
  order by grouping(p.row_kind), p.row_kind = 'not_linked', p.display_name, p.user_id
$$;

-- Per person (and the not-linked calls) and per counted tag: the conversations carrying it, then the
-- person's untagged conversations (tag_key null; a conversation whose only tags are not counted is
-- tagged, so it is in neither). Persons by name, not-linked last; within a person the most used
-- tag first, the untagged row last.
create or replace function cma.calls_per_person_tags_of(p_tenant_id uuid, p_from date, p_to date, p_market text, p_line text)
returns table (
  row_kind       text,
  user_id        uuid,
  tag_key        text,
  tag_name       text,
  conversations  integer
)
language sql stable
as $$
  with p as materialized (
    select * from cma.calls_people_of(p_tenant_id, p_from, p_to, p_market, p_line) where is_conversation
  ),
  r as (
    select p.row_kind, p.user_id, p.display_name, p.connection_id::text || ':' || tg.tag_ref as tk, tg.name as tn, count(*)::integer as n
    from p
    cross join lateral unnest(p.tag_refs) as tr(ref)
    join cma.telephony_tag tg
      on tg.tenant_id = p_tenant_id and tg.connection_id = p.connection_id and tg.tag_ref = tr.ref and tg.is_counted
    group by 1, 2, 3, 4, 5
    union all
    select p.row_kind, p.user_id, p.display_name, null, null, (count(*) filter (where not p.is_tagged))::integer
    from p
    group by 1, 2, 3
  )
  select r.row_kind, r.user_id, r.tk, r.tn, r.n
  from r
  order by r.row_kind = 'not_linked', r.display_name, r.user_id, r.tk is null, r.n desc, r.tn, r.tk
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. The application's reads (permission checked, filters checked, current tenant, row-level security)
-- ---------------------------------------------------------------------------------------------
-- The filters: a market is a two-letter code or 'unknown', a line a connection id ':' line ref (CMA04)
create or replace function cma.calls_filters_check(p_market text, p_line text)
returns void
language plpgsql immutable
as $$
begin
  if p_market is not null and p_market !~ '^([A-Z]{2}|unknown)$' then
    raise exception 'a market filter is a market code or unknown, not %', p_market using errcode = 'CMA04';
  end if;
  if p_line is not null and p_line !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:.{0,100}$' then
    raise exception 'a line filter is a connection id and a line ref, not %', p_line using errcode = 'CMA04';
  end if;
end
$$;

create or replace function cma.calls_overview(p_from date, p_to date, p_market text, p_line text, p_group text)
returns table (
  period                  text,
  group_key               text,
  group_label             text,
  calls                   integer,
  inbound                 integer,
  outbound                integer,
  answered_inbound        integer,
  connected_outbound      integer,
  connected_pct           numeric,
  conversations           integer,
  talk_seconds_total      bigint,
  talk_seconds_avg        numeric,
  outbound_talk_seconds     bigint,
  outbound_talk_avg       numeric,
  untagged_conversations  integer
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  if p_group is null or p_group not in ('day', 'week', 'market', 'line') then
    raise exception 'group by day, week, market or line, not %', p_group using errcode = 'CMA04';
  end if;
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.calls_filters_check(p_market, p_line);
  return query select * from cma.calls_overview_of(v_tenant, p_from, p_to, p_market, p_line, p_group);
end
$$;

create or replace function cma.calls_tag_use(p_from date, p_to date, p_market text, p_line text, p_group text)
returns table (
  group_key      text,
  group_label    text,
  tag_key        text,
  tag_name       text,
  is_counted     boolean,
  conversations  integer
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  if p_group is null or p_group not in ('day', 'week', 'market', 'line') then
    raise exception 'group by day, week, market or line, not %', p_group using errcode = 'CMA04';
  end if;
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.calls_filters_check(p_market, p_line);
  return query select * from cma.calls_tag_use_of(v_tenant, p_from, p_to, p_market, p_line, p_group);
end
$$;

create or replace function cma.calls_per_person(p_from date, p_to date, p_market text, p_line text)
returns table (
  row_kind                text,
  user_id                 uuid,
  display_name            text,
  unlinked_users          integer,
  answered_inbound        integer,
  inbound_talk_seconds    bigint,
  inbound_talk_avg        numeric,
  outbound_calls          integer,
  connected_outbound      integer,
  outbound_talk_seconds   bigint,
  outbound_talk_avg       numeric,
  conversations           integer,
  untagged_conversations  integer,
  first_call_time         time,
  last_call_time          time
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_permission('performance.team');
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.calls_filters_check(p_market, p_line);
  return query select * from cma.calls_per_person_of(v_tenant, p_from, p_to, p_market, p_line);
end
$$;

create or replace function cma.calls_per_person_tags(p_from date, p_to date, p_market text, p_line text)
returns table (
  row_kind       text,
  user_id        uuid,
  tag_key        text,
  tag_name       text,
  conversations  integer
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_permission('performance.team');
  perform cma.report_range(v_tenant, p_from, p_to);
  perform cma.calls_filters_check(p_market, p_line);
  return query select * from cma.calls_per_person_tags_of(v_tenant, p_from, p_to, p_market, p_line);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.calls_overview(date,date,text,text,text)',
    'cma.calls_tag_use(date,date,text,text,text)',
    'cma.calls_per_person(date,date,text,text)',
    'cma.calls_per_person_tags(date,date,text,text)',
    'cma.calls_filters_check(text,text)',
    -- the reads of an explicit tenant, which the functions above call in the caller's rights
    -- (row-level security keeps them to the current tenant whatever tenant they are given)
    'cma.calls_of(uuid,timestamptz,timestamptz,text,text)',
    'cma.calls_figures_of(uuid,date,date,text,text,text)',
    'cma.calls_overview_of(uuid,date,date,text,text,text)',
    'cma.calls_tag_use_of(uuid,date,date,text,text,text)',
    'cma.calls_people_of(uuid,date,date,text,text)',
    'cma.calls_per_person_of(uuid,date,date,text,text)',
    'cma.calls_per_person_tags_of(uuid,date,date,text,text)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008j', 'Calls overview and calls per agent: the connected-call threshold, calls, conversations, talk time and tag use per day, week, market and line with the previous period''s totals, the same per person with tags per person (no call id, hash or number returned)')
on conflict (version) do nothing;

commit;
reset role;
