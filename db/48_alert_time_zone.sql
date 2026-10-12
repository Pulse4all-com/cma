-- =============================================================================================
-- 48_alert_time_zone.sql: addition 0008c, alert times in the tenant's time zone
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 46_workday_window.sql (0008b). Rerunnable, forward-only, in one transaction. Run as your own IAM
-- login, dev first, then prod; then 49_verify_alert_time_zone.sql (dev), then
-- 45_verify_assignment_alerts.sql and 47_verify_workday_window.sql again (unchanged).
--
-- What it changes (README Decision log, 12 October 2026)
--   alert times        the body of a created alert ("created HH:MI") and of an assignment alert
--                      ("assigned HH:MI") shows the time in the tenant's zone (cma.tenant.timezone),
--                      no longer in the market's zone: agents work in the tenant's zone, and a GB
--                      deal showed London time ("assigned 10:17" on a message stamped 11:17, prod,
--                      12 October 2026). cma.ingest_record_alerts() and cma.ingest_assignment_alerts()
--                      are copied from 44_assignment_alerts.sql with only that expression changed;
--                      their signatures, privileges, conflict targets and everything else stay
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
  if not exists (select 1 from cma.schema_migration where version = '0008b') then
    raise exception 'addition 0008b (46_workday_window.sql) must run before 0008c';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Record alerts of 0008a, the time in the tenant's zone (otherwise unchanged)
-- ---------------------------------------------------------------------------------------------
create or replace function cma.ingest_record_alerts(p_connection_id uuid, p_record_type text, p_source_ids text[])
returns integer
language plpgsql
as $$
declare
  v_tenant     uuid := cma.current_tenant_id();
  v_system     text;
  v_default    integer;
  v_zone       text;
  r            record;
  m            cma.market;
  v_market     text;
  v_users      uuid[];
  v_fallback   boolean;
  v_msg        uuid;
  v_written    integer := 0;
