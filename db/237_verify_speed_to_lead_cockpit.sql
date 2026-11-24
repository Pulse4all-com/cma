-- =============================================================================================
-- 237_verify_speed_to_lead_cockpit.sql: verifies addition 0009zr, Sales → Speed to lead as a cockpit
-- (24 November 2026; brief B40b)
-- =============================================================================================
-- Universal: no seed is assumed. W1 checks the structure on the database itself; W2 to W13 work on two throwaway tenants
-- inside a subtransaction that is always rolled back, so nothing stays and the script runs in dev and in prod. W3, W4
-- and W5 compare besides on every tenant of the database (the seeds, dev's and prod's own data), as the application
-- acting for the tenant (row-level security). Synthetic data only (example.invalid people, invented ids, no name,
-- address or phone number of anyone). The fixed instants are the week of Monday 5 October 2026 (Europe/Amsterdam,
-- UTC+2), as 235's; two deals of a market open around the clock are placed relative to now() for the checks that turn
-- on the clock (W7, W8). Every check writes one row, OK or FAIL (its detail then starts "FAIL W<n>"), because Cloud SQL
-- Studio shows no notices; the block ends with a row of its own ("ran to the end"), which the verdict requires, so a
-- block that an error ended reads FAIL. Run as your own IAM login after 236_speed_to_lead_cockpit.sql, dev first, then
-- prod.
-- Expected: W1 to W13 OK, then the verdict "PASS 0009zr". Provoked (verify.provoke true at the top): every row reads
-- FAIL with its own id, and the verdict PROVOKED, NOT A PASS.
--
--   W1  structure: 0009zr recorded after 0009zq; cma.speed_to_lead_row has no first_call_* (D36) and ends in
--       last_attempt_at, last_call_at, deal_owner_ref, conversations_so_far, window_end (35 columns), cma_read.speed_to_lead
--       the same columns in the same order and the readers' only, and no function of cma or cma_read names a first_call_ column; the three
--       settings (two goals text, empty; stale days integer, 2); the new functions and the summary the application's
--       only; cma.speed_to_lead_of without a setting (so it is inlined), the plpgsql reads with jit off and
--       force_custom_plan, cma.open_leads_of with jit off; cma.check_tenant_setting keeps 224's rules
--   W2  the settings' rules: a goal takes '', 0 to 100 (spaces trimmed) and refuses 101, -1 and 'x' (CMA04); the stale
--       days take 1 to 30 and refuse 0, 31 and 'x' (CMA04); the figures carry the goals set (null for none)
--   W3  cma.speed_to_lead_of answers as 234's (kept here verbatim) in every column both have, row for row (except all
--       both ways), on both fixture tenants and on every tenant of the database
--   W4  the new columns: each deal's Attempts so far, first Attempt (its call and start), last Attempt and Conversations
--       are cma.deal_attempts_of's in the deal's window (from the creation less the pre-window to window_end, under
--       attempts.source); window_end is cma.sales_deals_of's (else the close, else now); last_call_at the latest call of
--       cma.lead_calls_of from the window's start; deal_owner_ref the deal's CRM owner; on both fixture tenants and on
--       every tenant of the database
--   W5  cma.open_leads_of gives 234's rows (kept here verbatim), in its order, on both fixture tenants and every tenant
--   W6  the figures of a period equal the summary's total of it, column by column, and the previous period's equal the
--       summary's total of that period; the page's figures, markets (never narrowed), trend, groups and deals equal the
--       figures', the summary's and the deals list's
--   W7  the previous period ends the day before the period at the same length (a past week: no cut); a period reaching
--       today: the same length before, cut at now's time of day
--   W8  stale follows speed_to_lead.stale_business_days: dO (three working days old in a market open every day) stale at
--       2, not at 3; dN (a minute old) never
--   W9  the summary's no_attempt group: shares, median and 80th percentile null, attempts 0; the week group's keys are
--       Mondays and its deals add up to the total over four weeks (the fixture's deals all in one of them)
--   W10 the deals list: the views partition the period's not called and called deals, newest first; pages of 2 give
--       every deal once with the view's count; the view, the limit and the offset checked (CMA04); each deal's attempts
--       are cma.deal_attempts_of's (number, start, connected, talk, conversation), at most 20 with the true count (dM: 22),
--       the tag meaning keys of the call (dP: not_reached), the agent (tu-1: Anna); only the allowed keys
--   W11 a Conversation: dA's connected call of 60 s is one; the share of the week's eight deals with a Conversation is
--       the summary's conversation_share and the figures'
--   W12 tenant isolation: tenant two's figures, deals list, page and summary hold none of tenant one's deals
--   W13 the database refuses the summary, the figures, the deals list and the page to an agent (CMA06)
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);                 -- 'true' to make every check fail

drop table if exists pg_temp.verify_0009zr;
create temporary table verify_0009zr (ord integer, check_name text, result text, detail text);

-- One result row as four texts: OK when the check holds and the run is not provoked, else FAIL with its id
create or replace function pg_temp.v9zr_row(p_ord integer, p_id text, p_name text, p_ok boolean, p_detail text)
returns text[]
language sql stable
as $$
  select array[p_ord::text, p_id || ' ' || p_name,
               case when coalesce(p_ok, false) and not current_setting('verify.provoke')::boolean then 'OK' else 'FAIL' end,
               case when coalesce(p_ok, false) and not current_setting('verify.provoke')::boolean then coalesce(p_detail, '')
                    else 'FAIL ' || p_id || ': ' || case when current_setting('verify.provoke')::boolean then 'provoked; ' else '' end
                         || coalesce(p_detail, '(no detail)') end]
$$;

-- The SQLSTATE a statement raises, or 'ok'
create or replace function pg_temp.v9zr_code(p_sql text)
returns text
language plpgsql
as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end
$$;

