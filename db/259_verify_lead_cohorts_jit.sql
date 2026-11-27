-- =============================================================================================
-- 259_verify_lead_cohorts_jit.sql: verifies addition 0010c, Lead cohorts' read without JIT compilation
-- =============================================================================================
-- Universal: no seed is assumed and nothing is written. S1 and S2 check the structure on the database itself; E1 reads
-- every tenant's lead deals of the Lead cohorts page's default span (the last twelve ISO weeks up to today, in the
-- tenant's zone) twice, through cma.lead_cohort_rows_of with its new setting and through 120's definition kept below
-- (pg_temp, without the setting), and compares the two row for row. It prints counts and milliseconds, never a row of
-- anyone, so the script runs in dev and in prod. Every check writes one row, OK or FAIL (its detail then starts
-- "FAIL <id>"), because Cloud SQL Studio shows no notices. Run as your own IAM login after 258_lead_cohorts_jit.sql, dev
-- first, then prod. Expected: S1, S2 OK and one E1 row OK per tenant, then "PASS 0010c". Provoked (verify.provoke
-- true at the top): every row FAIL and the verdict PROVOKED, NOT A PASS; E1 then also compares with a deliberate
-- difference (120's side without its first deal), which its detail shows as "1 only now" for a tenant with lead deals
-- in the span (a tenant without any fails on the switch alone).
--
-- Run time: 120's side keeps the session's JIT on purpose (the proof that the setting changes no answer), so in prod it
-- is the read the application cancelled, now without a timeout: expect 15 s or more for a tenant with lead deals, on the
-- one vCPU. Run it at a quiet moment; the new side takes about a second.
--
-- That the setting holds inside the call is PostgreSQL's (a function's SET applies for the call and is restored after
-- it); S1 checks that the function carries it.
--
--   S1  0010c recorded after 0008zm; cma.lead_cohort_rows_of(uuid, date, date, timestamptz) carries jit=off and only
--       that setting, is still plpgsql, stable, in the caller's rights, cma_owner's, the application's only (not
--       public, not the readers'), and its body is 120's word for word (the copy below)
--   S2  what 0010c leaves alone: cma.lead_cohorts_of carries no setting (so the execute still inlines it) and stays
--       sql, stable, in the caller's rights; cma_read.lead_cohort_rows() keeps its search path as its only setting
--   E1  per tenant: the lead deals of the page's default span through cma.lead_cohort_rows_of equal 120's definition's,
--       row for row (as text, the same instant on both sides); the detail gives the count, the milliseconds of each side
--       (120's side under the session's JIT settings) and the session's jit
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

drop table if exists pg_temp.verify_0010c;
create temporary table verify_0010c (ord integer, check_name text, result text, detail text);

create or replace function pg_temp.v10c_row(p_ord integer, p_id text, p_name text, p_ok boolean, p_detail text)
returns void
language sql
as $$
  insert into pg_temp.verify_0010c
  select p_ord, p_id || ' ' || p_name,
         case when coalesce(p_ok, false) and not current_setting('verify.provoke')::boolean then 'OK' else 'FAIL' end,
         case when coalesce(p_ok, false) and not current_setting('verify.provoke')::boolean then coalesce(p_detail, '')
              else 'FAIL ' || p_id || ': ' || case when current_setting('verify.provoke')::boolean then 'provoked; ' else '' end
                   || coalesce(p_detail, '(no detail)') end
$$;

-- 120's cma.lead_cohort_rows_of, word for word, without a setting: the definition before 0010c
create or replace function pg_temp.v10c_rows_120(p_tenant_id uuid, p_from date, p_to date, p_now timestamptz)
returns cma.lead_cohort_deal[]
language plpgsql stable
as $$
declare
  v_zone text;
  v_rows cma.lead_cohort_deal[];
begin
  select t.timezone into v_zone from cma.tenant t where t.id = p_tenant_id;
  execute format(
    'select coalesce(array_agg(x::cma.lead_cohort_deal order by x.created_at, x.deal_id), ''{}'')
     from cma.lead_cohorts_of(%L::uuid, %L::timestamptz, %L::timestamptz, %L::timestamptz) x',
    p_tenant_id, p_from::timestamp at time zone v_zone, (p_to + 1)::timestamp at time zone v_zone, p_now)
  into v_rows;
  return v_rows;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- S1 and S2: the structure
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_fn   regprocedure := to_regprocedure('cma.lead_cohort_rows_of(uuid,date,date,timestamptz)');
  v_of   regprocedure := to_regprocedure('cma.lead_cohorts_of(uuid,timestamptz,timestamptz,timestamptz)');
  v_rd   regprocedure := to_regprocedure('cma_read.lead_cohort_rows()');
  v_bad  text := '';
  v_cfg  text;
begin
  -- S1
  if not exists (select 1 from cma.schema_migration where version = '0010c') then
    v_bad := v_bad || '0010c not recorded; ';
  elsif (select applied_at from cma.schema_migration where version = '0010c')
        < (select applied_at from cma.schema_migration where version = '0008zm') then
    v_bad := v_bad || '0010c recorded before 0008zm; ';
  end if;
  if v_fn is null then
    v_bad := v_bad || 'cma.lead_cohort_rows_of missing; ';
  else
    v_cfg := (select array_to_string(proconfig, ',') from pg_proc where oid = v_fn);
    if v_cfg is distinct from 'jit=off' then
      v_bad := v_bad || 'its settings are ' || coalesce(v_cfg, 'none') || ', not jit=off alone; ';
    end if;
    if (select l.lanname from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = v_fn) <> 'plpgsql'
       or (select provolatile from pg_proc where oid = v_fn) <> 's'
       or (select prosecdef from pg_proc where oid = v_fn)
       or (select pg_get_userbyid(proowner) from pg_proc where oid = v_fn) <> 'cma_owner' then
      v_bad := v_bad || 'not plpgsql, stable, invoker and cma_owner''s; ';
    end if;
    if not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
       or has_function_privilege('public', v_fn, 'execute') then
      v_bad := v_bad || 'not the application''s only; ';
    end if;
    if (select prosrc from pg_proc where oid = v_fn)
       is distinct from (select prosrc from pg_proc where oid = 'pg_temp.v10c_rows_120(uuid,date,date,timestamptz)'::regprocedure) then
      v_bad := v_bad || 'its body differs from 120''s; ';
    end if;
  end if;
  perform pg_temp.v10c_row(1, 'S1', '0010c recorded; cma.lead_cohort_rows_of with jit=off alone, 120''s body, the application''s only',
                           v_bad = '', case when v_bad = '' then 'jit=off' else v_bad end);

  -- S2
  v_bad := '';
  if v_of is null then
    v_bad := v_bad || 'cma.lead_cohorts_of missing; ';
  elsif (select proconfig from pg_proc where oid = v_of) is not null
        or (select l.lanname from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = v_of) <> 'sql'
        or (select provolatile from pg_proc where oid = v_of) <> 's'
        or (select prosecdef from pg_proc where oid = v_of) then
    v_bad := v_bad || 'cma.lead_cohorts_of not a settingless stable sql function in the caller''s rights ('
             || coalesce((select array_to_string(proconfig, ',') from pg_proc where oid = v_of), 'no setting') || '); ';
  end if;
  if v_rd is null then
    v_bad := v_bad || 'cma_read.lead_cohort_rows() missing; ';
  elsif (select cardinality(proconfig) from pg_proc where oid = v_rd) is distinct from 1
        or not coalesce((select array_to_string(proconfig, ',') from pg_proc where oid = v_rd) like 'search_path=%pg_temp', false) then
    v_bad := v_bad || 'cma_read.lead_cohort_rows() settings ' || coalesce((select array_to_string(proconfig, ',') from pg_proc where oid = v_rd), 'none') || '; ';
  end if;
  perform pg_temp.v10c_row(2, 'S2', 'left alone: cma.lead_cohorts_of without a setting (inlined), the readers'' function with its search path only',
                           v_bad = '', case when v_bad = '' then 'as 120' else v_bad end);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- E1: the same lead deals as 120's definition, per tenant, over the page's default span
-- ---------------------------------------------------------------------------------------------
do $$
declare
  t       record;
  v_ord   integer := 10;
  v_now   timestamptz := now();
  v_today date;
  v_from  date;
  v_new   cma.lead_cohort_deal[];
  v_old   cma.lead_cohort_deal[];
  v_t0    timestamptz;
  v_ms_n  numeric;
  v_ms_o  numeric;
  v_only_n bigint;
  v_only_o bigint;
  v_err   text;
begin
  for t in select x.id, x.slug, x.timezone from cma.tenant x order by x.slug collate "C" loop
    v_err := null;
    begin
      -- the page's default: the last twelve ISO weeks up to today, in the tenant's zone
      v_today := (v_now at time zone coalesce(t.timezone, 'UTC'))::date;
      v_from  := date_trunc('week', v_today)::date - 7 * 11;

      v_t0 := clock_timestamp();
      v_new := cma.lead_cohort_rows_of(t.id, v_from, v_today, v_now);
      v_ms_n := round(extract(epoch from clock_timestamp() - v_t0)::numeric * 1000, 1);

      v_t0 := clock_timestamp();
      v_old := pg_temp.v10c_rows_120(t.id, v_from, v_today, v_now);
      v_ms_o := round(extract(epoch from clock_timestamp() - v_t0)::numeric * 1000, 1);

      -- provoked: 120's side without its first deal, a deliberate difference the comparison must see
      if current_setting('verify.provoke')::boolean then
        v_old := v_old[2:];
      end if;

      select count(*) into v_only_n from (select x::text from unnest(v_new) x except all select y::text from unnest(v_old) y) q;
      select count(*) into v_only_o from (select y::text from unnest(v_old) y except all select x::text from unnest(v_new) x) q;
    exception when others then v_err := 'SQLSTATE ' || sqlstate;   -- the code only: a message could quote a value of a row
    end;
    perform pg_temp.v10c_row(v_ord, 'E1', format('%s: the lead deals of %s to %s equal 120''s, row for row', t.slug, v_from, v_today),
                             v_err is null and v_only_n = 0 and v_only_o = 0
                               and cardinality(v_new) = cardinality(v_old),
                             coalesce(v_err, format('%s deals; %s only now, %s only before; %s ms now (jit off), %s ms with 120''s definition (session jit %s)',
                                                    cardinality(v_new), v_only_n, v_only_o, v_ms_n, v_ms_o, current_setting('jit'))));
    v_ord := v_ord + 1;
  end loop;
end
$$;

drop function if exists pg_temp.v10c_rows_120(uuid, date, date, timestamptz);
drop function if exists pg_temp.v10c_row(integer, text, text, boolean, text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0010c
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0010c where result <> 'OK') then 'FAIL'
                  when (select count(*) from pg_temp.verify_0010c where result = 'OK')
                       <> 2 + (select count(*) from cma.tenant) then 'FAIL'
                  else 'PASS 0010c' end,
             format('259_verify_lead_cohorts_jit: %s OK, %s FAIL', (select count(*) from pg_temp.verify_0010c where result = 'OK'),
                    (select count(*) from pg_temp.verify_0010c where result <> 'OK'))) x
order by ord;
reset role;