begin
  perform cma.assert_permission('ingest.write');
  v_system := cma.active_connection_adapter(p_connection_id);
  if coalesce(p_record_type, '') !~ '^[a-z][a-z0-9_]*$' then
    raise exception 'a record type is needed' using errcode = 'CMA04';
  end if;
  if p_source_ids is null or cardinality(p_source_ids) > 500 then
    raise exception 'source ids must be an array of at most 500' using errcode = 'CMA04';
  end if;
  v_default := coalesce((select s.value::integer from cma.tenant_settings() s where s.key = 'alerts.max_age_minutes'), 60);
  select t.timezone into v_zone from cma.tenant t where t.id = v_tenant;

  for r in
    select cr.source_id, cr.market, cr.pipeline_id, cr.source_created_at, cc.country,
           coalesce(p.label, cr.pipeline_id) as pipeline_label,
           coalesce(p.is_counted, true) as pipeline_counted,
           ru.id as rule_id, ru.name as rule_name, ru.pipeline_ids, ru.audience_permission, ru.match_language,
           ru.only_clocked_in, ru.fallback_permission, ru.urgency, coalesce(ru.max_age_minutes, v_default) as max_age
    from cma.crm_record cr
    join cma.message_rule ru
      on ru.tenant_id = cr.tenant_id and ru.enabled and ru.trigger = 'record_created' and ru.record_type = cr.record_type
    left join cma.connection_pipeline p
      on p.tenant_id = cr.tenant_id and p.connection_id = cr.connection_id and p.record_type = cr.record_type
     and p.source_pipeline_id = cr.pipeline_id
    left join cma.crm_contact cc
      on cc.tenant_id = cr.tenant_id and cc.connection_id = cr.connection_id and cc.source_id = cr.contact_source_id
     and cc.source_deleted_at is null
    where cr.tenant_id = v_tenant and cr.connection_id = p_connection_id and cr.record_type = p_record_type
      and cr.source_id = any (p_source_ids)
      and cr.source_deleted_at is null
    order by cr.source_created_at, cr.source_id, ru.name
  loop
    if r.source_created_at < now() - make_interval(mins => r.max_age) then
      continue;
    end if;
    if cardinality(r.pipeline_ids) = 0 then
      if not r.pipeline_counted then
        continue;
      end if;
    elsif r.pipeline_id is null or not (r.pipeline_id = any (r.pipeline_ids)) then
      continue;
    end if;
    if exists (select 1 from cma.message x
               where x.tenant_id = v_tenant and x.rule_id = r.rule_id and x.ref_system = v_system
                 and x.ref_type = p_record_type and x.ref_id = r.source_id) then
      continue;
    end if;

    v_market := coalesce(r.market, r.country);
    m := null;
    select * into m from cma.market mk where mk.tenant_id = v_tenant and mk.code = v_market;

    select coalesce(array_agg(u.id order by u.id), '{}') into v_users
    from cma.app_user u
    where u.tenant_id = v_tenant and u.status = 'active' and u.kind = 'person'
      and cma.has_permission(u.id, r.audience_permission)
      and (not r.only_clocked_in or cma.is_clocked_in(u.id))
      and (not r.match_language
           or (m.id is not null
               and (m.language_skill_key is null
                    or cma.has_skill(u.id, 'language', m.language_skill_key, m.min_language_level))));
    v_fallback := cardinality(v_users) = 0 and r.fallback_permission is not null;
    if v_fallback then
      select coalesce(array_agg(u.id order by u.id), '{}') into v_users
      from cma.app_user u
      where u.tenant_id = v_tenant and u.status = 'active' and u.kind = 'person'
        and cma.has_permission(u.id, r.fallback_permission);
    end if;

    v_msg := null;
    insert into cma.message (tenant_id, kind, urgency, title, body, ref_system, ref_type, ref_id, ref_url, rule_id,
                             target, sender_user_id)
    values (v_tenant, 'alert', r.urgency,
            'New ' || replace(p_record_type, '_', ' '),
            left(coalesce(m.code, v_market, 'unknown') || ' · ' || coalesce(r.pipeline_label, '-') || ' · created '
                 || to_char(r.source_created_at at time zone v_zone, 'HH24:MI'), 500),
            v_system, p_record_type, r.source_id, cma.record_url(p_connection_id, p_record_type, r.source_id), r.rule_id,
            jsonb_build_object('rule', r.rule_name, 'permission', r.audience_permission, 'market', v_market,
                               'matchLanguage', r.match_language, 'onlyClockedIn', r.only_clocked_in,
                               'fallback', v_fallback),
            cma.current_user_id())
    on conflict (tenant_id, rule_id, ref_system, ref_type, ref_id) where rule_id is not null and not (target ? 'assignee') do nothing
    returning id into v_msg;
    if v_msg is not null then
      perform cma.deliver_message(v_msg, v_users);
      v_written := v_written + 1;
    end if;
  end loop;
  return v_written;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. Assignment alerts of 0008a, the time in the tenant's zone (otherwise unchanged)
-- ---------------------------------------------------------------------------------------------
create or replace function cma.ingest_assignment_alerts(p_connection_id uuid, p_record_type text, p_source_ids text[])
returns integer
language plpgsql
as $$
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_system   text;
  v_default  integer;
  v_zone     text;
  r          record;
  m          cma.market;
  v_market   text;
  v_user     uuid;
  v_msg      uuid;
  v_written  integer := 0;