-- 234's cma.speed_to_lead_of, verbatim (its 34 columns as a table): W3 compares 0009zr's with it
create or replace function pg_temp.v9zr_stl_234(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns table (
  tenant_id uuid, deal_id uuid, connection_id uuid, deal_source_id text, pipeline_id text, pipeline_label text,
  business_date date, created_at timestamptz, market text, market_source text, is_closed boolean, status text,
  first_call_id uuid, first_call_source_id text, first_call_at timestamptz, first_call_linked boolean,
  first_any_call_at timestamptz, first_any_direction text, inbound_first boolean, first_connected_at timestamptz,
  agent_user_id uuid, agent_ref text, agent_from text, elapsed_seconds integer, business_seconds integer,
  target_seconds integer, within_target boolean, next_business_noon timestamptz, before_next_noon boolean,
  waiting_business_seconds integer, first_attempt_call_id uuid, first_attempt_at timestamptz, attempts_so_far integer,
  deal_owner_user_id uuid
)
language sql stable
as $$
  -- materialized, so the settings are read once per call (folded into the query, once per deal)
  with s as materialized (
    select greatest(0, cma.setting_of(p_tenant_id, 'speed_to_lead.pre_window_minutes')::integer) as pre_min,
           cma.setting_of(p_tenant_id, 'speed_to_lead.target_minutes')::integer * 60 as target_s,
           cma.setting_of(p_tenant_id, 'speed_to_lead.next_day_cutoff')::time as cutoff,
           cma.setting_of(p_tenant_id, 'attempts.source') as source
  ),
  -- each market's zone, office hours and holidays read once per call, not per deal
  cal as materialized (
    select * from cma.business_calendar_of(p_tenant_id)
  ),
  -- the window's end of each sales deal as Attempts per deal reads it (cma.sales_deals_of: the earliest of the close,
  -- the first order of the deal's contacts and now), so both give the same answer for every deal (Martin, 24 Nov 2026)
  w as materialized (
    select sd.deal_id, sd.window_end, sd.window_end_reason
    from cma.sales_deals_of(p_tenant_id, p_from, p_to, now()) sd
  ),
  d as materialized (
    -- the attempts' source and the cutoff as columns: a function argument holding a subquery stops the planner from
    -- inlining cma.deal_attempts_of, which then ran once per deal on its own plan (twice the time). A lead deal outside
    -- the sales deals (a pipeline that is both a lead and an order pipeline) ends at its close, else now
    select ld.*, ld.created_at - make_interval(mins => s.pre_min) as not_before,
           coalesce(w.window_end, case when ld.is_closed then coalesce(cr.closed_at, now()) else now() end) as until,
           coalesce(w.window_end_reason = 'ordered', false) as ordered,
           s.source as attempts_source, s.cutoff
    from cma.lead_deals_of(p_tenant_id, p_from, p_to) ld
    cross join s
    left join w on w.deal_id = ld.deal_id
    left join cma.crm_record cr on cr.tenant_id = p_tenant_id and cr.id = ld.deal_id
  ),
  -- every call of each deal from the window's start, read once: the first outbound CRM call, the first call and the
  -- first connected call, shown beside the measure as before
  c as materialized (
    select d.deal_id, lc.*
    from d
    cross join lateral cma.lead_calls_of(p_tenant_id, d.connection_id, d.record_type, d.source_id, d.contacts, d.not_before) lc
  ),
  fo as (select distinct on (c.deal_id) c.* from c where c.direction = 'outbound' order by c.deal_id, c.effective_at, c.call_id),
  fa as (select distinct on (c.deal_id) c.* from c order by c.deal_id, c.effective_at, c.call_id),
  fc as (select distinct on (c.deal_id) c.* from c where c.is_connected order by c.deal_id, c.effective_at, c.call_id),
  -- each deal's first Attempt in its window and the attempts so far: one lateral into cma.deal_attempts_of per deal,
  -- one aggregate row each (n numbers the attempts from 1, so the first is n = 1 and the count the highest n). Only for
  -- the deals that can have one: an attempt is one of the deal's calls in c (cma.deal_attempts_of reads
  -- cma.deal_calls_of from the same start, as cma.lead_calls_of does), under telephony a linked one, under crm an
  -- outbound one; the other deals have none and are not read again (a third of the deals at three times prod's volume)
  a as materialized (
    select d.deal_id, x.*
    from d
    cross join lateral (
      select (array_agg(z.call_id) filter (where z.n = 1))[1] as call_id,
             min(z.effective_at) filter (where z.n = 1) as effective_at,
             min(z.telephony_source_system) filter (where z.n = 1) as telephony_source_system,
             min(z.telephony_user_ref) filter (where z.n = 1) as telephony_user_ref,
             coalesce(max(z.n), 0)::integer as attempts
      from cma.deal_attempts_of(p_tenant_id, d.connection_id, d.record_type, d.source_id, d.contacts, d.not_before, d.until,
                                d.attempts_source) z
      where z.is_attempt) x
    where d.deal_id in (select c.deal_id from c
                        where case when (select s.source from s) = 'crm' then c.direction = 'outbound' else c.is_linked end)
  ),
  r as (
    select d.*, fo.call_id as fo_id, fo.call_source_id as fo_src, fo.effective_at as fo_at, fo.is_linked as fo_linked,
           fa.effective_at as fa_at, fa.direction as fa_dir, fc.effective_at as fc_at,
           a.call_id as at_id, a.effective_at as at_at, a.telephony_source_system as at_system, a.telephony_user_ref as at_user,
           coalesce(a.attempts, 0) as attempts,
           (select s.target_s from s) as target_s,
           nn.noon,
           bc.time_zone as cal_zone, bc.weekdays as cal_weekdays, bc.opens as cal_opens, bc.closes as cal_closes, bc.holidays as cal_holidays
    from d
    left join cal bc on bc.market = nullif(d.market, 'unknown')
    -- offset 0: the cutoff moment computed once per deal (pulled up, it ran once per reference), from the calendar's arrays
    left join lateral (select cma.next_business_noon_in(bc.time_zone, bc.weekdays, bc.holidays, d.created_at, d.cutoff) as noon
                       offset 0) nn on true
    left join fo on fo.deal_id = d.deal_id
    left join fa on fa.deal_id = d.deal_id
    left join fc on fc.deal_id = d.deal_id
    left join a on a.deal_id = d.deal_id
  ),
  m as (
    select r.*, bt.bs, bt.bs_now, xa.user_id as ag_user, xo.user_id as owner_user
    from r
    -- offset 0: each deal's business seconds computed once (pulled up, they ran once per reference), from the calendar's
    -- arrays; an attempt in the pre-window is 0 (cma.business_seconds_in of an end before the start)
    left join lateral (
      select case when r.at_at is not null
                  then cma.business_seconds_in(r.cal_zone, r.cal_weekdays, r.cal_opens, r.cal_closes, r.cal_holidays, r.created_at, r.at_at) end as bs,
             case when r.at_at is null and not r.is_closed and not r.ordered
                  then cma.business_seconds_in(r.cal_zone, r.cal_weekdays, r.cal_opens, r.cal_closes, r.cal_holidays, r.created_at, now()) end as bs_now
      offset 0) bt on true
    -- the agent: the first attempt's telephony user mapped to a person (as cma.calls_people_of maps a call's user)
    left join cma.app_user_external_id xa
      on xa.tenant_id = p_tenant_id and xa.system = r.at_system || '_user' and xa.external_id = r.at_user
    -- the deal's owner mapped to a person, apart from the measure
    left join cma.app_user_external_id xo
      on xo.tenant_id = p_tenant_id and xo.system = r.source_system || '_owner' and xo.external_id = r.owner_ref
  )
  select p_tenant_id, m.deal_id, m.connection_id, m.source_id, m.pipeline_id, m.pipeline_label, m.business_date,
         m.created_at, m.market, m.market_source, m.is_closed,
         case when m.at_at is not null then 'called'
              when m.is_closed or m.ordered then 'closed_before_first_call' else 'not_called_open' end,
         m.fo_id, m.fo_src, m.fo_at, m.fo_linked, m.fa_at, m.fa_dir,
         coalesce(m.fa_dir = 'inbound', false), m.fc_at,
         m.ag_user, m.at_user, case when m.at_user is not null then 'call' end,
         case when m.at_at is not null then greatest(0, floor(extract(epoch from m.at_at - m.created_at)))::integer end,
         m.bs, m.target_s,
         case when m.bs is not null then m.bs <= m.target_s
              when m.bs_now > m.target_s then false end,
         m.noon,
         case when m.at_at is not null and m.noon is not null then m.at_at < m.noon
              when m.at_at is null and not m.is_closed and not m.ordered and m.noon is not null and now() >= m.noon then false end,
         m.bs_now,
         m.at_id, m.at_at, m.attempts, m.owner_user
  from m
$$;

-- 234's cma.open_leads_of, verbatim: W5 compares 0009zr's with it (it reads the current cma.speed_to_lead_of, whose
-- not_called_open rows W3 proves unchanged, and the deals and their calls a second time, as 0009zq did)
create or replace function pg_temp.v9zr_open_leads_234(p_tenant_id uuid)
returns setof cma.open_lead_row
language sql stable
as $$
  -- materialized, so the two settings are read once per call (folded into the query, once per lead)
  with s as materialized (
    select cma.setting_of(p_tenant_id, 'leads.age_buckets_business_days') as edges,
           greatest(0, cma.setting_of(p_tenant_id, 'speed_to_lead.pre_window_minutes')::integer) as pre_min
  ),
  -- each market's zone, office hours and holidays read once per call, not per lead
  cal as materialized (
    select * from cma.business_calendar_of(p_tenant_id)
  ),
  r as (
    select * from cma.speed_to_lead_of(p_tenant_id, null, null) x where x.status = 'not_called_open'
  )
  select p_tenant_id, r.deal_id, r.connection_id, r.deal_source_id, r.pipeline_id, r.pipeline_label,
         r.deal_owner_user_id, d.owner_ref, r.market, r.created_at, r.waiting_business_seconds,
         a.days, b.bucket_from, b.bucket_to,
         case when r.within_target is false then true when r.waiting_business_seconds is null then null else false end,
         lc.last_at,
         case when lc.last_at is not null then floor(extract(epoch from now() - lc.last_at) / 86400)::integer end
  from r
  cross join s
  join cma.lead_deals_of(p_tenant_id, null, null) d on d.deal_id = r.deal_id
  left join cal bc on bc.market = nullif(r.market, 'unknown')
  -- offset 0: the days computed once per lead (pulled up, the call ran once per reference to a.days), from the calendar's arrays
  cross join lateral (select cma.business_days_in(bc.time_zone, bc.weekdays, bc.holidays, r.created_at, now()) as days offset 0) a
  cross join lateral cma.age_bucket_of(a.days, s.edges) b
  left join lateral (
    select max(c.effective_at) as last_at
    from cma.lead_calls_of(p_tenant_id, d.connection_id, d.record_type, d.source_id, d.contacts, d.created_at - make_interval(mins => s.pre_min)) c) lc on true
  order by r.waiting_business_seconds desc nulls last, r.created_at
