-- =============================================================================================
-- 76_audit_hardening.sql: addition 0008q, what the IT audit of 17 October 2026 changes in the database
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 74_forms_reporting.sql (0008p). Rerunnable, forward-only, in one transaction with a lock timeout.
-- Run as your own IAM login, dev first, then prod; then 77_verify_audit_hardening.sql (dev), then
-- 55_verify_uncounted_lines.sql, 61_verify_inbound_service.sql, 63_verify_calls_overview.sql,
-- 65_verify_calls_history_start.sql and 41_verify_lead_metrics.sql (dev) again (unchanged).
--
-- Full IT audit of 17 October 2026 (README Decision log; docs/audits/2026-10-17-full-audit, findings
-- DB-01, DB-02, DB-04, DB-05, DB-06, DB-07, DB-08, DP-01; backlog CMA-037 item 2 and CMA-060 parts 1 and 3).
--
-- What it changes
--   1. the uncounted-line trigger   cma.remove_calls_of_uncounted_line() asserts the acting person's
--                                    tenant.configure before it removes a line's calls (CMA01 without an
--                                    acting user unless the owner runs it, CMA06 without the right), as
--                                    cma.set_telephony_number() does; the trigger, its owner, its search
--                                    path and its rights are unchanged (55 A2 still holds). Before, a direct
--                                    update of is_counted by the Ingest service account removed a line's
--                                    calls with an audit trail naming no person (CMA-037 item 2)
--   2. the audit image of events    cma.audit_row() leaves the payload (raw) out of ingest_event's images:
--                                    the event row keeps the one copy, the audit kept five (the insert and
--                                    two updates, old and new); the log's growth driver (DB-02)
--   3. report cores on the index    cma.calls_of, cma.inbound_calls_of and cma.lead_deals_of bound their
--                                    period with coalesce(p_from, '-infinity') and coalesce(p_to, 'infinity')
--                                    instead of (p is null or ...), so the (tenant, time) indexes serve the
--                                    period; the same rows, the same signatures (DB-04)
--   4. ingest_event indexes         (tenant_id, connection_id, recorded_at desc) for the 24-hour count and
--                                    the last event of cma.sources(), and a partial index on the events
--                                    parked for review (DB-05)
--   5. deletes the application      DELETE revoked from cma_app on app_user, app_role, organisation, channel
--      never makes                  and role_permission: no function or route deletes from them (CMA-060
--                                    part 1); the set-replace deletes of the other master-data tables stay
--                                    until their functions move to validity columns (part 2)
--   6. execute rights of 0001-0003a nine write and read functions of the first migrations lose their PUBLIC
--                                    execute (the convention since 0003b); the helpers every role's
--                                    defaults, checks and triggers call stay as they are (DB-07)
--   7. search paths                  cma.find_tenants_for_identity() and cma.ingest_connection() pin
--                                    pg_catalog, cma, pg_temp like every other SECURITY DEFINER function (DB-08)
--   8. telephony raw                 cma.telephony_raw() drops a string value that holds an @, as the email
--                                    and task filters do (DP-01)
--
-- SQLSTATEs as before: CMA01 no acting user, CMA06 not permitted.
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
  if not exists (select 1 from cma.schema_migration where version = '0008p') then
    raise exception 'addition 0008p (74_forms_reporting.sql) must run before 0008q';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The uncounted-line trigger asserts the acting person's right
-- ---------------------------------------------------------------------------------------------
-- The role GUC keeps the outer SET ROLE inside a SECURITY DEFINER function, and a login without one
-- counts as itself: so the owner (a migration or a one-off under a personal login that set role
-- cma_owner) may switch a line off without an acting person, and the service accounts, members of
-- cma_app only, may not. An acting person needs tenant.configure, as on the screen.
create or replace function cma.remove_calls_of_uncounted_line()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, cma, pg_temp
as $$
declare
  v_user uuid := cma.current_user_id();
  v_role text := coalesce(nullif(current_setting('role', true), 'none'), session_user::text);
begin
  if new.is_counted or (tg_op = 'UPDATE' and not old.is_counted) then
    return null;                                        -- nothing switches off
  end if;
  if v_user is not null then
    if new.tenant_id is distinct from cma.current_tenant_id() then
      raise exception 'line % belongs to another tenant than the acting person', new.number_ref using errcode = 'CMA06';
    end if;
    perform cma.assert_permission('tenant.configure');
  elsif not pg_has_role(v_role, 'cma_owner', 'member') then
    raise exception 'switching line % off needs an acting person with tenant.configure (app.user_id is not set)', new.number_ref
      using errcode = 'CMA01';
  end if;
  perform cma.remove_uncounted_line_calls(new.tenant_id, new.connection_id, new.number_ref);
  return null;
