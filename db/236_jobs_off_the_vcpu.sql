-- =============================================================================================
-- 236_jobs_off_the_vcpu.sql: addition 0009zr, the minute jobs off prod's one vCPU (brief N07, WP6 and WP5; PR N07a)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics; the waits, the deferral and the cadences are settings. Runs unchanged
-- in every database, after 234_speed_to_lead_one.sql (0009zq). Rerunnable, forward-only, in one transaction with a lock
-- timeout. Run as your own IAM login: dev first, then 237_verify_jobs_off_the_vcpu.sql there (normal and provoked), then
-- the verifies that read what this re-creates, each still PASS: 211, 213, 217, 219, 221, 223 and 225 (they read
-- cma.subscription_facts_refresh_of or cma.renewal_outcomes_of; none is edited by this change), 41, 73, 75, 81, 95, 151,
-- 155 and 179 (they read cma.speed_to_lead_of or cma.open_leads_of directly or through cma.refresh_follow_up_of;
-- unchanged: the answers are the same; 99 and 221 ran too, as a further check), 191 and 235, edited by this change (both copy or read the printed definition of speed to lead,
-- which moved into cma.speed_to_lead_rows_of; they now take it from there when it exists), then 131_time_all.sql parts a
-- and b. Prod the same after the merge, outside office
-- hours: 236, 237, the same reruns where they run in prod (95, 73 and 81 run in dev only, as before).
--
-- Why (Martin, 24 November 2026; brief N07; decisions D6 and D7; prod evidence records/perf-prod-2026-11-24/ and the
-- brief's Prod facts): the Active refresh's job failed 25 times in two days with SQLSTATE 57014 at its 55 s statement
-- timeout, in streaks, after 0009zk's backfill tripled cma.subscription_event; a failed run was retried the next minute,
-- slower under the load it caused (a retry storm). The minute jobs together took the one vCPU in office hours.
--
-- What it changes
--   settings     jobs.defer_web_statements (integer, 2; 1 to 100): a web job defers its heavy step while at least this
--                many statements of the web service are active; jobs.defer_max_in_a_row (integer, 5; 0 to 60): how many
--                minutes in a row a job may defer before it computes regardless (D7, both ops settings, checked by
--                cma.check_job_setting()). customers.refresh_minutes: default 10 (was 5), the least time between two
--                computations of Customers → Active's take (night default N07-1, to confirm)
--   cma.web_busy(text)          SECURITY DEFINER, owned by cma_owner (which holds pg_read_all_stats since 0009w): the
--                number of active statements of the web service now (application_name cma-web, cma-web-local), nothing
--                else (no query text, pid or user); null when cma_owner cannot read other logins' activity. Executable by
--                cma_app and only for a scheduler user holding the job's permission (cma.assert_permission)
--   cma.job_gate_of(text)       whether a web minute job computes the current tenant now: nothing_to_read (the
--                follow-up without an active CRM connection and without stored items: one read of the tenant's
--                connections, no computation), after_timeout (the job's latest
--                runs for the tenant were cancelled by the statement timeout, 57014: wait 5, 10, 20, 40, at most 60 minutes
--                after the last one, reset by any other outcome), deferred (cma.web_busy() at or over
--                jobs.defer_web_statements and fewer than jobs.defer_max_in_a_row deferrals in a row), else go. Read from
--                cma.sync_run's own rows (sync_run_job_started_idx), no new table; the run row of a gated run says which
--                wait it was in its counts (timeout_wait, defer_wait, nothing_to_read)
--   cma.subscription_take_state two columns: outcomes_read_at (when the last renewal outcomes computation started
--                reading its inputs) and outcomes_full_at (when the last whole one did)
--   cma.renewal_outcomes_of(uuid, uuid[], text[])  new: the outcomes of the given subscriptions' cycles and of every
--                invoice renewal; cma.renewal_outcomes_of(uuid) (based on 210) is that with no subscription list (all)
--   cma.subscription_facts_refresh_of (based on 212) its step 2, the renewal outcomes, incremental: only the
--                subscriptions with an event or a row written since the last computation started (less 10 minutes for a
--                late commit; subscription_event_synced_idx), plus every invoice renewal, computed and compared; the whole
--                set on a forced refresh, a new business date, a chargeback written since, or when the last whole
--                computation is an hour old (night default N07-2, to confirm). Equal to the whole computation (237's F1
--                to F4). Everything else unchanged
--   cma.speed_to_lead_rows_of(uuid, timestamptz, timestamptz, boolean) new: cma.speed_to_lead_of's one definition (234)
--                with p_open_only, which reads only the lead deals not closed (every row of those deals as the whole read
--                gives it); cma.speed_to_lead_of (based on 234) is that with false
--   cma.open_leads_of (based on 234) reads cma.speed_to_lead_rows_of(…, true): the follow-up's open leads read 1,890
--                deals instead of 6,882 at three times prod's volume (237's L1 proves the same rows)
--   cma.refresh_follow_up_of  set jit = off (a function-level setting, not a redefinition): 2.0 s → 1.4 s per computation
--   small catalogs  autovacuum_analyze_threshold 10 and scale factor 0 on the configuration tables prod's diagnosis of
--                16 November 2026 lists as never analyzed (setting, tenant_setting, market, market_alias, business_hours,
--                business_holiday, telephony_tag, app_user_external_id), so a handful of edits gives them statistics
--
-- cma.subscription_event, a busy table (CLAUDE.md, Performance): one index this script does not require, built
-- concurrently from the Terminal (the pull request's Terminal block: set role cma_owner, lock_timeout '5s' and
-- statement_timeout '10min' as separate commands, then pg_index.indisvalid checked; an f: drop index concurrently and
-- build it again; the night's own first build came out invalid while long verify transactions held their locks):
--   create index concurrently if not exists subscription_event_paused_idx
--     on cma.subscription_event (tenant_id, connection_id, subscription_source_id, occurred_at desc) where status_to = 'paused';
-- Why (WP6.7): the subscriptions poll's run time tripled in a week (320 ms on 17 November, 1,009 ms on 24 November).
-- cma.ingest_upsert_subscriptions looks up, for every paused subscription it reads without a pause time from the
-- source, its latest pause event: through subscription_event_subscription_idx, which has no status_to, every event of
-- the subscription is read, and 0009zk's backfill of the old moves (23 November) tripled the events per subscription.
-- At three times prod's volume the lookups of 2,241 paused subscriptions take 440 ms; with this index (8 kB, the pause
-- events only) 4.8 ms. The function is unchanged and takes the index by itself. The rest of the tripling is the
-- saturated vCPU of the same hours (the Active refresh's timeout streaks), which the gate above removes.
--
-- The jobs (web/jobs/*.mjs) call cma.job_gate_of before their heavy step from this release on; on a database without it
-- they compute as before. docs/scheduler/deploy-active-customers.sh keeps the every-minute schedule: the waits are in
-- place, so the morning runbook redeploys it (prod runs every 10 minutes by hand since 24 November 2026).
-- =============================================================================================

begin;
set local lock_timeout = '5s';
set role cma_owner;

-- ---------------------------------------------------------------------------------------------
-- 1. Settings: the deferral (D7) and the Active take's least interval
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('jobs.defer_web_statements', 'integer', null, '2',
     'A web minute job defers its heavy step to the next minute while at least this many statements of the web service are active (1 to 100)'),
  ('jobs.defer_max_in_a_row', 'integer', null, '5',
     'How many minutes in a row a web minute job may defer before it computes regardless of the web''s load (0 to 60; 0 never defers)')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

update cma.setting
set default_value = '10',
    description = 'The least time in minutes between two computations of Customers → Active''s stored take (and how old a take may be before the refresh job checks its inputs again)'
where key = 'customers.refresh_minutes' and default_value = '5';

-- Their ranges, checked beside cma.check_tenant_setting() (its branches unchanged)
create or replace function cma.check_job_setting()
returns trigger
language plpgsql
as $$
begin
  if new.key = 'jobs.defer_web_statements'
     and (new.value !~ '^[0-9]{1,3}$' or new.value::integer not between 1 and 100) then
    raise exception 'Setting % takes a whole number from 1 to 100', new.key using errcode = 'CMA04';
  end if;
  if new.key = 'jobs.defer_max_in_a_row'
     and (new.value !~ '^[0-9]{1,2}$' or new.value::integer not between 0 and 60) then
    raise exception 'Setting % takes a whole number from 0 to 60', new.key using errcode = 'CMA04';
  end if;
  return new;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. cma.web_busy(): the web's active statements now, for the jobs' deferral
-- ---------------------------------------------------------------------------------------------
create or replace function cma.web_busy(p_job text)
returns integer
language plpgsql
stable
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  v integer;
begin
  if cma.job_permission_of(p_job) is null then
    raise exception 'no such job: %', p_job using errcode = 'CMA04';
  end if;
  -- only a scheduler user holding the job's permission (the jobs share the web's login, so a role cannot tell them apart)
  perform cma.assert_permission(cma.job_permission_of(p_job));
  -- without pg_read_all_stats another login's sessions show no state: unknown, never a false 0
  if not pg_has_role('cma_owner', 'pg_read_all_stats', 'member') then
    return null;
  end if;
  select count(*)::integer into v
  from pg_stat_activity a
  where a.datname = current_database() and a.backend_type = 'client backend' and a.state = 'active'
    and a.application_name in ('cma-web', 'cma-web-local') and a.pid <> pg_backend_pid();
  return v;
end
$$;
alter function cma.web_busy(text) owner to cma_owner;

-- ---------------------------------------------------------------------------------------------
-- 3. cma.job_gate_of(): nothing to read, the timeout's backoff, the deferral, or go
-- ---------------------------------------------------------------------------------------------
create or replace function cma.job_gate_of(p_job text)
returns jsonb
language plpgsql
volatile
as $$
declare
  v_tenant    uuid := cma.current_tenant_id();
  v_perm      text := cma.job_permission_of(p_job);
  r           record;
  n_timeouts  integer := 0;
  v_last      timestamptz;
  n_deferred  integer := 0;
  v_deferring boolean := true;
  v_wait      integer;
  v_web       integer;
  v_min_web   integer;
  v_max_defer integer;
begin
  if v_perm is null then
    raise exception 'no such job: %', p_job using errcode = 'CMA04';
  end if;
  perform cma.assert_permission(v_perm);
  -- 1. nothing to read: the follow-up of a tenant without an active CRM connection (a connection whose kind is not stored
  --    yet counts as a source) and without stored items. Min() over the tenant's few rows, never exists(). Customers →
  --    Active (whose not_set_up branch removes a switched-off tenant's take, 5 ms), data quality and Flash have their
  --    own answers for a tenant without sources, so they are never skipped for this reason
  if p_job = 'refresh_follow_up'
     and (select min(ic.id::text) from cma.integration_connection ic
          where ic.tenant_id = v_tenant and ic.status = 'active' and (ic.kind is null or ic.kind = 'crm')) is null
     -- and nothing stored that a computation would empty: a tenant whose CRM was switched off computes once more
     and (select min(i.kind) from cma.follow_up_item i where i.tenant_id = v_tenant) is null then
    return jsonb_build_object('go', false, 'reason', 'nothing_to_read');
  end if;
  -- 2. the job's latest finished runs for this tenant, newest first: the timeouts in a row (a gated run neither counts
  --    nor resets them) and the deferrals in a row (sync_run_job_started_idx)
  for r in
    select x.status, x.error, x.counts, x.finished_at
    from cma.sync_run x
    where x.tenant_id = v_tenant and x.job = p_job and x.connection_id is null and x.status <> 'running'
    order by x.started_at desc, x.id desc
    limit 200
  loop
    if v_deferring and r.counts ? 'defer_wait' then
      n_deferred := n_deferred + 1;
    else
      v_deferring := false;
    end if;
    if r.counts ? 'defer_wait' or r.counts ? 'timeout_wait' or r.counts ? 'nothing_to_read' then
      continue;
    end if;
    exit when not (r.status = 'failed' and r.error = '57014');
    n_timeouts := n_timeouts + 1;
    v_last := coalesce(v_last, r.finished_at);
  end loop;
  if n_timeouts > 0 then
    v_wait := least(60, 5 * power(2, least(n_timeouts, 5) - 1)::integer);
    if clock_timestamp() < v_last + make_interval(mins => v_wait) then
      return jsonb_build_object('go', false, 'reason', 'after_timeout', 'timeouts_in_a_row', n_timeouts, 'wait_minutes', v_wait,
                                'wait_until', v_last + make_interval(mins => v_wait));
    end if;
  end if;
  -- 3. the web's load (D7): defer while it is busy, at most jobs.defer_max_in_a_row minutes in a row
  v_min_web := cma.setting_of(v_tenant, 'jobs.defer_web_statements')::integer;
  v_max_defer := cma.setting_of(v_tenant, 'jobs.defer_max_in_a_row')::integer;
  v_web := cma.web_busy(p_job);
  if v_web is not null and v_web >= v_min_web and n_deferred < v_max_defer then
    return jsonb_build_object('go', false, 'reason', 'deferred', 'web_statements', v_web, 'deferrals_in_a_row', n_deferred + 1);
  end if;
  return jsonb_build_object('go', true, 'timeouts_in_a_row', n_timeouts, 'deferrals_in_a_row', n_deferred,
                            'web_statements', v_web);
end
$$;
-- ---------------------------------------------------------------------------------------------
-- 4. The renewal outcomes of a list of subscriptions (and every invoice renewal), and of all of them
-- ---------------------------------------------------------------------------------------------
-- The one definition of 210 with a list: the cycles of the subscriptions in p_connections and p_subscriptions (the pair
-- at the same place), or of every subscription when p_connections is null; the invoice renewals always all (their
-- subscription may be found through the customer, so a list cannot bound them; 484 rows at three times prod's volume)
create or replace function cma.renewal_outcomes_of(p_tenant_id uuid, p_connections uuid[], p_subscriptions text[])
returns table (connection_id uuid, subscription_source_id text, renewal_key text, cycle_index integer, renewal_source_id text,
               first_attempt_at timestamptz, outcome text, attempts integer, recovered_at timestamptz, days_to_recover numeric,
               error_code text, instrument_type text, payment_method_changed_before_recovery boolean)
language sql stable
rows 50000
as $$
  -- 0009zr: two branches, each behind a condition on the arguments alone (a one-time filter: the branch not taken reads
  -- nothing): every subscription's cycles without a list, or the listed subscriptions' cycles through
  -- subscription_event_subscription_idx. An or of the two in one where clause is planned for both and serves neither
  with a as (
    select e.connection_id, e.subscription_source_id, e.cycle_index,
           min(e.occurred_at) as first_at,
           min(e.occurred_at) filter (where e.event_type = 'renew_failed') as first_failed_at,
           min(e.occurred_at) filter (where e.event_type = 'renewed') as renewed_at,
           count(*) filter (where e.event_type = 'renew_failed') as failures,
           (array_agg(e.error_code order by e.occurred_at, e.source_id collate "C") filter (where e.event_type = 'renew_failed'))[1] as error_code,
           (array_agg(e.order_source_id order by e.occurred_at, e.source_id collate "C") filter (where e.event_type = 'renewed'))[1] as order_source_id
    from cma.subscription_event e
    where p_connections is null
      and e.tenant_id = p_tenant_id and e.event_type in ('renewed', 'renew_failed') and e.cycle_index is not null
    group by 1, 2, 3
    union all
    select e.connection_id, e.subscription_source_id, e.cycle_index,
           min(e.occurred_at) as first_at,
           min(e.occurred_at) filter (where e.event_type = 'renew_failed') as first_failed_at,
           min(e.occurred_at) filter (where e.event_type = 'renewed') as renewed_at,
           count(*) filter (where e.event_type = 'renew_failed') as failures,
           (array_agg(e.error_code order by e.occurred_at, e.source_id collate "C") filter (where e.event_type = 'renew_failed'))[1] as error_code,
           (array_agg(e.order_source_id order by e.occurred_at, e.source_id collate "C") filter (where e.event_type = 'renewed'))[1] as order_source_id
    from unnest(p_connections, p_subscriptions) l(c, s)
    join cma.subscription_event e
      on e.tenant_id = p_tenant_id and e.connection_id = l.c and e.subscription_source_id = l.s
     and e.event_type in ('renewed', 'renew_failed') and e.cycle_index is not null
    where p_connections is not null
    group by 1, 2, 3
  ), cyc as (
    select a.connection_id, a.subscription_source_id, 'cycle:' || a.cycle_index as renewal_key, a.cycle_index, null::text as renewal_source_id,
           a.first_at,
           case when a.renewed_at is not null and exists (
                       select 1 from cma.billing_event b
                       where b.tenant_id = p_tenant_id and b.connection_id = a.connection_id and b.kind = 'chargeback'
                         and b.order_source_id = a.order_source_id) then 'charged_back'
                when a.renewed_at is not null and a.failures = 0 then 'paid_first_attempt'
                when a.renewed_at is not null then 'recovered'
                else 'not_recovered' end as outcome,
           (a.failures + case when a.renewed_at is not null then 1 else 0 end)::integer as attempts,
           case when a.failures > 0 then a.renewed_at end as recovered_at,
           case when a.failures > 0 and a.renewed_at is not null
                then round((extract(epoch from a.renewed_at - a.first_failed_at) / 86400)::numeric, 1) end as days_to_recover,
           a.error_code,
           case when a.failures > 0 and a.renewed_at is not null then exists (
                  select 1 from cma.subscription_event p
                  where p.tenant_id = p_tenant_id and p.connection_id = a.connection_id and p.subscription_source_id = a.subscription_source_id
                    and p.event_type = 'payment_method_changed' and p.occurred_at > a.first_failed_at and p.occurred_at < a.renewed_at) end as pm_changed
    from a
  ), inv as (
    select b.connection_id, b.renewal_source_id,
           coalesce(max(b.subscription_source_id),
                    (select min(x.source_id) from cma.subscription x
                     where x.tenant_id = p_tenant_id and x.connection_id = b.connection_id and x.customer_source_id = min(b.customer_source_id)
                       and x.source_deleted_at is null
                     having count(*) = 1)) as subscription_source_id,
           min(b.occurred_at) filter (where b.kind = 'invoice_placed') as placed_at,
           min(b.occurred_at) filter (where b.kind = 'invoice_paid') as paid_at,
           count(*) filter (where b.kind = 'invoice_payment_failed') as failures
    from cma.billing_event b
    where b.tenant_id = p_tenant_id and b.kind like 'invoice\_%' and b.renewal_source_id is not null
    group by 1, 2
  )
  select c.connection_id, c.subscription_source_id, c.renewal_key, c.cycle_index, c.renewal_source_id, c.first_at, c.outcome, c.attempts,
         c.recovered_at, c.days_to_recover, c.error_code, s.payment_instrument_type, c.pm_changed
  from cyc c
  left join cma.subscription s on s.tenant_id = p_tenant_id and s.connection_id = c.connection_id and s.source_id = c.subscription_source_id
  union all
  select i.connection_id, i.subscription_source_id, 'invoice:' || i.renewal_source_id, null, i.renewal_source_id, i.placed_at,
         case when i.paid_at is not null then 'invoice_paid' else 'invoice_open' end,
         (1 + i.failures)::integer, null, null, null, s.payment_instrument_type, null
  from inv i
  left join cma.subscription s on s.tenant_id = p_tenant_id and s.connection_id = i.connection_id and s.source_id = i.subscription_source_id
  where i.placed_at is not null and i.subscription_source_id is not null
$$;

alter function cma.renewal_outcomes_of(uuid, uuid[], text[]) set jit = off;

-- 210's form: every subscription (the list left out); jit off as 210 set it, which also keeps it from being inlined
-- based on: 210_subscription_facts.sql
create or replace function cma.renewal_outcomes_of(p_tenant_id uuid)
returns table (connection_id uuid, subscription_source_id text, renewal_key text, cycle_index integer, renewal_source_id text,
               first_attempt_at timestamptz, outcome text, attempts integer, recovered_at timestamptz, days_to_recover numeric,
               error_code text, instrument_type text, payment_method_changed_before_recovery boolean)
language sql stable
rows 50000
as $$
  select * from cma.renewal_outcomes_of(p_tenant_id, null::uuid[], null::text[])
$$;
alter function cma.renewal_outcomes_of(uuid) set jit = off;
-- ---------------------------------------------------------------------------------------------
-- 5. The subscription facts' refresh with its renewal outcomes incremental (step 2); everything else as 212
-- ---------------------------------------------------------------------------------------------

-- based on: 212_subscription_facts_speed.sql
create or replace function cma.subscription_facts_refresh_of(p_tenant_id uuid, p_force boolean default false, p_now timestamptz default null)
returns jsonb
language plpgsql
as $$
declare
  v_now      timestamptz := coalesce(p_now, clock_timestamp());
  v_t0       timestamptz := clock_timestamp();
  v_zone     text := (select t.timezone from cma.tenant t where t.id = p_tenant_id);
  v_today    date;
  v_month    date;
  v_every    integer := cma.setting_of(p_tenant_id, 'subscriptions.take_refresh_minutes')::integer;
  v_holding  text[] := cma.flash_list_of(cma.setting_of(p_tenant_id, 'flash.device_holding_statuses'));
  v_state    cma.subscription_take_state;
  v_found    boolean;
  v_set_up   boolean;
  v_key      text;
  v_amounts  timestamptz := (select m.applied_at from cma.schema_migration m where m.version = '0009za');
  n_units    integer := 0;
  n_subs     integer := 0;
  n_months   integer := 0;
  n_outcomes integer := 0;
  n_cells    integer := 0;
  n_written  integer := 0;
  n          integer;
  v_mark     timestamptz := clock_timestamp();
  v_steps    jsonb := '{}';
  v_out_read timestamptz;
  v_out_full boolean;
  v_out_from timestamptz;
  v_scope_c  uuid[];
  v_scope_s  text[];
begin
  if p_tenant_id is distinct from cma.current_tenant_id() then
    raise exception 'a take is refreshed for the current tenant only' using errcode = 'CMA04';
  end if;
  select * into v_state from cma.subscription_take_state t where t.tenant_id = p_tenant_id;
  v_found := found;
  select coalesce(cma.flash_source_set_up_of(p_tenant_id, 'subscriptions'), false) into v_set_up;
  if not v_set_up then
    if v_found then
      if not pg_try_advisory_xact_lock(cma.subscription_facts_lock_key(p_tenant_id)) then
        return jsonb_build_object('refreshed', false, 'reason', 'running');
      end if;
      delete from cma.subscription_survival_take x where x.tenant_id = p_tenant_id;
      delete from cma.renewal_outcome x where x.tenant_id = p_tenant_id;
      delete from cma.subscription_month_take x where x.tenant_id = p_tenant_id;
      delete from cma.subscription_store_start x where x.tenant_id = p_tenant_id;
      delete from cma.subscription_take x where x.tenant_id = p_tenant_id;
      delete from cma.subscription_take_state x where x.tenant_id = p_tenant_id;
    end if;
    return jsonb_build_object('refreshed', false, 'reason', 'not_set_up');
  end if;
  if not p_force and v_found and v_now - v_state.computed_at < make_interval(mins => v_every) then
    return jsonb_build_object('refreshed', false, 'reason', 'fresh');
  end if;
  if not pg_try_advisory_xact_lock(cma.subscription_facts_lock_key(p_tenant_id)) then
    return jsonb_build_object('refreshed', false, 'reason', 'running');
  end if;
  select * into v_state from cma.subscription_take_state t where t.tenant_id = p_tenant_id;
  v_found := found;
  v_today := (v_now at time zone v_zone)::date;
  v_month := date_trunc('month', v_today)::date;
  v_key := cma.subscription_facts_inputs_key_of(p_tenant_id, v_today);
  v_steps := v_steps || jsonb_build_object('inputs_key', round(extract(epoch from clock_timestamp() - v_mark) * 1000));
  v_mark := clock_timestamp();
  if not p_force and v_found and v_state.inputs_key = v_key then
    update cma.subscription_take_state t
    set computed_at = v_now, duration_ms = (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer
    where t.tenant_id = p_tenant_id;
    return jsonb_build_object('refreshed', true, 'unchanged', true, 'rows', 0,
                              'duration_ms', (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer);
  end if;

  -- 1. device units (C.1): computed once, written to the mirror where they read differently (step 3 reads them from here)
  create temporary table if not exists subscription_facts_units (subscription_id uuid primary key, device_units integer, propositions text[],
                                                                  models text[]) on commit drop;
  delete from subscription_facts_units;
  insert into subscription_facts_units select * from cma.subscription_device_units_of(p_tenant_id);
  update cma.subscription x
  set device_units = u.device_units
  from subscription_facts_units u
  where x.tenant_id = p_tenant_id and x.id = u.subscription_id and x.device_units is distinct from u.device_units;
  get diagnostics n_units = row_count;
  v_steps := v_steps || jsonb_build_object('device_units', round(extract(epoch from clock_timestamp() - v_mark) * 1000));
  v_mark := clock_timestamp();

  -- 2. renewal outcomes (C.3), first: the subscriptions' renewals are counted from them. Computed into a temporary table,
  --    then only the rows that read differently are written (0009zf): a gone renewal deleted, a changed one updated, a new
  --    one inserted. A run rewrote every row before; between two runs a handful change
  -- 0009zr: incremental. Only the subscriptions with an event or a row written since the last computation started
  --    reading (less 10 minutes, for a write that committed late) are computed and compared, with every invoice renewal;
  --    the whole set on a forced refresh, a first or a new business date, a chargeback written since (it names an order,
  --    not a subscription; every other billing event reaches an invoice renewal, computed whole in every run), or once
  --    the last whole computation is an hour old. A deleted event is caught by the hourly whole computation. The same rows as the
  --    whole computation (237, F1 to F4)
  v_out_read := clock_timestamp();
  v_out_from := v_state.outcomes_read_at - interval '10 minutes';
  v_out_full := p_force or not v_found or v_state.outcomes_read_at is null or v_state.outcomes_full_at is null
                or v_state.business_date is distinct from v_today
                or v_now - v_state.outcomes_full_at >= interval '60 minutes'
                or (select max(b.synced_at) from cma.billing_event b where b.tenant_id = p_tenant_id and b.kind = 'chargeback') >= v_out_from;
  if not v_out_full then
    select coalesce(array_agg(x.c order by x.c, x.s), '{}'), coalesce(array_agg(x.s order by x.c, x.s), '{}')
      into v_scope_c, v_scope_s
    from (select e.connection_id as c, e.subscription_source_id as s
          from cma.subscription_event e where e.tenant_id = p_tenant_id and e.synced_at >= v_out_from
          union
          select s.connection_id, s.source_id from cma.subscription s where s.tenant_id = p_tenant_id and s.synced_at >= v_out_from) x;
  end if;
  create temporary table if not exists subscription_facts_outcomes (
    connection_id uuid not null, subscription_source_id text not null, renewal_key text not null, cycle_index integer, renewal_source_id text,
    first_attempt_at timestamptz, outcome text, attempts integer, recovered_at timestamptz, days_to_recover numeric(7,1), error_code text,
    instrument_type text, payment_method_changed_before_recovery boolean,
    primary key (connection_id, subscription_source_id, renewal_key)) on commit drop;
  delete from subscription_facts_outcomes;
  insert into subscription_facts_outcomes
  select r.* from cma.renewal_outcomes_of(p_tenant_id, case when not v_out_full then v_scope_c end, case when not v_out_full then v_scope_s end) r;
  get diagnostics n_outcomes = row_count;
  analyze subscription_facts_outcomes;
  delete from cma.renewal_outcome x
  where x.tenant_id = p_tenant_id
    -- 0009zr: in an incremental run only what it computed: the listed subscriptions' cycles and every invoice renewal
    and (v_out_full or x.renewal_key like 'invoice:%'
         or (x.connection_id, x.subscription_source_id) in (select l.c, l.s from unnest(v_scope_c, v_scope_s) l(c, s)))
    and not exists (select 1 from subscription_facts_outcomes o
                    where o.connection_id = x.connection_id and o.subscription_source_id = x.subscription_source_id and o.renewal_key = x.renewal_key);
  get diagnostics n = row_count; n_written := n_written + n;
  update cma.renewal_outcome x
  set cycle_index = o.cycle_index, renewal_source_id = o.renewal_source_id, first_attempt_at = o.first_attempt_at, outcome = o.outcome,
      attempts = o.attempts, recovered_at = o.recovered_at, days_to_recover = o.days_to_recover, error_code = o.error_code,
      instrument_type = o.instrument_type, payment_method_changed_before_recovery = o.payment_method_changed_before_recovery
  from subscription_facts_outcomes o
  where x.tenant_id = p_tenant_id and o.connection_id = x.connection_id and o.subscription_source_id = x.subscription_source_id
    and o.renewal_key = x.renewal_key
    and row(x.cycle_index, x.renewal_source_id, x.first_attempt_at, x.outcome, x.attempts, x.recovered_at, x.days_to_recover, x.error_code,
            x.instrument_type, x.payment_method_changed_before_recovery)::text
        is distinct from
        row(o.cycle_index, o.renewal_source_id, o.first_attempt_at, o.outcome, o.attempts, o.recovered_at, o.days_to_recover, o.error_code,
            o.instrument_type, o.payment_method_changed_before_recovery)::text;
  get diagnostics n = row_count; n_written := n_written + n;
  insert into cma.renewal_outcome (tenant_id, connection_id, subscription_source_id, renewal_key, cycle_index, renewal_source_id, first_attempt_at,
                                   outcome, attempts, recovered_at, days_to_recover, error_code, instrument_type,
                                   payment_method_changed_before_recovery)
  select p_tenant_id, o.connection_id, o.subscription_source_id, o.renewal_key, o.cycle_index, o.renewal_source_id, o.first_attempt_at, o.outcome,
         o.attempts, o.recovered_at, o.days_to_recover, o.error_code, o.instrument_type, o.payment_method_changed_before_recovery
  from subscription_facts_outcomes o
  where not exists (select 1 from cma.renewal_outcome x
                    where x.tenant_id = p_tenant_id and x.connection_id = o.connection_id and x.subscription_source_id = o.subscription_source_id
                      and x.renewal_key = o.renewal_key);
  get diagnostics n = row_count; n_written := n_written + n;

  -- the outcome rows the take holds now (as many as a whole computation gives)
  select count(*)::integer into n_outcomes from cma.renewal_outcome x where x.tenant_id = p_tenant_id;

  v_steps := v_steps || jsonb_build_object('outcomes', round(extract(epoch from clock_timestamp() - v_mark) * 1000));
  v_mark := clock_timestamp();

  -- 3. per subscription: computed into a temporary table, then written as step 2 writes its rows (0009zf)
  create temporary table if not exists subscription_facts_take (
    subscription_id uuid primary key, connection_id uuid, source_id text, market text, status text, payment_state text, state_since timestamptz,
    overdue boolean, chargeback_return_code text, amount_at_risk numeric(14,2), currency text, monthly_amount numeric, interval_group text,
    device_units integer, propositions text[], models text[], original_start_at timestamptz, original_start_basis text, cohort_month date,
    migrated boolean, renewals integer) on commit drop;
  delete from subscription_facts_take;
  insert into subscription_facts_take (subscription_id, connection_id, source_id, market, status, payment_state, state_since, overdue,
                                       chargeback_return_code, amount_at_risk, currency, monthly_amount, interval_group, device_units,
                                       propositions, models, original_start_at, original_start_basis, cohort_month, migrated, renewals)
  with sm as materialized (
    select y.connection_id, y.store_connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y
  ), ps as materialized (
    select * from cma.subscription_payment_state_of(p_tenant_id)
  ), du as materialized (
    select * from subscription_facts_units
  ), mig as materialized (
    select distinct e.connection_id, e.subscription_source_id
    from cma.subscription_event e
    where e.tenant_id = p_tenant_id and e.event_type = 'migrated'
  ), ren as materialized (
    -- the cycles renewed (step 2's outcomes that renewed)
    select r.connection_id, r.subscription_source_id, count(*) as renewals
    from cma.renewal_outcome r
    where r.tenant_id = p_tenant_id and r.cycle_index is not null and r.outcome in ('paid_first_attempt', 'recovered', 'charged_back')
    group by 1, 2
  ), fo as materialized (
    -- the store customer's earliest store order (not a test, not deleted), per store and customer
    select o.connection_id, o.customer_source_id, min(o.source_created_at) as first_at
    from cma.commerce_order o
    where o.tenant_id = p_tenant_id and o.is_test is not true and o.source_deleted_at is null and o.customer_source_id is not null
      and o.connection_id in (select sm.store_connection_id from sm)
    group by 1, 2
  ), b as (
    select x.id, x.connection_id, x.source_id, coalesce(sm.market, 'unknown') as market, x.status, ps.payment_state, ps.state_since, ps.overdue,
           ps.chargeback_return_code, ps.amount_at_risk, x.currency,
           x.amount_per_cycle * cma.active_month_factor_of(x.billing_interval, x.billing_interval_count) as monthly_amount,
           cma.subscription_interval_group_of(x.billing_interval, x.billing_interval_count) as interval_group,
           du.device_units, coalesce(du.propositions, '{}') as propositions, coalesce(du.models, '{}') as models,
           case when fo.first_at <= x.source_created_at then fo.first_at else x.source_created_at end as original_start_at,
           case when fo.first_at <= x.source_created_at then 'first_order' when x.source_created_at is not null then 'created' end as basis,
           mig.subscription_source_id is not null as migrated, coalesce(ren.renewals, 0)::integer as renewals
    from cma.subscription x
    left join sm on sm.connection_id = x.connection_id
    left join ps on ps.subscription_id = x.id
    left join du on du.subscription_id = x.id
    left join mig on mig.connection_id = x.connection_id and mig.subscription_source_id = x.source_id
    left join ren on ren.connection_id = x.connection_id and ren.subscription_source_id = x.source_id
    left join fo on fo.connection_id = sm.store_connection_id and fo.customer_source_id = x.customer_source_id
    where x.tenant_id = p_tenant_id and x.source_deleted_at is null
  )
  select b.id, b.connection_id, b.source_id, b.market, b.status, b.payment_state, b.state_since, b.overdue,
         b.chargeback_return_code, b.amount_at_risk, b.currency, b.monthly_amount, b.interval_group, b.device_units, b.propositions, b.models,
         b.original_start_at, b.basis, date_trunc('month', b.original_start_at at time zone v_zone)::date, b.migrated, b.renewals
  from b;
  get diagnostics n_subs = row_count;
  analyze subscription_facts_take;
  delete from cma.subscription_take x
  where x.tenant_id = p_tenant_id
    and not exists (select 1 from subscription_facts_take k where k.subscription_id = x.subscription_id);
  get diagnostics n = row_count; n_written := n_written + n;
  update cma.subscription_take x
  set connection_id = k.connection_id, source_id = k.source_id, market = k.market, status = k.status, payment_state = k.payment_state,
      state_since = k.state_since, overdue = k.overdue, chargeback_return_code = k.chargeback_return_code, amount_at_risk = k.amount_at_risk,
      currency = k.currency, monthly_amount = k.monthly_amount, interval_group = k.interval_group, device_units = k.device_units,
      propositions = k.propositions, models = k.models, original_start_at = k.original_start_at, original_start_basis = k.original_start_basis,
      cohort_month = k.cohort_month, migrated = k.migrated, renewals = k.renewals
  from subscription_facts_take k
  where x.tenant_id = p_tenant_id and k.subscription_id = x.subscription_id
    and row(x.connection_id, x.source_id, x.market, x.status, x.payment_state, x.state_since, x.overdue, x.chargeback_return_code, x.amount_at_risk,
            x.currency, x.monthly_amount, x.interval_group, x.device_units, x.propositions, x.models, x.original_start_at, x.original_start_basis,
            x.cohort_month, x.migrated, x.renewals)::text
        is distinct from
        row(k.connection_id, k.source_id, k.market, k.status, k.payment_state, k.state_since, k.overdue, k.chargeback_return_code, k.amount_at_risk,
            k.currency, k.monthly_amount, k.interval_group, k.device_units, k.propositions, k.models, k.original_start_at, k.original_start_basis,
            k.cohort_month, k.migrated, k.renewals)::text;
  get diagnostics n = row_count; n_written := n_written + n;
  insert into cma.subscription_take (tenant_id, subscription_id, connection_id, source_id, market, status, payment_state, state_since, overdue,
                                     chargeback_return_code, amount_at_risk, currency, monthly_amount, interval_group, device_units,
                                     propositions, models, original_start_at, original_start_basis, cohort_month, migrated, renewals)
  select p_tenant_id, k.subscription_id, k.connection_id, k.source_id, k.market, k.status, k.payment_state, k.state_since, k.overdue,
         k.chargeback_return_code, k.amount_at_risk, k.currency, k.monthly_amount, k.interval_group, k.device_units, k.propositions, k.models,
         k.original_start_at, k.original_start_basis, k.cohort_month, k.migrated, k.renewals
  from subscription_facts_take k
  where not exists (select 1 from cma.subscription_take x where x.tenant_id = p_tenant_id and x.subscription_id = k.subscription_id);
  get diagnostics n = row_count; n_written := n_written + n;

  v_steps := v_steps || jsonb_build_object('subscriptions', round(extract(epoch from clock_timestamp() - v_mark) * 1000));
  v_mark := clock_timestamp();

  -- 4a. when each store's rates start (C.5)
  delete from cma.subscription_store_start x where x.tenant_id = p_tenant_id;
  insert into cma.subscription_store_start (tenant_id, connection_id, market, first_event_month, migration_months, last_migration_month,
                                            straggler_months, stragglers, rate_start_month)
  select p_tenant_id, r.connection_id, coalesce(sm.market, 'unknown'), r.first_event_month, r.migration_months, r.last_migration_month,
         r.straggler_months, r.stragglers, r.rate_start_month
  from cma.subscription_rate_start_of(p_tenant_id, v_now) r
  left join (select y.connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y) sm on sm.connection_id = r.connection_id;

  -- 4. per store and month (C.4, C.5): the status moves, the base at each month's start and end, the observed amount
  --    changes; months from the store's first event to the current one
  delete from cma.subscription_month_take x where x.tenant_id = p_tenant_id;
  insert into cma.subscription_month_take (tenant_id, connection_id, market, month, kind, currency, subscriptions, amount, complete)
  with sm as materialized (
    select y.connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y
  ), mv as materialized (
    select * from cma.subscription_moves_of(p_tenant_id, v_now)
  ), first_ev as materialized (
    -- the store's first event's month and the month its rates start (step 4a)
    select x.connection_id, x.first_event_month as first_month, x.rate_start_month as first_complete
    from cma.subscription_store_start x
    where x.tenant_id = p_tenant_id
  ), months as materialized (
    select f.connection_id, g::date as month, f.first_complete
    from first_ev f
    cross join lateral generate_series(f.first_month, v_month, interval '1 month') g
  ), spans as materialized (
    -- each subscription's status from each move to the next
    select m.subscription_id, m.connection_id, m.status_to as status, m.at as from_at,
           lead(m.at) over (partition by m.subscription_id order by m.at, m.kind nulls first) as to_at
    from mv m
  ), x as materialized (
    select s.id, s.connection_id, s.source_id, s.amount_per_cycle, s.currency, s.billing_interval, s.billing_interval_count
    from cma.subscription s where s.tenant_id = p_tenant_id and s.source_deleted_at is null
  ), lc as materialized (
    -- each subscription's latest observed change of its amount, interval or currency: before it the amount is taken back
    -- through the changes (cma.subscription_amount_at), after it (or without one) it is the stored one
    select c.connection_id, c.subscription_source_id, max(c.observed_at) as last_at
    from cma.subscription_change c
    where c.tenant_id = p_tenant_id and c.field in ('amount_per_cycle', 'billing_interval', 'billing_interval_count', 'currency')
    group by 1, 2
  ), af as materialized (
    -- amounts are known from each connection's first load on (rule 12): the later of the observed changes' start (0009za)
    -- and the first time the CMA held a subscription of the connection
    select s.connection_id, greatest(v_amounts, min(s.first_seen_at)) as amounts_from
    from cma.subscription s where s.tenant_id = p_tenant_id
    group by 1
  ), bounds as materialized (
    select mo.connection_id, mo.month, k.kind, k.boundary
    from months mo
    cross join lateral (values ('start', (mo.month::timestamp at time zone v_zone)),
                               ('end', least(((mo.month + interval '1 month')::timestamp at time zone v_zone), v_now))) k(kind, boundary)
  ), base_counts as (
    -- the Total subscriptions (a device-holding status) at each month's start and end: a running sum per store over the
    -- spans in such a status, +1 where one begins, -1 where it ends, read at each boundary before the changes at its
    -- moment (the status just before it: a move at the very start of a month is that month's movement)
    select r.connection_id, r.month, r.kind, r.n
    from (
      select z.connection_id, z.month, z.kind,
             sum(z.d) over (partition by z.connection_id order by z.at, z.kind nulls last rows between unbounded preceding and current row) as n
      from (
        select sp.connection_id, sp.from_at as at, 1 as d, null::text as kind, null::date as month
        from spans sp where sp.status = any (v_holding)
        union all
        select sp.connection_id, sp.to_at, -1, null, null
        from spans sp where sp.status = any (v_holding) and sp.to_at is not null
        union all
        select b.connection_id, b.boundary, 0, b.kind, b.month from bounds b
      ) z
    ) r
    where r.kind is not null
  ), base as (
    -- the members of the Total subscriptions at the boundaries from the first load on, for their monthly amounts
    select b.connection_id, b.month, b.kind, sp.subscription_id, b.boundary
    from bounds b
    join spans sp on sp.connection_id = b.connection_id and sp.from_at < b.boundary and (sp.to_at is null or sp.to_at >= b.boundary)
                 and sp.status = any (v_holding)
    join af on af.connection_id = b.connection_id
    where v_amounts is not null and b.boundary >= af.amounts_from
  ), moved as (
    select m.connection_id, (date_trunc('month', m.at at time zone v_zone))::date as month, m.kind, m.subscription_id,
           case when m.kind in ('new', 'migrated', 'reactivated', 'resumed') then m.at else m.at - interval '1 microsecond' end as boundary
    from mv m
    where m.kind is not null
  ), amounted as (
    -- the observed changes of amount or interval (C.4): expansion or contraction where the monthly amount rose or fell
    -- in one currency, without a status move observed in the same read
    select c.connection_id, x.id as subscription_id, c.observed_at
    from cma.subscription_change c
    join x on x.connection_id = c.connection_id and x.source_id = c.subscription_source_id
    where c.tenant_id = p_tenant_id and c.field in ('amount_per_cycle', 'billing_interval', 'billing_interval_count') and c.observed_at <= v_now
      and not exists (select 1 from cma.subscription_change z
                      where z.tenant_id = p_tenant_id and z.connection_id = c.connection_id and z.subscription_source_id = c.subscription_source_id
                        and z.field = 'status' and z.observed_at = c.observed_at)
    group by 1, 2, 3
  ), changed as (
    select a.connection_id, (date_trunc('month', a.observed_at at time zone v_zone))::date as month,
           case when after.monthly_amount > before.monthly_amount then 'expansion' else 'contraction' end as kind,
           a.subscription_id, after.currency, abs(after.monthly_amount - before.monthly_amount) as amount
    from amounted a
    join x on x.id = a.subscription_id
    cross join lateral cma.subscription_amount_at(p_tenant_id, a.connection_id, x.source_id, a.observed_at - interval '1 microsecond',
                                                  x.amount_per_cycle, x.currency, x.billing_interval, x.billing_interval_count) before
    cross join lateral cma.subscription_amount_at(p_tenant_id, a.connection_id, x.source_id, a.observed_at,
                                                  x.amount_per_cycle, x.currency, x.billing_interval, x.billing_interval_count) after
    where before.currency = after.currency and before.monthly_amount is distinct from after.monthly_amount
      and before.monthly_amount is not null and after.monthly_amount is not null
  ), counted as (
    select b.connection_id, b.month, b.kind, b.subscription_id, b.boundary from base b
    union all
    select m.connection_id, m.month, m.kind, m.subscription_id, m.boundary from moved m
  ), valued as (
    select c.connection_id, c.month, c.kind, c.subscription_id,
           case when l.last_at > c.boundary then am.currency else x.currency end as currency,
           case when l.last_at > c.boundary then am.monthly_amount
                else x.amount_per_cycle * cma.active_month_factor_of(x.billing_interval, x.billing_interval_count) end as monthly_amount
    from counted c
    join x on x.id = c.subscription_id
    left join lc l on l.connection_id = x.connection_id and l.subscription_source_id = x.source_id
    left join lateral (select y.* from cma.subscription_amount_at(p_tenant_id, c.connection_id, x.source_id, c.boundary,
                                                                  x.amount_per_cycle, x.currency, x.billing_interval, x.billing_interval_count) y
                       where l.last_at > c.boundary) am on true
    join af on af.connection_id = c.connection_id
    where v_amounts is not null and c.boundary >= af.amounts_from
    union all
    select ch.connection_id, ch.month, ch.kind, ch.subscription_id, ch.currency, ch.amount from changed ch
  ), rows_ as (
    select bc.connection_id, bc.month, bc.kind, ''::text as currency, bc.n::integer as n, null::numeric as amount
    from base_counts bc
    union all
    select m.connection_id, m.month, m.kind, '', count(*)::integer, null from moved m group by 1, 2, 3
    union all
    select ch.connection_id, ch.month, ch.kind, '', count(*)::integer, null from changed ch group by 1, 2, 3
    union all
    select v.connection_id, v.month, v.kind, v.currency, count(*)::integer, round(sum(v.monthly_amount), 2)
    from valued v where v.currency is not null and v.monthly_amount is not null
    group by 1, 2, 3, 4
  )
  select p_tenant_id, r.connection_id, coalesce(sm.market, 'unknown'), r.month, r.kind, r.currency, r.n, r.amount,
         r.month < v_month and r.month >= f.first_complete
  from rows_ r
  join first_ev f on f.connection_id = r.connection_id
  left join sm on sm.connection_id = r.connection_id
  where r.month >= f.first_month and r.month <= v_month;
  get diagnostics n_months = row_count;
  v_steps := v_steps || jsonb_build_object('months', round(extract(epoch from clock_timestamp() - v_mark) * 1000));
  v_mark := clock_timestamp();

  -- 5. renewal survival (C.6): subscriptions purchased in the app (not migrated) by start cohort and interval group; the
  --    start is the subscription's own in the app (its created date), never the estimated original start, whose first
  --    store order may be another subscription's of the same customer
  delete from cma.subscription_survival_take x where x.tenant_id = p_tenant_id;
  insert into cma.subscription_survival_take (tenant_id, connection_id, market, cohort_month, interval_group, renewal_number, started, eligible, survived)
  select p_tenant_id, t.connection_id, t.market, date_trunc('month', s.source_created_at at time zone v_zone)::date, t.interval_group, n.n, count(*)::integer,
         count(*) filter (where s.source_created_at + make_interval(
                                   months => case s.billing_interval when 'month' then s.billing_interval_count * n.n
                                                                     when 'year' then 12 * s.billing_interval_count * n.n else 0 end,
                                   days => case s.billing_interval when 'day' then s.billing_interval_count * n.n
                                                                   when 'week' then 7 * s.billing_interval_count * n.n else 0 end) <= v_now)::integer,
         count(*) filter (where t.renewals >= n.n)::integer
  from cma.subscription_take t
  join cma.subscription s on s.tenant_id = t.tenant_id and s.id = t.subscription_id
  cross join generate_series(1, 24) n(n)
  where t.tenant_id = p_tenant_id and not t.migrated and s.source_created_at is not null and s.billing_interval is not null
    and s.billing_interval_count is not null
  group by t.connection_id, t.market, date_trunc('month', s.source_created_at at time zone v_zone)::date, t.interval_group, n.n;
  get diagnostics n_cells = row_count;
  v_steps := v_steps || jsonb_build_object('survival', round(extract(epoch from clock_timestamp() - v_mark) * 1000));

  -- 6. the take's row
  insert into cma.subscription_take_state as t (tenant_id, computed_at, business_date, duration_ms, inputs_key, subscriptions, amounts_from,
                                                outcomes_read_at, outcomes_full_at)
  values (p_tenant_id, v_now, v_today, (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer, v_key, n_subs, v_amounts,
          v_out_read, case when v_out_full then v_out_read else v_state.outcomes_full_at end)
  on conflict (tenant_id) do update
    set computed_at = excluded.computed_at, business_date = excluded.business_date, duration_ms = excluded.duration_ms,
        inputs_key = excluded.inputs_key, subscriptions = excluded.subscriptions, amounts_from = excluded.amounts_from,
        outcomes_read_at = excluded.outcomes_read_at, outcomes_full_at = excluded.outcomes_full_at;

  return jsonb_build_object('refreshed', true, 'unchanged', false, 'device_units_written', n_units, 'subscription_rows', n_subs,
                            'month_rows', n_months, 'outcome_rows', n_outcomes, 'survival_rows', n_cells,
                            -- 0009zr: whether the outcomes were computed whole, and how many subscriptions an incremental run read
                            'outcomes_whole', v_out_full, 'outcomes_scope', coalesce(cardinality(v_scope_c), 0),
                            'rows', n_subs + n_months + n_outcomes + n_cells,
                            'rows_written', n_written + n_months + n_cells, 'steps_ms', v_steps,
                            'duration_ms', (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer);
end
$$;
alter function cma.subscription_facts_refresh_of(uuid, boolean, timestamptz) set jit = off;
-- ---------------------------------------------------------------------------------------------
-- 6. Speed to lead's one definition with an open-only bound, for the follow-up's open leads
-- ---------------------------------------------------------------------------------------------
-- cma.speed_to_lead_rows_of holds 234's definition of cma.speed_to_lead_of word for word, plus one bound: with
-- p_open_only it reads the lead deals that are not closed. Every row depends on its own deal alone (its window, its
-- calls and attempts), so the open deals' rows are the whole read's rows of those deals (237, L1 and L2). It stays one
-- definition (24 November 2026: "reading the calls once outside cma.deal_attempts_of is refused, one definition matters
-- more"): cma.speed_to_lead_of is it without the bound, inlined into its callers as before
create or replace function cma.speed_to_lead_rows_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz, p_open_only boolean)
returns setof cma.speed_to_lead_row
language sql stable
as $$
  -- materialized, so the settings are read once per call (folded into the query, once per deal)
  with s as materialized (
    select greatest(0, cma.setting_of(p_tenant_id, 'speed_to_lead.pre_window_minutes')::integer) as pre_min,
           cma.setting_of(p_tenant_id, 'speed_to_lead.target_minutes')::integer * 60 as target_s,
           cma.setting_of(p_tenant_id, 'speed_to_lead.next_day_cutoff')::time as cutoff,
           cma.setting_of(p_tenant_id, 'attempts.source') as source
  ),
  -- each market's zone, office hours and holidays read once per call, not per deal
  cal as materialized (
    select * from cma.business_calendar_of(p_tenant_id)
  ),
  -- the window's end of each sales deal as Attempts per deal reads it (cma.sales_deals_of: the earliest of the close,
  -- the first order of the deal's contacts and now), so both give the same answer for every deal (Martin, 24 Nov 2026)
  w as materialized (
    select sd.deal_id, sd.window_end, sd.window_end_reason
    from cma.sales_deals_of(p_tenant_id, p_from, p_to, now()) sd
  ),
  d as materialized (
    -- the attempts' source and the cutoff as columns: a function argument holding a subquery stops the planner from
    -- inlining cma.deal_attempts_of, which then ran once per deal on its own plan (twice the time). A lead deal outside
    -- the sales deals (a pipeline that is both a lead and an order pipeline) ends at its close, else now
    select ld.*, ld.created_at - make_interval(mins => s.pre_min) as not_before,
           coalesce(w.window_end, case when ld.is_closed then coalesce(cr.closed_at, now()) else now() end) as until,
           coalesce(w.window_end_reason = 'ordered', false) as ordered,
           s.source as attempts_source, s.cutoff
    from cma.lead_deals_of(p_tenant_id, p_from, p_to) ld
    cross join s
    left join w on w.deal_id = ld.deal_id
    left join cma.crm_record cr on cr.tenant_id = p_tenant_id and cr.id = ld.deal_id
    -- 0009zr: with p_open_only the lead deals not closed only (the follow-up's open leads); each deal's row is its own
    where not coalesce(p_open_only, false) or not ld.is_closed
  ),
  -- every call of each deal from the window's start, read once: the first outbound CRM call, the first call and the
  -- first connected call, shown beside the measure as before
  c as materialized (
    select d.deal_id, lc.*
    from d
    cross join lateral cma.lead_calls_of(p_tenant_id, d.connection_id, d.record_type, d.source_id, d.contacts, d.not_before) lc
  ),
  fo as (select distinct on (c.deal_id) c.* from c where c.direction = 'outbound' order by c.deal_id, c.effective_at, c.call_id),
  fa as (select distinct on (c.deal_id) c.* from c order by c.deal_id, c.effective_at, c.call_id),
  fc as (select distinct on (c.deal_id) c.* from c where c.is_connected order by c.deal_id, c.effective_at, c.call_id),
  -- each deal's first Attempt in its window and the attempts so far: one lateral into cma.deal_attempts_of per deal,
  -- one aggregate row each (n numbers the attempts from 1, so the first is n = 1 and the count the highest n). Only for
  -- the deals that can have one: an attempt is one of the deal's calls in c (cma.deal_attempts_of reads
  -- cma.deal_calls_of from the same start, as cma.lead_calls_of does), under telephony a linked one, under crm an
  -- outbound one; the other deals have none and are not read again (a third of the deals at three times prod's volume)
  a as materialized (
    select d.deal_id, x.*
    from d
    cross join lateral (
      select (array_agg(z.call_id) filter (where z.n = 1))[1] as call_id,
             min(z.effective_at) filter (where z.n = 1) as effective_at,
             min(z.telephony_source_system) filter (where z.n = 1) as telephony_source_system,
             min(z.telephony_user_ref) filter (where z.n = 1) as telephony_user_ref,
             coalesce(max(z.n), 0)::integer as attempts
      from cma.deal_attempts_of(p_tenant_id, d.connection_id, d.record_type, d.source_id, d.contacts, d.not_before, d.until,
                                d.attempts_source) z
      where z.is_attempt) x
    where d.deal_id in (select c.deal_id from c
                        where case when (select s.source from s) = 'crm' then c.direction = 'outbound' else c.is_linked end)
  ),
  r as (
    select d.*, fo.call_id as fo_id, fo.call_source_id as fo_src, fo.effective_at as fo_at, fo.is_linked as fo_linked,
           fa.effective_at as fa_at, fa.direction as fa_dir, fc.effective_at as fc_at,
           a.call_id as at_id, a.effective_at as at_at, a.telephony_source_system as at_system, a.telephony_user_ref as at_user,
           coalesce(a.attempts, 0) as attempts,
           (select s.target_s from s) as target_s,
           nn.noon,
           bc.time_zone as cal_zone, bc.weekdays as cal_weekdays, bc.opens as cal_opens, bc.closes as cal_closes, bc.holidays as cal_holidays
    from d
    left join cal bc on bc.market = nullif(d.market, 'unknown')
    -- offset 0: the cutoff moment computed once per deal (pulled up, it ran once per reference), from the calendar's arrays
    left join lateral (select cma.next_business_noon_in(bc.time_zone, bc.weekdays, bc.holidays, d.created_at, d.cutoff) as noon
                       offset 0) nn on true
    left join fo on fo.deal_id = d.deal_id
    left join fa on fa.deal_id = d.deal_id
    left join fc on fc.deal_id = d.deal_id
    left join a on a.deal_id = d.deal_id
  ),
  m as (
    select r.*, bt.bs, bt.bs_now, xa.user_id as ag_user, xo.user_id as owner_user
    from r
    -- offset 0: each deal's business seconds computed once (pulled up, they ran once per reference), from the calendar's
    -- arrays; an attempt in the pre-window is 0 (cma.business_seconds_in of an end before the start)
    left join lateral (
      select case when r.at_at is not null
                  then cma.business_seconds_in(r.cal_zone, r.cal_weekdays, r.cal_opens, r.cal_closes, r.cal_holidays, r.created_at, r.at_at) end as bs,
             case when r.at_at is null and not r.is_closed and not r.ordered
                  then cma.business_seconds_in(r.cal_zone, r.cal_weekdays, r.cal_opens, r.cal_closes, r.cal_holidays, r.created_at, now()) end as bs_now
      offset 0) bt on true
    -- the agent: the first attempt's telephony user mapped to a person (as cma.calls_people_of maps a call's user)
    left join cma.app_user_external_id xa
      on xa.tenant_id = p_tenant_id and xa.system = r.at_system || '_user' and xa.external_id = r.at_user
    -- the deal's owner mapped to a person, apart from the measure
    left join cma.app_user_external_id xo
      on xo.tenant_id = p_tenant_id and xo.system = r.source_system || '_owner' and xo.external_id = r.owner_ref
  )
  select p_tenant_id, m.deal_id, m.connection_id, m.source_id, m.pipeline_id, m.pipeline_label, m.business_date,
         m.created_at, m.market, m.market_source, m.is_closed,
         case when m.at_at is not null then 'called'
              when m.is_closed or m.ordered then 'closed_before_first_call' else 'not_called_open' end,
         m.fo_id, m.fo_src, m.fo_at, m.fo_linked, m.fa_at, m.fa_dir,
         coalesce(m.fa_dir = 'inbound', false), m.fc_at,
         m.ag_user, m.at_user, case when m.at_user is not null then 'call' end,
         case when m.at_at is not null then greatest(0, floor(extract(epoch from m.at_at - m.created_at)))::integer end,
         m.bs, m.target_s,
         case when m.bs is not null then m.bs <= m.target_s
              when m.bs_now > m.target_s then false end,
         m.noon,
         case when m.at_at is not null and m.noon is not null then m.at_at < m.noon
              when m.at_at is null and not m.is_closed and not m.ordered and m.noon is not null and now() >= m.noon then false end,
         m.bs_now,
         m.at_id, m.at_at, m.attempts, m.owner_user
  from m
$$;

-- 234's form, every lead deal in the period: the one definition above without the open-only bound
-- based on: 234_speed_to_lead_one.sql
create or replace function cma.speed_to_lead_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns setof cma.speed_to_lead_row
language sql stable
as $$
  select * from cma.speed_to_lead_rows_of(p_tenant_id, p_from, p_to, false)
$$;

-- based on: 234_speed_to_lead_one.sql
create or replace function cma.open_leads_of(p_tenant_id uuid)
returns setof cma.open_lead_row
language sql stable
as $$
  -- materialized, so the two settings are read once per call (folded into the query, once per lead)
  with s as materialized (
    select cma.setting_of(p_tenant_id, 'leads.age_buckets_business_days') as edges,
           greatest(0, cma.setting_of(p_tenant_id, 'speed_to_lead.pre_window_minutes')::integer) as pre_min
  ),
  -- each market's zone, office hours and holidays read once per call, not per lead
  cal as materialized (
    select * from cma.business_calendar_of(p_tenant_id)
  ),
  r as (
    -- 0009zr: the open lead deals only (a closed deal is never not_called_open); the same rows as the whole read
    select * from cma.speed_to_lead_rows_of(p_tenant_id, null, null, true) x where x.status = 'not_called_open'
  )
  select p_tenant_id, r.deal_id, r.connection_id, r.deal_source_id, r.pipeline_id, r.pipeline_label,
         r.deal_owner_user_id, d.owner_ref, r.market, r.created_at, r.waiting_business_seconds,
         a.days, b.bucket_from, b.bucket_to,
         case when r.within_target is false then true when r.waiting_business_seconds is null then null else false end,
         lc.last_at,
         case when lc.last_at is not null then floor(extract(epoch from now() - lc.last_at) / 86400)::integer end
  from r
  cross join s
  join cma.lead_deals_of(p_tenant_id, null, null) d on d.deal_id = r.deal_id
  left join cal bc on bc.market = nullif(r.market, 'unknown')
  -- offset 0: the days computed once per lead (pulled up, the call ran once per reference to a.days), from the calendar's arrays
  cross join lateral (select cma.business_days_in(bc.time_zone, bc.weekdays, bc.holidays, r.created_at, now()) as days offset 0) a
  cross join lateral cma.age_bucket_of(a.days, s.edges) b
  left join lateral (
    select max(c.effective_at) as last_at
    from cma.lead_calls_of(p_tenant_id, d.connection_id, d.record_type, d.source_id, d.contacts, d.created_at - make_interval(mins => s.pre_min)) c) lc on true
  order by r.waiting_business_seconds desc nulls last, r.created_at
$$;

-- The follow-up refresh without JIT (night N07, WP5): a function-level setting, as 132 gave its open tickets and tasks.
-- Its statements' plans cost over jit_above_cost, so a fresh connection compiled them on every run (444 ms of the open
-- leads' 1,085 at three times prod's volume; without JIT 754 ms, the whole refresh 2.0 s → 1.4 s). Not a redefinition:
-- a later create or replace of the function repeats this line, as 132's rule says
alter function cma.refresh_follow_up_of(uuid, boolean) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 7. The small configuration tables: statistics after a handful of edits (prod's diagnosis of 16 November 2026 lists
--    them as never analyzed; a table of 10 to 101 rows never reaches the default threshold of 50 rows plus 10 %)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array['setting', 'tenant_setting', 'market', 'market_alias', 'business_hours', 'business_holiday',
                           'telephony_tag', 'app_user_external_id'] loop
    if to_regclass('cma.' || t) is not null then
      execute format('alter table cma.%I set (autovacuum_analyze_threshold = 10, autovacuum_analyze_scale_factor = 0)', t);
    end if;
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.web_busy(text)', 'cma.job_gate_of(text)', 'cma.check_job_setting()',
    'cma.renewal_outcomes_of(uuid,uuid[],text[])', 'cma.renewal_outcomes_of(uuid)',
    'cma.subscription_facts_refresh_of(uuid,boolean,timestamptz)',
    'cma.speed_to_lead_rows_of(uuid,timestamptz,timestamptz,boolean)', 'cma.speed_to_lead_of(uuid,timestamptz,timestamptz)',
    'cma.open_leads_of(uuid)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. Last, before the addition's row and the commit (CLAUDE.md, Performance; 132, section 10): the trigger on
--    cma.tenant_setting and the two columns of cma.subscription_take_state take ACCESS EXCLUSIVE locks held to the
--    commit; every settings read and the facts refresh wait on them for this moment only. The facts refresh above reads
--    the columns at run time, not at its creation
-- ---------------------------------------------------------------------------------------------
drop trigger if exists check_job_setting on cma.tenant_setting;
create trigger check_job_setting before insert or update on cma.tenant_setting
  for each row execute function cma.check_job_setting();
alter table cma.subscription_take_state add column if not exists outcomes_read_at timestamptz;
alter table cma.subscription_take_state add column if not exists outcomes_full_at timestamptz;
comment on column cma.subscription_take_state.outcomes_read_at is 'When the last computation of the renewal outcomes started reading its inputs (0009zr): the next one reads what was written since, less 10 minutes';
comment on column cma.subscription_take_state.outcomes_full_at is 'When the last whole computation of the renewal outcomes started (0009zr): a whole one at least every hour';

-- ---------------------------------------------------------------------------------------------
-- 10. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009zr', 'The minute jobs off the vCPU (Martin, 24 Nov 2026; brief N07, D6, D7): settings jobs.defer_web_statements (2) and jobs.defer_max_in_a_row (5), checked by cma.check_job_setting(); customers.refresh_minutes defaults to 10; cma.web_busy(text) (SECURITY DEFINER, the web''s active statements now) and cma.job_gate_of(text) (nothing_to_read, after_timeout: 5 to 60 minutes after a 57014, deferred, go) for the web minute jobs; cma.subscription_take_state.outcomes_read_at and outcomes_full_at; cma.renewal_outcomes_of(uuid, uuid[], text[]) and the facts refresh''s renewal outcomes incremental (the subscriptions written since, a whole one hourly and on a new date or a billing event); cma.speed_to_lead_rows_of (the one definition with an open-only bound) under cma.speed_to_lead_of and cma.open_leads_of; autovacuum analyze thresholds on the small configuration tables; cma.refresh_follow_up_of set jit = off')
on conflict (version) do nothing;

commit;
reset role;
