-- =============================================================================================
-- 257_verify_definer_search_path.sql: verifies addition 0010b, the readers' wrappers end their search path in pg_temp
-- =============================================================================================
-- Universal: no seed is assumed, so it runs in dev and in prod. Reads the catalog and calls the two wrappers and the core
-- functions they wrap; writes nothing (only its own temporary results). Run as your own IAM login after
-- 256_definer_search_path.sql, dev first, then prod. Expected: S1, D1, D2, D3 OK, then "PASS 0010b". Provoked
-- (verify.provoke true at the top): every row FAIL, the verdict PROVOKED, NOT A PASS.
--
--   S1  0010b recorded
--   D1  the two wrappers: search_path exactly pg_catalog, cma, pg_temp; still SECURITY DEFINER, stable, owner cma_owner,
--       rows 12 and 1 (as 134 made them); execute for cma_readonly only (not public, not cma_app)
--   D2  every SECURITY DEFINER function of cma and cma_read ends its search path in pg_temp (77's A5), with the counts,
--       and no SECURITY DEFINER function in any other schema but the system's (pg_catalog, information_schema, pg_toast)
--   D3  the wrappers answer as the core functions they wrap: cma.workday_stretches_of and cma.workday_summary_of against
--       the two readers' functions over the 25 latest workdays (by id), row for row both ways; app.tenant_id is cleared
--       first, so cma_read.reader_sees (which decides on that setting, not on the role) lets the wrappers see every
--       tenant; provoked, one wrapper row is left out, so the comparison must find that difference; a database without
--       workdays says so and passes on the catalog alone
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
select set_config('app.tenant_id', '', false);                       -- the wrappers see every tenant (cma_read.reader_sees)

drop table if exists pg_temp.verify_0010b;
create temporary table verify_0010b (ord integer, check_name text, result text, detail text);

create or replace function pg_temp.v10b_row(p_ord integer, p_id text, p_name text, p_ok boolean, p_detail text)
returns void
language sql
as $$
  insert into pg_temp.verify_0010b
  select p_ord, p_id || ' ' || p_name,
         case when coalesce(p_ok, false) and not current_setting('verify.provoke')::boolean then 'OK' else 'FAIL' end,
         case when coalesce(p_ok, false) and not current_setting('verify.provoke')::boolean then coalesce(p_detail, '')
              else 'FAIL ' || p_id || ': ' || case when current_setting('verify.provoke')::boolean then 'provoked; ' else '' end
                   || coalesce(p_detail, '(no detail)') end
$$;

do $$
declare
  ok       boolean;
  v_txt    text;
  v_bad    text;
  n_cma    integer;
  n_read   integer;
  n_days   integer;
  n_diff   integer;
  n_rows   integer;
begin
  -- S1
  ok := exists (select 1 from cma.schema_migration where version = '0010b');
  perform pg_temp.v10b_row(1, 'S1', 'recorded', ok, case when ok then '0010b recorded' else '0010b missing' end);

  -- D1
  select string_agg(format('%s: %s, definer %s, %s, owner %s, rows %s', p.proname,
                           coalesce((select c from unnest(p.proconfig) c where c like 'search_path=%'), 'no search_path'),
                           p.prosecdef, p.provolatile, pg_get_userbyid(p.proowner), p.prorows::integer), '; ' order by p.proname collate "C")
    into v_txt
  from pg_proc p
  where p.oid in ('cma.workday_stretches_reader_of(uuid, uuid, timestamptz)'::regprocedure,
                  'cma.workday_summary_reader_of(uuid, uuid, timestamptz)'::regprocedure);
  ok := v_txt = 'workday_stretches_reader_of: search_path=pg_catalog, cma, pg_temp, definer t, s, owner cma_owner, rows 12; '
             || 'workday_summary_reader_of: search_path=pg_catalog, cma, pg_temp, definer t, s, owner cma_owner, rows 1'
    and (select bool_and(has_function_privilege('cma_readonly', f, 'execute')
                         and not has_function_privilege('public', f, 'execute')
                         and not has_function_privilege('cma_app', f, 'execute'))
         from unnest(array['cma.workday_stretches_reader_of(uuid, uuid, timestamptz)',
                           'cma.workday_summary_reader_of(uuid, uuid, timestamptz)']) f);
  perform pg_temp.v10b_row(2, 'D1', 'the two wrappers', ok, v_txt || '; execute for cma_readonly only');

  -- D2 (77's A5)
  select count(*) filter (where n.nspname = 'cma'), count(*) filter (where n.nspname = 'cma_read'),
         string_agg(n.nspname || '.' || p.proname, ', ' order by n.nspname collate "C", p.proname collate "C")
           filter (where not exists (select 1 from unnest(p.proconfig) c where c ~ '^search_path=.*pg_temp$'))
    into n_cma, n_read, v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('cma', 'cma_read') and p.prosecdef;
  select string_agg(n.nspname || '.' || p.proname, ', ' order by n.nspname collate "C", p.proname collate "C") into v_txt
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where p.prosecdef and n.nspname not in ('cma', 'cma_read', 'pg_catalog', 'information_schema', 'pg_toast')
    and n.nspname not like 'pg_temp_%' and n.nspname not like 'pg_toast_temp_%';
  perform pg_temp.v10b_row(3, 'D2', 'every SECURITY DEFINER function ends its search path in pg_temp', v_bad is null and v_txt is null and n_cma >= 2,
    format('%s in cma, %s in cma_read, none elsewhere%s%s', n_cma, n_read, coalesce('; without pg_temp last: ' || v_bad, ''),
           coalesce('; definer functions in other schemas: ' || v_txt, '')));

  -- D3: the wrappers answer as the core functions they wrap, over the 25 latest workdays
  create temporary table v10b_days on commit drop as
    select w.tenant_id, w.id, coalesce(w.ended_at, now()) + interval '1 day' as day_end
    from cma.workday w order by w.id desc limit 25;
  select count(*) into n_days from v10b_days;
  select count(*) into n_diff from (
    (select d.id, x.* from v10b_days d cross join lateral cma.workday_stretches_of(d.tenant_id, d.id, d.day_end) x
     except all
     select d.id, x.* from v10b_days d cross join lateral cma.workday_stretches_reader_of(d.tenant_id, d.id, d.day_end) x)
    union all
    (select d.id, x.* from v10b_days d cross join lateral cma.workday_stretches_reader_of(d.tenant_id, d.id, d.day_end) x
     except all
     select d.id, x.* from v10b_days d cross join lateral cma.workday_stretches_of(d.tenant_id, d.id, d.day_end) x)) z;
  select n_diff + count(*) into n_diff from (
    (select d.id, x.* from v10b_days d cross join lateral cma.workday_summary_of(d.tenant_id, d.id, d.day_end) x
     except all
     select d.id, x.* from v10b_days d cross join lateral cma.workday_summary_reader_of(d.tenant_id, d.id, d.day_end) x)
    union all
    (select d.id, x.* from v10b_days d cross join lateral cma.workday_summary_reader_of(d.tenant_id, d.id, d.day_end) x
     except all
     select d.id, x.* from v10b_days d cross join lateral cma.workday_summary_of(d.tenant_id, d.id, d.day_end) x)) z;
  select count(*) into n_rows from v10b_days d cross join lateral cma.workday_stretches_reader_of(d.tenant_id, d.id, d.day_end) x;
  -- provoked: the comparison itself is put to the test, one wrapper row left out, so it must count one difference
  if current_setting('verify.provoke')::boolean and n_rows > 0 then
    select count(*) into n_diff from (
      (select d.id, x.* from v10b_days d cross join lateral cma.workday_stretches_of(d.tenant_id, d.id, d.day_end) x
       except all
       (select d.id, x.* from v10b_days d cross join lateral cma.workday_stretches_reader_of(d.tenant_id, d.id, d.day_end) x
        order by 1 offset 1))) z;
  end if;
  perform pg_temp.v10b_row(4, 'D3', 'the wrappers answer as the core functions', n_diff = 0 and (n_days = 0 or n_rows > 0),
    case when n_days = 0 then 'no workday in this database: the catalog checks alone'
         else format('%s workdays, %s stretches through the wrapper, %s rows differ%s', n_days, n_rows, n_diff,
                     case when current_setting('verify.provoke')::boolean then ' (one row left out on purpose)' else '' end) end);
  drop table if exists v10b_days;
end
$$;

drop function if exists pg_temp.v10b_row(integer, text, text, boolean, text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0010b
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0010b where result <> 'OK') then 'FAIL'
                  when (select count(*) from pg_temp.verify_0010b where result = 'OK') <> 4 then 'FAIL'
                  else 'PASS 0010b' end,
             format('257_verify_definer_search_path: %s OK, %s FAIL', (select count(*) from pg_temp.verify_0010b where result = 'OK'),
                    (select count(*) from pg_temp.verify_0010b where result <> 'OK'))) x
order by ord;
reset role;
