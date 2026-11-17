-- =============================================================================================
-- 196_sync_run_reads.sql: addition 0009x, prod's slowdown part 2: the sync_run reads of Data quality, the Flash landing
-- and System health read only what they need
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 194_audit_bookkeeping.sql
-- (0009w). Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own IAM login: first the three
-- indexes below from the Terminal (dev, then prod), then this script in dev, 197_verify_sync_run_reads.sql there (normal,
-- then provoked), the verifies below, then prod the same way before the merge of its pull request, outside office hours
-- (the last section locks cma.sync_run against writes while it counts the existing runs: about a second at prod's volume;
-- a job that starts meanwhile waits for it; on a rerun readers wait too, see section 5).
-- Main's web and the ingest run unchanged on it: the two functions keep their names, arguments, columns and answers.
--
-- First, from the Terminal (never Studio: Studio wraps a script in a transaction, which a concurrent build refuses), on
-- cma.sync_run, a busy table (CLAUDE.md, Performance): dev, then prod, each index its own statement with set role
-- cma_owner, lock_timeout '5s' and statement_timeout '10min' given as separate commands of the same session, then
-- pg_index.indisvalid checked (t; an f: drop index concurrently, then create it again). The pull request's Terminal blocks
-- give them ready to run. The script refuses to run until the three exist and are valid:
--   create index concurrently if not exists sync_run_succeeded_idx on cma.sync_run (tenant_id, connection_id, finished_at desc)
--     where status = 'succeeded';
--   create index concurrently if not exists sync_run_job_started_idx on cma.sync_run (tenant_id, job, connection_id, started_at desc, id desc);
--   create index concurrently if not exists sync_run_job_finished_idx on cma.sync_run (tenant_id, job, connection_id, status, finished_at desc, id desc)
--     include (started_at) where status in ('succeeded', 'failed');
--
-- Why (Martin, 17 November 2026; Decision log, 17 Nov 2026; evidence records/perf-prod-2026-11-16/prod-slowdown-diagnosis.txt,
-- #289, section 8): cma.data_quality() and the Flash landing (cma.flash_page) read 195,694 sync_run rows per call, and
-- cma.system_health_runs() 1,061,425 (three passes over the 30 days); sync_run grows by about 25,000 rows a day in prod
-- (38,000 with Pulse4all Invest's), so every call grows with it.
--   cma.flash_sources_of(tenant) (148), called by both Data quality and the Flash landing, takes per source kind the
--     latest finish of a succeeded run of the kind's connections as max(finished_at) over every such run: no index orders
--     a connection's succeeded runs by their finish, so every succeeded run of the tenant's history was read, once per
--     kind. Now: per connection its latest succeeded finish, one probe of sync_run_succeeded_idx, and the kind's max over
--     those. Same answer: the max over a set is the max of its parts' maxima.
--   cma.system_health_runs() (132) grouped every run of the 30 days, then the failed ones again. Now: the job and
--     connection pairs by a loose index scan of sync_run_job_started_idx (one probe per job and connection), their runs of
--     the last 24 hours from cma.sync_run_hour (below, one row per pair and UTC hour), the runs of the one hour that
--     straddles the 24 hours' start counted from sync_run_job_started_idx; per pair its
--     latest run (sync_run_job_started_idx), its latest succeeded finish and its latest failed run among the runs started
--     in the 30 days (sync_run_job_finished_idx, newest finish first, the first started in the 30 days). Same rows,
--     columns and order as 132's: 197 compares both definitions at the same instant.
--
-- What it adds
--   cma.sync_run_hour       per tenant, job, connection (none for the scheduler's jobs) and UTC hour of the start: runs
--                           (every run started in that hour, whatever its status) and failed (those failed). Bookkeeping:
--                           tenant-scoped (row-level security), no audit trigger (0009w), read only for the application;
--                           kept by the trigger below and filled once from every existing run in section 5
--   cma.sync_run_hour_count()  the trigger function (owner's rights, pinned search path): after a run's insert, its delete,
--                           or an update of its tenant, job, connection or start, or into or out of failed, moves its
--                           count; a run that finishes succeeded writes nothing
--   cma_read.sync_run_hour  the readers' view
--   three indexes on cma.sync_run (above, from the Terminal); sync_run's autovacuum at 2 % (vacuum and insert vacuum)
-- What it re-creates (same signature, rights and answers)
--   cma.flash_sources_of(uuid)       based on 148_installed_base_list.sql
--   cma.system_health_runs()         based on 132_perf.sql; now says its rows (50)
-- Verifies to run again after this script (dev first, then prod where they run there):
--   reading cma.system_health_runs directly: 79_verify_system_health.sql and 81_verify_follow_up_snapshot.sql (dev only),
--     133_verify_perf.sql (E2 compares it with its own earlier definition)
--   reading cma.flash_sources_of directly: 123, 137, 139, 147, 149 (A3 and D1 compare it with 0008zn's answer), 159, 181
--   reading it through a caller: 169_verify_pledge_lists.sql (cma.pledge_snapshot_write); through cma.data_quality,
--     cma.flash_page, flash_rows(_of), flash_compute_of and flash_document_of also 41, 69, 73, 75, 105, 113, 143, 161, 173,
--     189 and 193, which the ones above cover (run them where a release runs them anyway)
--   195_verify_audit_bookkeeping.sql (0009w: sync_run's triggers and audit rows)
--   the time scripts: 131_time_all.sql part a (System health, Data quality, the Flash landing), prod outside office hours
-- None is edited by this change: each comparison keeps the definition it compares with. web/verify/flash.mjs (pure) now
-- expects cma.flash_sources_of's latest definition in this script.
--
-- Re-running cma.setup_tenant_table('cma.sync_run_hour') would give the application insert, update and delete on it again
-- and put an audit trigger back: a later migration that calls it repeats this script's section 1 after it.
--
-- The writes it adds: one upsert of a small row per run started and none per run finished succeeded (one per run that
-- fails); the three indexes take an entry per run, the two partial ones per finished run. A run's finish now changes an
-- indexed column (status), so its update is no longer a heap-only update: every index of sync_run takes the new version.
--
-- SQLSTATEs: none new.
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
  if not exists (select 1 from cma.schema_migration where version = '0009w') then
    raise exception 'addition 0009w (194_audit_bookkeeping.sql) has not run in this database';
  end if;
  -- valid, and as the header defines them (a mistyped Terminal statement is refused here)
  if (select count(*) from pg_index i join pg_class c on c.oid = i.indexrelid
      where c.relnamespace = 'cma'::regnamespace and i.indrelid = 'cma.sync_run'::regclass and i.indisvalid
        and pg_get_indexdef(c.oid) in (
          'CREATE INDEX sync_run_succeeded_idx ON cma.sync_run USING btree (tenant_id, connection_id, finished_at DESC) WHERE (status = ''succeeded''::text)',
          'CREATE INDEX sync_run_job_started_idx ON cma.sync_run USING btree (tenant_id, job, connection_id, started_at DESC, id DESC)',
          'CREATE INDEX sync_run_job_finished_idx ON cma.sync_run USING btree (tenant_id, job, connection_id, status, finished_at DESC, id DESC) INCLUDE (started_at) WHERE (status = ANY (ARRAY[''succeeded''::text, ''failed''::text]))')) <> 3 then
    raise exception 'the indexes sync_run_succeeded_idx, sync_run_job_started_idx and sync_run_job_finished_idx must exist, be valid and be defined as this script''s header says first: create them concurrently from the Terminal';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. cma.sync_run_hour: the runs per job, connection and UTC hour
-- ---------------------------------------------------------------------------------------------
create table if not exists cma.sync_run_hour (
  tenant_id      uuid not null references cma.tenant (id),
  job            text not null,
  connection_id  uuid,
  hour           timestamptz not null check (hour = date_trunc('hour', hour, 'UTC')),
  runs           integer not null default 0 check (runs >= 0),
  failed         integer not null default 0 check (failed >= 0 and failed <= runs),
  constraint sync_run_hour_key unique nulls not distinct (tenant_id, job, connection_id, hour)
) with (fillfactor = 50);
-- a minute job's hour row is updated about 60 times an hour: free space on its page keeps those updates heap-only
alter table cma.sync_run_hour set (fillfactor = 50);
comment on table cma.sync_run_hour is 'The runs of cma.sync_run per tenant, job, connection (none for the scheduler''s jobs) and UTC hour of their start: runs (every status) and failed (0009x). Kept by the trigger sync_run_hour on cma.sync_run (cma.sync_run_hour_count); read by System health (cma.system_health_runs). Bookkeeping: not audited, read only for the application';
select cma.setup_tenant_table('cma.sync_run_hour');
drop trigger if exists audit on cma.sync_run_hour;
revoke insert, update, delete on cma.sync_run_hour from cma_app;

create or replace view cma_read.sync_run_hour as
  select tenant_id, job, connection_id, hour, runs, failed
  from cma.sync_run_hour
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 2. The trigger function: a run's count moves with it
-- ---------------------------------------------------------------------------------------------
-- The key's connection is compared with = or is null (an index condition either way, unlike is not distinct from)
create or replace function cma.sync_run_hour_count()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, cma, pg_temp
as $$
declare
  v_same boolean := tg_op = 'UPDATE' and old.tenant_id = new.tenant_id and old.job = new.job
                    and old.connection_id is not distinct from new.connection_id
                    and date_trunc('hour', old.started_at, 'UTC') = date_trunc('hour', new.started_at, 'UTC');
begin
  if v_same then
    -- the same hour: only a move into or out of failed counts
    if (old.status = 'failed') is distinct from (new.status = 'failed') then
      if new.connection_id is null then
        update cma.sync_run_hour h set failed = h.failed + case when new.status = 'failed' then 1 else -1 end
        where h.tenant_id = new.tenant_id and h.job = new.job and h.connection_id is null and h.hour = date_trunc('hour', new.started_at, 'UTC');
      else
        update cma.sync_run_hour h set failed = h.failed + case when new.status = 'failed' then 1 else -1 end
        where h.tenant_id = new.tenant_id and h.job = new.job and h.connection_id = new.connection_id
          and h.hour = date_trunc('hour', new.started_at, 'UTC');
      end if;
    end if;
    return null;
  end if;
  if tg_op in ('UPDATE', 'DELETE') then
    if old.connection_id is null then
      update cma.sync_run_hour h set runs = h.runs - 1, failed = h.failed - case when old.status = 'failed' then 1 else 0 end
      where h.tenant_id = old.tenant_id and h.job = old.job and h.connection_id is null and h.hour = date_trunc('hour', old.started_at, 'UTC');
    else
      update cma.sync_run_hour h set runs = h.runs - 1, failed = h.failed - case when old.status = 'failed' then 1 else 0 end
      where h.tenant_id = old.tenant_id and h.job = old.job and h.connection_id = old.connection_id
        and h.hour = date_trunc('hour', old.started_at, 'UTC');
    end if;
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    insert into cma.sync_run_hour as h (tenant_id, job, connection_id, hour, runs, failed)
    values (new.tenant_id, new.job, new.connection_id, date_trunc('hour', new.started_at, 'UTC'), 1,
            case when new.status = 'failed' then 1 else 0 end)
    on conflict (tenant_id, job, connection_id, hour) do update
      set runs = h.runs + 1, failed = h.failed + excluded.failed;
  end if;
  return null;
end
$$;
revoke execute on function cma.sync_run_hour_count() from public;

-- ---------------------------------------------------------------------------------------------
-- 3. Data quality and the Flash landing: a source kind's last read, per connection through its index
-- ---------------------------------------------------------------------------------------------
-- As 0008zz (148), with last_read_at the max of each connection's latest succeeded finish (one probe of
-- sync_run_succeeded_idx per connection) instead of the max over every succeeded run of the kind's connections
-- based on: 148_installed_base_list.sql
create or replace function cma.flash_sources_of(p_tenant_id uuid)
returns jsonb
language sql stable
as $$
  with c as (
    select ic.id, ic.adapter,
           case when ic.kind is not null then ic.kind
                when exists (select 1 from cma.commerce_store x where x.tenant_id = ic.tenant_id and x.connection_id = ic.id) then 'commerce'
                else (cma.connection_held_kinds_of(ic.tenant_id, ic.id))[1] end as kind
    from cma.integration_connection ic
    where ic.tenant_id = p_tenant_id and ic.status = 'active'
  ), k as (
    select x.kind, array_agg(distinct c.adapter order by c.adapter) filter (where c.id is not null) as adapters,
           (select max(l.finished_at)
            from c c2
            cross join lateral (select r.finished_at from cma.sync_run r
                                where r.tenant_id = p_tenant_id and r.connection_id = c2.id and r.status = 'succeeded'
                                  and r.finished_at is not null
                                order by r.finished_at desc
                                limit 1) l
            where c2.kind = x.kind) as last_read_at
    from unnest(array['commerce', 'subscriptions', 'assets', 'crm', 'reviews']) x(kind)
    left join c on c.kind = x.kind
    group by x.kind
  )
  select jsonb_object_agg(k.kind, jsonb_build_object(
           'set_up', cma.flash_source_set_up_of(p_tenant_id, k.kind),
           'adapters', coalesce(to_jsonb(k.adapters), '[]'::jsonb),
           'last_read_at', k.last_read_at))
  from k
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. System health: the pairs and the day's counts from the hours, the rest per pair through its index
-- ---------------------------------------------------------------------------------------------
-- The same rows, columns and order as 0008zr's (132): per job and connection with a run started in the 30 days, the
-- latest run (started_at desc, id desc), the latest succeeded finish and the latest failed finish and its code
-- (finished_at desc, id desc) among the runs started in the 30 days, the runs and failed runs started in the 24 hours
--   pairs   every job of the tenant and each of its connections (and no connection), found by a loose index scan of
--           sync_run_job_started_idx (one probe each), kept when its latest run started in the 30 days; its runs of the
--           24 hours: the hours after the 24 hours' start summed (cma.sync_run_hour), the hour holding that start counted
--           from its runs
--   l       the latest run: sync_run_job_started_idx, newest first, the first row
--   o, b    the latest succeeded finish and the latest failed run: sync_run_job_finished_idx, newest finish first (a
--           failed run without a finish first, as the earlier ordered aggregate put it), the first started in the 30 days
-- A pair's connection is matched with = or is null in two branches of one lateral, so each branch is an index range; the
-- null branch orders by the index's whole key (job, connection, then time): ordered by time alone the planner, which does
-- not count is null as an equality, walked the tenant's runs by sync_run_tenant_started_idx instead (191 ms a probe locally
-- for a job never run without a connection)
-- based on: 132_perf.sql
create or replace function cma.system_health_runs()
returns table(
  job text, connection_id uuid,
  last_started_at timestamptz, last_finished_at timestamptz, last_status text, last_error text, last_counts jsonb,
  last_succeeded_at timestamptz, last_failed_at timestamptz, last_failed_error text,
  runs_24h integer, failed_24h integer)
language plpgsql stable
rows 50
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
  v_day    timestamptz := now() - interval '24 hours';
  v_month  timestamptz := now() - interval '30 days';
  v_edge   timestamptz := date_trunc('hour', now() - interval '24 hours', 'UTC');
begin
  perform cma.assert_permission('tenant.configure');
  return query
    with recursive j as (
      -- the tenant's jobs, one probe of sync_run_job_started_idx each (a loose index scan)
      select (select r.job from cma.sync_run r where r.tenant_id = v_tenant order by r.job limit 1) as job
      union all
      select (select r.job from cma.sync_run r where r.tenant_id = v_tenant and r.job > j.job order by r.job limit 1) from j where j.job is not null
    ), c as (
      -- per job its connections, likewise
      select j.job, (select r.connection_id from cma.sync_run r where r.tenant_id = v_tenant and r.job = j.job and r.connection_id is not null
                      order by r.connection_id limit 1) as connection_id
      from j where j.job is not null
      union all
      select c.job, (select r.connection_id from cma.sync_run r where r.tenant_id = v_tenant and r.job = c.job and r.connection_id > c.connection_id
                      order by r.connection_id limit 1)
      from c where c.connection_id is not null
    ), p0 as (
      -- every pair the tenant ever ran, and each job without a connection (dropped below when it has no such run)
      select c.job, c.connection_id from c where c.connection_id is not null
      union all
      select j.job, null::uuid from j where j.job is not null
    ), p as (
      -- the hours after the 24 hours' start, summed: at most 24 rows per pair (sync_run_hour_key)
      select p0.job, p0.connection_id, h.runs, h.failed
      from p0
      cross join lateral (
        select coalesce(sum(z.runs), 0)::integer as runs, coalesce(sum(z.failed), 0)::integer as failed
        from ((select x.runs, x.failed from cma.sync_run_hour x
               where x.tenant_id = v_tenant and x.job = p0.job and x.connection_id = p0.connection_id and x.hour > v_day)
              union all
              (select x.runs, x.failed from cma.sync_run_hour x
               where p0.connection_id is null and x.tenant_id = v_tenant and x.job = p0.job and x.connection_id is null
                 and x.hour > v_day)) z) h
    )
    select p.job, p.connection_id, l.started_at, l.finished_at, l.status, l.error, l.counts,
           o.finished_at, b.finished_at, b.error, p.runs + e.runs, p.failed + e.failed
    from p
    cross join lateral (
      (select r.started_at, r.finished_at, r.status, r.error, r.counts from cma.sync_run r
       where r.tenant_id = v_tenant and r.job = p.job and r.connection_id = p.connection_id
       order by r.started_at desc, r.id desc limit 1)
      union all
      (select r.started_at, r.finished_at, r.status, r.error, r.counts from cma.sync_run r
       where p.connection_id is null and r.tenant_id = v_tenant and r.job = p.job and r.connection_id is null
       order by r.job, r.connection_id, r.started_at desc, r.id desc limit 1)) l
    cross join lateral (
      select count(*)::integer as runs, (count(*) filter (where z.status = 'failed'))::integer as failed
      from ((select r.status from cma.sync_run r
             where r.tenant_id = v_tenant and r.job = p.job and r.connection_id = p.connection_id
               and r.started_at > v_day and r.started_at < v_edge + interval '1 hour')
            union all
            (select r.status from cma.sync_run r
             where p.connection_id is null and r.tenant_id = v_tenant and r.job = p.job and r.connection_id is null
               and r.started_at > v_day and r.started_at < v_edge + interval '1 hour')) z) e
    left join lateral (
      (select r.finished_at from cma.sync_run r
       where r.tenant_id = v_tenant and r.job = p.job and r.connection_id = p.connection_id and r.status = 'succeeded'
         and r.finished_at is not null and r.started_at > v_month
       order by r.finished_at desc limit 1)
      union all
      (select r.finished_at from cma.sync_run r
       where p.connection_id is null and r.tenant_id = v_tenant and r.job = p.job and r.connection_id is null and r.status = 'succeeded'
         and r.finished_at is not null and r.started_at > v_month
       order by r.job, r.connection_id, r.status, r.finished_at desc limit 1)) o on true
    left join lateral (
      (select r.finished_at, r.error from cma.sync_run r
       where r.tenant_id = v_tenant and r.job = p.job and r.connection_id = p.connection_id and r.status = 'failed'
         and r.started_at > v_month
       order by r.finished_at desc, r.id desc limit 1)
      union all
      (select r.finished_at, r.error from cma.sync_run r
       where p.connection_id is null and r.tenant_id = v_tenant and r.job = p.job and r.connection_id is null and r.status = 'failed'
         and r.started_at > v_month
       order by r.job, r.connection_id, r.status, r.finished_at desc, r.id desc limit 1)) b on true
    where l.started_at > v_month
    order by p.job, p.connection_id;
end
$$;

-- a function made again keeps its grants (the application's, 132 and 148), not its settings: neither had one; the new
-- system_health_runs gets one, below
revoke execute on function cma.system_health_runs() from public;
revoke execute on function cma.flash_sources_of(uuid) from public;
grant execute on function cma.system_health_runs() to cma_app;
grant execute on function cma.flash_sources_of(uuid) to cma_app;
-- JIT off on system_health_runs: its loose index scan is a recursive CTE whose row estimate (10,000 per level) lifts the
-- plan's cost past jit_above_cost, and compiling it cost 800 ms a call locally against a few milliseconds of execution
alter function cma.system_health_runs() set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 5. The counts of every existing run, then the trigger. Last: the lock on cma.sync_run (SHARE ROW EXCLUSIVE, which
--    CREATE TRIGGER takes too) holds every run's insert, finish and delete until the commit, so none is counted twice or
--    missed (CLAUDE.md, Performance; 132, section 10); a statement timeout of 120 s bounds it. A rerun counts again from
--    scratch, and its DROP TRIGGER of the existing triggers takes ACCESS EXCLUSIVE: on a rerun readers of sync_run wait too
-- ---------------------------------------------------------------------------------------------
-- sync_run vacuumed after 2 % of its rows changed or were inserted, not the default 20 %: a run's finish now writes a new
-- version into every index, and the recent pages the 24 hours' reads visit become all-visible within hours, not days.
-- A storage parameter takes SHARE UPDATE EXCLUSIVE: no reader or writer waits
alter table cma.sync_run set (autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_insert_scale_factor = 0.02);

set local statement_timeout = '120s';
lock table cma.sync_run in share row exclusive mode;
delete from cma.sync_run_hour;
insert into cma.sync_run_hour (tenant_id, job, connection_id, hour, runs, failed)
select r.tenant_id, r.job, r.connection_id, date_trunc('hour', r.started_at, 'UTC'), count(*)::integer,
       (count(*) filter (where r.status = 'failed'))::integer
from cma.sync_run r
group by 1, 2, 3, 4;
drop trigger if exists sync_run_hour on cma.sync_run;
create trigger sync_run_hour after insert or delete on cma.sync_run
  for each row execute function cma.sync_run_hour_count();
drop trigger if exists sync_run_hour_change on cma.sync_run;
create trigger sync_run_hour_change after update on cma.sync_run
  for each row
  when (old.tenant_id is distinct from new.tenant_id or old.job is distinct from new.job
        or old.connection_id is distinct from new.connection_id or old.started_at is distinct from new.started_at
        or (old.status = 'failed') is distinct from (new.status = 'failed'))
  execute function cma.sync_run_hour_count();

-- ---------------------------------------------------------------------------------------------
-- 6. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009x', 'Prod''s slowdown part 2 (Martin, 17 November 2026): the sync_run reads read what they need. cma.sync_run_hour (runs and failed per tenant, job, connection and UTC hour; kept by the triggers sync_run_hour and sync_run_hour_change on cma.sync_run through cma.sync_run_hour_count; not audited; cma_read.sync_run_hour); cma.flash_sources_of (148) takes a kind''s last read per connection through sync_run_succeeded_idx; cma.system_health_runs (132) takes its pairs and 24-hour counts from the hours and the rest per pair through sync_run_job_started_idx and sync_run_job_finished_idx (the three indexes built concurrently from the Terminal first); same answers')
on conflict (version) do nothing;

commit;
reset role;
