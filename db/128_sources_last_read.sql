-- =============================================================================================
-- 128_sources_last_read.sql: addition 0008zq, Configuration → Sources shows a connection's last read
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics: a connection's reads are its own rows of cma.sync_run, whatever the
-- adapter and whatever the job. Runs unchanged in every database, after 126_workday_sessions.sql (0008zp). Rerunnable,
-- forward-only, in one transaction with a lock timeout. Run as your own IAM login: dev first, then
-- 129_verify_sources_last_read.sql (dev and prod), then 53 (its B2 reads cma.sources() by column name) and 79 again
-- (unchanged, still PASS); then prod, 128 before the merge (the web of this change reads the five columns below and
-- cma.source_reads), then 129. The web of main runs unchanged on it: web/src/lib/data/postgres.ts reads `select * from cma.sources()` and maps the
-- columns it knows by name, so five more columns at the end change nothing it shows. No table, view or column changes,
-- so docs/datamap/schema.json needs no refresh and docs/datamap/catalog.json is unchanged.
--
-- Why (Decision log, 4 November 2026; prod on that day): the Sources page showed Juo GB, Trusted Shops Subscriptions
-- and the asset register with `0` events and `Never`, while each was read on schedule (Juo GB 288 polls a day since
-- 29 October, Trusted Shops hourly since 25 October). cma.sources() (0008e, 52) derives events_24h, events_waiting,
-- events_needs_review and last_event_at from cma.ingest_event alone, and a polled source (ingest-poll-reviews,
-- ingest-poll-subscriptions, ingest-poll-assets) writes cma.sync_run rows, never an ingest event. Reports → Flash already
-- reads the right thing per source kind (cma.flash_sources_of, 122); this addition gives the Sources page the same per
-- connection, next to the events, so no connection that is read reads "Never".
--
-- What it changes
--   cma.sources()      dropped and created again (a function's return type cannot change under create or replace): the
--                      same permission check (tenant.configure), the same columns in the same order, then five more:
--                        last_read_at        timestamptz  the finish of the connection's latest started succeeded sync_run,
--                                                         any job (a long reconcile that started before a poll and finished
--                                                         after it is not the last read: the poll is)
--                        last_read_job       text         that run's job (sync_run's own vocabulary: backfill, reconcile,
--                                                         reviews_poll, subscriptions_poll, assets_poll, ...)
--                        reads_24h           integer      sync_run rows of the connection started in the last 24 hours
--                        reads_failed_24h    integer      of those, status failed
--                        last_read_error     text         the error of the latest failed run started in the last 24 hours
--                                                         (a code the ingest writes, never a value), null otherwise
--                      Owner cma_owner, execute for cma_app only, as 52 set them. Every read of cma.sync_run here is served
--                      by sync_run_started_idx (tenant_id, connection_id, started_at) of 32: the 24-hour counts as a range,
--                      the latest succeeded run and the latest failed run as the index scanned backward that stops at the
--                      first match (order by started_at desc, id desc). Measured in cma-dev-pg on 5 November 2026 on the
--                      HubSpot connection's 40,534 runs: ordered by finished_at 125 ms (a parallel seq scan and a top-N
--                      sort), ordered by started_at 0.14 ms (an index scan backward); Decision log, 5 November 2026.
--   cma.source_reads(connection_id)   new (the connection's page, Reads panel): the connection's last 20 cma.sync_run rows,
--                      newest first (started_at desc, id desc): run_id, job, stream, started_at, finished_at, status, the
--                      counts the run recorded and its error (a code the ingest writes, never a value). tenant.configure;
--                      the tenant's own connection only (another tenant's id answers no rows). Owner cma_owner, execute for
--                      cma_app only, as cma.sources()
-- What it does not change
--   cma.system_health_runs() (78) and cma.flash_sources_of (122): System health keeps its own per-job rows and Flash its
--   per-kind last read; both read cma.sync_run as before. No row is changed.
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
  if not exists (select 1 from cma.schema_migration where version = '0008zp') then
    raise exception 'addition 0008zp (126_workday_sessions.sql) must run before 0008zq';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. cma.sources(): 52's read, with the connection's reads from cma.sync_run after the events
-- ---------------------------------------------------------------------------------------------
drop function if exists cma.sources();

