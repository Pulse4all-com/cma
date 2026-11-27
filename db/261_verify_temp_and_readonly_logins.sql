-- =============================================================================================
-- 261_verify_temp_and_readonly_logins.sql: verifies addition 0010d, TEMPORARY only for cma_owner and cma_app, no reader
-- creating anything, the readers read-only on this database
-- =============================================================================================
-- Universal: no seed is assumed, so it runs in dev and in prod. Reads the catalog; its one behaviour check runs first, in a
-- block that is always rolled back, so nothing stays. Run as your own IAM login (a member of cma_readonly, as every team
-- login is) after 260_temp_and_readonly_logins.sql, in a fresh session (the runner opens one per script; in Studio, a new
-- tab: B1 cannot be judged in a session that has made a temporary object already). Dev first, then prod. Expected: S1,
-- T1, T2, T3, T4, B1, R1, R2 OK, then "PASS 0010d". Provoked (verify.provoke true at the top): every row FAIL, the verdict
-- PROVOKED, NOT A PASS.
--
-- The reader logins, as 260 finds them: every login holding cma_readonly and none of cma_owner, cma_app or the database
-- owner's role, neither a superuser nor a role administrator nor one of Cloud SQL's own (bq_reader and
-- cma-nocodb@<project>.iam in prod on 27 November 2026). A reader login added later without 260's settings fails T3 or R1.
--
--   S1  0010d recorded after 0010b
--   T1  PUBLIC holds no TEMPORARY on this database
--   T2  cma_owner and cma_app hold TEMPORARY by a grant of their own; no other role holds it by a grant, but the
--       database's owner (who holds every right on it); the detail names a role to revoke
--   T3  cma_readonly and every reader login hold no TEMPORARY, by any route (a grant, PUBLIC, a role, ownership)
--   T4  PUBLIC, cma_readonly and every reader login hold no CREATE on this database or on any of its schemas (public
--       included: it is on the database's default search path)
--   B1  in fact: as cma_readonly, CREATE TEMPORARY TABLE is refused (42501), the first step of the path 0010b closed. It runs
--       before this script makes any temporary object: Postgres checks TEMPORARY once per session, when the session's
--       temporary schema is first made, so after that any role of the session could make one
--   R1  there is a reader login, and each is read-only by default on this database (default_transaction_read_only=on, IN
--       DATABASE) and carries no such setting for every database (NocoDB's own database, nocodb, stays writable). That a
--       read-only session refuses a write and any DDL is Postgres's own rule (seen locally: a reader's CREATE TEMPORARY
--       TABLE ends in "cannot execute CREATE TABLE in a read-only transaction"); a session may set the default off, which
--       is why T1 to B1 take TEMPORARY away as well
--   R2  no session of a reader login started before 0010d was recorded (such a session keeps the old behaviour until it
--       reconnects; NocoDB's cma_read pool keeps no idle connection, so wait a minute and run this again). Needs
--       pg_read_all_stats on cma_owner (0009w) to see other logins' sessions: a session it cannot date fails
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

-- the reader logins, as 260 finds them
create temporary table verify_0010d_readers as
select ro.oid, ro.rolname::text as rolname
from pg_roles ro
where ro.rolcanlogin and not ro.rolsuper and not ro.rolcreaterole and ro.rolname not like 'cloudsql%'
  and pg_has_role(ro.oid, 'cma_readonly', 'MEMBER') and not pg_has_role(ro.oid, 'cma_owner', 'MEMBER')
  and not pg_has_role(ro.oid, 'cma_app', 'MEMBER')
  and not pg_has_role(ro.oid, (select d.datdba from pg_database d where d.datname = current_database()), 'MEMBER');

do $$
declare
  v_db     text := current_database();
  v_dboid  oid := (select d.oid from pg_database d where d.datname = current_database());
  v_owner  name := (select pg_get_userbyid(d.datdba) from pg_database d where d.datname = current_database());
  v_since  timestamptz;
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

  -- T2: the grantees of TEMPORARY by name, each once (the owner aside)
  select string_agg(g.name, ', ' order by g.name collate "C") into v_txt
  from (select distinct case when a.grantee = 0 then 'PUBLIC' else pg_get_userbyid(a.grantee)::text end as name
        from aclexplode((select d.datacl from pg_database d where d.oid = v_dboid)) a
        where a.privilege_type = 'TEMPORARY' and a.grantee <> (select d.datdba from pg_database d where d.oid = v_dboid)) g;
  perform pg_temp.v10d_row(3, 'T2', 'TEMPORARY for cma_owner and cma_app alone', v_txt = 'cma_app, cma_owner',
    format('granted to: %s (the owner %s aside)%s', coalesce(v_txt, 'nobody'), v_owner,
           case when v_txt is distinct from 'cma_app, cma_owner' then '; 260 prints the grant or revoke to run' else '' end));

  -- T3: cma_readonly and the reader logins hold none, by any route
  select string_agg(x.rolname, ', ' order by x.rolname collate "C") filter (where has_database_privilege(x.oid, v_db, 'TEMPORARY')),
         string_agg(x.rolname, ', ' order by x.rolname collate "C")
    into v_bad, v_txt
  from (select r.oid, r.rolname from pg_temp.verify_0010d_readers r
        union select ro.oid, ro.rolname::text from pg_roles ro where ro.rolname = 'cma_readonly') x;
  perform pg_temp.v10d_row(4, 'T3', 'the readers hold no TEMPORARY', v_bad is null,
    format('readers: %s; with TEMPORARY: %s', v_txt, coalesce(v_bad, 'none')));

  -- T4: no CREATE for PUBLIC or a reader on the database or any of its schemas
  select string_agg(x.who || ' on ' || x.what, ', ' order by x.who collate "C", x.what collate "C") into v_bad
  from (select 'PUBLIC'::text as who, 'database ' || v_db as what where has_database_privilege('public', v_db, 'CREATE')
        union all
        select 'PUBLIC', 'schema ' || n.nspname from pg_namespace n
        where n.nspname not like 'pg\_%' and n.nspname <> 'information_schema' and has_schema_privilege('public', n.oid, 'CREATE')
        union all
        select x.rolname, 'database ' || v_db
        from (select r.oid, r.rolname from pg_temp.verify_0010d_readers r
              union select ro.oid, ro.rolname::text from pg_roles ro where ro.rolname = 'cma_readonly') x
        where has_database_privilege(x.oid, v_db, 'CREATE')
        union all
        select x.rolname, 'schema ' || n.nspname
        from (select r.oid, r.rolname from pg_temp.verify_0010d_readers r
              union select ro.oid, ro.rolname::text from pg_roles ro where ro.rolname = 'cma_readonly') x
        cross join pg_namespace n
        where n.nspname not like 'pg\_%' and n.nspname <> 'information_schema' and has_schema_privilege(x.oid, n.oid, 'CREATE')) x;
  perform pg_temp.v10d_row(5, 'T4', 'no reader and not PUBLIC may create on this database or its schemas', v_bad is null,
    format('CREATE held: %s', coalesce(v_bad, 'none')));

  -- B1
  v_code := current_setting('verify.b1', true);
  perform pg_temp.v10d_row(6, 'B1', 'as cma_readonly, CREATE TEMPORARY TABLE is refused', v_code = '42501',
    format('cma_readonly''s CREATE TEMPORARY TABLE: %s', v_code));

  -- R1: a reader login exists; each read-only on this database, and none on every database
  select string_agg(r.rolname, ', ' order by r.rolname collate "C")
           filter (where not exists (select 1 from pg_db_role_setting s where s.setrole = r.oid and s.setdatabase = v_dboid
                                     and 'default_transaction_read_only=on' = any (s.setconfig))),
         string_agg(r.rolname, ', ' order by r.rolname collate "C")
           filter (where exists (select 1 from pg_db_role_setting s where s.setrole = r.oid and s.setdatabase = 0
                                 and exists (select 1 from unnest(s.setconfig) c where c like 'default_transaction_read_only=%'))),
         string_agg(r.rolname, ', ' order by r.rolname collate "C")
    into v_bad, v_code, v_txt
  from pg_temp.verify_0010d_readers r;
  perform pg_temp.v10d_row(7, 'R1', 'the reader logins are read-only on this database only',
    v_txt is not null and v_bad is null and v_code is null,
    format('reader logins: %s; not read-only here: %s; read-only on every database: %s', coalesce(v_txt, 'none found'),
           coalesce(v_bad, 'none'), coalesce(v_code, 'none')));

  -- R2: no reader session older than 0010d (or not datable)
  v_since := (select m.applied_at from cma.schema_migration m where m.version = '0010d');
  select string_agg(format('%s pid %s since %s', a.usename, a.pid, coalesce(to_char(a.backend_start, 'YYYY-MM-DD HH24:MI:SS TZ'), 'unknown (no pg_read_all_stats)')),
                    ', ' order by a.usename collate "C", a.pid)
    into v_bad
  from pg_stat_activity a
  where a.datname = v_db and a.usesysid in (select r.oid from pg_temp.verify_0010d_readers r)
    and (v_since is null or a.backend_start is null or a.backend_start < v_since);
  perform pg_temp.v10d_row(8, 'R2', 'no reader session older than 0010d', v_since is not null and v_bad is null,
    format('0010d at %s; older reader sessions: %s', coalesce(to_char(v_since, 'YYYY-MM-DD HH24:MI:SS TZ'), 'not recorded'),
           coalesce(v_bad || ' (wait a minute for them to reconnect, then run this again)', 'none')));
end
$$;

drop function if exists pg_temp.v10d_row(integer, text, text, boolean, text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0010d
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0010d where result <> 'OK') then 'FAIL'
                  when (select count(*) from pg_temp.verify_0010d where result = 'OK') <> 8 then 'FAIL'
                  else 'PASS 0010d' end,
             format('261_verify_temp_and_readonly_logins: %s OK, %s FAIL', (select count(*) from pg_temp.verify_0010d where result = 'OK'),
                    (select count(*) from pg_temp.verify_0010d where result <> 'OK'))) x
order by ord;
reset role;
