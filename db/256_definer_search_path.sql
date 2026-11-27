-- =============================================================================================
-- 256_definer_search_path.sql: addition 0010b, the two readers' wrappers of 134 end their search path in pg_temp (N07h)
-- =============================================================================================
-- Universal: no customer, tenant, market or vendor specifics. Runs unchanged in every database, after
-- 134_hours_reads.sql, which made the two functions; it refuses to run without them. It needs nothing of the additions
-- after 134, and nothing of 0010a (#336, 254/255, open as this is written): either may run first. Rerunnable,
-- forward-only, in one transaction with a lock timeout. No table, view or column changes; no function is re-created
-- (two ALTER FUNCTION … SET, so their bodies, rights, rows estimates and grants stay exactly as 134 left them, and no
-- "based on" line applies).
-- Run as your own IAM login: dev first, then 257_verify_definer_search_path.sql there (normal, then provoked), then the
-- verifies below; then prod: this script, 257 and the same verifies (those that run in prod).
--
-- Why (Martin, 25 and 27 November 2026; CMA-155): 77's A5 ("every SECURITY DEFINER function of cma and cma_read pins its
-- search path with pg_temp last") fails in dev on cma.workday_stretches_reader_of and cma.workday_summary_reader_of,
-- which 134 made with search_path = pg_catalog, cma. A SECURITY DEFINER function runs with its owner's rights; without
-- pg_temp named last, the session's temporary schema is searched first (PostgreSQL's documentation, "Writing SECURITY
-- DEFINER Functions Safely"), so a caller's temporary object could stand in for one the function names without a schema.
-- Both bodies name every object with its schema today, so nothing is exposed; the rule holds for every definer function
-- all the same, and A5 checks it.
--
-- What it changes
--   cma.workday_stretches_reader_of(uuid, uuid, timestamptz)   search_path = pg_catalog, cma, pg_temp
--   cma.workday_summary_reader_of(uuid, uuid, timestamptz)     search_path = pg_catalog, cma, pg_temp
-- Then it checks every SECURITY DEFINER function of cma and cma_read (18 and 22 in a database at 0009zz) and refuses to
-- commit while one lacks pg_temp last (A5's rule), naming them.
--
-- Verifies that read what this changes, run again after this script: 77 (its A5; dev only), 135 (the two wrappers and the
-- readers' views over them), and, through cma_read.time_interval and cma_read.workday_summary, 07 (dev only), 47, 51 and
-- 231 (grep -lw 'cma\.workday_(stretches|summary)_reader_of' db/*verify*.sql, and the views' readers). None is edited.
-- =============================================================================================

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
  if to_regprocedure('cma.workday_stretches_reader_of(uuid, uuid, timestamptz)') is null
     or to_regprocedure('cma.workday_summary_reader_of(uuid, uuid, timestamptz)') is null then
    raise exception '134_hours_reads.sql (the two readers'' wrappers) must run before 0010b';
  end if;
end
$$;

alter function cma.workday_stretches_reader_of(uuid, uuid, timestamptz) set search_path = pg_catalog, cma, pg_temp;
alter function cma.workday_summary_reader_of(uuid, uuid, timestamptz) set search_path = pg_catalog, cma, pg_temp;

-- A5's rule, before the commit: every SECURITY DEFINER function of cma and cma_read ends its search path in pg_temp
do $$
declare
  v_bad text;
begin
  select string_agg(n.nspname || '.' || p.proname, ', ' order by n.nspname collate "C", p.proname collate "C") into v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('cma', 'cma_read') and p.prosecdef
    and not exists (select 1 from unnest(p.proconfig) c where c ~ '^search_path=.*pg_temp$');
  if v_bad is not null then
    raise exception 'SECURITY DEFINER functions without pg_temp last in their search path: %', v_bad;
  end if;
end
$$;

insert into cma.schema_migration (version, description)
values ('0010b', 'The two readers'' wrappers of 134 (cma.workday_stretches_reader_of, cma.workday_summary_reader_of, SECURITY DEFINER) end their search path in pg_temp: search_path = pg_catalog, cma, pg_temp (CMA-155, 77''s A5); every SECURITY DEFINER function of cma and cma_read checked before the commit')
on conflict (version) do nothing;

commit;
reset role;