begin
  perform cma.assert_permission('ingest.write');
  v_system := cma.active_connection_adapter(p_connection_id);
  if coalesce(p_record_type, '') !~ '^[a-z][a-z0-9_]*$' then
    raise exception 'a record type is needed' using errcode = 'CMA04';
  end if;
  if p_source_ids is null or cardinality(p_source_ids) > 500 then
    raise exception 'source ids must be an array of at most 500' using errcode = 'CMA04';
  end if;
  v_default := coalesce((select s.value::integer from cma.tenant_settings() s where s.key = 'alerts.max_age_minutes'), 60);
  select t.timezone into v_zone from cma.tenant t where t.id = v_tenant;

  for r in
    select cr.source_id, cr.market, cr.pipeline_id, cr.owner_ref, cc.country,
           greatest(cr.source_created_at, cr.source_updated_at) as changed_at,
           coalesce(p.label, cr.pipeline_id) as pipeline_label,
           coalesce(p.is_counted, true) as pipeline_counted,
           ru.id as rule_id, ru.name as rule_name, ru.pipeline_ids, ru.urgency, coalesce(ru.max_age_minutes, v_default) as max_age
    from cma.crm_record cr
    join cma.message_rule ru
      on ru.tenant_id = cr.tenant_id and ru.enabled and ru.trigger = 'record_assigned' and ru.record_type = cr.record_type
    left join cma.connection_pipeline p
      on p.tenant_id = cr.tenant_id and p.connection_id = cr.connection_id and p.record_type = cr.record_type
     and p.source_pipeline_id = cr.pipeline_id
    left join cma.crm_contact cc
      on cc.tenant_id = cr.tenant_id and cc.connection_id = cr.connection_id and cc.source_id = cr.contact_source_id
     and cc.source_deleted_at is null
    where cr.tenant_id = v_tenant and cr.connection_id = p_connection_id and cr.record_type = p_record_type
      and cr.source_id = any (p_source_ids)
      and cr.source_deleted_at is null and cr.owner_ref is not null
    order by cr.source_created_at, cr.source_id, ru.name
  loop
    if r.changed_at is null or r.changed_at < now() - make_interval(mins => r.max_age) then
      continue;
    end if;
    if cardinality(r.pipeline_ids) = 0 then
      if not r.pipeline_counted then
        continue;
      end if;
    elsif r.pipeline_id is null or not (r.pipeline_id = any (r.pipeline_ids)) then
      continue;
    end if;
    select x.user_id into v_user
    from cma.app_user_external_id x
    join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
    where x.tenant_id = v_tenant and x.system = v_system || '_owner' and x.external_id = r.owner_ref
      and u.status = 'active' and u.kind = 'person';
    if v_user is null then
      continue;
    end if;
    if exists (select 1 from cma.message x
               where x.tenant_id = v_tenant and x.rule_id = r.rule_id and x.ref_system = v_system
                 and x.ref_type = p_record_type and x.ref_id = r.source_id and x.target ->> 'assignee' = r.owner_ref) then
      continue;
    end if;

    v_market := coalesce(r.market, r.country);
    m := null;
    select * into m from cma.market mk where mk.tenant_id = v_tenant and mk.code = v_market;

    v_msg := null;
    insert into cma.message (tenant_id, kind, urgency, title, body, ref_system, ref_type, ref_id, ref_url, rule_id,
                             target, sender_user_id)
    values (v_tenant, 'alert', r.urgency,
            'New ' || replace(p_record_type, '_', ' ') || ' assigned to you',
            left(coalesce(m.code, v_market, 'unknown') || ' · ' || coalesce(r.pipeline_label, '-') || ' · assigned '
                 || to_char(r.changed_at at time zone v_zone, 'HH24:MI'), 500),
            v_system, p_record_type, r.source_id, cma.record_url(p_connection_id, p_record_type, r.source_id), r.rule_id,
            jsonb_build_object('rule', r.rule_name, 'assignee', r.owner_ref, 'market', v_market),
            cma.current_user_id())
    on conflict (tenant_id, rule_id, ref_system, ref_type, ref_id, (target ->> 'assignee')) where rule_id is not null and target ? 'assignee' do nothing
    returning id into v_msg;
    if v_msg is not null then
      perform cma.deliver_message(v_msg, array[v_user]);
      v_written := v_written + 1;
    end if;
  end loop;
  return v_written;
end
$$;

insert into cma.schema_migration (version, description)
values ('0008c', 'Alert times in the tenant''s time zone: the created and assigned time in the body of record and assignment alerts uses the tenant''s zone, not the market''s')
on conflict (version) do nothing;

commit;
reset role;
