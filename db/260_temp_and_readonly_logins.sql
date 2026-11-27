-- =============================================================================================
-- 260_temp_and_readonly_logins.sql: addition 0010d, TEMPORARY only for the roles that create temporary objects, and the
-- readers' logins read-only on this database (N07i, defence in depth after 0010b)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics; the reader logins are found by name pattern (bq_reader, and
-- NocoDB's IAM login cma-nocodb@<project>.iam), so the script is the same in every database. Runs after
-- 256_definer_search_path.sql (0010b); it refuses to run without it. Rerunnable, forward-only. It changes no table, view,
-- column or function.
--
-- Rights. Sections 1 and 2 change the database's privileges and two logins' settings: that needs the database owner's
-- rights and CREATEROLE with ADMIN on those logins, which your IAM login may not hold (00_roles.sql is the one step that
-- needs postgres). Each statement is tried under your own login; where it is not allowed, the script says so, records
-- nothing and stops, printing the statements to run once in Cloud SQL Studio as postgres, connected to this database;
-- then run this script again: it finds them done and records 0010d. Run as your own IAM login: dev first, then
-- 261_verify_temp_and_readonly_logins.sql there (normal, then provoked), then 257 and 77 again (dev; 77 refuses prod);
-- then prod the same way.
--
-- Why (Martin, 27 November 2026; Decision log, 27 Nov 2026): 0010b closed a path by which a login holding cma_readonly and
-- TEMPORARY on the database could have its own temporary function run with cma_owner's rights (a temporary domain named
-- uuid, cast in cma_read.reader_sees inside the SECURITY DEFINER wrappers of 134). In prod the readers bq_reader and
-- cma-nocodb@p4a-cma-prod.iam held TEMPORARY through PUBLIC. Defence in depth, so that a later slip in a SECURITY DEFINER
-- function cannot be reached the same way: no reader may create a temporary object here, and the readers' sessions on
-- this database are read-only by default.
--
-- What it changes
--   1. TEMPORARY on this database  revoked from PUBLIC; granted to cma_owner and cma_app, the two roles that create
--      temporary objects: cma_owner in every verify and timing script and in tools/perf (after set role cma_owner or set
--      local role cma_owner; the team's logins hold cma_owner without inherit and switch to it), cma_app in the
--      subscription facts refresh (cma.subscription_facts_refresh_of, the caller's rights, called by the minute job as
--      the web service's login, which inherits cma_app). No route of web/ and nothing in ingest/ creates one. The readers
--      (cma_readonly) create none here; NocoDB's own metadata is in database nocodb, whose grants (docs/nocodb/grants.sql)
--      this does not touch.
--   2. default_transaction_read_only = on for bq_reader and cma-nocodb@<project>.iam, in this database only (ALTER ROLE
--      … IN DATABASE): BigQuery's federated queries and NocoDB's cma_read source only read here (cma_readonly holds
--      SELECT on cma_read and nothing else), while NocoDB writes its metadata in database nocodb, which stays writable.
--      A session may still set it off itself: this is a default, a second line behind the grants, not a lock.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (the Studio statements it prints are the postgres part; emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
-- the guard reads schema cma, which your login reaches as cma_owner (a team login holds it without inherit)
set role cma_owner;
do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0010b') then
    raise exception 'addition 0010b (256_definer_search_path.sql) must run before 0010d';
  end if;
end
$$;
reset role;

-- ---------------------------------------------------------------------------------------------
-- 1 and 2, under your own login (before set role: cma_owner owns neither the database nor the logins)
-- ---------------------------------------------------------------------------------------------
-- A GRANT or REVOKE the login may not make is a warning, not an error, in Postgres: the state is checked below in any case
do $$
declare
  v_db text := current_database();
  r    record;
begin
  -- each statement only where its state is not there yet, so a rerun after the Studio step says nothing
  if has_database_privilege('public', v_db, 'TEMPORARY') then
    begin
      execute format('revoke temporary on database %I from public', v_db);
    exception when others then
      raise notice 'TEMPORARY not revoked from PUBLIC under your login: % (the Studio step below)', sqlerrm;
    end;
  end if;
  if not exists (select 1 from aclexplode((select d.datacl from pg_database d where d.datname = v_db)) a
                 where a.grantee = 'cma_owner'::regrole and a.privilege_type = 'TEMPORARY')
     or not exists (select 1 from aclexplode((select d.datacl from pg_database d where d.datname = v_db)) a
                    where a.grantee = 'cma_app'::regrole and a.privilege_type = 'TEMPORARY') then
    begin
      execute format('grant temporary on database %I to cma_owner, cma_app', v_db);
    exception when others then
      raise notice 'TEMPORARY not granted to cma_owner and cma_app under your login: % (the Studio step below)', sqlerrm;
    end;
  end if;
  for r in select ro.rolname from pg_roles ro
           where (ro.rolname = 'bq_reader' or ro.rolname like 'cma-nocodb@%.iam')
             and not exists (select 1 from pg_db_role_setting s
                             where s.setrole = ro.oid and s.setdatabase = (select d.oid from pg_database d where d.datname = v_db)
                               and 'default_transaction_read_only=on' = any (s.setconfig))
           order by ro.rolname collate "C" loop
    begin
      execute format('alter role %I in database %I set default_transaction_read_only = on', r.rolname, v_db);
    exception when others then
      raise notice '% not set read-only on % under your login: % (the Studio step below)', r.rolname, v_db, sqlerrm;
    end;
  end loop;
end
$$;

begin;
set local lock_timeout = '5s';
set role cma_owner;

-- ---------------------------------------------------------------------------------------------
-- 3. The state before the record: anything missing stops the script with the Studio statements, and nothing is recorded
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_db      text := current_database();
  v_dboid   oid := (select d.oid from pg_database d where d.datname = current_database());
  v_missing text := '';
  v_studio  text := '';
  r         record;
begin
  if has_database_privilege('public', v_db, 'TEMPORARY') then
    v_missing := v_missing || 'PUBLIC still holds TEMPORARY; ';
    v_studio := v_studio || format(E'revoke temporary on database %I from public;\n', v_db);
  end if;
  if not (has_database_privilege('cma_owner', v_db, 'TEMPORARY') and has_database_privilege('cma_app', v_db, 'TEMPORARY'))
     or not exists (select 1 from aclexplode((select d.datacl from pg_database d where d.oid = v_dboid)) a
                    where a.grantee = 'cma_app'::regrole and a.privilege_type = 'TEMPORARY')
     or not exists (select 1 from aclexplode((select d.datacl from pg_database d where d.oid = v_dboid)) a
                    where a.grantee = 'cma_owner'::regrole and a.privilege_type = 'TEMPORARY') then
    v_missing := v_missing || 'cma_owner and cma_app need TEMPORARY by a grant of their own; ';
    v_studio := v_studio || format(E'grant temporary on database %I to cma_owner, cma_app;\n', v_db);
  end if;
  for r in select ro.oid, ro.rolname from pg_roles ro
           where ro.rolname = 'bq_reader' or ro.rolname like 'cma-nocodb@%.iam' order by ro.rolname collate "C" loop
    if not exists (select 1 from pg_db_role_setting s
                   where s.setrole = r.oid and s.setdatabase = v_dboid and 'default_transaction_read_only=on' = any (s.setconfig)) then
      v_missing := v_missing || r.rolname || ' is not read-only on ' || v_db || '; ';
      v_studio := v_studio || format(E'alter role %I in database %I set default_transaction_read_only = on;\n', r.rolname, v_db);
    end if;
  end loop;
  if v_missing <> '' then
    raise exception E'0010d is not recorded: %\nRun once in Cloud SQL Studio as postgres, connected to database %, then this script again:\n%',
      v_missing, v_db, v_studio;
  end if;
end
$$;

insert into cma.schema_migration (version, description)
values ('0010d', 'TEMPORARY on the database only for cma_owner and cma_app (revoked from PUBLIC), and the readers bq_reader and cma-nocodb@<project>.iam read-only on this database by default (default_transaction_read_only = on, IN DATABASE): defence in depth after 0010b')
on conflict (version) do nothing;

commit;
reset role;
