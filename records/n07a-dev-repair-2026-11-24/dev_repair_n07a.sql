-- Dev only (cma-dev-pg), one transaction: takes #318's 236 (speed to lead cockpit) out of dev so that N07a's
-- 236_jobs_off_the_vcpu.sql runs again. Afterwards: rerun 234_speed_to_lead_one.sql, then N07a's 236.
-- #318 re-creates all of this later as its renumbered 242/243 (0009zu), on top of N07a.
-- Leaves alone: the schema_migration row 0009zr, the three settings speed_to_lead.goal_* and
-- speed_to_lead.stale_business_days (and any tenant values for them), cma.check_tenant_setting's extra checks for them,
-- and the jit/plan settings on cma.speed_to_lead_rows(date, date). None of these is read by N07a or 234.
begin;
set local lock_timeout = '5s';
set role cma_owner;

-- 1. #318's new reads and their types (none existed before #318)
drop function if exists cma.speed_to_lead_page(date, date, text, text, text, integer, integer);
drop function if exists cma.speed_to_lead_deals_of(date, date, text, text, integer, integer);
drop function if exists cma.speed_to_lead_figures(date, date, text);
drop function if exists cma.speed_to_lead_view_check(text, integer, integer);
drop function if exists cma.speed_to_lead_deals_from(uuid, cma.speed_to_lead_row[], date, date, text, text, integer, integer);
drop function if exists cma.speed_to_lead_figures_from(uuid, cma.speed_to_lead_row[], date, date, date, date, timestamptz, text, text);
drop function if exists cma.speed_to_lead_groups_from(cma.speed_to_lead_row[], date, date, text, text);
drop type if exists cma.speed_to_lead_deal_row;
drop type if exists cma.speed_to_lead_figures_row;

-- 2. #318's summary has more columns than 234's; 234's rerun makes its own again
drop function if exists cma.speed_to_lead_summary(date, date, text, text);

-- 3. The readers' view is made from the type's columns; 234's rerun makes it again
drop view if exists cma_read.speed_to_lead;

-- 4. The row type back to 234's columns in 234's order: every column after status is dropped and added again in that
--    order (the first twelve stay). The functions that return the type stay; 234 and N07a's 236 re-create them
do $$
begin
  if exists (select 1 from pg_attribute a
             where a.attrelid = (select t.typrelid from pg_type t where t.oid = to_regtype('cma.speed_to_lead_row'))
               and a.attname = 'window_end' and not a.attisdropped) then
    alter type cma.speed_to_lead_row
      drop attribute first_any_call_at, drop attribute first_any_direction, drop attribute inbound_first,
      drop attribute first_connected_at, drop attribute agent_user_id, drop attribute agent_ref, drop attribute agent_from,
      drop attribute elapsed_seconds, drop attribute business_seconds, drop attribute target_seconds,
      drop attribute within_target, drop attribute next_business_noon, drop attribute before_next_noon,
      drop attribute waiting_business_seconds, drop attribute first_attempt_call_id, drop attribute first_attempt_at,
      drop attribute attempts_so_far, drop attribute deal_owner_user_id, drop attribute last_attempt_at,
      drop attribute last_call_at, drop attribute deal_owner_ref, drop attribute conversations_so_far,
      drop attribute window_end;
    alter type cma.speed_to_lead_row
      add attribute first_call_id uuid, add attribute first_call_source_id text, add attribute first_call_at timestamptz,
      add attribute first_call_linked boolean, add attribute first_any_call_at timestamptz,
      add attribute first_any_direction text, add attribute inbound_first boolean,
      add attribute first_connected_at timestamptz, add attribute agent_user_id uuid, add attribute agent_ref text,
      add attribute agent_from text, add attribute elapsed_seconds integer, add attribute business_seconds integer,
      add attribute target_seconds integer, add attribute within_target boolean,
      add attribute next_business_noon timestamptz, add attribute before_next_noon boolean,
      add attribute waiting_business_seconds integer, add attribute first_attempt_call_id uuid,
      add attribute first_attempt_at timestamptz, add attribute attempts_so_far integer,
      add attribute deal_owner_user_id uuid;
  end if;
end
$$;

-- 5. 234's and N07a's functions still hold #318's bodies; 234's rerun, then N07a's 236, replace them. Until then
--    speed to lead's reads fail in dev (a minute at most)
commit;