$$;

-- W3: the rows of both definitions that differ, in the columns both have, for one tenant (both directions)
create or replace function pg_temp.v9zr_w3(p_tenant uuid, out rows_now bigint, out differ bigint)
language sql stable
as $$
  with a as (select x.tenant_id, x.deal_id, x.connection_id, x.deal_source_id, x.pipeline_id, x.pipeline_label, x.business_date,
                    x.created_at, x.market, x.market_source, x.is_closed, x.status, x.first_any_call_at, x.first_any_direction,
                    x.inbound_first, x.first_connected_at, x.agent_user_id, x.agent_ref, x.agent_from, x.elapsed_seconds,
                    x.business_seconds, x.target_seconds, x.within_target, x.next_business_noon, x.before_next_noon,
                    x.waiting_business_seconds, x.first_attempt_call_id, x.first_attempt_at, x.attempts_so_far, x.deal_owner_user_id
             from cma.speed_to_lead_of(p_tenant, null, null) x),
       b as (select x.tenant_id, x.deal_id, x.connection_id, x.deal_source_id, x.pipeline_id, x.pipeline_label, x.business_date,
                    x.created_at, x.market, x.market_source, x.is_closed, x.status, x.first_any_call_at, x.first_any_direction,
                    x.inbound_first, x.first_connected_at, x.agent_user_id, x.agent_ref, x.agent_from, x.elapsed_seconds,
                    x.business_seconds, x.target_seconds, x.within_target, x.next_business_noon, x.before_next_noon,
                    x.waiting_business_seconds, x.first_attempt_call_id, x.first_attempt_at, x.attempts_so_far, x.deal_owner_user_id
             from pg_temp.v9zr_stl_234(p_tenant, null, null) x)
  select (select count(*) from a),
         (select count(*) from (select * from a except all select * from b) y) + (select count(*) from (select * from b except all select * from a) y)
$$;

-- W4: the deals whose new columns differ from what they are made of, for one tenant
create or replace function pg_temp.v9zr_w4(p_tenant uuid, out rows_now bigint, out differ bigint)
language sql stable
as $$
  with s as (select greatest(0, cma.setting_of(p_tenant, 'speed_to_lead.pre_window_minutes')::integer) as pre,
                    cma.setting_of(p_tenant, 'attempts.source') as src),
       r as (select * from cma.speed_to_lead_of(p_tenant, null, null)),
       ld as (select * from cma.lead_deals_of(p_tenant, null, null)),
       sd as (select * from cma.sales_deals_of(p_tenant, null, null, now())),
       z as (select r.deal_id, a.*
             from r join ld on ld.deal_id = r.deal_id cross join s
             cross join lateral cma.deal_attempts_of(p_tenant, ld.connection_id, ld.record_type, ld.source_id, ld.contacts,
                                                     ld.created_at - make_interval(mins => s.pre), r.window_end, s.src) a
             where a.is_attempt),
       lc as (select ld.deal_id, max(c.effective_at) as last_at
              from ld cross join s
              cross join lateral cma.lead_calls_of(p_tenant, ld.connection_id, ld.record_type, ld.source_id, ld.contacts,
                                                   ld.created_at - make_interval(mins => s.pre)) c
              group by ld.deal_id),
       x as (select r.deal_id, r.attempts_so_far, r.first_attempt_at, r.first_attempt_call_id, r.last_attempt_at, r.conversations_so_far,
                    r.window_end, r.last_call_at, r.deal_owner_ref from r),
       y as (select r.deal_id, count(z.n)::integer, min(z.effective_at) filter (where z.n = 1),
                    (array_agg(z.call_id) filter (where z.n = 1))[1], max(z.effective_at), (count(*) filter (where z.conversation))::integer,
                    coalesce(sd.window_end, case when ld.is_closed then coalesce(cr.closed_at, now()) else now() end),
                    lc.last_at, ld.owner_ref
             from r
             join ld on ld.deal_id = r.deal_id
             left join z on z.deal_id = r.deal_id
             left join sd on sd.deal_id = r.deal_id
             left join lc on lc.deal_id = r.deal_id
             left join cma.crm_record cr on cr.tenant_id = p_tenant and cr.id = r.deal_id
             group by r.deal_id, sd.window_end, ld.is_closed, cr.closed_at, lc.last_at, ld.owner_ref)
  select (select count(*) from x),
         (select count(*) from (select * from x except all select * from y) q) + (select count(*) from (select * from y except all select * from x) q)
$$;

-- W5: 0009zr's open leads against 234's, as text in the function's order, for one tenant
create or replace function pg_temp.v9zr_w5(p_tenant uuid, out rows_now bigint, out same boolean)
language sql stable
as $$
  select (select count(*) from cma.open_leads_of(p_tenant)),
         (select string_agg(x::text, '|' order by o) from cma.open_leads_of(p_tenant) with ordinality x(tenant_id, deal_id, connection_id,
            deal_source_id, pipeline_id, pipeline_label, owner_user_id, owner_ref, market, created_at, waiting_business_seconds,
            age_business_days, bucket_from, bucket_to, past_target, last_call_at, last_call_days, o))
         is not distinct from
         (select string_agg(x::text, '|' order by o) from pg_temp.v9zr_open_leads_234(p_tenant) with ordinality x(tenant_id, deal_id, connection_id,
            deal_source_id, pipeline_id, pipeline_label, owner_user_id, owner_ref, market, created_at, waiting_business_seconds,
            age_business_days, bucket_from, bucket_to, past_target, last_call_at, last_call_days, o))
$$;

-- ---------------------------------------------------------------------------------------------
-- W1. Structure
-- ---------------------------------------------------------------------------------------------
do $$
declare
  rows_ text[] := '{}';
  v_ok boolean; v_txt text; v_bad text := '';
  v_type text; v_view text; v_cfg text;