create function cma.sources()
returns table (
  connection_id        uuid,
  key                  text,
  adapter              text,
  name                 text,
  external_account_id  text,
  kind                 text,
  held_kinds           text[],
  status               text,
  signing_secret_name  text,
  token_secret_name    text,
  settings             jsonb,
  events_24h           integer,
  events_waiting       integer,
  events_needs_review  integer,
  last_event_at        timestamptz,
  pipelines            integer,
  forms                integer,
  call_outcomes        integer,
  fields               integer,
  lines                integer,
  tags                 integer,
  store_handle         text,
  last_read_at         timestamptz,
  last_read_job        text,
  reads_24h            integer,
  reads_failed_24h     integer,
  last_read_error      text
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('tenant.configure');
  return query
    select c.id, c.key::text, c.adapter::text, c.name::text, c.external_account_id::text, c.kind::text,
           cma.connection_held_kinds_of(c.tenant_id, c.id), c.status::text,
           c.signing_secret_name::text, c.token_secret_name::text, c.settings,
           (select count(*)::integer from cma.ingest_event e where e.tenant_id = c.tenant_id and e.connection_id = c.id and e.recorded_at > now() - interval '24 hours'),
           (select count(*)::integer from cma.ingest_event e where e.tenant_id = c.tenant_id and e.connection_id = c.id and e.status in ('received', 'failed')),
           (select count(*)::integer from cma.ingest_event e where e.tenant_id = c.tenant_id and e.connection_id = c.id and e.status = 'needs_review'),
           (select max(e.recorded_at) from cma.ingest_event e where e.tenant_id = c.tenant_id and e.connection_id = c.id),
           (select count(*)::integer from cma.connection_pipeline x where x.tenant_id = c.tenant_id and x.connection_id = c.id),
           (select count(*)::integer from cma.connection_form x where x.tenant_id = c.tenant_id and x.connection_id = c.id),
           (select count(*)::integer from cma.connection_call_outcome x where x.tenant_id = c.tenant_id and x.connection_id = c.id),
           (select count(*)::integer from cma.connection_field x where x.tenant_id = c.tenant_id and x.connection_id = c.id),
           (select count(*)::integer from cma.telephony_number x where x.tenant_id = c.tenant_id and x.connection_id = c.id),
           (select count(*)::integer from cma.telephony_tag x where x.tenant_id = c.tenant_id and x.connection_id = c.id),
           (select s.handle::text from cma.commerce_store s where s.tenant_id = c.tenant_id and s.connection_id = c.id),
           -- the connection's reads (addition 0008zq): a polled source writes runs, never an event
           lr.finished_at,
           lr.job::text,
           (select count(*)::integer from cma.sync_run r where r.tenant_id = c.tenant_id and r.connection_id = c.id and r.started_at > now() - interval '24 hours'),
           (select count(*)::integer from cma.sync_run r where r.tenant_id = c.tenant_id and r.connection_id = c.id and r.started_at > now() - interval '24 hours' and r.status = 'failed'),
           (select r.error::text from cma.sync_run r where r.tenant_id = c.tenant_id and r.connection_id = c.id and r.started_at > now() - interval '24 hours' and r.status = 'failed'
             order by r.started_at desc, r.id desc limit 1)
    from cma.integration_connection c
    -- the latest started succeeded run, shown by its finish: sync_run_started_idx scanned backward, stopping at the first match
    left join lateral (select r.finished_at, r.job from cma.sync_run r
                       where r.tenant_id = c.tenant_id and r.connection_id = c.id and r.status = 'succeeded'
                       order by r.started_at desc, r.id desc limit 1) lr on true
    where c.tenant_id = cma.current_tenant_id()
    order by c.name, c.id;
end
$$;

comment on function cma.sources() is 'Every connection of the tenant (tenant.configure): kind, held kinds, secret names, settings, its events of cma.ingest_event (24 hours, waiting, for review, the last) and, since 0008zq, its reads of cma.sync_run (the latest started succeeded run, shown by its finish, and its job; the runs and failed runs of the last 24 hours; the latest started failure''s code), and its catalog sizes';

-- ---------------------------------------------------------------------------------------------
-- 2. cma.source_reads(): one connection's last 20 runs, newest first (the connection page's Reads panel)
-- ---------------------------------------------------------------------------------------------
create or replace function cma.source_reads(p_connection_id uuid)
returns table (
  run_id       uuid,
  job          text,
  stream       text,
  started_at   timestamptz,
  finished_at  timestamptz,
  status       text,
  counts       jsonb,
  error        text
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('tenant.configure');
  return query
    select r.id, r.job::text, r.stream::text, r.started_at, r.finished_at, r.status::text, r.counts, r.error::text
    from cma.sync_run r
    where r.tenant_id = cma.current_tenant_id() and r.connection_id = p_connection_id
    order by r.started_at desc, r.id desc
    limit 20;
end
$$;

comment on function cma.source_reads(uuid) is 'One connection''s last 20 runs of cma.sync_run, newest first (tenant.configure; the tenant''s own connection only): job, stream, started and finished, status, the counts the run recorded, its error code';

-- ---------------------------------------------------------------------------------------------
-- 3. Privileges: the application only, as 52 set them (a dropped function loses its grants)
-- ---------------------------------------------------------------------------------------------
revoke execute on function cma.sources() from public;
grant execute on function cma.sources() to cma_app;
revoke execute on function cma.source_reads(uuid) from public;
grant execute on function cma.source_reads(uuid) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 4. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008zq', 'Sources last read: cma.sources() (0008e) recreated with five columns after the catalog sizes, last_read_at, last_read_job, reads_24h, reads_failed_24h and last_read_error, read from the connection''s own cma.sync_run rows, so a polled connection (reviews, subscriptions, assets) that writes runs and never an ingest event shows its last read on Configuration → Sources instead of Never; same permission, same columns before them, same grants; cma.source_reads(connection_id), the connection''s last 20 runs newest first for the connection page''s Reads panel')
on conflict (version) do nothing;

commit;
reset role;
