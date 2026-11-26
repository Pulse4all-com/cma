-- =============================================================================================
-- 252_roster_pause_no_market.sql: addition 0009zz, a pause block has no hours market (brief A's follow-up)
-- =============================================================================================
-- Universal: no customer, tenant, status, market or vendor specifics. Runs unchanged in every database, after
-- 248_roster_assignments.sql (0009zx); it refuses to run before 0009zx is recorded. #334 holds 0009zy with 250/251; this
-- needs nothing of it and it needs nothing of this, so the guard asks for 0009zx only and either may run first (two PRs on
-- one number are renumbered in merge order, Decision log, 25 Nov 2026). Rerunnable, forward-only, in one transaction with a
-- lock timeout. No table, view or column changes: functions only.
-- Run as your own IAM login: dev first, then 253_verify_roster_pause_no_market.sql there (normal, then provoked), then the
-- verifies below; then prod, before the merge: this script, 253 and the same verifies.
--
-- Why (Martin's hand check in dev, 26 November 2026, image 914c510): the Planned hours panel showed "LB GB", a lunch break
-- under an hours market. A pause is no work under a market: a block of kind pause has no Hours market (Decision log,
-- 26 Nov 2026). The planner's CODE-MARKET on a pause type is refused with a clear text (CMA04); a pause is stored without a
-- market and every read shows it without one, so the Planned hours panel lists pauses per type, without a market.
--
-- What it changes (each from its latest earlier definition, 248_roster_assignments.sql, named on the line above its create;
-- signatures, columns and every other answer kept)
--   cma.roster_assignment_rules()          the table's insert rule also refuses an hours market on a block of a pause type
--                                          (CMA04), whoever writes
--   cma.roster_put_assignments(5 args)     strict (the planner, cma.roster_set_assignments): a pause with an hours market
--                                          is refused (CMA04, "assignment type LB is a pause, and a pause has no hours
--                                          market: plan LB without one, not LB-GB"); not strict (Copy week, Apply standard
--                                          week): the pause is written without the market an older block or standard row
--                                          may still carry, never dropped; a pause that differs from a current row only
--                                          by that older market counts as unchanged, so a retired pause type does not
--                                          lock its person-date (it is rewritten without the market)
--   cma.roster_blocks_json, cma.roster_assignments, cma.standard_week()
--                                          a pause block's hoursMarket / hours_market_code is null
--   cma.roster_slot_coverage, cma.roster_planned_hours
--                                          a pause block counts under no market (null), not under the Default market
--   cma.roster_published_blocks_json       a pause block: hoursMarket null, ownMarket false, hoursMarketZone null (My
--                                          schedule shows no market time in brackets for a pause); via cma.my_roster and
--                                          cma.roster_today
--   cma.save_standard_week(date, text)     a pause block is saved without a market
-- A pause block written before this script keeps its stored market as history (insert-only, D7); every read above shows it
-- without one, and the planner's next write of that person-date stores it without one.
--
-- Verifies that read what this changes, run again after this script (grep -lw 'cma\.<function>' db/*verify*.sql, and the
-- functions that call them: roster_published_blocks_json through my_roster and roster_today, roster_blocks_json through
-- roster_cell and roster_set_assignments):
--   249_verify_roster_assignments.sql   edited by this change: B4's agent view of LB reads "pause - - false -" (no market,
--                                       not own market, no zone) where it read "pause - NL true Europe/Amsterdam"; B10
--                                       already counted LB under no market (a2 has no Default market), unchanged
--   25_verify_roster.sql, 199_verify_roster_planned.sql
--                                       my_roster and roster_today; unchanged (their fixtures hold no blocks)
-- 131_time_all.sql: no new read; the rows 'roster assignments', 'roster slot coverage', 'roster planned hours', 'standard
-- week', 'my roster week' and 'my roster today' read the re-created functions as before (the type is already
-- joined in each; save_standard_week gains that join, by key on a small catalog).
--
-- SQLSTATEs as 0005's: CMA04 invalid.
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
select set_config('app.actor_label', 'migration:0009zz', true);

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0009zx') then
    raise exception 'addition 0009zx (248_roster_assignments.sql) must run before 0009zz';
  end if;
end
$$;
-- ---------------------------------------------------------------------------------------------
-- 1. The table's rule: a pause block has no hours market (insert)
-- ---------------------------------------------------------------------------------------------
-- A block's start and end lie on the tenant's slot grid (D6), its market is an hours market of the tenant (D5), and a
-- block of kind pause has no market
-- based on: 248_roster_assignments.sql
create or replace function cma.roster_assignment_rules()
returns trigger
language plpgsql
as $$
declare
  v_slot integer := cma.setting_of(new.tenant_id, 'roster.slot_minutes')::integer;
  v_start integer := (extract(epoch from new.start_time) / 60)::integer;
  v_end integer := (extract(epoch from new.end_time) / 60)::integer;
begin
  if v_start % v_slot <> 0 or v_end % v_slot <> 0 then
    raise exception 'an assignment starts and ends on the % minute grid; got % to %', v_slot,
      to_char(new.start_time, 'HH24:MI'), case when v_end = 1440 then '24:00' else to_char(new.end_time, 'HH24:MI') end
      using errcode = 'CMA04';
  end if;
  -- A pause is no work under a market: a block of kind pause has no hours market (Martin, 26 November 2026); checked
  -- first, so a pause with any market gets this reason
  if new.hours_market_code is not null and exists (
       select 1 from cma.assignment_type t
       where t.tenant_id = new.tenant_id and t.id = new.assignment_type_id and t.kind = 'pause') then
    raise exception 'a pause has no hours market: plan it without one (got %)', new.hours_market_code using errcode = 'CMA04';
  end if;
  if new.hours_market_code is not null and not exists (
       select 1 from cma.market m
       where m.tenant_id = new.tenant_id and m.code = new.hours_market_code and m.hours_market_code = m.code) then
    raise exception 'market % is no hours market of the tenant', new.hours_market_code using errcode = 'CMA04';
  end if;
  return new;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. The writer: a pause with a market is refused (the planner) or written without it (Copy week, Apply standard week)
-- ---------------------------------------------------------------------------------------------
-- The one writer of blocks (roster.manage), 248's, with the pause rule: see 248 for the contract. A pause with an hours
-- market is refused when strict and written without it when not
-- based on: 248_roster_assignments.sql
create or replace function cma.roster_put_assignments(p_week_id uuid, p_user_id uuid, p_date date, p_blocks jsonb, p_strict boolean)
returns jsonb
language plpgsql
as $$
declare
  v_shift  cma.roster_entry;
  v_slot   integer := cma.setting_of(cma.current_tenant_id(), 'roster.slot_minutes')::integer;
  b        jsonb;
  v_type   cma.assignment_type;
  v_start  time;
  v_end    time;
  v_market text;
  v_note   text;
  v_bad    text;
  -- the wanted blocks, validated, as a JSON array of {type_id, start_time, end_time, market, note} (no temporary table:
  -- a catalog write per call on the application's write path)
  v_want   jsonb := '[]'::jsonb;
  v_kept   integer := 0;
  v_ended  integer := 0;
  v_added  integer := 0;
  v_drop   integer := 0;
begin
  perform cma.assert_permission('roster.manage');
  if p_blocks is null or jsonb_typeof(p_blocks) <> 'array' then
    raise exception 'blocks must be a JSON array' using errcode = 'CMA04';
  end if;
  if jsonb_array_length(p_blocks) > 96 then
    raise exception 'at most 96 blocks per person and date' using errcode = 'CMA04';
  end if;
  -- Its own guards, whoever calls it (defence in depth: its callers check the same first): the past stays locked, and no
  -- current block of the person-date may belong to another roster week, an empty list included
  if p_date < cma.business_date(now(), cma.user_timezone(p_user_id)) then
    raise exception 'date % is in the past for this person; the roster plans today and ahead', p_date using errcode = 'CMA04';
  end if;
  if exists (select 1 from cma.roster_assignment a
             where a.tenant_id = cma.current_tenant_id() and a.user_id = p_user_id and a.business_date = p_date
               and a.valid_to is null and a.roster_week_id <> p_week_id) then
    raise exception 'this person''s assignments on % belong to another roster', p_date using errcode = 'CMA03';
  end if;
  select * into v_shift from cma.roster_entry
   where tenant_id = cma.current_tenant_id() and user_id = p_user_id and business_date = p_date and valid_to is null;
  if jsonb_array_length(p_blocks) > 0 then
    if v_shift.id is null or v_shift.kind <> 'shift' then
      raise exception 'an assignment lies inside a shift: this person has no shift on %', p_date using errcode = 'CMA04';
    end if;
    if v_shift.roster_week_id <> p_week_id then
      raise exception 'this person''s shift on % belongs to another roster', p_date using errcode = 'CMA03';
    end if;
  end if;

  for b in select value from jsonb_array_elements(p_blocks) loop
    v_bad := null;
    if jsonb_typeof(b) <> 'object' then
      raise exception 'each block is a JSON object' using errcode = 'CMA04';
    end if;
    select * into v_type from cma.assignment_type
     where tenant_id = cma.current_tenant_id() and code = upper(btrim(coalesce(b->>'code', '')));
    if v_type.id is null then
      if p_strict then
        raise exception 'assignment type % does not exist', coalesce(b->>'code', 'none') using errcode = 'CMA02';
      end if;
      v_drop := v_drop + 1;
      continue;
    end if;
    if coalesce(b->>'start', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or coalesce(b->>'end', '') !~ '^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$' then
      raise exception 'a block''s start and end are hh:mm, the end at the latest 24:00' using errcode = 'CMA04';
    end if;
    v_start := (b->>'start')::time;
    v_end := (b->>'end')::time;
    v_market := nullif(btrim(coalesce(b->>'hoursMarket', '')), '');
    v_note := nullif(btrim(coalesce(b->>'note', '')), '');
    -- A pause has no hours market (Martin, 26 November 2026): the planner's CODE-MARKET on a pause type is refused; Copy
    -- week and Apply standard week write the pause without the market an older block or standard row may still carry
    if v_type.kind = 'pause' and v_market is not null then
      if p_strict then
        raise exception 'assignment type % is a pause, and a pause has no hours market: plan % without one, not %-%',
          v_type.code, v_type.code, v_type.code, v_market using errcode = 'CMA04';
      end if;
      v_market := null;
    end if;
    if v_end <= v_start then
      v_bad := format('the block %s ends after it starts', v_type.code);
    elsif cma.roster_block_minutes(v_start) % v_slot <> 0 or cma.roster_block_minutes(v_end) % v_slot <> 0 then
      v_bad := format('the block %s starts and ends on the %s minute grid', v_type.code, v_slot);
    elsif v_start < v_shift.start_time or v_end > v_shift.end_time then
      v_bad := format('the block %s %s to %s lies outside the shift %s to %s', v_type.code, b->>'start', b->>'end',
                      to_char(v_shift.start_time, 'HH24:MI'), case when v_shift.end_time = '24:00'::time then '24:00' else to_char(v_shift.end_time, 'HH24:MI') end);
    elsif v_note is not null and length(v_note) > 120 then
      v_bad := 'a block''s note has at most 120 characters';
    end if;
    -- A retired type or market stays on a block that is kept unchanged; a new block needs an active one. A pause that
    -- differs only by the market an older row still holds (written before 0009zz) counts as unchanged: the planner writes
    -- back the pause it read, without the market, and a retired pause type must not lock the person-date
    if v_bad is null and not exists (
         select 1 from cma.roster_assignment a
         where a.tenant_id = cma.current_tenant_id() and a.user_id = p_user_id and a.business_date = p_date and a.valid_to is null
           and a.assignment_type_id = v_type.id and a.start_time = v_start and a.end_time = v_end
           and (v_type.kind = 'pause' or a.hours_market_code is not distinct from v_market) and a.note is not distinct from v_note) then
      if v_type.status <> 'active' then
        v_bad := format('assignment type %s is no longer in use', v_type.code);
      elsif v_market is not null then
        if p_strict then
          perform cma.assert_hours_market(v_market);
        elsif not cma.is_hours_market(v_market) then
          v_bad := format('market %s is no active hours market', v_market);
        end if;
      end if;
    end if;
    if v_bad is not null then
      if p_strict then
        raise exception '%', v_bad using errcode = 'CMA04';
      end if;
      v_drop := v_drop + 1;
      continue;
    end if;
    if exists (select 1 from jsonb_to_recordset(v_want) as x(start_time time, end_time time)
               where x.start_time < v_end and v_start < x.end_time) then
      if p_strict then
        raise exception 'the blocks overlap at % to %', b->>'start', b->>'end' using errcode = 'CMA04';
      end if;
      v_drop := v_drop + 1;
      continue;
    end if;
    v_want := v_want || jsonb_build_array(jsonb_build_object('type_id', v_type.id, 'start_time', v_start, 'end_time', v_end,
                                                             'market', v_market, 'note', v_note));
  end loop;

  -- End the current blocks that are not wanted any more (before the new ones: the exclusion constraint is per statement)
  with ended as (
    update cma.roster_assignment a set valid_to = clock_timestamp()
     where a.tenant_id = cma.current_tenant_id() and a.user_id = p_user_id and a.business_date = p_date and a.valid_to is null
       and not exists (select 1 from jsonb_to_recordset(v_want) as x(type_id uuid, start_time time, end_time time, market text, note text)
                       where x.type_id = a.assignment_type_id and x.start_time = a.start_time and x.end_time = a.end_time
                         and x.market is not distinct from a.hours_market_code and x.note is not distinct from a.note)
    returning 1)
  select count(*) into v_ended from ended;

  -- Insert the new ones; the kept ones stay as they are
  with added as (
    insert into cma.roster_assignment (tenant_id, roster_week_id, user_id, business_date, assignment_type_id, start_time, end_time,
                                       hours_market_code, note)
    select cma.current_tenant_id(), p_week_id, p_user_id, p_date, x.type_id, x.start_time, x.end_time, x.market, x.note
    from jsonb_to_recordset(v_want) as x(type_id uuid, start_time time, end_time time, market text, note text)
    where not exists (select 1 from cma.roster_assignment a
                      where a.tenant_id = cma.current_tenant_id() and a.user_id = p_user_id and a.business_date = p_date
                        and a.valid_to is null and x.type_id = a.assignment_type_id and x.start_time = a.start_time
                        and x.end_time = a.end_time and x.market is not distinct from a.hours_market_code
                        and x.note is not distinct from a.note)
    order by x.start_time
    returning 1)
  select count(*) into v_added from added;
  v_kept := jsonb_array_length(v_want) - v_added;

  -- Link each block this call ended to its successor: the new block with the same start, else the first new one it overlaps
  if v_added > 0 then
    update cma.roster_assignment o
       set superseded_by = coalesce(
             (select n.id from cma.roster_assignment n
              where n.tenant_id = o.tenant_id and n.user_id = o.user_id and n.business_date = o.business_date and n.valid_to is null
                and n.recorded_at >= now() and n.start_time = o.start_time limit 1),
             (select n.id from cma.roster_assignment n
              where n.tenant_id = o.tenant_id and n.user_id = o.user_id and n.business_date = o.business_date and n.valid_to is null
                and n.recorded_at >= now() and n.start_time < o.end_time and o.start_time < n.end_time
              order by n.start_time limit 1))
     where o.tenant_id = cma.current_tenant_id() and o.user_id = p_user_id and o.business_date = p_date
       and o.valid_to >= now() and o.superseded_by is null;
  end if;

  return jsonb_build_object('kept', v_kept, 'ended', v_ended, 'added', v_added, 'dropped', v_drop);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The reads: a pause block shows no hours market
-- ---------------------------------------------------------------------------------------------
-- A person-date's current blocks as JSON (the planner's answer); a pause shows no market
-- based on: 248_roster_assignments.sql
create or replace function cma.roster_blocks_json(p_user_id uuid, p_date date)
returns jsonb
language sql stable
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'assignmentId', a.id, 'code', t.code, 'start', to_char(a.start_time, 'HH24:MI'),
           'end', case when a.end_time = '24:00'::time then '24:00' else to_char(a.end_time, 'HH24:MI') end,
           'hoursMarket', case when t.kind = 'pause' then null else a.hours_market_code end, 'note', a.note, 'recordedAt', a.recorded_at)
           order by a.start_time), '[]'::jsonb)
  from cma.roster_assignment a
  join cma.assignment_type t on t.tenant_id = a.tenant_id and t.id = a.assignment_type_id
  where a.tenant_id = cma.current_tenant_id() and a.user_id = p_user_id and a.business_date = p_date and a.valid_to is null
$$;

-- The current blocks of the week (what the planner paints); a pause shows no market
-- based on: 248_roster_assignments.sql
create or replace function cma.roster_assignments(p_week_start date, p_team_key text default null)
returns table (
  assignment_id      uuid,
  user_id            uuid,
  business_date      date,
  code               text,
  name               text,
  kind               text,
  work_area          text,
  is_extra           boolean,
  start_time         time,
  end_time           time,
  hours_market_code  text,
  note               text,
  recorded_at        timestamptz
)
language plpgsql stable rows 500
as $$
#variable_conflict use_column
declare
  v_team uuid;
begin
  perform cma.assert_permission('roster.manage');
  perform cma.assert_week_start(p_week_start);
  v_team := cma.roster_team_id(p_team_key);
  return query
    with blocks as materialized (
      select a.* from cma.roster_assignment a
      join cma.roster_week w on w.tenant_id = a.tenant_id and w.id = a.roster_week_id
      where a.tenant_id = cma.current_tenant_id()
        and w.week_start = p_week_start and w.team_id is not distinct from v_team
        and a.valid_to is null
    ),
    -- on the roster, asked once per person, not once per block (the N06 lesson on per-row calls)
    people as materialized (
      select x.user_id from (select distinct b.user_id from blocks b) x where cma.on_roster(x.user_id)
    )
    select a.id, a.user_id, a.business_date, t.code::text, t.name::text, t.kind::text, s.work_area::text, t.is_extra,
           a.start_time, a.end_time, (case when t.kind = 'pause' then null else a.hours_market_code end)::text, a.note::text, a.recorded_at
    from blocks a
    join people p on p.user_id = a.user_id
    join cma.assignment_type t on t.tenant_id = a.tenant_id and t.id = a.assignment_type_id
    left join cma.work_status s on s.tenant_id = t.tenant_id and s.id = t.work_status_id
    order by a.business_date, a.user_id, a.start_time;
end
$$;

-- D12 per slot of the planner zone's day: the people working and the people per type and hours market; a block without
-- a market counts under the person's Default market, a pause under none
-- based on: 248_roster_assignments.sql
create or replace function cma.roster_slot_coverage(p_date date, p_team_key text default null)
returns table (
  slot_start         timestamptz,
  slot_time          time,
  working            integer,
  code               text,
  hours_market_code  text,
  people             integer
)
language plpgsql stable rows 300
as $$
#variable_conflict use_column
declare
  v_team uuid;
  v_zone text;
  v_slot integer;
begin
  perform cma.assert_permission('roster.manage');
  if p_date is null then
    raise exception 'a date is required' using errcode = 'CMA04';
  end if;
  v_team := cma.roster_team_id(p_team_key);
  v_zone := cma.roster_planner_zone();
  v_slot := cma.setting_of(cma.current_tenant_id(), 'roster.slot_minutes')::integer;
  return query
    with raw as materialized (
      -- the weeks that hold the business dates around the day, through roster_week_week_idx (no read of older weeks)
      select a.user_id, a.business_date, a.start_time, a.end_time, a.hours_market_code, a.assignment_type_id
      from cma.roster_week w
      join cma.roster_assignment a on a.tenant_id = w.tenant_id and a.roster_week_id = w.id
      where w.tenant_id = cma.current_tenant_id()
        and w.week_start between cma.week_start(p_date - 1) and cma.week_start(p_date + 1)
        and w.team_id is not distinct from v_team
        and a.valid_to is null and a.business_date between p_date - 1 and p_date + 1
    ),
    -- once per person: on the roster, the zone and the Default market (not once per block)
    people as materialized (
      select u.id as user_id, cma.user_timezone(u.id) as zone, u.default_hours_market_code
      from (select distinct r.user_id from raw r) x
      join cma.app_user u on u.tenant_id = cma.current_tenant_id() and u.id = x.user_id
      where cma.on_roster(x.user_id)
    ),
    blocks as materialized (
      select r.user_id, t.code, t.kind, t.sort_order,
             case when t.kind = 'pause' then null else coalesce(r.hours_market_code, p.default_hours_market_code) end as market,
             (r.business_date + r.start_time) at time zone p.zone as starts,
             (r.business_date + r.end_time) at time zone p.zone as ends
      from raw r
      join people p on p.user_id = r.user_id
      join cma.assignment_type t on t.tenant_id = cma.current_tenant_id() and t.id = r.assignment_type_id
    ),
    slots as (
      select s as slot_start
      from generate_series(p_date::timestamp at time zone v_zone,
                           (p_date + 1)::timestamp at time zone v_zone - make_interval(mins => v_slot),
                           make_interval(mins => v_slot)) s
    ),
    hits as materialized (
      select sl.slot_start, b.user_id, b.code, b.kind, b.sort_order, b.market
      from slots sl join blocks b on b.starts <= sl.slot_start and sl.slot_start < b.ends
    ),
    -- the people working per slot, counted once per slot
    working as (
      select h.slot_start, count(distinct h.user_id)::integer as n from hits h where h.kind = 'work' group by h.slot_start
    )
    select h.slot_start, (h.slot_start at time zone v_zone)::time, coalesce(wk.n, 0),
           h.code::text, h.market::text, count(distinct h.user_id)::integer
    from hits h
    left join working wk on wk.slot_start = h.slot_start
    group by h.slot_start, wk.n, h.code, h.sort_order, h.market
    order by h.slot_start, h.sort_order, h.code collate "C", h.market collate "C" nulls last;
end
$$;

-- D12: the planned minutes per person, date, type and hours market of the week's current blocks; a block without a market
-- under the person's Default market, a pause under none
-- based on: 248_roster_assignments.sql
create or replace function cma.roster_planned_hours(p_week_start date, p_team_key text default null)
returns table (
  user_id            uuid,
  business_date      date,
  code               text,
  kind               text,
  hours_market_code  text,
  planned_minutes    integer
)
language plpgsql stable rows 500
as $$
#variable_conflict use_column
declare
  v_team uuid;
begin
  perform cma.assert_permission('roster.manage');
  perform cma.assert_week_start(p_week_start);
  v_team := cma.roster_team_id(p_team_key);
  return query
    with raw as materialized (
      select a.user_id, a.business_date, a.start_time, a.end_time, a.hours_market_code, a.assignment_type_id
      from cma.roster_assignment a
      join cma.roster_week w on w.tenant_id = a.tenant_id and w.id = a.roster_week_id
      where a.tenant_id = cma.current_tenant_id()
        and w.week_start = p_week_start and w.team_id is not distinct from v_team
        and a.valid_to is null
    ),
    -- once per person: on the roster, the zone and the Default market (not once per block)
    people as materialized (
      select u.id as user_id, cma.user_timezone(u.id) as zone, u.default_hours_market_code
      from (select distinct r.user_id from raw r) x
      join cma.app_user u on u.tenant_id = cma.current_tenant_id() and u.id = x.user_id
      where cma.on_roster(x.user_id)
    )
    select r.user_id, r.business_date, t.code::text, t.kind::text,
           (case when t.kind = 'pause' then null else coalesce(r.hours_market_code, p.default_hours_market_code) end)::text,
           sum((extract(epoch from ((r.business_date + r.end_time) at time zone p.zone)
                                 - ((r.business_date + r.start_time) at time zone p.zone)) / 60))::integer
    from raw r
    join people p on p.user_id = r.user_id
    join cma.assignment_type t on t.tenant_id = cma.current_tenant_id() and t.id = r.assignment_type_id
    group by r.user_id, r.business_date, t.code, t.kind, t.sort_order,
             case when t.kind = 'pause' then null else coalesce(r.hours_market_code, p.default_hours_market_code) end
    order by r.user_id, r.business_date, t.sort_order, t.code collate "C",
             (case when t.kind = 'pause' then null else coalesce(r.hours_market_code, p.default_hours_market_code) end) collate "C" nulls last;
end
$$;

-- The tenant's current Standard week of the people on the roster (roster.manage); a pause shows no market
-- based on: 248_roster_assignments.sql
create or replace function cma.standard_week()
returns table (
  user_id       uuid,
  iso_weekday   smallint,
  kind          text,
  start_time    time,
  end_time      time,
  absence_key   text,
  absence_name  text,
  note          text,
  assignments   jsonb,
  recorded_at   timestamptz
)
language plpgsql stable rows 300
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('roster.manage');
  return query
    select e.user_id, e.iso_weekday, e.kind::text, e.start_time, e.end_time, a.key::text, a.name::text, e.note::text,
           coalesce((select jsonb_agg(jsonb_build_object('code', t.code, 'start', to_char(x.start_time, 'HH24:MI'),
                                                         'end', case when x.end_time = '24:00'::time then '24:00' else to_char(x.end_time, 'HH24:MI') end,
                                                         'hoursMarket', case when t.kind = 'pause' then null else x.hours_market_code end, 'note', x.note) order by x.start_time)
                     from cma.standard_week_assignment x
                     join cma.assignment_type t on t.tenant_id = x.tenant_id and t.id = x.assignment_type_id
                     where x.tenant_id = e.tenant_id and x.standard_week_entry_id = e.id and x.valid_to is null), '[]'::jsonb),
           e.recorded_at
    from cma.standard_week_entry e
    left join cma.absence_type a on a.tenant_id = e.tenant_id and a.id = e.absence_type_id
    where e.tenant_id = cma.current_tenant_id() and e.valid_to is null
      and cma.on_roster(e.user_id)
    order by e.user_id, e.iso_weekday;
end
$$;

-- A person-date's published blocks as JSON for My schedule and the Live board; a pause shows no market, is not own
-- market and has no market zone. Internal, as 248's: never from a route with a request's person
-- based on: 248_roster_assignments.sql
create or replace function cma.roster_published_blocks_json(p_week_id uuid, p_user_id uuid, p_date date)
returns jsonb
language sql stable
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', t.code, 'name', t.name, 'kind', t.kind, 'workArea', s.work_area, 'isExtra', t.is_extra,
           'start', to_char(a.start_time, 'HH24:MI'),
           'end', case when a.end_time = '24:00'::time then '24:00' else to_char(a.end_time, 'HH24:MI') end,
           'hoursMarket', case when t.kind = 'pause' then null else coalesce(a.hours_market_code, u.default_hours_market_code) end,
           'ownMarket', t.kind <> 'pause' and a.hours_market_code is null,
           'hoursMarketZone', case when t.kind = 'pause' then null else m.time_zone end)
           order by a.start_time), '[]'::jsonb)
  from cma.roster_published_assignment a
  join cma.assignment_type t on t.tenant_id = a.tenant_id and t.id = a.assignment_type_id
  left join cma.work_status s on s.tenant_id = t.tenant_id and s.id = t.work_status_id
  join cma.app_user u on u.tenant_id = a.tenant_id and u.id = a.user_id
  left join cma.market m on m.tenant_id = a.tenant_id and m.code = coalesce(a.hours_market_code, u.default_hours_market_code)
  where a.roster_week_id = p_week_id and a.user_id = p_user_id and a.business_date = p_date
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Save as standard week: a pause block is saved without a market
-- ---------------------------------------------------------------------------------------------
-- Save as standard week (D9), 248's; a pause block is saved without a market
-- based on: 248_roster_assignments.sql
create or replace function cma.save_standard_week(p_week_start date, p_team_key text default null)
returns table (user_id uuid, business_date date, outcome text, reason text, blocks integer, blocks_dropped integer)
language plpgsql rows 300
as $$
#variable_conflict use_column
declare
  v_team uuid;
  p      record;
  r      record;
  v_new  uuid;
  v_n    integer;
begin
  perform cma.assert_permission('roster.manage');
  perform cma.assert_week_start(p_week_start);
  v_team := cma.roster_team_id(p_team_key);
  -- one save of the tenant's Standard week at a time (two at once would meet on the current rows' unique index)
  perform pg_advisory_xact_lock(hashtext('cma.standard_week:' || cma.current_tenant_id()::text));
  for p in
    select u.id from cma.app_user u
    where u.tenant_id = cma.current_tenant_id() and cma.roster_in_scope(u.id, v_team, p_week_start)
    order by u.id
  loop
    -- End this person's current standard rows (blocks first, then the days)
    update cma.standard_week_assignment set valid_to = clock_timestamp()
     where tenant_id = cma.current_tenant_id() and standard_week_assignment.user_id = p.id and valid_to is null;
    update cma.standard_week_entry set valid_to = clock_timestamp()
     where tenant_id = cma.current_tenant_id() and standard_week_entry.user_id = p.id and valid_to is null;

    for r in
      select e.id, e.business_date, e.kind, e.start_time, e.end_time, e.absence_type_id, a.carries_over, e.note
      from cma.roster_entry e
      join cma.roster_week w on w.tenant_id = e.tenant_id and w.id = e.roster_week_id
      left join cma.absence_type a on a.tenant_id = e.tenant_id and a.id = e.absence_type_id
      where e.tenant_id = cma.current_tenant_id() and e.user_id = p.id and e.valid_to is null
        and w.week_start = p_week_start and w.team_id is not distinct from v_team
      order by e.business_date
    loop
      user_id := p.id; business_date := r.business_date; blocks := 0; blocks_dropped := 0;
      if r.kind = 'absence' and not r.carries_over then
        outcome := 'skipped'; reason := 'absence_not_carried'; return next; continue;
      end if;
      insert into cma.standard_week_entry (tenant_id, user_id, iso_weekday, kind, start_time, end_time, absence_type_id, note)
      values (cma.current_tenant_id(), p.id, extract(isodow from r.business_date)::smallint, r.kind, r.start_time, r.end_time,
              r.absence_type_id, r.note)
      returning id into v_new;
      update cma.standard_week_entry o set superseded_by = v_new
       where o.tenant_id = cma.current_tenant_id() and o.user_id = p.id and o.iso_weekday = extract(isodow from r.business_date)
         and o.valid_to >= now() and o.superseded_by is null and o.id <> v_new;
      if r.kind = 'shift' then
        insert into cma.standard_week_assignment (tenant_id, standard_week_entry_id, user_id, iso_weekday, assignment_type_id,
                                                  start_time, end_time, hours_market_code, note)
        select cma.current_tenant_id(), v_new, p.id, extract(isodow from r.business_date)::smallint, x.assignment_type_id,
               x.start_time, x.end_time, case when t.kind = 'pause' then null else x.hours_market_code end, x.note
        from cma.roster_assignment x
        join cma.assignment_type t on t.tenant_id = x.tenant_id and t.id = x.assignment_type_id
        where x.tenant_id = cma.current_tenant_id() and x.user_id = p.id and x.business_date = r.business_date and x.valid_to is null;
        get diagnostics v_n = row_count;
        blocks := v_n;
      end if;
      outcome := 'done'; reason := null;
      return next;
    end loop;
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Privileges: as 248's (a create or replace keeps them; restated so a rerun on a drifted database sets them again)
-- ---------------------------------------------------------------------------------------------
revoke execute on function cma.roster_assignment_rules() from public;
revoke execute on function
  cma.roster_put_assignments(uuid, uuid, date, jsonb, boolean), cma.roster_blocks_json(uuid, date),
  cma.roster_assignments(date, text), cma.roster_slot_coverage(date, text), cma.roster_planned_hours(date, text),
  cma.standard_week(), cma.roster_published_blocks_json(uuid, uuid, date), cma.save_standard_week(date, text)
from public;
grant execute on function
  cma.roster_put_assignments(uuid, uuid, date, jsonb, boolean), cma.roster_blocks_json(uuid, date),
  cma.roster_assignments(date, text), cma.roster_slot_coverage(date, text), cma.roster_planned_hours(date, text),
  cma.standard_week(), cma.roster_published_blocks_json(uuid, uuid, date), cma.save_standard_week(date, text)
to cma_app;

comment on column cma.roster_assignment.hours_market_code is 'The Hours market the block is planned under; null is own market, the person''s Default market at booking. A block of kind pause has none (0009zz)';

-- ---------------------------------------------------------------------------------------------
-- 6. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009zz', 'A pause block has no hours market (Martin, 26 November 2026): the table and the planner refuse one on a pause type (CMA04), Copy week and Apply standard week write a pause without one, and every read of the blocks, the slot coverage and the planned hours shows a pause under no market')
on conflict (version) do nothing;

commit;
reset role;
