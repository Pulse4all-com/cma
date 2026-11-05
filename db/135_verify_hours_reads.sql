-- =============================================================================================
-- 135_verify_hours_reads.sql: verifies addition 0008zs, the hours reads at volume (N06d, 6 November 2026)
-- =============================================================================================
-- Universal: no seed is assumed. Block S checks the addition row, the columns and the grants; block E proves the two
-- views and cma.team_hours answer exactly what they did, on the database it runs in (the hours fixture locally, dev's
-- and prod's own data): the previous definitions are kept here as temporary views and a temporary function (46's
-- time_interval_all, 50's workday_summary_all, 09's team_hours, 19's team_now, copied verbatim with pg_temp.old_ in place of cma.),
-- and the two are compared row for row, every tenant at once as the owner for the views, and per active tenant as
-- the application acting as the tenant's first person holding workday.team for the function (a tenant without one
-- reads skip; the function's previous body reads the face the view check has just proven equal, so the comparison
-- stays within a minute at volume). The sessions column is compared with the count the web made per row before (0008zp). Every check
-- writes one row, ok or FAIL, and the last row is the verdict, because Cloud SQL Studio shows no notices. Run as your
-- own IAM login after 134_hours_reads.sql, dev first, then prod. now() is one instant inside the transaction, so an
-- open day's stretches read the same on both sides.
-- Expected verdict, in dev and in prod: "0008zs verified | 135_verify_hours_reads: <n> ok, 0 FAIL, <k> skip";
-- provoked (verify.provoke true at the top): every E row reads FAIL (the previous definition's first row is dropped
-- before the comparison, or the row says the set was empty), every S row reads FAIL, and the verdict PROVOKED, NOT A
-- PASS.
--   S  the addition row after 0008zr; time_interval_all's columns unchanged; workday_summary_all's and the face's
--      columns as before, the face with sessions last; team_hours's columns with sessions last, executable by cma_app
--      only; cma.workday_stretches_of and cma.workday_summary_of present with the caller's rights for the application;
--      the readers' wrappers with the owner's rights for cma_readonly alone; the readers' views keep their columns
--   E  time_interval_all row for row; workday_summary_all row for row; sessions on the face against the per-row count; team_hours for the last 7 days, 31 days, 92 days and the tenant's first person, in order;
--      team_now against 19's join, in order, as the first person holding monitoring.live
--   A  the rights: as the application the day functions answer the own tenant's day only (another tenant's id or no
--      tenant set gives nothing, by row-level security); as a reader cma_read.workday_summary and cma_read.time_interval
--      read every tenant, through the wrappers, as many rows as the owner's core views hold
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

drop table if exists pg_temp.verify_0008zs;
create temporary table verify_0008zs (ord integer, check_name text, result text, detail text);
grant select, insert on pg_temp.verify_0008zs to cma_app;

-- The previous definitions, verbatim, under pg_temp.old_
-- time_interval_all as 46 defined it
create temporary view old_time_interval_all as
  with ordered as (
    select e.tenant_id, e.workday_id, e.user_id, e.id as event_id, e.kind, e.status_id, e.occurred_at,
           lead(e.occurred_at) over (partition by e.workday_id order by e.occurred_at, e.recorded_at, e.id) as next_at,
           cma.business_day_time(w.business_date, w.timezone,
             (select coalesce(ts.value, st.default_value)::time
              from cma.setting st
              left join cma.tenant_setting ts on ts.tenant_id = w.tenant_id and ts.key = st.key
              where st.key = 'workday.window_end')) as day_end
    from cma.time_event_effective_all e
    join cma.workday w on w.tenant_id = e.tenant_id and w.id = e.workday_id
  )
  select tenant_id, workday_id, user_id, event_id, status_id,
         occurred_at as from_at,
         next_at     as to_at,
         next_at is null as is_open,
         next_at is null and now() > day_end as is_capped,
         greatest(0, floor(extract(epoch from (least(coalesce(next_at, now()), day_end) - occurred_at))))::bigint as seconds
  from ordered
  where kind in ('start', 'status');