begin
  v_ok := exists (select 1 from cma.schema_migration where version = '0009zr')
      and exists (select 1 from cma.schema_migration where version = '0009zq');
  v_type := (select string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod), ',' order by a.attnum)
             from pg_attribute a where a.attrelid = (select t.typrelid from pg_type t where t.oid = 'cma.speed_to_lead_row'::regtype)
               and a.attnum > 0 and not a.attisdropped);
  v_view := (select string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod), ',' order by a.attnum)
             from pg_attribute a where a.attrelid = 'cma_read.speed_to_lead'::regclass and a.attnum > 0 and not a.attisdropped);
  if v_type !~ ',deal_owner_user_id:uuid,last_attempt_at:timestamp with time zone,last_call_at:timestamp with time zone,deal_owner_ref:text,conversations_so_far:integer,window_end:timestamp with time zone$'
     or (select count(*) from regexp_split_to_table(v_type, ',')) <> 35 or position('first_call_' in v_type) > 0 then
    v_bad := v_bad || 'the row type is ' || v_type || '; ';
  end if;
  if v_view is distinct from v_type then
    v_bad := v_bad || 'cma_read.speed_to_lead is ' || coalesce(v_view, 'missing') || '; ';
  end if;
  if not has_table_privilege('cma_readonly', 'cma_read.speed_to_lead', 'select') or has_table_privilege('cma_app', 'cma_read.speed_to_lead', 'select') then
    v_bad := v_bad || 'cma_read.speed_to_lead is not the readers'' alone; ';
  end if;
  select string_agg(n.nspname || '.' || p.proname, ', ' order by p.proname collate "C") into v_txt
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('cma', 'cma_read') and p.prosrc ~ 'first_call_(id|source_id|at|linked)';
  if v_txt is not null then
    v_bad := v_bad || 'first_call_ still named by ' || v_txt || '; ';
  end if;
  select string_agg(s.key || '=' || s.value_type || ':' || s.default_value, ' ' order by s.key collate "C") into v_txt
  from cma.setting s where s.key in ('speed_to_lead.goal_within_target_pct', 'speed_to_lead.goal_before_cutoff_pct', 'speed_to_lead.stale_business_days');
  if v_txt is distinct from 'speed_to_lead.goal_before_cutoff_pct=text: speed_to_lead.goal_within_target_pct=text: speed_to_lead.stale_business_days=integer:2' then
    v_bad := v_bad || 'the settings are ' || coalesce(v_txt, 'missing') || '; ';
  end if;
  foreach v_txt in array array['cma.speed_to_lead_summary(date,date,text,text)', 'cma.speed_to_lead_figures(date,date,text)',
                               'cma.speed_to_lead_deals_of(date,date,text,text,integer,integer)',
                               'cma.speed_to_lead_page(date,date,text,text,text,integer,integer)',
                               'cma.speed_to_lead_view_check(text,integer,integer)',
                               'cma.speed_to_lead_groups_from(cma.speed_to_lead_row[],date,date,text,text)',
                               'cma.speed_to_lead_figures_from(uuid,cma.speed_to_lead_row[],date,date,date,date,timestamptz,text,text)',
                               'cma.speed_to_lead_deals_from(uuid,cma.speed_to_lead_row[],date,date,text,text,integer,integer)',
                               'cma.speed_to_lead_of(uuid,timestamptz,timestamptz)', 'cma.speed_to_lead_rows(date,date)', 'cma.open_leads_of(uuid)'] loop
    if to_regprocedure(v_txt) is null then
      v_bad := v_bad || v_txt || ' missing; ';
    elsif not has_function_privilege('cma_app', v_txt, 'execute') or has_function_privilege('public', v_txt, 'execute')
          or has_function_privilege('cma_readonly', v_txt, 'execute') then
      v_bad := v_bad || v_txt || ' not the application''s only; ';
    end if;
  end loop;
  -- the settings of the reads: none on the one function (it is inlined), jit off and custom plans on the plpgsql reads
  select string_agg(p.proname || '=' || coalesce(array_to_string(p.proconfig, ','), '-'), ' ' order by p.proname collate "C") into v_cfg
  from pg_proc p
  where p.oid in ('cma.speed_to_lead_of(uuid,timestamptz,timestamptz)'::regprocedure, 'cma.open_leads_of(uuid)'::regprocedure,
                  'cma.speed_to_lead_summary(date,date,text,text)'::regprocedure, 'cma.speed_to_lead_figures(date,date,text)'::regprocedure,
                  'cma.speed_to_lead_deals_of(date,date,text,text,integer,integer)'::regprocedure,
                  'cma.speed_to_lead_page(date,date,text,text,text,integer,integer)'::regprocedure,
                  'cma.speed_to_lead_rows(date,date)'::regprocedure);
  if v_cfg is distinct from 'open_leads_of=jit=off speed_to_lead_deals_of=jit=off,plan_cache_mode=force_custom_plan '
                            || 'speed_to_lead_figures=jit=off,plan_cache_mode=force_custom_plan speed_to_lead_of=- '
                            || 'speed_to_lead_page=jit=off,plan_cache_mode=force_custom_plan speed_to_lead_rows=jit=off,plan_cache_mode=force_custom_plan '
                            || 'speed_to_lead_summary=jit=off,plan_cache_mode=force_custom_plan' then
    v_bad := v_bad || 'the reads'' settings are ' || coalesce(v_cfg, '-') || '; ';
  end if;
  -- the settings trigger keeps 224's rules (a sample of them) and has the three new ones
  v_txt := (select p.prosrc from pg_proc p where p.oid = 'cma.check_tenant_setting()'::regprocedure);
  if position('subscriptions.rates_start_month' in v_txt) = 0 or position('reports.fx_eur_rates' in v_txt) = 0
     or position('speed_to_lead.goal_within_target_pct' in v_txt) = 0 or position('speed_to_lead.stale_business_days' in v_txt) = 0 then
    v_bad := v_bad || 'cma.check_tenant_setting lost a rule or lacks a new one; ';
  end if;
  rows_ := rows_ || pg_temp.v9zr_row(1, 'W1', 'structure: the addition, the row type and the view, no first_call_, the settings, the grants, the reads'' settings',
                                     v_ok and v_bad = '', case when not v_ok then '0009zr or 0009zq not recorded; ' else '' end
                                                          || coalesce(nullif(v_bad, ''), '35 columns, the five new last, no first_call_; the view the same; the three settings; grants and settings as designed'));
  insert into verify_0009zr (ord, check_name, result, detail)
  select rows_[4 * i - 3]::integer, rows_[4 * i - 2], rows_[4 * i - 1], rows_[4 * i] from generate_series(1, cardinality(rows_) / 4) i;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- W2 to W13, on two throwaway tenants (rolled back)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  rows_ text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_analyst1 uuid; v_anna uuid; v_bram uuid; v_ing1 uuid;
  v_admin2 uuid; v_analyst2 uuid; v_ing2 uuid;
  v_crm uuid; v_tel uuid; v_crm2 uuid;
  v_from timestamptz := '2026-10-04 22:00:00+00';   -- Monday 5 October 2026, 00:00 in Amsterdam
  v_to   timestamptz := '2026-10-12 22:00:00+00';   -- Tuesday 13 October, 00:00 in Amsterdam
  v_today date := (now() at time zone 'Europe/Amsterdam')::date;
  v_ok boolean; v_ok2 boolean; v_txt text; v_txt2 text; v_n bigint; v_m bigint; r record; f record; d text; j jsonb; j2 jsonb;
  v_ids uuid[];