end
$$;
alter function cma.remove_calls_of_uncounted_line() owner to cma_owner;
revoke execute on function cma.remove_calls_of_uncounted_line() from public;

-- ---------------------------------------------------------------------------------------------
-- 2. The audit image of an ingest event carries no payload
-- ---------------------------------------------------------------------------------------------
-- As 0008l left it, plus: ingest_event's raw is left out of both images. The event row itself keeps
-- the payload (filtered by the adapter), and its status transitions are deterministic, so the audit
-- loses no evidence; it loses the five copies of every webhook payload it kept.
create or replace function cma.audit_row()
returns trigger
language plpgsql
as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
begin
  if tg_op = 'DELETE' and tg_table_schema = 'cma'
     and tg_table_name in ('telephony_call', 'telephony_call_tag', 'call_link')
     and coalesce(current_setting('cma.audit_keys_only', true), '') = 'uncounted_line' then
    v_old := jsonb_strip_nulls(jsonb_build_object(
      'id', v_old -> 'id', 'tenant_id', v_old -> 'tenant_id', 'connection_id', v_old -> 'connection_id',
      'source_id', v_old -> 'source_id', 'call_source_id', v_old -> 'call_source_id', 'tag_ref', v_old -> 'tag_ref',
      'telephony_call_id', v_old -> 'telephony_call_id', 'crm_call_id', v_old -> 'crm_call_id',
      'reason', 'uncounted_line'));
  end if;
  if tg_table_schema = 'cma' and tg_table_name = 'invitation' then
    v_old := v_old - 'token_hash';
    v_new := v_new - 'token_hash';
  end if;
  if tg_table_schema = 'cma' and tg_table_name = 'ingest_event' then
    v_old := v_old - 'raw';
    v_new := v_new - 'raw';
  end if;
  insert into cma.audit_log (tenant_id, table_name, action, old_row, new_row, actor_user_id, actor_label)
  values (
    (coalesce(v_new, v_old) ->> 'tenant_id')::uuid,
    tg_table_name,
    lower(tg_op),
    v_old,
    v_new,
    cma.current_user_id(),
    cma.current_actor_label()
  );
  return null;   -- after trigger, return value is ignored
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The report cores bound their period in a way the index serves
-- ---------------------------------------------------------------------------------------------
-- (p is null or col >= p) is not an index condition; col >= coalesce(p, '-infinity') is, and a null
-- parameter keeps today's meaning (no bound). Everything else in the three functions is as 0008j,
-- 0008i and 0007d left it.
create or replace function cma.calls_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz, p_market text, p_line text)
returns table(connection_id uuid, source_system text, direction text, line_key text, line_name text, market text, zone text,
              started_at timestamptz, business_date date, week_start date, local_time time, user_ref text,
              is_answered_inbound boolean, is_connected_outbound boolean, is_conversation boolean, talk_seconds integer,
              tag_refs text[], is_tagged boolean)
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
      and tc.started_at >= coalesce(p_from, '-infinity'::timestamptz)
      and tc.started_at < coalesce(p_to, 'infinity'::timestamptz)
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
    select tc.*, n.name as n_name, m.code as m_code, coalesce(m.time_zone, s.tenant_zone) as z,
           (tc.answered_at is null and tc.ended_at is null
            and tc.started_at >= now() - make_interval(mins => s.waiting_max)) as waiting
    from cma.telephony_call tc
    cross join s
    left join cma.telephony_number n
      on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
    left join cma.market m on m.tenant_id = tc.tenant_id and m.code = n.market
    where tc.tenant_id = p_tenant_id
      and tc.direction = 'inbound'
      and tc.source_deleted_at is null
      and tc.started_at is not null
      and coalesce(n.is_counted, true)
      and tc.started_at >= coalesce(p_from, '-infinity'::timestamptz)
      and tc.started_at < coalesce(p_to, 'infinity'::timestamptz)
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

create or replace function cma.lead_deals_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns table(deal_id uuid, connection_id uuid, source_system text, record_type text, source_id text, pipeline_id text,
              pipeline_label text, owner_ref text, contact_source_id text, is_closed boolean, created_at timestamptz,
              business_date date, market text, market_source text, contacts text[])
