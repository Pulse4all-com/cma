-- =============================================================================================
-- 222_subscription_moves_entry.sql: addition 0009zk, a subscription's entry status is the one its first status event names
-- as its previous, even when that event names none
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 210_subscription_facts.sql
-- (0009ze); it needs neither 0009zh (#308) nor 0009zi and 0009zj (#309), and they need nothing of it. Rerunnable,
-- forward-only, in one transaction with a lock timeout. Run as your own IAM login: dev first, then
-- 223_verify_subscription_moves_entry.sql there (normal, then provoked), then the verifies that read what this
-- re-creates: 211_verify_subscription_facts.sql and 213_verify_subscription_facts_speed.sql (cma.subscription_moves_of,
-- directly and through cma.subscription_facts_refresh_of; grep -lw 'cma\.subscription_moves_of' db/*verify*.sql), and,
-- where 0009zi ran, 219_verify_source_figure_moves.sql (its B2 reads the moves). Neither is edited: their events all name
-- a previous status. Prod: this script and 223 (its block B refuses prod's data, as 211's does). No page reads anything
-- new; the facts' next refresh uses it (the minute job's step, when its inputs change: the backfill of the events that
-- follows this in PROD_RUNBOOK phase 23 changes them).
--
-- Why (Martin, 23 November 2026, PROD_RUNBOOK 19.18 and 19.19): the CMA holds no status event before 28 January 2026,
-- because Juo wrote every update before that day in its legacy shape (the new status at the top level, no input) and the
-- adapter read the new shape only. The adapter now reads the legacy shape too (ingest/src/adapters/juo/map.mjs, this
-- addition), and the backfill of the events stores those moves with no previous status (Juo's legacy shape names none).
-- 210's cma.subscription_moves_of takes a subscription's entry status from the first status event that names a previous
-- status, so a subscription with a legacy move first and a new-shape move later would enter in the later move's previous
-- status: a subscription canceled in 2025 (legacy, no previous status) and reactivated in March 2026 (from canceled) would
-- enter canceled, and its 2025 cancellation would be no churn. 210's own comment says the rule meant: the status the first
-- status event names as its previous one, else active. This makes the code say it.
--
-- What it re-creates
--   cma.subscription_moves_of(uuid,timestamptz)   210: the entry status is the first status event's status_from, active
--                                                 when it names none (210 skipped events without one); JIT off; nothing
--                                                 else changes
-- Who reads it: cma.subscription_facts_refresh_of (212) for cma.subscription_month_take, so the movements, the Churn rate
-- and the Failed rate (cma_read.subscription_churn_month), and 219's B2 where 0009zi ran. Where every subscription's first
-- status event names a previous status (every event the CMA held before the backfill but the canceled and paused reports
-- whose previousStatus Juo left out), the answer is 210's; 223's A2 compares the two row for row on every tenant and names
-- the subscriptions that differ (counts only).
-- Cost: the same plan as 210's (one aggregate's filter loses a condition); no index.
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
  if not exists (select 1 from cma.schema_migration where version = '0009ze') then
    raise exception 'addition 0009ze (210_subscription_facts.sql) has not run in this database';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The status moves: the entry status from the first status event, named or not
-- ---------------------------------------------------------------------------------------------
-- The status moves of every present subscription (C.4, C.5), reconstructed from the app's events up to a moment: its
-- entry at its creation in the app (kind new, or migrated when the app migrated it) in the status the first status event
-- names as its previous one (else active); every event that sets a status (status_changed, canceled, paused, resumed,
-- reactivated) that moves it; and, when the last of them does not end in the subscription's current status (the audit's
-- status_chain: a pause without an event), a last move into the current status at the latest of the last event, the
-- subscription's paused or canceled time and its last update at the source. A move's kind: churned (into an ended status,
-- flash.ended_subscription_statuses, from one that is not), moved_to_failed (into failed, while failed is not an ended
-- status), paused, resumed (paused to active), reactivated (any other status to active), none otherwise
-- based on: 210_subscription_facts.sql
create or replace function cma.subscription_moves_of(p_tenant_id uuid, p_now timestamptz)
returns table (subscription_id uuid, connection_id uuid, at timestamptz, status_from text, status_to text, kind text)
language sql stable
rows 100000
as $$
  with st as materialized (
    select cma.flash_list_of(cma.setting_of(p_tenant_id, 'flash.ended_subscription_statuses')) as ended
  ), s as materialized (
    select x.id, x.connection_id, x.source_id, x.status, x.source_created_at, x.paused_at, x.canceled_at, x.source_updated_at
    from cma.subscription x
    where x.tenant_id = p_tenant_id and x.source_deleted_at is null
  ), ev as materialized (
    select s.id, e.occurred_at, e.source_id, e.event_type, e.status_from,
           case e.event_type when 'status_changed' then e.status_to when 'canceled' then 'canceled' when 'paused' then 'paused'
                             when 'resumed' then 'active' when 'reactivated' then 'active' end as status_to
    from s
    join cma.subscription_event e on e.tenant_id = p_tenant_id and e.connection_id = s.connection_id and e.subscription_source_id = s.source_id
    where e.occurred_at <= p_now
      and e.event_type in ('status_changed', 'canceled', 'paused', 'resumed', 'reactivated', 'migrated', 'purchased', 'created')
  ), first_ev as (
    select ev.id, min(ev.occurred_at) as first_at,
           -- 0009zk: the first status event's previous status, even when unknown (then active, below): an earlier
           -- report without one (Juo's legacy shape) is no longer passed over for a later event's
           (array_agg(ev.status_from order by ev.occurred_at, ev.source_id collate "C")
              filter (where ev.status_to is not null))[1] as first_from,
           bool_or(ev.event_type = 'migrated') as migrated
    from ev
    group by ev.id
  ), seq as (
    -- the entry, then the status events in their order
    select s.id, coalesce(s.source_created_at, f.first_at) as at, 0 as ord, ''::text as src, coalesce(f.first_from, 'active') as status_to,
           coalesce(f.migrated, false) as migrated
    from s left join first_ev f on f.id = s.id
    where coalesce(s.source_created_at, f.first_at) <= p_now
    union all
    select ev.id, ev.occurred_at, 1, ev.source_id, ev.status_to, false
    from ev where ev.status_to is not null
  ), lagged as (
    select q.id, q.at, q.ord, q.src, q.status_to, q.migrated,
           lag(q.status_to) over (partition by q.id order by q.at, q.ord, q.src collate "C") as status_from,
           row_number() over (partition by q.id order by q.at desc, q.ord desc, q.src collate "C" desc) as from_last
    from seq q
  ), moves as (
    select l.id, l.at, l.status_from, l.status_to, l.ord, l.migrated
    from lagged l
    where l.ord = 0 or l.status_from is distinct from l.status_to
    union all
    -- the current status where the events do not end in it
    select s.id,
           greatest(l.at, case when s.status = 'paused' then s.paused_at when s.status in ('canceled', 'expired') then s.canceled_at end,
                    least(s.source_updated_at, p_now)),
           l.status_to, s.status, 2, false
    from s
    join lagged l on l.id = s.id and l.from_last = 1
    where l.status_to is distinct from s.status and s.source_updated_at <= p_now
  )
  select m.id, s.connection_id, m.at, m.status_from, m.status_to,
         case when m.ord = 0 then case when m.status_to = 'active' then case when m.migrated then 'migrated' else 'new' end end
              when m.status_to = any ((select st.ended from st)::text[]) then
                case when m.status_from = any ((select st.ended from st)::text[]) then null else 'churned' end
              when m.status_to = 'failed' then 'moved_to_failed'
              when m.status_to = 'paused' then 'paused'
              when m.status_to = 'active' and m.status_from = 'paused' then 'resumed'
              when m.status_to = 'active' then 'reactivated' end
  from moves m
  join s on s.id = m.id
$$;
alter function cma.subscription_moves_of(uuid, timestamptz) set jit = off;

do $$
begin
  execute 'revoke execute on function cma.subscription_moves_of(uuid,timestamptz) from public';
  execute 'grant execute on function cma.subscription_moves_of(uuid,timestamptz) to cma_app';
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009zk', 'Juo''s legacy status moves: the adapter reads an update''s top-level status when it carries no input (every update before 28 January 2026), and cma.subscription_moves_of re-created from 210 so a subscription''s entry status is the one its first status event names as its previous, active when it names none')
on conflict (version) do nothing;

commit;
reset role;