begin
  begin
    -- tenants, people and roles (as the owner)
    v_t1 := cma.create_tenant('verify-0009zr-one', 'Verify 0009zr one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0009zr-two', 'Verify 0009zr two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-anna@example.invalid', 'Anna Verify') returning id into v_anna;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-bram@example.invalid', 'Bram Verify') returning id into v_bram;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-analyst2@example.invalid', 'analyst2') returning id into v_analyst2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_analyst1, 'analytics'), (v_t1, v_anna, 'agent'), (v_t1, v_bram, 'agent'),
                 (v_t2, v_admin2, 'admin'), (v_t2, v_analyst2, 'analytics')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verifycrm', 'Verify 0009zr CRM', 'portal-1') returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verifytel', 'Verify 0009zr telephony', 'tel-1') returning id into v_tel;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t2, 'verifycrm', 'Verify 0009zr CRM two', 'portal-2') returning id into v_crm2;
    perform set_config('role', 'cma_app', true);

    -- tenant one's configuration (the admin): NL Monday to Friday 09:00-17:00, GB open around the clock, the settings, the
    -- owners (o-1 Anna, o-2 Bram) and the telephony user tu-1 (Anna; tu-9 is nobody)
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    perform cma.set_business_hours('*', x::smallint, '09:00-17:00') from generate_series(1, 5) x;
    perform cma.set_business_hours('GB', x::smallint, '00:00-24:00') from generate_series(1, 7) x;
    perform cma.set_tenant_setting('intake.start_date', '2026-09-01');
    perform cma.set_tenant_setting('speed_to_lead.pre_window_minutes', '10');
    perform cma.set_tenant_setting('speed_to_lead.target_minutes', '60');
    perform cma.set_user_external_id(v_anna, 'verifycrm_owner', 'o-1');
    perform cma.set_user_external_id(v_bram, 'verifycrm_owner', 'o-2');
    perform cma.set_user_external_id(v_anna, 'verifytel_user', 'tu-1');

    -- the catalogs (the Ingest user), the counted line and the tag meaning (the admin)
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_pipelines(v_crm, '[
      {"recordType": "deal", "pipelineId": "sales", "label": "Sales", "stages": [
         {"stageId": "s1", "label": "Open", "order": 1, "isClosed": false, "outcome": null},
         {"stageId": "sl", "label": "Lost", "order": 9, "isClosed": true, "outcome": "lost"}]},
      {"recordType": "deal", "pipelineId": "selfserve", "label": "Self Serve", "stages": [{"stageId": "o1", "label": "Won", "order": 1, "isClosed": true, "outcome": "won"}]}]');
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'number', '[{"numberRef": "n-nl", "name": "Verify NL line", "digits": "+31000000001"}]');
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'tag', '[{"tagRef": "tg-nr", "name": "Not Reached"}, {"tagRef": "tg-plain", "name": "Plain"}]');
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_telephony_number(v_tel, 'n-nl', 'NL', true);
    perform cma.set_telephony_tag_meaning(v_tel, 'tg-nr', 'not_reached');
    perform cma.set_pipeline_order(v_crm, 'deal', 'selfserve', true);
    perform cma.set_pipeline_lead(v_crm, 'deal', 'selfserve', false);
    perform cma.set_business_holiday('NL', '2026-10-08', 'Verify holiday');

    -- the deals (UTC; Amsterdam is UTC+2 until 25 October), as 235's, and dM (22 attempts); dO and dN in GB, three days
    -- and a minute before now
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_records(v_crm, '[
      {"recordType": "deal", "sourceId": "dA", "pipelineId": "sales", "stageId": "s1", "ownerRef": "o-2", "contactId": "kA", "market": "NL", "createdAt": "2026-10-05T08:00:00Z", "updatedAt": "2026-10-05T08:00:00Z"},
      {"recordType": "deal", "sourceId": "dH", "pipelineId": "sales", "stageId": "s1", "ownerRef": "o-1", "contactId": "kH", "market": "NL", "createdAt": "2026-10-05T09:00:00Z", "updatedAt": "2026-10-05T09:00:00Z"},
      {"recordType": "deal", "sourceId": "dP", "pipelineId": "sales", "stageId": "s1", "ownerRef": "o-1", "contactId": "kP", "market": "NL", "createdAt": "2026-10-05T10:00:00Z", "updatedAt": "2026-10-05T10:00:00Z"},
      {"recordType": "deal", "sourceId": "dC", "pipelineId": "sales", "stageId": "sl", "ownerRef": "o-1", "contactId": "kC", "market": "NL", "createdAt": "2026-10-06T08:00:00Z", "closedAt": "2026-10-06T12:00:00Z", "updatedAt": "2026-10-06T12:00:00Z"},
      {"recordType": "deal", "sourceId": "dW", "pipelineId": "sales", "stageId": "s1", "ownerRef": "o-1", "contactId": "kW", "market": "NL", "createdAt": "2026-10-07T08:00:00Z", "updatedAt": "2026-10-07T08:00:00Z"},
      {"recordType": "deal", "sourceId": "dF", "pipelineId": "sales", "stageId": "s1", "ownerRef": "o-1", "contactId": "kF", "market": "NL", "createdAt": "2026-10-09T13:00:00Z", "updatedAt": "2026-10-09T13:00:00Z"},
      {"recordType": "deal", "sourceId": "dM", "pipelineId": "sales", "stageId": "s1", "ownerRef": "o-9", "contactId": "kM", "market": "NL", "createdAt": "2026-10-09T07:00:00Z", "updatedAt": "2026-10-09T07:00:00Z"},
      {"recordType": "deal", "sourceId": "dX", "pipelineId": "sales", "stageId": "s1", "ownerRef": "o-1", "contactId": "kX", "market": "NL", "createdAt": "2026-10-07T09:00:00Z", "updatedAt": "2026-10-07T09:00:00Z"},
      {"recordType": "deal", "sourceId": "dXo", "pipelineId": "selfserve", "stageId": "o1", "contactId": "kX", "market": "NL", "createdAt": "2026-10-07T09:30:00Z", "closedAt": "2026-10-07T09:30:00Z", "updatedAt": "2026-10-07T09:30:00Z"}]');
    perform cma.ingest_upsert_records(v_crm, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'dO', 'pipelineId', 'sales', 'stageId', 's1', 'ownerRef', 'o-1', 'contactId', 'kO', 'market', 'GB',
                         'createdAt', now() - interval '3 days', 'updatedAt', now() - interval '3 days'),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'dN', 'pipelineId', 'sales', 'stageId', 's1', 'ownerRef', 'o-1', 'contactId', 'kN', 'market', 'GB',
                         'createdAt', now() - interval '1 minute', 'updatedAt', now() - interval '1 minute')));
    perform cma.ingest_upsert_contacts(v_crm, (
      select jsonb_agg(jsonb_build_object('sourceId', k, 'country', 'NL', 'updatedAt', '2026-10-01T00:00:00Z'))
      from unnest(array['kA', 'kH', 'kP', 'kC', 'kW', 'kF', 'kM', 'kX', 'kO', 'kN']) k));
    -- the CRM calls, each on its deal's contact, all outbound; a hash where an Aircall call logged it (as 235's), and dM's
    -- 22 calls ten minutes apart from Friday 9 October 07:10 UTC
    perform cma.ingest_upsert_calls(v_crm, (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('sourceId', c.id, 'occurredAt', c.at, 'direction', 'outbound', 'ownerRef', 'o-1',
                                                            'counterpartHash', case when c.linked then md5(c.id) || md5(c.id || 'x') end,
                                                            'updatedAt', c.at)))
      from (select * from (values
              ('cA0', timestamptz '2026-10-05T08:05:00Z', false),
              ('cA1', timestamptz '2026-10-05T09:00:00Z', true),
              ('cH1', timestamptz '2026-10-05T09:10:00Z', false),
              ('cP0', timestamptz '2026-10-05T09:44:00Z', true),
              ('cP1', timestamptz '2026-10-05T09:55:00Z', true),
              ('cC1', timestamptz '2026-10-06T13:00:00Z', true),
              ('cW1', timestamptz '2026-10-07T08:30:00Z', true),
              ('cF1', timestamptz '2026-10-12T07:30:00Z', true),
              ('cX1', timestamptz '2026-10-07T10:00:00Z', true)) v(id, at, linked)
            union all
            select 'cM' || g, timestamptz '2026-10-09T07:10:00Z' + make_interval(mins => 10 * (g - 1)), true from generate_series(1, 22) g) c));
    perform cma.ingest_upsert_associations(v_crm, (
      select jsonb_agg(jsonb_build_object('fromType', 'crm_call', 'fromId', a.c, 'toType', 'contact', 'toId', a.k, 'removed', false,
                                          'changedAt', '2026-10-01T00:00:00Z'))
      from (select * from (values ('cA0', 'kA'), ('cA1', 'kA'), ('cH1', 'kH'), ('cP0', 'kP'), ('cP1', 'kP'), ('cC1', 'kC'), ('cW1', 'kW'),
                                  ('cF1', 'kF'), ('cX1', 'kX')) v(c, k)
            union all select 'cM' || g, 'kM' from generate_series(1, 22) g) a));
    -- the Aircall calls that logged them, 10 seconds earlier, with the same hash: cA1 answered after 5 s with 60 s of talk
    -- (a Conversation); cP1 tagged Not Reached (meaning not_reached) and Plain (no meaning); the rest not answered
    perform cma.ingest_upsert_telephony_calls(v_tel, (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'sourceId', 't' || t.c, 'direction', 'outbound', 'startedAt', t.started - interval '10 seconds',
               'answeredAt', case when t.c = 'cA1' then t.started - interval '5 seconds' end,
               'endedAt', case when t.c = 'cA1' then t.started + interval '55 seconds' else t.started + interval '20 seconds' end,
               'numberRef', 'n-nl', 'userRef', t.usr,
               'tags', case when t.c = 'cP1' then '[{"tagRef": "tg-nr", "name": "Not Reached"}, {"tagRef": "tg-plain", "name": "Plain"}]'::jsonb end,
               'counterpartHash', md5(t.c) || md5(t.c || 'x'), 'versionAt', t.started + interval '1 hour')))
      from (select * from (values
              ('cA1', timestamptz '2026-10-05T09:00:00Z', 'tu-1'),
              ('cP0', timestamptz '2026-10-05T09:44:00Z', 'tu-1'),
              ('cP1', timestamptz '2026-10-05T09:55:00Z', 'tu-1'),
              ('cC1', timestamptz '2026-10-06T13:00:00Z', 'tu-1'),
              ('cW1', timestamptz '2026-10-07T08:30:00Z', 'tu-9'),
              ('cF1', timestamptz '2026-10-12T07:30:00Z', 'tu-1'),
              ('cX1', timestamptz '2026-10-07T10:00:00Z', 'tu-1')) v(c, started, usr)
            union all
            select 'cM' || g, timestamptz '2026-10-09T07:10:00Z' + make_interval(mins => 10 * (g - 1)), 'tu-1' from generate_series(1, 22) g) t));
    perform cma.link_calls('2026-09-01T00:00:00Z');

    -- tenant two: NL, the same source id dA (open, never called) and dB (closed before any call)
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.set_business_hours('*', x::smallint, '09:00-17:00') from generate_series(1, 5) x;
    perform cma.set_tenant_setting('intake.start_date', '2026-09-01');
    perform set_config('app.user_id', v_ing2::text, true);
    perform cma.ingest_upsert_pipelines(v_crm2, '[
      {"recordType": "deal", "pipelineId": "sales", "label": "Sales", "stages": [
         {"stageId": "s1", "label": "Open", "order": 1, "isClosed": false, "outcome": null},
         {"stageId": "sl", "label": "Lost", "order": 9, "isClosed": true, "outcome": "lost"}]}]');
    perform cma.ingest_upsert_records(v_crm2, '[
      {"recordType": "deal", "sourceId": "dA", "pipelineId": "sales", "stageId": "s1", "contactId": "kA", "market": "NL", "createdAt": "2026-10-05T08:00:00Z", "updatedAt": "2026-10-05T08:00:00Z"},
      {"recordType": "deal", "sourceId": "dB", "pipelineId": "sales", "stageId": "sl", "contactId": "kB", "market": "NL", "createdAt": "2026-10-06T08:00:00Z", "closedAt": "2026-10-06T09:00:00Z", "updatedAt": "2026-10-06T09:00:00Z"}]');

    -- W2. the settings' rules (tenant one's admin); the figures carry the goals (the analyst)
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := '';
    foreach d in array array['', '0', '100', ' 80 ', '101', '-1', 'x', '1.5'] loop
      v_txt := v_txt || format('%s:%s ', quote_literal(d), pg_temp.v9zr_code(format('select cma.set_tenant_setting(%L, %L)', 'speed_to_lead.goal_within_target_pct', d)));
    end loop;
    v_txt := v_txt || '| ';
    foreach d in array array['1', '30', '0', '31', 'x', ''] loop
      v_txt := v_txt || format('%s:%s ', quote_literal(d), pg_temp.v9zr_code(format('select cma.set_tenant_setting(%L, %L)', 'speed_to_lead.stale_business_days', d)));
    end loop;
    perform cma.set_tenant_setting('speed_to_lead.goal_within_target_pct', ' 80 ');
    perform cma.set_tenant_setting('speed_to_lead.goal_before_cutoff_pct', '');
    perform cma.set_tenant_setting('speed_to_lead.stale_business_days', '2');
    perform set_config('app.user_id', v_analyst1::text, true);
    select v_txt || format('| stored %s; figures goals %s/%s stale %s', (select ts.value from cma.tenant_setting ts where ts.tenant_id = v_t1 and ts.key = 'speed_to_lead.goal_within_target_pct'),
                           coalesce(x.goal_within_target_pct::text, '-'), coalesce(x.goal_before_cutoff_pct::text, '-'), x.stale_business_days)
      into v_txt from cma.speed_to_lead_figures('2026-10-05', '2026-10-11') x;
    rows_ := rows_ || pg_temp.v9zr_row(2, 'W2', 'the goals take 0 to 100 or nothing, the stale days 1 to 30; anything else CMA04',
      v_txt = $t$'':ok '0':ok '100':ok ' 80 ':ok '101':CMA04 '-1':CMA04 'x':CMA04 '1.5':CMA04 | '1':ok '30':ok '0':CMA04 '31':CMA04 'x':CMA04 '':CMA04 | stored 80; figures goals 80/- stale 2$t$,
      v_txt);

    -- W3. the one function answers as 234's in every column both have, on both tenants and every tenant (as the application)
    v_txt := ''; v_ok := true;
    for d in select te.id::text from cma.tenant te order by te.id loop
      perform set_config('app.tenant_id', d, true);
      select * into r from pg_temp.v9zr_w3(d::uuid);
      v_ok := v_ok and r.differ = 0;
      v_txt := v_txt || format('%s: %s rows, %s differ; ', case d when v_t1::text then 'one' when v_t2::text then 'two' else 'tenant' end, r.rows_now, r.differ);
      if d = v_t1::text then v_ok := v_ok and r.rows_now = 10; end if;
    end loop;
    rows_ := rows_ || pg_temp.v9zr_row(3, 'W3', 'cma.speed_to_lead_of answers as 234''s in every column both have', v_ok, v_txt);

    -- W4. the new columns are what they are made of, on both tenants and every tenant
    v_txt := ''; v_ok := true;
    for d in select te.id::text from cma.tenant te order by te.id loop
      perform set_config('app.tenant_id', d, true);
      select * into r from pg_temp.v9zr_w4(d::uuid);
      v_ok := v_ok and r.differ = 0;
      v_txt := v_txt || format('%s: %s rows, %s differ; ', case d when v_t1::text then 'one' when v_t2::text then 'two' else 'tenant' end, r.rows_now, r.differ);
    end loop;
    perform set_config('app.tenant_id', v_t1::text, true);
    select string_agg(format('%s:%s/%s/%s', x.deal_source_id, x.attempts_so_far, x.conversations_so_far, coalesce(x.deal_owner_ref, '-')), ' '
                      order by x.deal_source_id collate "C")
      into v_txt2 from cma.speed_to_lead_of(v_t1, v_from, v_to) x where x.deal_source_id in ('dA', 'dM', 'dH');
    rows_ := rows_ || pg_temp.v9zr_row(4, 'W4', 'the Attempts, the last call, the owner reference and the window''s end of every deal',
      v_ok and v_txt2 = 'dA:1/1/o-2 dH:0/0/o-1 dM:22/0/o-9', v_txt || v_txt2);

    -- W5. the open leads as 234's, in order, on both tenants and every tenant
    v_txt := ''; v_ok := true;
    for d in select te.id::text from cma.tenant te order by te.id loop
      perform set_config('app.tenant_id', d, true);
      select * into r from pg_temp.v9zr_w5(d::uuid);
      v_ok := v_ok and r.same;
      v_txt := v_txt || format('%s: %s leads, %s; ', case d when v_t1::text then 'one' when v_t2::text then 'two' else 'tenant' end, r.rows_now,
                               case when r.same then 'the same' else 'DIFFER' end);
      if d = v_t1::text then v_ok := v_ok and r.rows_now = 3; end if;
    end loop;
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    rows_ := rows_ || pg_temp.v9zr_row(5, 'W5', 'cma.open_leads_of gives 234''s rows in its order', v_ok, v_txt);

    -- W6. the figures equal the summary's total, for the period and the previous one; the page's parts equal the reads'
    select * into f from cma.speed_to_lead_figures('2026-10-05', '2026-10-11');
    select * into r from cma.speed_to_lead_summary('2026-10-05', '2026-10-11', 'total');
    v_ok := (f.deals, f.called, f.within_target_pct, f.before_next_noon_pct, f.median_business_minutes, f.open_not_called,
             f.closed_before_first_call, f.attempts_mean, f.attempts_median, f.conversation_share)
            is not distinct from (r.deals, r.called, r.within_target_pct, r.before_next_noon_pct, r.median_business_minutes, r.open_not_called,
             r.closed_before_first_call, r.attempts_mean, r.attempts_median, r.conversation_share);
    v_txt := format('now %s deals %s called %s/%s %% median %s open %s closed %s attempts %s/%s conv %s', f.deals, f.called, f.within_target_pct,
                    f.before_next_noon_pct, f.median_business_minutes, f.open_not_called, f.closed_before_first_call, f.attempts_mean,
                    f.attempts_median, f.conversation_share);
    select * into r from cma.speed_to_lead_summary('2026-09-28', '2026-10-04', 'total');
    v_ok := v_ok and (f.prev_deals, f.prev_called, f.prev_within_target_pct, f.prev_before_next_noon_pct, f.prev_median_business_minutes,
                      f.prev_open_not_called, f.prev_closed_before_first_call, f.prev_attempts_mean, f.prev_attempts_median, f.prev_conversation_share)
                     is not distinct from (r.deals, r.called, r.within_target_pct, r.before_next_noon_pct, r.median_business_minutes, r.open_not_called,
                      r.closed_before_first_call, r.attempts_mean, r.attempts_median, r.conversation_share);
    v_txt := v_txt || format('; previous %s deals', f.prev_deals);
    -- the page's parts against the reads (narrowed to NL; the markets never narrowed)
    j := cma.speed_to_lead_page('2026-10-05', '2026-10-11', 'NL', 'agent', 'called', 50, 0);
    v_ok2 := j -> 'figures' = (select to_jsonb(x) from cma.speed_to_lead_figures('2026-10-05', '2026-10-11', 'NL') x)
         and j -> 'markets' = (select coalesce(jsonb_agg(to_jsonb(x) order by x.group_key), '[]') from cma.speed_to_lead_summary('2026-10-05', '2026-10-11', 'market') x)
         and j ->> 'trend_group' = 'day'
         and j -> 'trend' = (select coalesce(jsonb_agg(to_jsonb(x) order by x.group_key), '[]') from cma.speed_to_lead_summary('2026-10-05', '2026-10-11', 'day', 'NL') x)
         and j -> 'groups' = (select coalesce(jsonb_agg(to_jsonb(x) order by x.group_key), '[]') from cma.speed_to_lead_summary('2026-10-05', '2026-10-11', 'agent', 'NL') x)
         and j -> 'deals' = (select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc, x.deal_id), '[]') from cma.speed_to_lead_deals_of('2026-10-05', '2026-10-11', 'NL', 'called', 50, 0) x)
         and jsonb_array_length(j -> 'markets') = 1 and jsonb_array_length(j -> 'deals') > 0;
    rows_ := rows_ || pg_temp.v9zr_row(6, 'W6', 'the figures equal the summary''s total, both periods; the page''s parts equal the reads''',
      v_ok and v_ok2 and f.deals = 8 and f.prev_deals = 0, v_txt || case when v_ok2 then '; the page''s parts equal' else '; the page''s parts DIFFER' end);

    -- W7. the previous period: a past week against the week before, uncut; a period reaching today against the same
    --     length before, cut at now's time of day
    select format('%s..%s %s', x.previous_from, x.previous_to, coalesce(x.previous_until::text, 'uncut')),
           x.previous_from = '2026-09-28' and x.previous_to = '2026-10-04' and x.previous_until is null
      into v_txt, v_ok from cma.speed_to_lead_figures('2026-10-05', '2026-10-11') x;
    select v_txt || format('; to today: %s..%s until now %s', x.previous_from - v_today, x.previous_to - v_today, x.previous_until = now()),
           v_ok and x.previous_from = v_today - 13 and x.previous_to = v_today - 7 and x.previous_until = now()
      into v_txt, v_ok from cma.speed_to_lead_figures(v_today - 6, v_today) x;
    rows_ := rows_ || pg_temp.v9zr_row(7, 'W7', 'the previous period ends the day before the period, at the same length', v_ok, v_txt);

    -- W8. stale: dO (GB, open every day, three days old) at 2 and at 3; dN (a minute old) never
    select string_agg(format('%s:%s', x.deal_source_id, x.stale), ' ' order by x.deal_source_id collate "C") into v_txt
    from cma.speed_to_lead_deals_of(v_today - 6, v_today, 'GB', 'not_called', 50, 0) x;
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('speed_to_lead.stale_business_days', '3');
    perform set_config('app.user_id', v_analyst1::text, true);
    select v_txt || ' | at 3 ' || string_agg(format('%s:%s', x.deal_source_id, x.stale), ' ' order by x.deal_source_id collate "C") into v_txt
    from cma.speed_to_lead_deals_of(v_today - 6, v_today, 'GB', 'not_called', 50, 0) x;
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('speed_to_lead.stale_business_days', '2');
    perform set_config('app.user_id', v_analyst1::text, true);
    rows_ := rows_ || pg_temp.v9zr_row(8, 'W8', 'stale follows speed_to_lead.stale_business_days',
      v_txt = 'dN:f dO:t | at 3 dN:f dO:f', v_txt);

    -- W9. no_attempt: shares, median and 80th percentile null, attempts 0 (dH, dC, dX, dO, dN never attempted in the week:
    --     dO and dN are not in it); the week group: Mondays, adding up to the total
    select format('%s deals: median %s p80 %s within %s before %s conv %s attempts %s/%s', x.deals, coalesce(x.median_business_minutes::text, '-'),
                  coalesce(x.p80_business_minutes::text, '-'), coalesce(x.within_target_pct::text, '-'), coalesce(x.before_next_noon_pct::text, '-'),
                  coalesce(x.conversation_share::text, '-'), x.attempts_mean, x.attempts_median)
      into v_txt from cma.speed_to_lead_summary('2026-10-05', '2026-10-11', 'agent') x where x.group_key = 'no_attempt';
    select v_txt || format(' | week: %s groups, %s Mondays, %s deals', count(*), count(*) filter (where extract(isodow from x.group_key::date) = 1), sum(x.deals))
      into v_txt from cma.speed_to_lead_summary('2026-09-28', '2026-10-25', 'week') x;
    v_ok := v_txt = format('3 deals: median - p80 - within - before - conv - attempts 0.00/0.0 | week: 1 groups, 1 Mondays, %s deals',
                           (select x.deals from cma.speed_to_lead_summary('2026-09-28', '2026-10-25', 'total') x));
    rows_ := rows_ || pg_temp.v9zr_row(9, 'W9', 'no_attempt''s shares and median null; the week group adds up', v_ok, v_txt);

    -- W10. the deals list
    -- the views partition the period's not called and called deals, newest first
    select string_agg(x.deal_source_id, ',' order by o) into v_txt
    from cma.speed_to_lead_deals_of('2026-10-05', '2026-10-11', null, 'called', 50, 0) with ordinality x(deal_id, connection_id, deal_source_id, market,
      pipeline_id, pipeline_label, created_at, status, business_seconds, within_target, before_next_noon, cutoff_at, owner_user_id, owner_name,
      attempts_so_far, attempts, stale, view_total, o);
    select v_txt || ' | ' || string_agg(x.deal_source_id, ',' order by o) into v_txt
    from cma.speed_to_lead_deals_of('2026-10-05', '2026-10-11', null, 'not_called', 50, 0) with ordinality x(deal_id, connection_id, deal_source_id, market,
      pipeline_id, pipeline_label, created_at, status, business_seconds, within_target, before_next_noon, cutoff_at, owner_user_id, owner_name,
      attempts_so_far, attempts, stale, view_total, o);
    v_ok := v_txt = 'dF,dM,dW,dP,dA | dH';
    -- pages of 2: every called deal once, with the view's count
    select string_agg(x.deal_source_id || ':' || x.view_total, ',' order by g, x.created_at desc) into v_txt2
    from generate_series(0, 2) g cross join lateral cma.speed_to_lead_deals_of('2026-10-05', '2026-10-11', null, 'called', 2, 2 * g) x;
    v_ok := v_ok and v_txt2 = 'dF:5,dM:5,dW:5,dP:5,dA:5';
    v_txt := v_txt || ' | pages ' || coalesce(v_txt2, '-');
    -- the checks of the view, the limit and the offset
    v_txt := v_txt || ' | ' || pg_temp.v9zr_code('select * from cma.speed_to_lead_deals_of(''2026-10-05'', ''2026-10-11'', null, ''all'', 50, 0)')
             || ',' || pg_temp.v9zr_code('select * from cma.speed_to_lead_deals_of(''2026-10-05'', ''2026-10-11'', null, ''called'', 0, 0)')
             || ',' || pg_temp.v9zr_code('select * from cma.speed_to_lead_deals_of(''2026-10-05'', ''2026-10-11'', null, ''called'', 201, 0)')
             || ',' || pg_temp.v9zr_code('select * from cma.speed_to_lead_deals_of(''2026-10-05'', ''2026-10-11'', null, ''called'', 50, -1)')
             || ',' || pg_temp.v9zr_code('select cma.speed_to_lead_page(''2026-10-05'', ''2026-10-11'', null, ''total'', ''called'', 50, 0)');
    v_ok := v_ok and v_txt like '% | CMA04,CMA04,CMA04,CMA04,CMA04';
    -- each listed deal's attempts are cma.deal_attempts_of's (the first 20), with the true count beside them
    select count(*) filter (where q.differs), string_agg(q.src || ':' || q.n_list || '/' || q.n_true, ' ' order by q.src collate "C")
      into v_n, v_txt2
    from (select x.deal_source_id as src, jsonb_array_length(x.attempts) as n_list, x.attempts_so_far as n_true,
                 -- the five keys cma.deal_attempts_of gives, against its rows
                 (select jsonb_agg(jsonb_build_object('n', a -> 'n', 'started_at', a -> 'started_at', 'connected', a -> 'connected',
                                                      'talk_seconds', a -> 'talk_seconds', 'conversation', a -> 'conversation') order by (a ->> 'n')::integer)
                  from jsonb_array_elements(x.attempts) a)
                 is distinct from (
                   select jsonb_agg(jsonb_build_object('n', z.n, 'started_at', z.effective_at, 'connected', z.connected,
                                                       'talk_seconds', z.talk_seconds, 'conversation', z.conversation) order by z.n)
                   from cma.speed_to_lead_of(v_t1, v_from, v_to) sl
                   join cma.lead_deals_of(v_t1, v_from, v_to) ld on ld.deal_id = sl.deal_id
                   cross join lateral cma.deal_attempts_of(v_t1, ld.connection_id, ld.record_type, ld.source_id, ld.contacts,
                                                           ld.created_at - interval '10 minutes', sl.window_end, 'telephony') z
                   where sl.deal_id = x.deal_id and z.is_attempt and z.n <= 20) as differs
          from cma.speed_to_lead_deals_of('2026-10-05', '2026-10-11', null, 'called', 50, 0) x) q;
    v_ok := v_ok and v_n = 0 and v_txt2 = 'dA:1/1 dF:1/1 dM:20/22 dP:1/1 dW:1/1';
    v_txt := v_txt || ' | attempts ' || coalesce(v_txt2, '-') || format(' (%s differ)', v_n);
    -- dP's tag meaning keys (not the tag's text), the agent by name, only the allowed keys
    select x.attempts into j from cma.speed_to_lead_deals_of('2026-10-05', '2026-10-11', null, 'called', 50, 0) x where x.deal_source_id = 'dP';
    select string_agg(distinct k, ',' order by k) into v_txt2
    from cma.speed_to_lead_deals_of('2026-10-05', '2026-10-11', null, 'called', 50, 0) x
    cross join lateral jsonb_array_elements(x.attempts) a cross join lateral jsonb_object_keys(a) k;
    v_ok := v_ok and j -> 0 -> 'tag_meanings' = '["not_reached"]'::jsonb and j -> 0 ->> 'agent_user_id' = v_anna::text
            and j -> 0 ->> 'agent_name' = 'Anna Verify'
            and v_txt2 = 'agent_name,agent_user_id,business_seconds,connected,conversation,n,started_at,tag_meanings,talk_seconds';
    v_txt := v_txt || format(' | dP tags %s agent %s | keys %s', j -> 0 -> 'tag_meanings', j -> 0 ->> 'agent_name', v_txt2);
    rows_ := rows_ || pg_temp.v9zr_row(10, 'W10', 'the deals list: views, order, pages, checks, the attempts as cma.deal_attempts_of''s', v_ok, v_txt);

    -- W11. a Conversation: dA's call (answered, 60 s); the week's share of deals with one is the summary's and the figures'
    select format('dA %s conversation(s); share summary %s figures %s', (select x.conversations_so_far from cma.speed_to_lead_of(v_t1, v_from, v_to) x where x.deal_source_id = 'dA'),
                  s.conversation_share, fg.conversation_share),
           (select x.conversations_so_far from cma.speed_to_lead_of(v_t1, v_from, v_to) x where x.deal_source_id = 'dA') = 1
             and s.conversation_share = round(100.0 * 1 / 8, 1) and fg.conversation_share = s.conversation_share
      into v_txt, v_ok
    from cma.speed_to_lead_summary('2026-10-05', '2026-10-11', 'total') s, cma.speed_to_lead_figures('2026-10-05', '2026-10-11') fg;
    rows_ := rows_ || pg_temp.v9zr_row(11, 'W11', 'a Conversation counts in conversations_so_far and the share of deals with one', v_ok, v_txt);

    -- W12. tenant two's reads hold none of tenant one's deals
    select array_agg(x.deal_id) into v_ids from cma.speed_to_lead_of(v_t1, null, null) x;
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_analyst2::text, true);
    j2 := cma.speed_to_lead_page('2026-10-05', '2026-10-11', null, 'day', 'not_called', 50, 0);
    select format('figures %s deals; list %s (%s of one); page %s deals, %s of one; summary %s; of one as two %s',
                  (select x.deals from cma.speed_to_lead_figures('2026-10-05', '2026-10-11') x),
                  (select string_agg(x.deal_source_id, ',') from cma.speed_to_lead_deals_of('2026-10-05', '2026-10-11', null, 'not_called', 50, 0) x),
                  (select count(*) from cma.speed_to_lead_deals_of('2026-10-05', '2026-10-11', null, 'not_called', 50, 0) x where x.deal_id = any (v_ids)),
                  (j2 -> 'figures' ->> 'deals'),
                  (select count(*) from jsonb_array_elements(j2 -> 'deals') e where (e ->> 'deal_id')::uuid = any (v_ids)),
                  (select x.deals from cma.speed_to_lead_summary('2026-10-05', '2026-10-11', 'total') x),
                  (select count(*) from cma.speed_to_lead_of(v_t1, null, null)))
      into v_txt;
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    rows_ := rows_ || pg_temp.v9zr_row(12, 'W12', 'tenant isolation on the figures, the deals list, the page and the summary',
      v_txt = 'figures 2 deals; list dA (0 of one); page 2 deals, 0 of one; summary 2; of one as two 0', v_txt);

    -- W13. the database refuses the reads to a person holding neither reports.view nor performance.team (an agent):
    --      CMA06 from the summary, the figures, the deals list and the page, whatever the web checked before
    perform set_config('app.user_id', v_anna::text, true);
    v_txt := pg_temp.v9zr_code('select * from cma.speed_to_lead_summary(''2026-10-05'', ''2026-10-11'', ''day'')')
             || ',' || pg_temp.v9zr_code('select * from cma.speed_to_lead_figures(''2026-10-05'', ''2026-10-11'')')
             || ',' || pg_temp.v9zr_code('select * from cma.speed_to_lead_deals_of(''2026-10-05'', ''2026-10-11'', null, ''called'', 50, 0)')
             || ',' || pg_temp.v9zr_code('select cma.speed_to_lead_page(''2026-10-05'', ''2026-10-11'', null, ''day'', ''called'', 50, 0)');
    perform set_config('app.user_id', v_analyst1::text, true);
    rows_ := rows_ || pg_temp.v9zr_row(13, 'W13', 'an agent is refused every read in the database (CMA06)',
      v_txt = 'CMA06,CMA06,CMA06,CMA06', v_txt);

    raise exception using errcode = 'CMAOK';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      rows_ := rows_ || array['99', 'block ended early', 'FAIL', 'FAIL block: error ' || sqlstate || ': ' || sqlerrm];
  end;
  perform set_config('role', 'cma_owner', true);
  insert into verify_0009zr (ord, check_name, result, detail)
  select rows_[4 * i - 3]::integer, rows_[4 * i - 2], rows_[4 * i - 1], rows_[4 * i] from generate_series(1, cardinality(rows_) / 4) i;
  insert into verify_0009zr values (98, 'ran to the end',
    case when v_provoke or cardinality(rows_) / 4 <> 12 or '99' = any (rows_) then 'FAIL' else 'OK' end,
    format('%s fixture rows', cardinality(rows_) / 4));
end
$$;

drop function if exists pg_temp.v9zr_w3(uuid);
drop function if exists pg_temp.v9zr_w4(uuid);
drop function if exists pg_temp.v9zr_w5(uuid);
drop function if exists pg_temp.v9zr_open_leads_234(uuid);
drop function if exists pg_temp.v9zr_stl_234(uuid, timestamptz, timestamptz);
drop function if exists pg_temp.v9zr_code(text);
drop function if exists pg_temp.v9zr_row(integer, text, text, boolean, text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009zr
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009zr where result <> 'OK') then 'FAIL'
                  when (select count(*) from pg_temp.verify_0009zr where result = 'OK') <> 14 then 'FAIL'
                  else 'PASS 0009zr' end,
             format('237_verify_speed_to_lead_cockpit: %s OK, %s FAIL', (select count(*) from pg_temp.verify_0009zr where result = 'OK'),
                    (select count(*) from pg_temp.verify_0009zr where result <> 'OK'))) x
order by ord;