language sql stable
as $$
  with s as (
    select t.timezone as zone, cma.setting_of(t.id, 'intake.start_date')::date as start_date
    from cma.tenant t where t.id = p_tenant_id
  )
  select d.id, d.connection_id, d.source_system, d.record_type, d.source_id, d.pipeline_id,
         coalesce(p.label, d.pipeline_id), d.owner_ref, d.contact_source_id, coalesce(d.is_closed, false),
         d.source_created_at, (d.source_created_at at time zone s.zone)::date, rm.code, rm.source,
         array(select x from (select d.contact_source_id as x where d.contact_source_id is not null
                              union
                              select a.to_id from cma.crm_association a
                              where a.tenant_id = d.tenant_id and a.connection_id = d.connection_id
                                and a.from_type = d.record_type and a.from_id = d.source_id
                                and a.to_type = 'contact' and a.removed_at is null) c
               order by x)
  from cma.crm_record d
  cross join s
  left join cma.connection_pipeline p
    on p.tenant_id = d.tenant_id and p.connection_id = d.connection_id
   and p.record_type = d.record_type and p.source_pipeline_id = d.pipeline_id
  cross join lateral cma.record_market_of(d.tenant_id, d.connection_id, d.market, d.contact_source_id) rm
  where d.tenant_id = p_tenant_id
    and d.record_type = 'deal'
    and d.source_deleted_at is null
    and coalesce(p.is_counted, true) and coalesce(p.is_lead, true)
    and d.source_created_at >= (s.start_date::timestamp at time zone s.zone)
    and d.source_created_at >= coalesce(p_from, '-infinity'::timestamptz)
    and d.source_created_at < coalesce(p_to, 'infinity'::timestamptz)
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. ingest_event: the indexes cma.sources() reads
-- ---------------------------------------------------------------------------------------------
create index if not exists ingest_event_recorded_idx on cma.ingest_event (tenant_id, connection_id, recorded_at desc);
create index if not exists ingest_event_needs_review_idx on cma.ingest_event (tenant_id, connection_id) where status = 'needs_review';

-- ---------------------------------------------------------------------------------------------
-- 5. Deletes the application never makes (CMA-060 part 1)
-- ---------------------------------------------------------------------------------------------
revoke delete on cma.app_user, cma.app_role, cma.organisation, cma.channel, cma.role_permission from cma_app;

-- ---------------------------------------------------------------------------------------------
-- 6. Execute rights of the first migrations' functions: the application only (DB-07)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.open_workday(timestamptz)', 'cma.end_workday(uuid, timestamptz, text)', 'cma.set_status(uuid, text, timestamptz)',
    'cma.correct_workday(uuid, date, jsonb, text)', 'cma.correct_time_event(uuid, text, timestamptz, text, uuid, text, uuid)',
    'cma.refresh_workday(uuid)', 'cma.team_hours(date, date, uuid)', 'cma.team_people()', 'cma.user_permissions(uuid)'
  ] loop
    if to_regprocedure(f) is null then
      raise exception 'function % not found: check its signature against the database', f;
    end if;
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Search paths of the two early SECURITY DEFINER functions (DB-08)
-- ---------------------------------------------------------------------------------------------
alter function cma.find_tenants_for_identity(text, text) set search_path = pg_catalog, cma, pg_temp;
alter function cma.ingest_connection(text) set search_path = pg_catalog, cma, pg_temp;

-- ---------------------------------------------------------------------------------------------
-- 8. telephony_raw drops a string that holds an @ (DP-01)
-- ---------------------------------------------------------------------------------------------
create or replace function cma.telephony_raw(p_raw jsonb)
returns jsonb
language sql immutable
as $$
  select coalesce((
    select jsonb_object_agg(e.key, e.value)
    from (select e.key, e.value
          from jsonb_each(case when jsonb_typeof(p_raw) = 'object' then p_raw else '{}'::jsonb end) e
          where e.key ~ '^[A-Za-z0-9_.-]{1,60}$'
            and e.key !~* '(digit|phone|number|e164|email|mail|name|comment|note|record|voicemail|asset|contact|address|body|content|link|url|transcript|summary)'
            and (jsonb_typeof(e.value) in ('number', 'boolean')
                 or (jsonb_typeof(e.value) = 'string'
                     and length(e.value #>> '{}') <= 200
                     and (e.value #>> '{}') !~ '@'
                     and not ((e.value #>> '{}') ~ '^\+?[0-9 ().-]{7,20}$' and (e.value #>> '{}') !~ '^\d{4}-\d{2}-\d{2}')))
          order by e.key
          limit 50) e), '{}'::jsonb)
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008q', 'Audit hardening (17 October 2026): switching a line off asserts the acting person''s tenant.configure inside the trigger; no payload in ingest_event''s audit images; the report cores bound their period on the index; indexes for the sources read; DELETE revoked from the application on five master-data tables; PUBLIC execute revoked on nine early functions; two SECURITY DEFINER search paths completed; telephony raw without @ strings')
on conflict (version) do nothing;

commit;
reset role;
