-- =============================================================================================
-- 182_live_missed_first.sql: addition 0009q, the Live board's poll reads the first missed callers and their count
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 180_flash_stored_cards.sql
-- (0009p). Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own IAM login: dev first, then
-- 183_verify_live_missed_first.sql there (normal, then provoked), then 131_time_all.sql part a (its poll rows time the
-- new read). No function is re-created and no table, view, column or index changes, so no other verify is run again:
-- cma.inbound_now() stays exactly as 170 left it (133, 145, 165 and 171 read it and are not touched). Prod: this script
-- and 183 before the merge; the web of main runs unchanged on it (it keeps calling cma.inbound_now()).
--
-- Why (Martin, 11 November 2026: speed first, also on Live Newco; docs/open-decisions.md, "The poll still sends every
-- missed caller every 10 seconds. Cap it in the API with a count and a Show all on demand"): the board shows the oldest
-- twenty missed callers and a "Show all" button, yet its poll read every missed caller with a record link each, every
-- ten seconds per open board: at three times prod's volume about 1,700 callers, 45 ms of database time against the
-- poll's 20 ms, and 700 kB of JSON per poll. With this read: 25 ms and 10 kB at that volume (measured locally,
-- 12 November 2026). So the poll is halved and still above its 20 ms there: what remains is the callers' derivation itself
-- and the office-hours wait, computed for every caller before the cut (docs/open-decisions.md).
--
-- What it adds
--   read   cma.inbound_now_first(p_first): cma.inbound_now()'s answer with the missed callers cut to the oldest
--          p_first (null: every caller, for "Show all"): today's figures (cma.inbound_today_live_of, without the two
--          keys cma.inbound_now() keeps for one release, waiting_now and longest_waiting_seconds), callbacks (the
--          oldest p_first callers, each with its record link, in cma.inbound_now()'s order) and summary (listed: how
--          many callers the whole list holds, as before; shown: how many this answer holds; anonymous_count and
--          lookback_days as before). The callers are read once (cma.missed_callbacks_of, unchanged); the record link and
--          the row's JSON are built for the listed rows only. monitoring.live (CMA06); p_first below 0 CMA04
-- What it leaves: cma.inbound_now() itself, exactly as it is, for the web of main until this change is released and
-- for its four verifies. The web of this change calls cma.inbound_now_first alone (the data API's every caller is
-- cma.inbound_now_first(null)), so after the release cma.inbound_now() has no caller: removing it, and with it the two
-- kept keys, stays the open decision it was, and that migration edits 133, 145, 165, 171 and 183.
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
  if not exists (select 1 from cma.schema_migration where version = '0009p') then
    raise exception 'addition 0009p (180_flash_stored_cards.sql) has not run in this database';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Inbound now with the first missed callers
-- ---------------------------------------------------------------------------------------------
-- The callers once, materialized: their count, and the oldest p_first of them in cma.inbound_now()'s order (started_at,
-- source_id; a null limit takes them all). plpgsql and stable, as cma.inbound_now(): an aggregate inside a plpgsql
-- select into may run in parallel, where a return query (a cursor) may not (night N06)
create or replace function cma.inbound_now_first(p_first integer)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_total  integer;
  v_list   jsonb;
begin
  perform cma.assert_permission('monitoring.live');
  if p_first < 0 then
    raise exception 'first takes 0 or more, or null for every caller' using errcode = 'CMA04';
  end if;
  with m as materialized (
    select * from cma.missed_callbacks_of(v_tenant)
  ),
  l as (
    select * from m order by m.started_at, m.source_id limit p_first
  )
  select (select count(*) from m)::integer,
         coalesce((select jsonb_agg(to_jsonb(l) || jsonb_build_object('record_url', cma.record_url(l.connection_id, 'call', l.source_id))
                                    order by l.started_at, l.source_id)
                   from l), '[]'::jsonb)
    into v_total, v_list;
  return jsonb_build_object(
    'today', (select to_jsonb(x) - 'waiting_now' from cma.inbound_today_live_of(v_tenant) x),
    'callbacks', v_list,
    'summary', (select jsonb_build_object('listed', v_total, 'shown', jsonb_array_length(v_list),
                                          'anonymous_count', cma.anonymous_missed_calls_of(v_tenant, now() - make_interval(days => s.lookback)),
                                          'lookback_days', s.lookback)
                from (select greatest(0, cma.setting_of(t.id, 'telephony.callback_lookback_days')::integer) as lookback
                      from cma.tenant t where t.id = v_tenant) s));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. Grants: the application only
-- ---------------------------------------------------------------------------------------------
revoke execute on function cma.inbound_now_first(integer) from public;
grant execute on function cma.inbound_now_first(integer) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 3. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009q', 'Live board: cma.inbound_now_first(first) answers cma.inbound_now()''s today (without waiting_now and longest_waiting_seconds), the oldest so many missed callers with their record links and a summary with the whole list''s count (listed) and this answer''s (shown), so the board''s poll reads one screen of callers instead of every caller; cma.inbound_now() unchanged')
on conflict (version) do nothing;

commit;
reset role;
