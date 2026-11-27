-- =============================================================================================
-- 261_verify_temp_and_readonly_logins.sql: verifies addition 0010d, TEMPORARY only for cma_owner and cma_app, the
-- readers read-only on this database
-- =============================================================================================
-- Universal: no seed is assumed, so it runs in dev and in prod. Reads the catalog; its one behaviour check runs first, in a
-- block that is always rolled back, so nothing stays. Run as your own IAM login (a member of cma_readonly, as every team
-- login is) after 260_temp_and_readonly_logins.sql, dev first, then prod. Expected: S1, T1, T2, T3, B1, R1 OK, then "PASS
-- 0010d". Provoked (verify.provoke true at the top): every row FAIL, the verdict PROVOKED, NOT A PASS.
--
--   S1  0010d recorded after 0010b
--   T1  PUBLIC holds no TEMPORARY on this database
--   T2  cma_owner and cma_app hold TEMPORARY by a grant of their own; no other role holds it by a grant, but the
--       database's owner (who holds every right on it)
--   T3  the readers (bq_reader, cma-nocodb@<project>.iam where present, and cma_readonly itself) hold no TEMPORARY
--   B1  in fact: as cma_readonly, CREATE TEMPORARY TABLE is refused (42501), the first step of the path 0010b closed. It runs
--       before this script makes any temporary object: Postgres checks TEMPORARY once per session, when the session's
--       temporary schema is first made, so after that any role of the session could make one
--   R1  each reader login present is read-only by default on this database (default_transaction_read_only=on, IN
--       DATABASE) and carries no setting for every database (NocoDB's own database, nocodb, stays writable). That a
--       read-only session refuses a write is Postgres's own rule (it still allows temporary tables, which T1 to B1 take
--       away from the readers)
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
select set_config('verify.provoke', 'false', false);                 -- 'true' to make every check fail