-- workday_summary_all as 50 defined it, over the old stretches
create temporary view old_workday_summary_all as
  select w.id as workday_id, w.tenant_id, w.user_id, w.business_date, w.timezone, w.status,
         w.started_at, w.ended_at,
         coalesce(sum(i.seconds) filter (where s.is_working),    0)::bigint as working_seconds,
         coalesce(sum(i.seconds) filter (where s.is_productive), 0)::bigint as productive_seconds,
         coalesce(sum(i.seconds) filter (where s.is_paid),       0)::bigint as paid_seconds,
         coalesce(sum(i.seconds) filter (where s.is_billable),   0)::bigint as billable_seconds,
         coalesce(bool_or(i.is_capped), false) as is_capped,
         ((w.status = 'open'
           and now() > cma.business_day_time(w.business_date, w.timezone,
                         (select coalesce(ts.value, st.default_value)::time
                          from cma.setting st
                          left join cma.tenant_setting ts on ts.tenant_id = w.tenant_id and ts.key = st.key
                          where st.key = 'workday.window_end')))
          or exists (select 1 from cma.time_event_effective_all e
                     where e.tenant_id = w.tenant_id and e.workday_id = w.id and e.kind = 'end' and e.source = 'system')
          or exists (select 1 from cma.import_day d
                     join cma.time_event_effective_all e on e.tenant_id = d.tenant_id and e.id = d.end_event_id
                     where d.tenant_id = w.tenant_id and d.workday_id = w.id and (d.closed_by_rule or d.clipped))) as needs_correction,
         exists (select 1 from cma.time_event e
                 where e.tenant_id = w.tenant_id and e.workday_id = w.id and e.source = 'correction') as has_correction,
         (select e.status_id from cma.time_event_effective_all e
          where e.tenant_id = w.tenant_id and e.workday_id = w.id and e.kind in ('start', 'status')
          order by e.occurred_at desc, e.recorded_at desc limit 1) as current_status_id
  from cma.workday w
  left join pg_temp.old_time_interval_all i on i.tenant_id = w.tenant_id and i.workday_id = w.id
  left join cma.work_status s on s.tenant_id = i.tenant_id and s.id = i.status_id
  where exists (select 1 from cma.time_event_effective_all e
                where e.tenant_id = w.tenant_id and e.workday_id = w.id and e.kind = 'start')
  group by w.id;

