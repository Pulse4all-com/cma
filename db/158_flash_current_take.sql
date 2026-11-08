-- =============================================================================================
-- 158_flash_current_take.sql: addition 0009e, the installed base's first paint from a stored current take
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics: which overviews keep a current take and how often it is refreshed
-- are tenant settings, never code. Runs unchanged in every database, after 156_courtesy_completed_orders.sql (0009d).
-- Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own IAM login, away from the minutes the
-- snapshot job runs (it takes the flash_watch_finding constraint's lock last, see section 7): dev first, then
-- 159_verify_flash_current_take.sql there, then the verifies that read what this remakes (below); then the merge; then
-- the same in prod right after the merge, before the job's redeploy with the merge's image
-- (docs/scheduler/deploy-flash.sh, every minute since this addition). main's web runs unchanged on it: the document keeps
-- every key and gains refreshed_at, and as_of is the instant its figures were computed (the take's, or now as before).
-- Until the job runs on the merge's image at its new cadence no current take is written, and the page reads live, as
-- today.
--
-- Why (Martin, 8 November 2026; brief 0009e; Decision log, 8 Nov 2026, D1 to D6): Assets → Installed base (and Flash's
-- installed_base overview, the same code) took a total p50 of 2,008 ms and p95 of 2,898 ms in prod over 7 days (64
-- loads), dbMs p50 1,223 ms: the document is the live computation over every device (cma.flash_compute_of). Its first
-- paint is to come within the report budget (time to first byte p75 400 ms), the records list streaming after it as
-- today. So the now of an overview of the tenant setting flash.current_overviews is read from a stored current take: the
-- live computation's rows (cma.flash_compute_of, the one code path the dated snapshot uses too), stored per tenant and
-- overview, replaced when older than flash.current_refresh_minutes by the snapshot job (the scheduler's flash.snapshot,
-- SECURITY DEFINER writers owned by cma_owner; the application writes nothing), shown with its Refreshed at. A take that
-- is missing, older than three times the setting, or older than a change of definition or setting is not read: now is
-- then computed live, slow but correct, never silently old figures; System health shows the job failing and the watch
-- opens current_stale.
--
-- What it adds
--   settings              flash.current_overviews (installed_base): the stock overviews but data quality whose now comes
--                         from a current take, each once, comma-separated, spaces removed; empty: every now is live.
--                         flash.current_refresh_minutes (5; 1 to 1440): how old a take may be before the job takes it
--                         again; a take older than three times it is not read. Checked by cma.check_flash_current_setting()
--                         beside cma.check_tenant_setting() (0009a's branches unchanged), as data_quality.refresh_minutes
--   cma.flash_current_take  one current take per tenant and overview: one row per grouping set as cma.flash_compute_of
--                         gives it live (dims, measures), the definition version and computed_at ("Refreshed at"), the
--                         row shape of cma.flash_snapshot without a date or run; replaced whole by every refresh (no
--                         growth). cma.setup_tenant_table() (row-level security, the tenant policy) without the audit
--                         trigger (a derived table rewritten every few minutes, as cma.data_quality_snapshot), and no
--                         insert, update or delete for the application: the refresh alone writes it
--   cma.flash_current_keys()  the overviews a current take may hold: the stock overviews but data quality (a flow's now is
--                         a period; data quality reads its own stored result since 0008zr)
--   cma.flash_current_overviews_ok(value), cma.flash_current_overviews_of(tenant)  the setting's form; the tenant's list
--   cma.flash_current_state_of(tenant, overview, computed_at, version, now)  one derivation for the read, the refresh and
--                         the watch: off (not in the setting), none (no take), outdated (another definition version, or
--                         computed before the latest migration), fresh (younger than the setting), usable (younger than
--                         three times it), stale (older)
--   cma.flash_current_forget()  a tenant's setting written, changed or reset (a reset deletes its row) removes that
--                         tenant's current takes (trigger forget_flash_current_takes on cma.tenant_setting, SECURITY
--                         DEFINER: the writer of a setting holds no write on the takes), so no take computed under the
--                         earlier settings is read: now is live until the next refresh takes it under the new ones.
--                         Configuration outside the settings (device statuses and their flags, models, markets) follows
--                         the refresh interval as the data does
--   cma.flash_current_refresh_of(tenant, overview, force)  the owner's alone: unless fresh (reason fresh, checked before
--                         the lock and again under it), under a transaction-level advisory lock per tenant and overview
--                         (a second refresh at the same time skips, reason running), replaces the take with
--                         cma.flash_compute_of's rows now; flash.snapshot and the current tenant checked first
--   cma.flash_current_refresh(tenant)  the job's entry: SECURITY DEFINER, owned by cma_owner, search path pinned, the
--                         application's only; flash.snapshot and the current tenant first; removes the takes of overviews no
--                         longer in the setting and refreshes each overview of the setting in a subtransaction of its
--                         own, so one overview's failure is counted (current_failed, current_error: its SQLSTATE) and
--                         never costs another's take; an overview whose source is not set up keeps none (current_not_set_up)
--   reads                 cma.flash_document_of (and so cma.flash_overview, its one caller) reads a stock overview's now
--                         from its take when it may be read (fresh or usable), else computes it live as before; the
--                         document gains refreshed_at (the take's instant, null when computed by the read) and as_of is
--                         the instant the figures were computed. As of a date, flows, the records (cma.flash_rows), the
--                         files' records, the landing and its cards (cma.flash_page, cma.flash_headline) are unchanged
--   the watch             cma.flash_watch_of opens current_stale for an overview of the setting whose take exists but is
--                         older than three times the setting at the take; flash_watch_finding's kind check takes it
--   readers               cma_read.flash_current_take (every column), as cma_read.flash_snapshot
-- Remade (each from its latest earlier definition, its `-- based on:` line above it): cma.flash_document_of (136) and
-- cma.flash_watch_of (138), each with jit off again (a create or replace drops a function's settings).
-- Verifies that read what this remakes, rerun after it (grep -lw over db/*verify*.sql for cma.flash_document_of,
-- cma.flash_overview, cma.flash_watch_of, cma.flash_snapshot_take and cma.flash_snapshot_take_at):
-- 123_verify_flash.sql (edited by this addition: A3's settings list holds the two new flash.* settings once 0009e is
-- recorded), 137_verify_flash_insights.sql, 139_verify_flash_totals.sql, 147_verify_installed_base_models.sql; their
-- throwaway tenants hold no current take, so their answers are as before.
--
-- SQLSTATEs as before: CMA01 no acting user, CMA04 invalid, CMA06 not permitted.
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
  if not exists (select 1 from cma.schema_migration where version = '0009d') then
    raise exception 'addition 0009d (156_courtesy_completed_orders.sql) must run before 0009e';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The overviews a current take may hold, the settings and their checks
-- ---------------------------------------------------------------------------------------------
-- The stock overviews but data quality, in the overviews' order: a flow's now is a period (today by default), and data
-- quality reads its own stored result (0008zr)
create or replace function cma.flash_current_keys()
returns text[]
language sql immutable
as $$
  select array_agg(o.key order by o.sort_order) from cma.flash_overviews() o where o.kind = 'stock' and o.key <> 'data_quality'
$$;

-- flash.current_overviews' form: empty, or keys of cma.flash_current_keys(), each once, comma-separated
create or replace function cma.flash_current_overviews_ok(p_value text)
returns boolean
language sql immutable
as $$
  select cma.flash_list_ok(p_value, '^[a-z_]{1,40}$', 10, true)
         and not exists (select 1 from unnest(cma.flash_list_of(p_value)) x where not (x = any (cma.flash_current_keys())))
$$;

-- The tenant's overviews with a current take, in the setting's order (a key the list cannot hold is left out)
create or replace function cma.flash_current_overviews_of(p_tenant_id uuid)
returns text[]
language sql stable
as $$
  select coalesce(array_agg(x.k order by x.n), '{}'::text[])
  from unnest(cma.flash_list_of(cma.setting_of(p_tenant_id, 'flash.current_overviews'))) with ordinality x(k, n)
  where x.k = any (cma.flash_current_keys())
$$;

insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('flash.current_overviews', 'text', null, 'installed_base',
     'The Flash overviews whose now is read from a stored current take refreshed by the snapshot job, with its Refreshed at: stock overviews but data quality, each once, comma-separated; empty: every now is computed live'),
  ('flash.current_refresh_minutes', 'integer', null, '5',
     'How old a current take may be, in minutes (1 to 1440), before the snapshot job takes it again; a take older than three times this is not read and now is computed live')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- Their forms, checked beside cma.check_tenant_setting() (0009a's branches unchanged), as 0008zr's data-quality setting
create or replace function cma.check_flash_current_setting()
returns trigger
language plpgsql
as $$
begin
  if new.key = 'flash.current_overviews' then
    new.value := regexp_replace(new.value, '[[:space:]]+', '', 'g');
    if not cma.flash_current_overviews_ok(new.value) then
      raise exception 'Setting % takes stock Flash overviews but data quality (%), each once, comma-separated, or nothing',
        new.key, array_to_string(cma.flash_current_keys(), ', ') using errcode = 'CMA04';
    end if;
  end if;
  if new.key = 'flash.current_refresh_minutes'
     and (new.value !~ '^[0-9]{1,4}$' or new.value::integer not between 1 and 1440) then
    raise exception 'Setting % takes a whole number of minutes from 1 to 1440', new.key using errcode = 'CMA04';
  end if;
  return new;
end
$$;
-- (its trigger on cma.tenant_setting is created last, section 7: the lock it takes is held to the commit)

-- The scheduler's permission now covers the current takes too (its key and holders unchanged)
update cma.permission
set description = 'Take the daily Flash snapshot of the business date that just ended and refresh the current takes (the scheduler''s system user only; no default role)'
where key = 'flash.snapshot';

-- ---------------------------------------------------------------------------------------------
-- 2. The table
-- ---------------------------------------------------------------------------------------------
create table if not exists cma.flash_current_take (
  tenant_id           uuid not null default cma.current_tenant_id() references cma.tenant (id),
  overview            text not null,
  dims                jsonb not null,
  measures            jsonb not null,
  definition_version  text not null check (definition_version ~ '^[0-9a-z.]{1,20}$'),
  computed_at         timestamptz not null,
  primary key (tenant_id, overview, dims),
  check (cma.flash_row_ok(overview, dims, measures))
);
comment on table cma.flash_current_take is 'Flash: one current take per tenant and overview of flash.current_overviews: the figures as cma.flash_compute_of computed them live at computed_at (Refreshed at), one row per grouping set, dims and measures held to the overview''s allow-list, no id of a record and no @ (0009e). Written by the snapshot job''s refresh only (cma.flash_current_refresh), replaced whole when older than flash.current_refresh_minutes; derived, not audited';
comment on column cma.flash_current_take.computed_at is 'The instant the take was computed (the refresh''s transaction time): the page''s Refreshed at; the same on every row of a take';

select cma.setup_tenant_table('cma.flash_current_take');
-- A derived table rewritten every few minutes: no audit trigger (as cma.data_quality_snapshot, 0008zr); the refresh leaves
-- the job's sync_run row instead. Read only for the application: the refresh writes with the owner's rights
drop trigger if exists audit on cma.flash_current_take;
revoke insert, update, delete on cma.flash_current_take from cma_app;

-- ---------------------------------------------------------------------------------------------
-- 3. One derivation of a take's state
-- ---------------------------------------------------------------------------------------------
-- A take (its computed_at and definition version, as read with its rows) at p_now: off when the overview is not in the
-- tenant's flash.current_overviews; none without a take; outdated when stored under another definition version, or
-- computed before the latest migration (what the figures count may have changed; a change of the tenant's settings
-- removes its takes instead, cma.flash_current_forget below);
-- fresh when younger than flash.current_refresh_minutes (the refresh skips it); usable when younger than three times it
-- (the read takes it, the refresh takes it again); stale when older (the read computes now live). The read takes fresh
-- and usable; the refresh every state but fresh and off; the watch an old take of an overview of the setting
create or replace function cma.flash_current_state_of(p_tenant_id uuid, p_overview text, p_computed_at timestamptz, p_version text,
                                                      p_now timestamptz)
returns text
language sql stable
as $$
  select case
    when p_overview is null or not (p_overview = any (cma.flash_current_overviews_of(p_tenant_id))) then 'off'
    when p_computed_at is null then 'none'
    when p_version is distinct from cma.flash_definition_version(p_overview)
      or p_computed_at < (select max(m.applied_at) from cma.schema_migration m)
      then 'outdated'
    when p_computed_at > p_now - make_interval(mins => cma.setting_of(p_tenant_id, 'flash.current_refresh_minutes')::integer) then 'fresh'
    when p_computed_at > p_now - make_interval(mins => 3 * cma.setting_of(p_tenant_id, 'flash.current_refresh_minutes')::integer) then 'usable'
    else 'stale' end
$$;

-- A tenant's setting written, changed or reset (a reset deletes the row, cma.set_tenant_setting) removes that tenant's
-- current takes: what the figures count may follow the setting (bands, holding statuses, required references), and the
-- document's settings are now's, so a take computed under the earlier ones is never read; now is live until the job's
-- next refresh. SECURITY DEFINER, owned by cma_owner, search path pinned: whoever writes a setting holds no write on the
-- takes. The trigger itself is created last (section 7)
create or replace function cma.flash_current_forget()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, cma, pg_temp
as $$
begin
  delete from cma.flash_current_take c
  where c.tenant_id = case when tg_op = 'DELETE' then old.tenant_id else new.tenant_id end;
  return null;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. The refresh: the owner's writer and the job's entry
-- ---------------------------------------------------------------------------------------------
-- The advisory lock key of one tenant's current take of one overview
create or replace function cma.flash_current_lock_key(p_tenant_id uuid, p_overview text)
returns bigint
language sql immutable
as $$
  select hashtextextended(p_tenant_id::text || '/flash_current_take/' || p_overview, 0)
$$;

-- Replaces one overview's current take with the live computation's rows now (cma.flash_compute_of, as the read computes
-- now and the dated take a date: one code path), in the caller's transaction, computed_at its time. Under a
-- transaction-level advisory lock per tenant and overview: a second refresh at the same time skips (refreshed false,
-- reason running). Unless p_force, a take that is fresh is kept (reason fresh, read before the lock, so a fresh take is
-- answered without it, and again under it) and an overview not in the setting is left (reason off). An overview whose source is not set up keeps no take (reason not_set_up, any take removed): the read
-- computes now live, which answers not set up at once. The owner's alone (the job's entry runs it with the owner's rights, the application holds no write
-- on the table); flash.snapshot and the current tenant are checked first, as the take's writers check them
create or replace function cma.flash_current_refresh_of(p_tenant_id uuid, p_overview text, p_force boolean default false)
returns jsonb
language plpgsql
as $$
declare
  v_t0      timestamptz := clock_timestamp();
  v_at      timestamptz;
  v_version text;
  v_state   text;
  v_rows    integer;
begin
  perform cma.assert_permission('flash.snapshot');
  if p_tenant_id is null or p_tenant_id is distinct from cma.current_tenant_id() then
    raise exception 'a current take is refreshed for the current tenant only' using errcode = 'CMA06';
  end if;
  if p_overview is null or not (p_overview = any (cma.flash_current_keys())) then
    raise exception 'overview % keeps no current take: a stock overview but data quality does (%)', p_overview,
      array_to_string(cma.flash_current_keys(), ', ') using errcode = 'CMA04';
  end if;
  -- the state before the lock: a fresh take (or an overview not in the setting) is answered without taking it, so a long
  -- transaction holding the lock (a time script, a verify) never makes the job's every-minute run answer running
  select max(c.computed_at), min(c.definition_version) into v_at, v_version
  from cma.flash_current_take c where c.tenant_id = p_tenant_id and c.overview = p_overview;
  v_state := cma.flash_current_state_of(p_tenant_id, p_overview, v_at, v_version, now());
  if not coalesce(p_force, false) and v_state in ('fresh', 'off') then
    return jsonb_build_object('refreshed', false, 'reason', v_state)
           || case when v_state = 'fresh' then jsonb_build_object('age_seconds', floor(extract(epoch from now() - v_at))::integer) else '{}'::jsonb end;
  end if;
  if not pg_try_advisory_xact_lock(cma.flash_current_lock_key(p_tenant_id, p_overview)) then
    return jsonb_build_object('refreshed', false, 'reason', 'running');
  end if;
  -- the state again under the lock, so a refresh that committed meanwhile is seen
  select max(c.computed_at), min(c.definition_version) into v_at, v_version
  from cma.flash_current_take c where c.tenant_id = p_tenant_id and c.overview = p_overview;
  v_state := cma.flash_current_state_of(p_tenant_id, p_overview, v_at, v_version, now());
  if not coalesce(p_force, false) and v_state in ('fresh', 'off') then
    return jsonb_build_object('refreshed', false, 'reason', v_state)
           || case when v_state = 'fresh' then jsonb_build_object('age_seconds', floor(extract(epoch from now() - v_at))::integer) else '{}'::jsonb end;
  end if;
  delete from cma.flash_current_take c where c.tenant_id = p_tenant_id and c.overview = p_overview;
  if not coalesce(cma.flash_source_set_up_of(p_tenant_id, (select o.source from cma.flash_overviews() o where o.key = p_overview)), false) then
    return jsonb_build_object('refreshed', false, 'reason', 'not_set_up');
  end if;
  insert into cma.flash_current_take (tenant_id, overview, dims, measures, definition_version, computed_at)
  select p_tenant_id, p_overview, c.dims, c.measures, cma.flash_definition_version(p_overview), now()
  from cma.flash_compute_of(p_tenant_id, p_overview) c;
  get diagnostics v_rows = row_count;
  return jsonb_build_object('refreshed', true, 'rows', v_rows, 'state_before', v_state,
                            'duration_ms', floor(extract(epoch from clock_timestamp() - v_t0) * 1000)::integer);
end
$$;

-- The job's entry (flash.snapshot): the current tenant's current takes that are due. SECURITY DEFINER, owned by
-- cma_owner, search path pinned, executable by the application only: the application holds no write on the table, so
-- this is the one way a current take is written, always the live computation's. The permission and the tenant are
-- checked before anything else. The takes of overviews no longer in flash.current_overviews are removed; each overview of
-- the setting is refreshed when due, in a subtransaction of its own, so one overview's failure is counted with its
-- SQLSTATE (never its message, which may hold values) and the others keep theirs. The answer's keys are the job's run
-- row counts (whole numbers) and current_error
create or replace function cma.flash_current_refresh(p_tenant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, cma, pg_temp
as $$
declare
  v_t0        timestamptz := clock_timestamp();
  v_keys      text[];
  k           text;
  r           jsonb;
  v_refreshed integer := 0;
  v_fresh     integer := 0;
  v_running   integer := 0;
  v_not_set   integer := 0;
  v_failed    integer := 0;
  v_rows      integer := 0;
  v_error     text;
begin
  perform cma.assert_permission('flash.snapshot');
  if p_tenant_id is null or p_tenant_id is distinct from cma.current_tenant_id() then
    raise exception 'a current take is refreshed for the current tenant only' using errcode = 'CMA06';
  end if;
  v_keys := cma.flash_current_overviews_of(p_tenant_id);
  delete from cma.flash_current_take c where c.tenant_id = p_tenant_id and not (c.overview = any (v_keys));
  foreach k in array v_keys loop
    begin
      r := cma.flash_current_refresh_of(p_tenant_id, k, false);
      if (r ->> 'refreshed')::boolean then
        v_refreshed := v_refreshed + 1;
        v_rows := v_rows + (r ->> 'rows')::integer;
      elsif r ->> 'reason' = 'running' then
        v_running := v_running + 1;
      elsif r ->> 'reason' = 'not_set_up' then
        v_not_set := v_not_set + 1;
      else
        v_fresh := v_fresh + 1;
      end if;
    exception when others then
      v_failed := v_failed + 1;
      v_error := coalesce(v_error, sqlstate);
    end;
  end loop;
  return jsonb_build_object('current_refreshed', v_refreshed, 'current_fresh', v_fresh, 'current_running', v_running,
                            'current_not_set_up', v_not_set, 'current_failed', v_failed, 'current_rows', v_rows,
                            'current_duration_ms', floor(extract(epoch from clock_timestamp() - v_t0) * 1000)::integer)
         || case when v_error is not null then jsonb_build_object('current_error', v_error) else '{}'::jsonb end;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. The document: now from the current take when it may be read
-- ---------------------------------------------------------------------------------------------
-- As 0008zt (136), with the now of a stock overview of flash.current_overviews read from its stored current take when the
-- take may be read (cma.flash_current_state_of: fresh or usable), else computed live as before; as_of is the instant the
-- figures were computed (the take's, or this read's now), and refreshed_at the take's instant (null when computed live).
-- Every other key and every snapshot read as before. An overview's document for an explicit tenant (no permission
-- checked: the reads check it). Live (p_as_of null): the current take or cma.flash_compute_of now, a flow over p_from to
-- p_to (today when absent). A snapshot (p_as_of a date): a stock overview as stored for that date (CMA02 without a
-- succeeded snapshot), a flow summed over the dates of p_from to p_to (as_of alone when absent) that have one (CMA02 when
-- none has), the dates without one listed. The totals are the {} row, or the market's row when p_market is given (zeros
-- when the market has none); the rows every other grouping set's, of that market only when given
-- based on: 136_flash_insights.sql
create or replace function cma.flash_document_of(p_tenant_id uuid, p_overview text, p_market text, p_as_of date, p_from date, p_to date)
returns jsonb
language plpgsql stable
as $$
declare
  o          record;
  v_today    date := cma.tenant_today_of(p_tenant_id);
  v_from     date;
  v_to       date;
  v_mode     text;
  v_sources  jsonb;
  v_all      jsonb;
  v_dates    date[];
  v_missing  jsonb;
  v_version  text := cma.flash_definition_version(p_overview);
  v_total    jsonb;
  v_totals   jsonb;
  v_rows     jsonb;
  v_extra    jsonb := '{}'::jsonb;
  v_active   jsonb;
  -- the settings the figures followed: now's, or as of a date the snapshot run's (0008zt's three, absent from a run
  -- taken before them, read as null)
  v_run_settings jsonb;
  -- now from the overview's stored current take (0009e): the instant it was computed and its definition, null when the
  -- take may not be read (none, older than three times flash.current_refresh_minutes, or older than a change of
  -- definition or setting) and now is computed live
  v_taken        timestamptz;
  v_take_version text;
begin
  select * into o from cma.flash_overviews() x where x.key = p_overview;
  if o.kind = 'flow' then
    v_from := coalesce(p_from, p_as_of, v_today);
    v_to := coalesce(p_to, p_as_of, v_today);
  end if;
  if p_as_of is null then
    v_mode := 'live';
    v_sources := cma.flash_sources_of(p_tenant_id);
    -- a stock overview of flash.current_overviews reads its stored current take (0009e): the rows and the instant in one
    -- statement, so a refresh committing meanwhile is seen whole or not at all; a take that may not be read is computed
    -- live, as before (never silently old figures)
    if o.kind = 'stock' then
      select max(c.computed_at), min(c.definition_version),
             coalesce(jsonb_agg(jsonb_build_object('dims', c.dims, 'measures', c.measures) order by c.dims::text), '[]'::jsonb)
      into v_taken, v_take_version, v_all
      from cma.flash_current_take c
      where c.tenant_id = p_tenant_id and c.overview = p_overview;
      if cma.flash_current_state_of(p_tenant_id, p_overview, v_taken, v_take_version, now()) not in ('fresh', 'usable') then
        v_taken := null;
      end if;
    end if;
    if v_taken is null then
      select coalesce(jsonb_agg(jsonb_build_object('dims', c.dims, 'measures', c.measures) order by c.dims::text), '[]'::jsonb) into v_all
      from cma.flash_compute_of(p_tenant_id, p_overview, v_from, v_to) c;
    end if;
  else
    v_mode := 'snapshot';
    select array_agg(r.snapshot_date order by r.snapshot_date) into v_dates
    from cma.flash_snapshot_run r
    where r.tenant_id = p_tenant_id and r.status = 'succeeded'
      and r.snapshot_date between coalesce(v_from, p_as_of) and coalesce(v_to, p_as_of);
    if v_dates is null then
      raise exception 'no Flash snapshot for %', case when o.kind = 'flow' then v_from || ' to ' || v_to else p_as_of::text end
        using errcode = 'CMA02';
    end if;
    select r.sources, r.settings into v_sources, v_run_settings from cma.flash_snapshot_run r
    where r.tenant_id = p_tenant_id and r.status = 'succeeded' and r.snapshot_date = v_dates[cardinality(v_dates)];
    select coalesce(jsonb_agg(jsonb_build_object('dims', c.dims, 'measures', c.measures) order by c.dims::text), '[]'::jsonb) into v_all
    from cma.flash_snapshot_sum_of(p_tenant_id, p_overview, v_dates) c;
    select min(s.definition_version) into v_version from cma.flash_snapshot s
    where s.tenant_id = p_tenant_id and s.overview = p_overview and s.snapshot_date = any (v_dates);
    if o.kind = 'flow' then
      select coalesce(jsonb_agg(g::date order by g), '[]'::jsonb) into v_missing
      from generate_series(v_from, v_to, interval '1 day') g where not (g::date = any (v_dates));
      v_extra := v_extra || jsonb_build_object('days', jsonb_build_object('covered', cardinality(v_dates), 'missing', v_missing));
    end if;
  end if;

  -- the totals: the {} row, or the market's own row (zeros when the market has none); the rows of the other sets
  select r -> 'measures' into v_total from jsonb_array_elements(v_all) r where r -> 'dims' = '{}'::jsonb;
  if p_market is null then
    v_totals := v_total;
  else
    select r -> 'measures' into v_totals from jsonb_array_elements(v_all) r where r -> 'dims' = jsonb_build_object('market', p_market);
    if v_totals is null and v_total is not null then
      select jsonb_object_agg(e.key, case when jsonb_typeof(e.value) = 'object' then '{}'::jsonb else '0'::jsonb end) into v_totals
      from jsonb_each(v_total) e where e.key not in ('median_age_days', 'oldest_age_days', 'devices_per_holding_subscription');
    end if;
  end if;
  select coalesce(jsonb_agg(r order by (r -> 'dims')::text), '[]'::jsonb) into v_rows
  from jsonb_array_elements(v_all) r
  where r -> 'dims' <> '{}'::jsonb and (p_market is null or r -> 'dims' ->> 'market' = p_market);

  if p_overview = 'churn' then
    select coalesce(s.measures -> 'active_subscriptions', null) into v_active from cma.flash_snapshot s
    where s.tenant_id = p_tenant_id and s.overview = 'subscriptions' and s.snapshot_date = v_to
      and s.dims = case when p_market is null then '{}'::jsonb else jsonb_build_object('market', p_market) end;
    if v_active is null and exists (select 1 from cma.flash_snapshot_run r
                                    where r.tenant_id = p_tenant_id and r.status = 'succeeded' and r.snapshot_date = v_to) then
      v_active := '0'::jsonb;
    end if;
    if v_active is null and p_as_of is null and v_to >= v_today and (v_sources -> 'subscriptions' ->> 'set_up')::boolean then
      select to_jsonb(count(*)) into v_active from cma.flash_subscriptions_of(p_tenant_id) s
      where s.is_active and (p_market is null or s.market = p_market);
    end if;
    v_extra := v_extra || jsonb_build_object('active_at_end', v_active);
  elsif p_overview = 'data_quality' then
    v_extra := v_extra || jsonb_build_object('history', coalesce((
      select jsonb_agg(jsonb_build_object('date', s.snapshot_date, 'check', s.dims ->> 'check', 'findings', s.measures -> 'findings')
                       order by s.snapshot_date, s.dims ->> 'check')
      from cma.flash_snapshot s
      where s.tenant_id = p_tenant_id and s.overview = 'data_quality'
        and s.snapshot_date in (select r.snapshot_date from cma.flash_snapshot_run r
                                where r.tenant_id = p_tenant_id and r.status = 'succeeded' and r.snapshot_date <= coalesce(p_as_of, v_today)
                                order by r.snapshot_date desc limit 30)
        and s.dims ? 'check'
        and s.dims = case when p_market is null then jsonb_build_object('check', s.dims ->> 'check')
                          else jsonb_build_object('check', s.dims ->> 'check', 'market', p_market) end), '[]'::jsonb));
  end if;

  return jsonb_build_object(
    'overview', p_overview, 'kind', o.kind, 'mode', v_mode,
    -- now: the instant the figures were computed (the take's, or this read's); as of a date: that date
    'as_of', case when v_mode = 'live' then to_jsonb(coalesce(v_taken, now())) else to_jsonb(p_as_of) end,
    -- Refreshed at (0009e): the stored current take's instant, null when the figures were computed by this read
    'refreshed_at', v_taken,
    'from', v_from, 'to', v_to, 'market', p_market,
    'source', o.source,
    'set_up', case when o.source is null then true else coalesce((v_sources -> o.source ->> 'set_up')::boolean, false) end,
    'sources', v_sources,
    'totals', v_totals, 'rows', v_rows,
    'definition_version', v_version, 'headline', o.headline, 'dims', to_jsonb(o.dims), 'sets', o.sets, 'measures', to_jsonb(o.measures),
    'count_measures', to_jsonb(o.count_measures), 'sorts', to_jsonb(o.sorts),
    'labels', cma.flash_labels_of(p_tenant_id, p_overview),
    'settings', jsonb_build_object(
      'active_subscription_statuses', to_jsonb(cma.flash_active_statuses_of(p_tenant_id)),
      'ended_subscription_statuses', to_jsonb(cma.flash_ended_statuses_of(p_tenant_id)),
      'required_contact_refs', to_jsonb(cma.flash_list_of(cma.setting_of(p_tenant_id, 'commerce.required_contact_refs'))),
      'required_device_refs', to_jsonb(cma.flash_list_of(cma.setting_of(p_tenant_id, 'assets.required_refs'))),
      'negative_max_rating', cma.setting_of(p_tenant_id, 'reviews.negative_max_rating')::integer,
      'file_max_rows', cma.setting_of(p_tenant_id, 'flash.file_max_rows')::integer,
      'device_bands', case when p_as_of is null then to_jsonb(cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'flash.device_bands')))
                           when v_run_settings ? 'flash.device_bands' then to_jsonb(cma.flash_bounds_of(v_run_settings ->> 'flash.device_bands')) end,
      'subscription_age_months', case when p_as_of is null then to_jsonb(cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'flash.subscription_age_months')))
                                      when v_run_settings ? 'flash.subscription_age_months'
                                      then to_jsonb(cma.flash_bounds_of(v_run_settings ->> 'flash.subscription_age_months')) end,
      'customer_segments', case when p_as_of is null then to_jsonb(cma.flash_list_of(cma.setting_of(p_tenant_id, 'crm.customer_segments')))
                                when v_run_settings ? 'crm.customer_segments' then to_jsonb(cma.flash_list_of(v_run_settings ->> 'crm.customer_segments')) end)
      -- the statuses the figures count and their meanings, for the hints (now's: cma.flash_status_settings_of)
      || (cma.flash_status_settings_of(p_tenant_id) - 'active_subscription_statuses' - 'ended_subscription_statuses'),
    'first_snapshot_date', (select min(r.snapshot_date) from cma.flash_snapshot_run r where r.tenant_id = p_tenant_id and r.status = 'succeeded'),
    'today', cma.tenant_today_of(p_tenant_id), 'time_zone', (select t.timezone from cma.tenant t where t.id = p_tenant_id))
    || v_extra;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. The watch: current_stale
-- ---------------------------------------------------------------------------------------------
-- As 0008zu (138), with current_stale: an overview of flash.current_overviews whose current take exists and is older than
-- three times flash.current_refresh_minutes at the take's instant (the refresh is failing and the page computes its now
-- live). Every other kind as before
-- based on: 138_flash_totals.sql
create or replace function cma.flash_watch_of(p_tenant_id uuid, p_date date, p_now timestamptz)
returns jsonb
language plpgsql
as $$
declare
  v_pct      numeric := cma.setting_of(p_tenant_id, 'flash.watch_jump_pct')::numeric;
  v_min      numeric := cma.setting_of(p_tenant_id, 'flash.watch_jump_min')::numeric;
  v_floor    numeric := cma.setting_of(p_tenant_id, 'flash.watch_stale_min_minutes')::numeric;
  v_prev_ok  boolean;
  v_flow_ok  boolean;
  v_opened   integer;
  v_resolved integer;
begin
  perform cma.assert_permission('flash.snapshot');
  if p_tenant_id is null or p_tenant_id is distinct from cma.current_tenant_id() or p_date is null or p_now is null then
    raise exception 'the watch runs for the current tenant only' using errcode = 'CMA06';
  end if;
  v_prev_ok := exists (select 1 from cma.flash_snapshot_run r where r.tenant_id = p_tenant_id and r.snapshot_date = p_date - 1 and r.status = 'succeeded');
  v_flow_ok := (select count(*) from cma.flash_snapshot_run r
                where r.tenant_id = p_tenant_id and r.status = 'succeeded' and r.snapshot_date between p_date - 7 and p_date - 1) = 7;
  with sm as materialized (
    select * from cma.flash_subscription_stores_of(p_tenant_id)
  ), m as (
    select o.key as overview, unnest(o.count_measures) as measure, o.kind from cma.flash_overviews() o
  ), day_rows as (
    -- the [market] rows of the stock overviews and the [check] rows of data quality, on p_date and the date before
    select s.snapshot_date, s.overview, s.dims, e.key as measure, (e.value #>> '{}')::numeric as v
    from cma.flash_snapshot s
    cross join lateral jsonb_each(s.measures) e
    join m on m.overview = s.overview and m.measure = e.key and m.kind = 'stock'
    where s.tenant_id = p_tenant_id and s.snapshot_date in (p_date, p_date - 1) and jsonb_typeof(e.value) = 'number'
      and ((s.overview <> 'data_quality' and s.dims ? 'market' and (select count(*) from jsonb_object_keys(s.dims)) = 1)
           or (s.overview = 'data_quality' and s.dims ? 'check' and (select count(*) from jsonb_object_keys(s.dims)) = 1))
  ), na as (
    -- a count measure left out of an overview's totals row on either date does not apply that day (with_required_refs
    -- while no contact reference is required): it is not compared, so switching a requirement on or off is no jump
    select distinct s.overview, m.measure
    from cma.flash_snapshot s
    join m on m.overview = s.overview and m.kind = 'stock'
    where s.tenant_id = p_tenant_id and s.snapshot_date in (p_date, p_date - 1) and s.dims = '{}'::jsonb and not (s.measures ? m.measure)
    union
    -- an overview whose definition changed between the two dates (its totals stored under two versions, 0008zu): none of
    -- its measures is compared, so a change of what a figure counts is no jump
    select x.overview, m.measure
    from (select s.overview from cma.flash_snapshot s
          where s.tenant_id = p_tenant_id and s.snapshot_date in (p_date, p_date - 1) and s.dims = '{}'::jsonb
          group by s.overview having count(distinct s.definition_version) > 1) x
    join m on m.overview = x.overview and m.kind = 'stock'
  ), j as (
    select coalesce(t.overview, y.overview) as overview, coalesce(t.dims, y.dims) as dims, coalesce(t.measure, y.measure) as measure,
           coalesce(t.v, 0) as v, coalesce(y.v, 0) as p
    from (select * from day_rows where snapshot_date = p_date) t
    full join (select * from day_rows where snapshot_date = p_date - 1) y on y.overview = t.overview and y.dims = t.dims and y.measure = t.measure
    where not exists (select 1 from na where na.overview = coalesce(t.overview, y.overview) and na.measure = coalesce(t.measure, y.measure))
  ), prev as (
    -- a flow overview's [market] rows above 0 on each of the 7 dates before p_date
    select s.overview, s.dims, e.key as measure
    from cma.flash_snapshot s
    cross join lateral jsonb_each(s.measures) e
    join m on m.overview = s.overview and m.measure = e.key and m.kind = 'flow'
    where s.tenant_id = p_tenant_id and s.snapshot_date between p_date - 7 and p_date - 1
      and s.dims ? 'market' and (select count(*) from jsonb_object_keys(s.dims)) = 1
      and jsonb_typeof(e.value) = 'number' and (e.value #>> '{}')::numeric > 0
    group by 1, 2, 3
    having count(*) = 7
  ), c as (
    select ic.id, ic.adapter, ic.settings,
           case when ic.kind is not null then ic.kind
                when exists (select 1 from cma.commerce_store x where x.tenant_id = ic.tenant_id and x.connection_id = ic.id) then 'commerce'
                else (cma.connection_held_kinds_of(ic.tenant_id, ic.id))[1] end as kind,
           coalesce((select st.handle from cma.commerce_store st where st.tenant_id = ic.tenant_id and st.connection_id = ic.id),
                    (select sm.handle from sm where sm.connection_id = ic.id)) as store
    from cma.integration_connection ic
    where ic.tenant_id = p_tenant_id and ic.status = 'active'
  ), win as (
    -- the succeeded runs of the 7 days before p_now of the active connections of a source Flash reads, backfills aside
    -- (started by hand: no cadence), each with the gap since the run before of the same job and stream in those days
    select x.connection_id, x.job, x.stream, x.finished_at,
           extract(epoch from x.finished_at - lag(x.finished_at) over (partition by x.connection_id, x.job, x.stream order by x.finished_at)) / 60 as gap
    from cma.sync_run x
    where x.tenant_id = p_tenant_id and x.status = 'succeeded' and x.job <> 'backfill'
      and x.finished_at > p_now - interval '7 days' and x.finished_at <= p_now
      and x.connection_id in (select c.id from c where c.kind in ('commerce', 'subscriptions', 'assets', 'crm', 'reviews'))
  ), sets as (
    -- a connection's poll interval settings: <job>_interval_minutes is the cadence of that job (assets_poll_interval_minutes
    -- of assets_poll), the smallest when two name one job
    select c.id as connection_id, left(e.key, length(e.key) - length('_interval_minutes')) as job,
           min((e.value #>> '{}')::numeric) as minutes
    from c
    cross join lateral jsonb_each(c.settings) e
    where c.kind in ('commerce', 'subscriptions', 'assets', 'crm', 'reviews')
      and e.key like '%\_poll\_interval\_minutes'
      and case when (e.value #>> '{}') ~ '^[0-9]{1,5}$' then (e.value #>> '{}')::numeric > 0 else false end
    group by 1, 2
  ), cand as (
    -- every job and stream with a cadence: its setting (its age from its last succeeded run of any time), else the median
    -- gap of its runs of the 7 days (raw), at least flash.watch_stale_min_minutes (cadence)
    select s.connection_id, x.job, x.stream, max(x.finished_at) as last_at, s.minutes as raw, s.minutes as cadence, 'setting'::text as basis
    from sets s
    join cma.sync_run x on x.tenant_id = p_tenant_id and x.connection_id = s.connection_id and x.job = s.job
                       and x.status = 'succeeded' and x.finished_at <= p_now
    group by s.connection_id, x.job, x.stream, s.minutes
    union all
    select w.connection_id, w.job, w.stream, max(w.finished_at),
           (percentile_cont(0.5) within group (order by w.gap) filter (where w.gap > 0))::numeric,
           greatest((percentile_cont(0.5) within group (order by w.gap) filter (where w.gap > 0))::numeric, v_floor), 'runs'
    from win w
    where not exists (select 1 from sets s where s.connection_id = w.connection_id and s.job = w.job)
    group by w.connection_id, w.job, w.stream
    having count(*) filter (where w.gap > 0) > 0
  ), gov as (
    -- a connection's most frequent job and stream: the smallest cadence before the floor (on a tie the latest read, then
    -- the names), so a job measured at 1 minute governs one set at 5 even though the floor makes both 5
    select distinct on (k.connection_id) k.connection_id, k.job, k.stream, k.last_at, k.cadence, k.basis, c.kind, c.adapter, c.store
    from cand k
    join c on c.id = k.connection_id
    order by k.connection_id, k.raw, k.last_at desc, k.job collate "C", k.stream collate "C" nulls first
  ), cur as (
    -- jump and dq_rise
    select case when j.overview = 'data_quality' then 'dq_rise' else 'jump' end as kind, j.overview, j.dims, j.measure, j.v as value,
           j.p as previous, round(greatest(v_min, v_pct * j.p / 100), 2) as threshold, jsonb_build_object('jump_pct', v_pct, 'jump_min', v_min) as detail
    from j
    where v_prev_ok and abs(j.v - j.p) > v_min and abs(j.v - j.p) * 100 > v_pct * j.p
      and (j.overview <> 'data_quality' or j.v > j.p)
    union all
    -- flow_zero
    select 'flow_zero', prev.overview, prev.dims, prev.measure, coalesce((s.measures ->> prev.measure)::numeric, 0), null::numeric, 0::numeric,
           jsonb_build_object('previous_days', 7)
    from prev
    left join cma.flash_snapshot s
      on s.tenant_id = p_tenant_id and s.snapshot_date = p_date and s.overview = prev.overview and s.dims = prev.dims
    where v_flow_ok and coalesce((s.measures ->> prev.measure)::numeric, 0) = 0
    union all
    -- source_stale: per source, adapter and store, the stale connection with the oldest read of its most frequent job and
    -- stream, and how many are stale
    select 'source_stale', null::text, z.dims, null::text, z.value, null::numeric, z.threshold,
           z.detail || jsonb_build_object('connections', z.n)
    from (select distinct on (st.dims) st.dims, st.value, st.threshold, st.detail, count(*) over (partition by st.dims) as n
          from (select jsonb_strip_nulls(jsonb_build_object('source', g.kind, 'adapter', g.adapter, 'store', g.store)) as dims,
                       round(extract(epoch from p_now - g.last_at) / 60) as value, round(3 * g.cadence) as threshold,
                       jsonb_build_object('cadence_minutes', round(g.cadence, 1), 'cadence_basis', g.basis,
                                          'age_minutes', round(extract(epoch from p_now - g.last_at) / 60), 'last_read_at', g.last_at)
                       || jsonb_strip_nulls(jsonb_build_object('job', g.job, 'stream', g.stream)) as detail,
                       g.last_at
                from gov g
                where extract(epoch from p_now - g.last_at) / 60 > 3 * g.cadence) st
          order by st.dims, st.last_at, st.value desc) z
    union all
    -- snapshot_missing
    select 'snapshot_missing', null::text, '{}'::jsonb, null::text, ((p_date - 1) - x.last_before)::numeric, null::numeric, null::numeric,
           jsonb_build_object('missing_from', x.last_before + 1, 'missing_to', p_date - 1, 'days', (p_date - 1) - x.last_before)
    from (select max(r.snapshot_date) as last_before from cma.flash_snapshot_run r
          where r.tenant_id = p_tenant_id and r.status = 'succeeded' and r.snapshot_date < p_date - 1) x
    where x.last_before is not null and not v_prev_ok
    union all
    -- current_stale (0009e): an overview of flash.current_overviews whose stored current take exists but is older than
    -- three times flash.current_refresh_minutes at p_now, so the page computes its now live: the refresh is failing. The
    -- value its age in minutes, the threshold three times the setting. No take at all is no finding (a source not set up
    -- keeps none); a take younger than that is none either, even when a change of definition or setting has made it
    -- unreadable until the next refresh
    select 'current_stale', k.overview, '{}'::jsonb, null::text, round(extract(epoch from p_now - k.computed_at) / 60), null::numeric,
           3 * cma.setting_of(p_tenant_id, 'flash.current_refresh_minutes')::numeric,
           jsonb_build_object('age_minutes', round(extract(epoch from p_now - k.computed_at) / 60))
    from (select c.overview, max(c.computed_at) as computed_at from cma.flash_current_take c
          where c.tenant_id = p_tenant_id group by c.overview) k
    where k.overview = any (cma.flash_current_overviews_of(p_tenant_id))
      and k.computed_at <= p_now - make_interval(mins => 3 * cma.setting_of(p_tenant_id, 'flash.current_refresh_minutes')::integer)
  ), res as (
    -- every open finding whose condition no longer holds
    update cma.flash_watch_finding f set state = 'resolved', resolved_on = p_date
    where f.tenant_id = p_tenant_id and f.state = 'open'
      and not exists (select 1 from cur n
                      where n.kind = f.kind and coalesce(n.overview, '') = coalesce(f.overview, '') and n.dims = f.dims
                        and coalesce(n.measure, '') = coalesce(f.measure, ''))
    returning 1
  ), ins as (
    -- every condition that holds without an open finding, once per key (a condition that holds twice is one finding, so
    -- a take never fails on the open findings' unique index)
    insert into cma.flash_watch_finding (tenant_id, snapshot_date, kind, overview, dims, measure, value, previous, threshold, detail)
    select distinct on (n.kind, coalesce(n.overview, ''), n.dims, coalesce(n.measure, ''))
           p_tenant_id, p_date, n.kind, n.overview, n.dims, n.measure, n.value, n.previous, n.threshold, n.detail
    from cur n
    where not exists (select 1 from cma.flash_watch_finding f
                      where f.tenant_id = p_tenant_id and f.state = 'open' and f.kind = n.kind
                        and coalesce(f.overview, '') = coalesce(n.overview, '') and f.dims = n.dims
                        and coalesce(f.measure, '') = coalesce(n.measure, ''))
    returning 1
  )
  select (select count(*) from res), (select count(*) from ins) into v_resolved, v_opened;
  return jsonb_build_object('watch_opened', v_opened, 'watch_resolved', v_resolved,
                            'watch_open', (select count(*) from cma.flash_watch_finding f where f.tenant_id = p_tenant_id and f.state = 'open'));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Readers, grants and JIT, the watch's kinds, the addition
-- ---------------------------------------------------------------------------------------------
-- Every column: codes and figures (no id of a record), as cma_read.flash_snapshot
create or replace view cma_read.flash_current_take as
  select tenant_id, overview, dims, measures, definition_version, computed_at
  from cma.flash_current_take
  where cma_read.reader_sees(tenant_id);

do $$
declare
  f text;
begin
  -- the application's: the state, the setting's helpers, the job's entry (a function made again keeps its grants)
  foreach f in array array[
    'cma.flash_current_keys()', 'cma.flash_current_overviews_ok(text)', 'cma.flash_current_overviews_of(uuid)',
    'cma.flash_current_state_of(uuid,text,timestamptz,text,timestamptz)', 'cma.flash_current_refresh(uuid)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
  -- the refresh's writer and its lock key: the owner's alone (the entry runs them with the owner's rights)
  foreach f in array array['cma.flash_current_refresh_of(uuid,text,boolean)', 'cma.flash_current_lock_key(uuid,text)'] loop
    execute format('revoke execute on function %s from public, cma_app', f);
  end loop;
  -- JIT off again on the two remade functions (as 0008zt and 0008zu set it), and on the refresh's two (the large read)
  foreach f in array array[
    'cma.flash_document_of(uuid,text,text,date,date,date)', 'cma.flash_watch_of(uuid,date,timestamptz)',
    'cma.flash_current_refresh_of(uuid,text,boolean)', 'cma.flash_current_refresh(uuid)'
  ] loop
    execute format('alter function %s set jit = off', f);
  end loop;
end
$$;
revoke execute on function cma.check_flash_current_setting() from public;
revoke execute on function cma.flash_current_forget() from public, cma_app;

-- The triggers on cma.tenant_setting and the watch's kinds, last, directly before the addition and the commit: each takes
-- a lock that is held to the commit (cma.tenant_setting is read on nearly every request, cma.flash_watch_finding by
-- Flash's landing and the snapshot take; CLAUDE.md, Performance), so they wait for nothing that follows
drop trigger if exists check_flash_current_setting on cma.tenant_setting;
create trigger check_flash_current_setting before insert or update on cma.tenant_setting
  for each row execute function cma.check_flash_current_setting();
drop trigger if exists forget_flash_current_takes on cma.tenant_setting;
create trigger forget_flash_current_takes after insert or update or delete on cma.tenant_setting
  for each row execute function cma.flash_current_forget();

alter table cma.flash_watch_finding drop constraint if exists flash_watch_finding_kind_check;
alter table cma.flash_watch_finding add constraint flash_watch_finding_kind_check
  check (kind in ('jump', 'flow_zero', 'source_stale', 'snapshot_missing', 'dq_rise', 'current_stale'));
comment on table cma.flash_watch_finding is 'Flash: the deterministic watch''s findings after each snapshot (jump, flow_zero, source_stale, snapshot_missing, dq_rise; current_stale since 0009e): aggregates, codes and counts only, no id of a record (0008zn). Written and resolved by the take only; one open finding per kind, overview, dims and measure';

insert into cma.schema_migration (version, description)
values ('0009e', 'The installed base''s first paint from a stored current take: cma.flash_current_take (one take per tenant and overview of flash.current_overviews, default installed_base: cma.flash_compute_of''s rows now, replaced when older than flash.current_refresh_minutes, default 5, by the snapshot job through cma.flash_current_refresh, SECURITY DEFINER, flash.snapshot; no audit trigger, no write for the application; cma_read.flash_current_take); cma.flash_document_of reads a stock overview''s now from its take when fresh or usable (cma.flash_current_state_of: younger than three times the setting, its definition current and no migration since; a change of the tenant''s settings removes its takes, cma.flash_current_forget), else live as before, and answers refreshed_at; cma.flash_watch_of opens current_stale for a take older than three times the setting')
on conflict (version) do nothing;

commit;
reset role;