-- B1 before anything temporary exists in this session (the check above, T3's note): as cma_readonly, rolled back
do $$
declare
  v_code text;
begin
  begin
    set local role cma_readonly;
    begin
      create temporary table verify_0010d_reader_temp (x integer);
      v_code := 'created';
    exception when insufficient_privilege then
      v_code := sqlstate;
    end;
    raise exception using errcode = 'V10D0', message = 'rolled back';
  exception
    when sqlstate 'V10D0' then null;
    when insufficient_privilege then v_code := 'cannot set role cma_readonly (' || sqlerrm || ')';
  end;
  perform set_config('verify.b1', coalesce(v_code, 'not run'), false);
end
$$;
set role cma_owner;

drop table if exists pg_temp.verify_0010d;
create temporary table verify_0010d (ord integer, check_name text, result text, detail text);

create or replace function pg_temp.v10d_row(p_ord integer, p_id text, p_name text, p_ok boolean, p_detail text)
returns void
language sql
as $$
  insert into pg_temp.verify_0010d
  select p_ord, p_id || ' ' || p_name,
         case when coalesce(p_ok, false) and not current_setting('verify.provoke')::boolean then 'OK' else 'FAIL' end,
         case when coalesce(p_ok, false) and not current_setting('verify.provoke')::boolean then coalesce(p_detail, '')
              else 'FAIL ' || p_id || ': ' || case when current_setting('verify.provoke')::boolean then 'provoked; ' else '' end
                   || coalesce(p_detail, '(no detail)') end
$$;

do $$
declare
  v_db     text := current_database();
  v_dboid  oid := (select d.oid from pg_database d where d.datname = current_database());
  v_owner  name := (select pg_get_userbyid(d.datdba) from pg_database d where d.datname = current_database());
  ok       boolean;
  v_txt    text;
  v_bad    text;
  v_code   text;
begin
  -- S1
  ok := (select a.applied_at >= b.applied_at from cma.schema_migration a, cma.schema_migration b
         where a.version = '0010d' and b.version = '0010b');
  perform pg_temp.v10d_row(1, 'S1', 'recorded after 0010b', ok, case when ok then '0010d after 0010b' else '0010d or 0010b missing, or in the wrong order' end);

  -- T1
  ok := not has_database_privilege('public', v_db, 'TEMPORARY');
  perform pg_temp.v10d_row(2, 'T1', 'PUBLIC holds no TEMPORARY', ok, format('PUBLIC TEMPORARY on %s: %s', v_db, not ok));

  -- T2: the grantees of TEMPORARY by name (the owner aside)
  select string_agg(case when a.grantee = 0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end, ', '
                    order by case when a.grantee = 0 then 'PUBLIC' else pg_get_userbyid(a.grantee)::text end collate "C")
    into v_txt
  from aclexplode((select d.datacl from pg_database d where d.oid = v_dboid)) a
  where a.privilege_type = 'TEMPORARY' and a.grantee <> (select d.datdba from pg_database d where d.oid = v_dboid);
  perform pg_temp.v10d_row(3, 'T2', 'TEMPORARY for cma_owner and cma_app alone', v_txt = 'cma_app, cma_owner',
    format('granted to: %s (the owner %s aside)', coalesce(v_txt, 'nobody'), v_owner));

  -- T3: the readers hold none, and a role holding cma_readonly alone is refused a temporary table
  select string_agg(r.rolname, ', ' order by r.rolname collate "C") filter (where has_database_privilege(r.oid, v_db, 'TEMPORARY'))
    into v_bad
  from pg_roles r where r.rolname in ('cma_readonly', 'bq_reader') or r.rolname like 'cma-nocodb@%.iam';
  select string_agg(r.rolname, ', ' order by r.rolname collate "C") into v_txt
  from pg_roles r where r.rolname in ('cma_readonly', 'bq_reader') or r.rolname like 'cma-nocodb@%.iam';
  perform pg_temp.v10d_row(4, 'T3', 'the readers hold no TEMPORARY', v_bad is null,
    format('readers: %s; with TEMPORARY: %s', v_txt, coalesce(v_bad, 'none')));
  v_code := current_setting('verify.b1', true);
  perform pg_temp.v10d_row(5, 'B1', 'as cma_readonly, CREATE TEMPORARY TABLE is refused', v_code = '42501',
    format('cma_readonly''s CREATE TEMPORARY TABLE: %s', v_code));

  -- R1: each reader login read-only on this database, and no setting for every database
  select string_agg(r.rolname, ', ' order by r.rolname collate "C")
           filter (where not exists (select 1 from pg_db_role_setting s where s.setrole = r.oid and s.setdatabase = v_dboid
                                     and 'default_transaction_read_only=on' = any (s.setconfig))),
         string_agg(r.rolname, ', ' order by r.rolname collate "C")
           filter (where exists (select 1 from pg_db_role_setting s where s.setrole = r.oid and s.setdatabase = 0
                                 and exists (select 1 from unnest(s.setconfig) c where c like 'default_transaction_read_only=%'))),
         string_agg(r.rolname, ', ' order by r.rolname collate "C")
    into v_bad, v_code, v_txt
  from pg_roles r where r.rolname = 'bq_reader' or r.rolname like 'cma-nocodb@%.iam';
  perform pg_temp.v10d_row(6, 'R1', 'the reader logins are read-only on this database only',
    v_txt is not null and v_bad is null and v_code is null,
    format('reader logins: %s; not read-only here: %s; read-only on every database: %s', coalesce(v_txt, 'none found'),
           coalesce(v_bad, 'none'), coalesce(v_code, 'none')));

end
$$;

drop function if exists pg_temp.v10d_row(integer, text, text, boolean, text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0010d
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0010d where result <> 'OK') then 'FAIL'
                  when (select count(*) from pg_temp.verify_0010d where result = 'OK') <> 6 then 'FAIL'
                  else 'PASS 0010d' end,
             format('261_verify_temp_and_readonly_logins: %s OK, %s FAIL', (select count(*) from pg_temp.verify_0010d where result = 'OK'),
                    (select count(*) from pg_temp.verify_0010d where result <> 'OK'))) x
order by ord;
reset role;