-- team_hours as 09 defined it, with the sessions the web counted per row (0008zp). It reads cma.workday_summary, the
-- face E2 has just proven equal to the previous one column for column: reading the previous summary here instead
-- would compute the whole history for every comparison (minutes at volume) and prove nothing more
create function pg_temp.old_team_hours(p_from date, p_to date, p_user_id uuid default null)
returns table (
  user_id uuid, display_name text, organisation_name text, business_date date, timezone text, status text,
  started_at timestamptz, ended_at timestamptz, working_seconds bigint, paid_seconds bigint,
  is_capped boolean, needs_correction boolean, has_correction boolean, sessions integer
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('workday.team');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 91 then
    raise exception 'the range must run forward and cover at most 92 days' using errcode = 'CMA04';
  end if;
  return query
    select s.user_id, u.display_name::text, coalesce(o.name, '')::text, s.business_date, s.timezone::text,
           s.status::text, s.started_at, s.ended_at, s.working_seconds, s.paid_seconds,
           s.is_capped, s.needs_correction, s.has_correction,
           (select count(*) from cma.time_event_effective e
              join cma.workday w on w.tenant_id = e.tenant_id and w.id = e.workday_id
             where w.user_id = s.user_id and w.business_date = s.business_date and e.kind = 'start')::int
    from cma.workday_summary s
    join cma.app_user u on u.tenant_id = s.tenant_id and u.id = s.user_id
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    where s.business_date between p_from and p_to
      and (p_user_id is null or s.user_id = p_user_id)
    order by s.business_date, u.display_name, s.user_id;
end
$$;
grant execute on function pg_temp.old_team_hours(date, date, uuid) to cma_app;

-- team_now as 19 defined it (a plain join on the person and the date), over the same views
create function pg_temp.old_team_now()
returns table (
  user_id            uuid,
  display_name       text,
  organisation_key   text,
  organisation_name  text,
  timezone           text,
  business_date      date,          -- today in the person's zone
  workday_id         uuid,          -- null when the person has no day today
  day_status         text,          -- 'open', 'ended', or null without a day
  started_at         timestamptz,
  ended_at           timestamptz,
  status_key         text,          -- the day's current (or, once ended, last) status
  status_name        text,
  status_active      boolean,
  is_working         boolean,
  is_productive      boolean,
  is_paid            boolean,
  is_billable        boolean,
  status_since       timestamptz,   -- start of the open stretch; null once the day ended
  closed_seconds     bigint,        -- worked seconds in the closed stretches (is_working)
  running_since      timestamptz    -- start of the open stretch when it is a working one
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('monitoring.live');
  return query
    select u.id, u.display_name::text, o.key::text, coalesce(o.name, '')::text, tz.zone::text,
           cma.business_date(now(), tz.zone),
           s.workday_id, s.status::text, s.started_at, s.ended_at,
           ws.key::text, ws.name::text, (ws.status = 'active'),
           ws.is_working, ws.is_productive, ws.is_paid, ws.is_billable,
           c.status_since,
           coalesce(c.closed_seconds, 0)::bigint,
           c.running_since
    from cma.app_user u
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    cross join lateral (select cma.user_timezone(u.id) as zone) tz
    left join cma.workday_summary s
           on s.user_id = u.id and s.business_date = cma.business_date(now(), tz.zone)
    left join cma.work_status ws
           on ws.tenant_id = u.tenant_id and ws.id = s.current_status_id
    left join lateral (
      select sum(i.seconds) filter (where iws.is_working and (not i.is_open or i.is_capped)) as closed_seconds,
             max(i.from_at) filter (where iws.is_working and i.is_open and not i.is_capped)  as running_since,
             max(i.from_at) filter (where i.is_open and not i.is_capped)                     as status_since
      from cma.time_interval i
      join cma.work_status iws on iws.tenant_id = u.tenant_id and iws.id = i.status_id
      where i.workday_id = s.workday_id
    ) c on s.workday_id is not null
    where u.tenant_id = cma.current_tenant_id()
      and cma.time_is_kept(u.id)
    order by u.display_name, u.id;
end
$$;
grant execute on function pg_temp.old_team_now() to cma_app;

-- The comparison: the two statements' rows as sets (and in order where asked); provoke drops the old answer's first row
create or replace function pg_temp.v0008zs_diff(p_new text, p_old text, p_ordered boolean)
returns text
language plpgsql
as $$
declare
  v_old text := p_old;
  v_n_new bigint; v_n_old bigint; v_only_new bigint; v_only_old bigint; v_same boolean;
begin
  if current_setting('verify.provoke')::boolean then
    v_old := format('select * from (%s) z offset 1', p_old);
  end if;
  execute format('select count(*) from (%s) a', p_new) into v_n_new;
  execute format('select count(*) from (%s) a', v_old) into v_n_old;
  if current_setting('verify.provoke')::boolean and v_n_new = 0 then
    return 'provoked, but the set is empty: nothing to differ (FAIL by the switch)';
  end if;
  if p_ordered then
    execute format('select (select string_agg(a::text, ''|'' order by a.o) from (select row_number() over () as o, t from (%s) t) a) is not distinct from
                           (select string_agg(b::text, ''|'' order by b.o) from (select row_number() over () as o, t from (%s) t) b)', p_new, v_old) into v_same;
  else
    v_same := true;
  end if;
  execute format('select count(*) from ((%s) except all (%s)) a', p_new, v_old) into v_only_new;
  execute format('select count(*) from ((%s) except all (%s)) a', v_old, p_new) into v_only_old;
  if v_only_new = 0 and v_only_old = 0 and v_same then
    return null;
  end if;
  return format('%s rows now against %s before: %s only now, %s only before%s', v_n_new, v_n_old, v_only_new, v_only_old,
                case when not v_same and v_only_new = 0 and v_only_old = 0 then ', the same rows in another order' else '' end);
end
$$;
grant execute on function pg_temp.v0008zs_diff(text, text, boolean) to cma_app;

-- The tenant's first active person (the oldest) holding a permission, as the time scripts pick it
create or replace function pg_temp.v0008zs_user(p_tenant uuid, p_perm text)
returns uuid
language sql
as $$
  select u.id from cma.app_user u
  where u.tenant_id = p_tenant and u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, p_perm)
  order by u.created_at, u.id limit 1
$$;

-- ---------------------------------------------------------------------------------------------
-- S. Structure and privileges
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_ok boolean; v_txt text;
begin
  v_ok := exists (select 1 from cma.schema_migration where version = '0008zs')
      and (select min(applied_at) from cma.schema_migration where version = '0008zs')
        >= (select min(applied_at) from cma.schema_migration where version = '0008zr');
  insert into verify_0008zs values (101, 'S1 addition 0008zs recorded after 0008zr', case when v_ok and not v_provoke then 'ok' else 'FAIL' end, '');

  select string_agg(column_name, ',' order by ordinal_position) into v_txt
  from information_schema.columns where table_schema = 'cma' and table_name = 'time_interval_all';
  v_ok := v_txt = 'tenant_id,workday_id,user_id,event_id,status_id,from_at,to_at,is_open,is_capped,seconds';
  insert into verify_0008zs values (102, 'S2 time_interval_all keeps its ten columns in their order', case when v_ok and not v_provoke then 'ok' else 'FAIL' end, coalesce(v_txt, 'no columns'));

  select string_agg(column_name, ',' order by ordinal_position) into v_txt
  from information_schema.columns where table_schema = 'cma' and table_name = 'workday_summary_all';
  v_ok := v_txt = 'workday_id,tenant_id,user_id,business_date,timezone,status,started_at,ended_at,working_seconds,productive_seconds,paid_seconds,billable_seconds,is_capped,needs_correction,has_correction,current_status_id';
  insert into verify_0008zs values (103, 'S3 workday_summary_all keeps its sixteen columns in their order (47 A4, 51 A5)', case when v_ok and not v_provoke then 'ok' else 'FAIL' end, coalesce(v_txt, 'no columns'));

  select string_agg(column_name, ',' order by ordinal_position) into v_txt
  from information_schema.columns where table_schema = 'cma' and table_name = 'workday_summary';
  v_ok := v_txt = 'workday_id,tenant_id,user_id,business_date,timezone,status,started_at,ended_at,working_seconds,productive_seconds,paid_seconds,billable_seconds,is_capped,needs_correction,has_correction,current_status_id,sessions';
  insert into verify_0008zs values (104, 'S4 the face workday_summary carries the sixteen columns and sessions last', case when v_ok and not v_provoke then 'ok' else 'FAIL' end, coalesce(v_txt, 'no columns'));

  select pg_get_function_result(p.oid) into v_txt from pg_proc p where p.oid = 'cma.team_hours(date, date, uuid)'::regprocedure;
  v_ok := v_txt like '%has_correction boolean, sessions integer)';
  insert into verify_0008zs values (105, 'S5 cma.team_hours returns sessions as its last column', case when v_ok and not v_provoke then 'ok' else 'FAIL' end, coalesce(v_txt, 'no function'));

  v_ok := has_function_privilege('cma_app', 'cma.team_hours(date, date, uuid)', 'execute')
      and not has_function_privilege('cma_readonly', 'cma.team_hours(date, date, uuid)', 'execute')
      and (select proconfig @> array['jit=off'] from pg_proc where oid = 'cma.team_hours(date, date, uuid)'::regprocedure)
      and (select proconfig @> array['jit=off'] from pg_proc where oid = 'cma.team_now()'::regprocedure)
      and not has_table_privilege('cma_app', 'cma.workday_summary_all', 'select')
      and not has_table_privilege('cma_app', 'cma.time_interval_all', 'select')
      and has_table_privilege('cma_app', 'cma.workday_summary', 'select');
  insert into verify_0008zs values (106, 'S6 team_hours executable by cma_app only, team_hours and team_now with jit off; the core views for the owner, the face for the application', case when v_ok and not v_provoke then 'ok' else 'FAIL' end, '');

  v_ok := to_regprocedure('cma.workday_stretches_of(uuid, uuid, timestamptz)') is not null
      and has_function_privilege('cma_app', 'cma.workday_stretches_of(uuid, uuid, timestamptz)', 'execute')
      and not has_function_privilege('cma_readonly', 'cma.workday_stretches_of(uuid, uuid, timestamptz)', 'execute')
      and (select provolatile = 's' and not prosecdef and prorows = 12 from pg_proc where oid = 'cma.workday_stretches_of(uuid, uuid, timestamptz)'::regprocedure)
      and to_regprocedure('cma.workday_summary_of(uuid, uuid, timestamptz)') is not null
      and has_function_privilege('cma_app', 'cma.workday_summary_of(uuid, uuid, timestamptz)', 'execute')
      and not has_function_privilege('cma_readonly', 'cma.workday_summary_of(uuid, uuid, timestamptz)', 'execute')
      and (select provolatile = 's' and not prosecdef and prorows = 1 from pg_proc where oid = 'cma.workday_summary_of(uuid, uuid, timestamptz)'::regprocedure);
  insert into verify_0008zs values (107, 'S7 the day functions exist, stable, the caller''s rights, 12 and 1 rows estimated, executable by the application and not by the readers or public', case when v_ok and not v_provoke then 'ok' else 'FAIL' end, '');

  v_ok := to_regprocedure('cma.workday_stretches_reader_of(uuid, uuid, timestamptz)') is not null
      and to_regprocedure('cma.workday_summary_reader_of(uuid, uuid, timestamptz)') is not null
      and (select bool_and(prosecdef and provolatile = 's') from pg_proc where oid in ('cma.workday_stretches_reader_of(uuid, uuid, timestamptz)'::regprocedure, 'cma.workday_summary_reader_of(uuid, uuid, timestamptz)'::regprocedure))
      and has_function_privilege('cma_readonly', 'cma.workday_summary_reader_of(uuid, uuid, timestamptz)', 'execute')
      and not has_function_privilege('cma_app', 'cma.workday_summary_reader_of(uuid, uuid, timestamptz)', 'execute')
      and not has_function_privilege('public', 'cma.workday_stretches_reader_of(uuid, uuid, timestamptz)', 'execute')
      and has_table_privilege('cma_readonly', 'cma_read.workday_summary', 'select')
      and (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns where table_schema = 'cma_read' and table_name = 'workday_summary')
          = 'workday_id,tenant_id,user_id,business_date,timezone,status,started_at,ended_at,working_seconds,productive_seconds,paid_seconds,billable_seconds,is_capped,needs_correction,has_correction,current_status_id'
      and (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns where table_schema = 'cma_read' and table_name = 'time_interval')
          = 'tenant_id,workday_id,user_id,event_id,status_id,from_at,to_at,is_open,is_capped,seconds';
  insert into verify_0008zs values (108, 'S8 the readers'' wrappers exist with the owner''s rights, the readers'' alone; cma_read.workday_summary and cma_read.time_interval keep their columns', case when v_ok and not v_provoke then 'ok' else 'FAIL' end, '');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- E. The same answers: the views for every tenant as the owner, the function per tenant as the application
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_diff text; v_n bigint;
begin
  v_diff := pg_temp.v0008zs_diff('select * from cma.time_interval_all', 'select * from pg_temp.old_time_interval_all', false);
  select count(*) into v_n from cma.time_interval_all;
  insert into verify_0008zs values (201, 'E1 time_interval_all: every stretch of every tenant as before', case when v_diff is null then 'ok' else 'FAIL' end, coalesce(v_diff, v_n || ' stretches'));

  v_diff := pg_temp.v0008zs_diff('select * from cma.workday_summary_all', 'select * from pg_temp.old_workday_summary_all', false);
  select count(*) into v_n from cma.workday_summary_all;
  insert into verify_0008zs values (202, 'E2 workday_summary_all: every day of every tenant as before, column for column', case when v_diff is null then 'ok' else 'FAIL' end, coalesce(v_diff, v_n || ' days'));

end
$$;

set role cma_app;
do $$
declare
  t record; v_user uuid; v_diff text; v_n bigint; i integer;
  v_ranges text[] := array['current_date - 6, current_date', 'current_date - 30, current_date', 'current_date - 91, current_date'];
  v_names text[] := array['7 days', '31 days', '92 days'];
begin
  -- The previous function's per-row count turns to a generic plan after five calls and then reads every event of the
  -- tenant per row (the cost 0008zs removes); this block compares answers, not speed, so it keeps the custom plans
  perform set_config('plan_cache_mode', 'force_custom_plan', true);
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug loop
    perform set_config('app.tenant_id', t.id::text, true), set_config('app.user_id', '', true), set_config('app.actor_label', 'verify-0008zs', true);
    v_user := pg_temp.v0008zs_user(t.id, 'workday.team');
    perform set_config('app.user_id', coalesce(v_user::text, ''), true);
    if v_user is null then
      insert into verify_0008zs values (210, 'E4 ' || t.slug || ' team_hours', 'skip', 'no active person holds workday.team: not compared');
      continue;
    end if;
    v_diff := pg_temp.v0008zs_diff(
      'select workday_id, sessions from cma.workday_summary',
      'select s.workday_id, (select count(*) from cma.time_event_effective e where e.workday_id = s.workday_id and e.kind = ''start'')::integer from cma.workday_summary s', false);
    insert into verify_0008zs values (203, 'E3 ' || t.slug || ' sessions on the face: each day''s effective clock-ins as the per-row count gave them', case when v_diff is null then 'ok' else 'FAIL' end, coalesce(v_diff, 'every day'));
    for i in 1..3 loop
      v_diff := pg_temp.v0008zs_diff(format('select * from cma.team_hours(%s, null)', v_ranges[i]), format('select * from pg_temp.old_team_hours(%s, null)', v_ranges[i]), true);
      execute format('select count(*) from cma.team_hours(%s, null)', v_ranges[i]) into v_n;
      insert into verify_0008zs values (210 + i, 'E4 ' || t.slug || ' team_hours ' || v_names[i] || ': the same rows in the same order, sessions included', case when v_diff is null then 'ok' else 'FAIL' end, coalesce(v_diff, v_n || ' rows'));
    end loop;
    v_diff := pg_temp.v0008zs_diff(format('select * from cma.team_hours(current_date - 30, current_date, %L)', v_user), format('select * from pg_temp.old_team_hours(current_date - 30, current_date, %L)', v_user), true);
    insert into verify_0008zs values (214, 'E5 ' || t.slug || ' team_hours of one person, 31 days: the same', case when v_diff is null then 'ok' else 'FAIL' end, coalesce(v_diff, 'the same'));
    v_user := pg_temp.v0008zs_user(t.id, 'monitoring.live');
    if v_user is null then
      insert into verify_0008zs values (215, 'E6 ' || t.slug || ' team_now', 'skip', 'no active person holds monitoring.live: not compared');
    else
      perform set_config('app.user_id', v_user::text, true);
      v_diff := pg_temp.v0008zs_diff('select * from cma.team_now()', 'select * from pg_temp.old_team_now()', true);
      execute 'select count(*) from cma.team_now()' into v_n;
      insert into verify_0008zs values (215, 'E6 ' || t.slug || ' team_now: the same people, days and stretches in the same order', case when v_diff is null then 'ok' else 'FAIL' end, coalesce(v_diff, v_n || ' people'));
    end if;
  end loop;
exception when others then
  insert into verify_0008zs values (299, 'E block ended early', 'FAIL', 'error ' || sqlstate || ': ' || left(sqlerrm, 160));
end
$$;
reset role;
set role cma_owner;

-- ---------------------------------------------------------------------------------------------
-- A. The rights: the application fails closed, the readers read through cma_read
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_mine uuid; v_other uuid; v_day uuid; v_end timestamptz; v_n1 bigint; v_n2 bigint; v_n3 bigint; v_n4 bigint; v_ok boolean;
begin
  -- the first active tenant with a day and another tenant's id, looked up as the owner; the calls as the application
  select t.id into v_mine from cma.tenant t where t.status = 'active' and exists (select 1 from cma.workday w where w.tenant_id = t.id) order by t.slug limit 1;
  select t.id into v_other from cma.tenant t where t.id <> v_mine order by t.slug limit 1;
  if v_mine is null then
    insert into verify_0008zs values (301, 'A1 the day functions fail closed', 'skip', 'no tenant with a workday');
    return;
  end if;
  select w.id, cma.business_day_time(w.business_date, w.timezone, '23:59'::time) into v_day, v_end from cma.workday w where w.tenant_id = v_mine order by w.business_date desc limit 1;
  set local role cma_app;
  perform set_config('app.tenant_id', v_mine::text, true), set_config('app.user_id', '', true);
  select count(*) into v_n1 from cma.workday_stretches_of(v_mine, v_day, v_end);                -- own tenant: the day's stretches
  select count(*) into v_n2 from cma.workday_stretches_of(v_other, v_day, v_end);               -- another tenant's id: nothing
  perform set_config('app.tenant_id', '', true);
  select count(*) into v_n3 from cma.workday_stretches_of(v_mine, v_day, v_end);                -- no tenant set: nothing
  select count(*) into v_n4 from cma.workday_summary_of(v_mine, v_day, v_end) x where x.sessions > 0;
  set local role cma_owner;
  perform set_config('app.tenant_id', '', true);
  v_ok := v_n1 > 0 and v_n2 = 0 and v_n3 = 0 and v_n4 = 0;
  insert into verify_0008zs values (301, 'A1 as the application the day functions answer the own tenant''s day only: another tenant''s id or no tenant set gives nothing (row-level security)',
    case when v_ok and not v_provoke then 'ok' else 'FAIL' end, format('%s stretches of the own day, %s with the other tenant''s id, %s and %s without a tenant', v_n1, v_n2, v_n3, v_n4));
exception when others then
  set local role cma_owner;
  insert into verify_0008zs values (301, 'A1 the day functions fail closed', 'FAIL', 'error ' || sqlstate || ': ' || left(sqlerrm, 160));
end
$$;
grant select, insert on pg_temp.verify_0008zs to cma_readonly;
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_n1 bigint; v_n2 bigint; v_ok boolean;
begin
  if not pg_has_role(session_user, 'cma_readonly', 'member') then
    insert into verify_0008zs values (302, 'A2 the readers read cma_read.workday_summary and cma_read.time_interval', 'skip', 'this login is no member of cma_readonly: not checked here');
    return;
  end if;
  set local role cma_readonly;
  select count(*) into v_n1 from cma_read.workday_summary;
  select count(*) into v_n2 from cma_read.time_interval;
  set local role cma_owner;
  v_ok := v_n1 = (select count(*) from cma.workday_summary_all) and v_n2 = (select count(*) from cma.time_interval_all);
  insert into verify_0008zs values (302, 'A2 the readers read cma_read.workday_summary and cma_read.time_interval, every tenant, through the day functions',
    case when v_ok and not v_provoke then 'ok' else 'FAIL' end, format('%s days, %s stretches', v_n1, v_n2));
exception when others then
  insert into verify_0008zs values (302, 'A2 the readers read cma_read.workday_summary and cma_read.time_interval', 'FAIL', 'error ' || sqlstate || ': ' || left(sqlerrm, 160));
end
$$;

drop function if exists pg_temp.v0008zs_diff(text, text, boolean);
drop function if exists pg_temp.v0008zs_user(uuid, text);
drop function if exists pg_temp.old_team_hours(date, date, uuid);
drop function if exists pg_temp.old_team_now();
drop view if exists pg_temp.old_workday_summary_all;
drop view if exists pg_temp.old_time_interval_all;

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0008zs
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0008zs where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0008zs where result = 'ok') then 'FAIL'
                  else '0008zs verified' end,
             format('135_verify_hours_reads: %s ok, %s FAIL, %s skip', (select count(*) from pg_temp.verify_0008zs where result = 'ok'),
                    (select count(*) from pg_temp.verify_0008zs where result = 'FAIL'), (select count(*) from pg_temp.verify_0008zs where result = 'skip'))) x
order by ord;
drop table if exists pg_temp.verify_0008zs;
reset role;
