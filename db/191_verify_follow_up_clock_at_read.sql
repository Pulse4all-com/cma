-- =============================================================================================
-- 191_verify_follow_up_clock_at_read.sql: verifies addition 0009u, the follow-up's clock fields derived at read, not
-- stored (16 November 2026)
-- =============================================================================================
-- Universal: no seed is assumed. Block S checks the addition, the grants and that the follow-up's tables stay unaudited;
-- block E works on every tenant's own data (the volume fixture locally, the seeds, dev's and prod's data), block A on a
-- throwaway tenant; every E and A check runs inside a subtransaction that is always rolled back, so nothing stays and
-- the script runs in dev and in prod. Every check writes one row, ok, skip or FAIL, and the last row is the verdict,
-- because Cloud SQL Studio shows no notices. Run as your own IAM login after 190_follow_up_clock_at_read.sql, dev
-- first, then prod.
-- Expected verdict, in dev and in prod: "0009u verified | 191_verify_follow_up_clock_at_read: <n> ok, 0 FAIL, <k> skip"
-- (E3 skips a tenant without an active person who may read the report lists; a tenant without open items reads ok on
-- empty sets). Provoked (verify.provoke true at the top): the derived side is computed a minute later than the live one
-- (E2, E3, A1), the clock check reads the stored row as 0009o stored it (E4, A2: the three fields move every minute in
-- office hours), the real change is undone before the refresh (A3), and every other row reads FAIL; the verdict PROVOKED,
-- NOT A PASS.
--
-- A minute later in one transaction: Studio runs a script in one transaction, so now() cannot move. The clock is therefore
-- a parameter: the three functions that read now() (cma.open_tickets_of, cma.speed_to_lead_of, cma.open_leads_of, as
-- 178 defined them; 190 leaves them) are copied here from the database's own definition (pg_get_functiondef) into
-- pg_temp with now() replaced by an instant p_at, and E0 proves each copy at now() equals the function row for row and
-- in order. The items a refresh would store at an instant are then computed with the refresh's own expressions (190's
-- shape, and 0009o's for the contrast) at two instants a minute apart; a refresh writes an item when its fingerprint
-- differs (179's E8 proves that part).
--
--   S  S1 the addition row after 0009t; S2 the new and re-created functions executable by the application and not by
--      public; S3 cma.follow_up_item, follow_up_snapshot and follow_up_marker carry no audit trigger (the item writes never
--      reach cma.audit_log)
--   E  per tenant, acting as its Scheduler user under row-level security: E0 the copies with the instant as a parameter
--      equal the functions at now(); E1 after a refresh no stored lead row holds waiting_business_seconds and no stored
--      ticket row open_business_seconds or minutes_to_breach, and each list keeps its count; E2 the follow-up lists
--      (cma.follow_up_list_of, every row, and the attention filter) equal the live rows at the same instant, in order;
--      E3 cma.open_leads() and cma.open_tickets() equal cma.open_leads_of and cma.open_tickets_of at the same instant, in
--      order (acting as an active person who holds reports.view; skip without one); E4 a minute of office hours (the next
--      weekday 11:06 to 11:07 UTC, as the evidence of 16 November): in the stored row nothing moves but the day counts and
--      the state words; the rows a refresh would write then, in 0009o's shape and in 0009u's, in the detail
--   A  a throwaway tenant, a market open around the clock, leads and tickets in each state: A1 after a refresh the page
--      (cma.follow_up_page), an agent's own follow-up (cma.my_follow_up), cma.open_leads() and cma.open_tickets() return
--      the live rows at the same instant; A2 a minute later nothing but the clock has moved: the items a refresh would
--      store are the same, so it writes 0 rows (0009o's shape: every lead and ticket with a market); a second refresh at the same
--      instant writes 0; A3 a real change is written: a ticket's owner (2 rows: deleted and inserted) and the last ticket
--      closed (1 row: deleted), and the stored owner and items follow; A4 the refreshes added no audit row for the
--      follow-up's tables
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);                 -- 'true' to make every check fail

drop table if exists pg_temp.verify_0009u;
create temporary table verify_0009u (ord integer, check_name text, result text, detail text);
grant select, insert on pg_temp.verify_0009u to cma_app;

-- ---------------------------------------------------------------------------------------------
-- The clock as a parameter: the three functions that read now(), copied from the database's own definitions
-- ---------------------------------------------------------------------------------------------
do $$
declare
  d text;
  v_path text := current_setting('search_path');
begin
  -- every name qualified in the printed definitions
  perform set_config('search_path', 'pg_catalog', true);
  d := pg_get_functiondef('cma.open_tickets_of(uuid)'::regprocedure);
  if position('FUNCTION cma.open_tickets_of(p_tenant_id uuid)' in d) = 0 then raise exception 'open_tickets_of: unexpected header'; end if;
  d := replace(replace(d, 'FUNCTION cma.open_tickets_of(p_tenant_id uuid)', 'FUNCTION pg_temp.v0009u_open_tickets_at(p_tenant_id uuid, p_at timestamp with time zone)'),
               'now()', 'p_at');
  execute d;
  d := pg_get_functiondef('cma.speed_to_lead_of(uuid,timestamptz,timestamptz)'::regprocedure);
  if position('FUNCTION cma.speed_to_lead_of(p_tenant_id uuid, p_from timestamp with time zone, p_to timestamp with time zone)' in d) = 0 then
    raise exception 'speed_to_lead_of: unexpected header';
  end if;
  d := replace(replace(d, 'FUNCTION cma.speed_to_lead_of(p_tenant_id uuid, p_from timestamp with time zone, p_to timestamp with time zone)',
                          'FUNCTION pg_temp.v0009u_speed_to_lead_at(p_tenant_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_at timestamp with time zone)'),
               'now()', 'p_at');
  execute d;
  d := pg_get_functiondef('cma.open_leads_of(uuid)'::regprocedure);
  if position('FUNCTION cma.open_leads_of(p_tenant_id uuid)' in d) = 0 or position('cma.speed_to_lead_of(p_tenant_id, NULL::timestamp with time zone, NULL::timestamp with time zone)' in d) = 0
     and position('cma.speed_to_lead_of(p_tenant_id, null, null)' in d) = 0 then
    raise exception 'open_leads_of: unexpected header or call';
  end if;
  d := replace(replace(replace(replace(d, 'FUNCTION cma.open_leads_of(p_tenant_id uuid)', 'FUNCTION pg_temp.v0009u_open_leads_at(p_tenant_id uuid, p_at timestamp with time zone)'),
                               'cma.speed_to_lead_of(p_tenant_id, NULL::timestamp with time zone, NULL::timestamp with time zone)',
                               'pg_temp.v0009u_speed_to_lead_at(p_tenant_id, NULL::timestamp with time zone, NULL::timestamp with time zone, p_at)'),
                       'cma.speed_to_lead_of(p_tenant_id, null, null)', 'pg_temp.v0009u_speed_to_lead_at(p_tenant_id, null, null, p_at)'),
               'now()', 'p_at');
  execute d;
  perform set_config('search_path', v_path, true);
end
$$;

-- The lead and ticket items a refresh would store at an instant, with the refresh's own expressions: p_shape '0009u' as 190
-- stores the row (without the three clock fields), '0009o' as 178 did; with each item's fingerprint
create or replace function pg_temp.v0009u_items_at(p_tenant_id uuid, p_at timestamptz, p_shape text)
returns table (kind text, item_id uuid, sort_key integer, state text, item_row jsonb, print text)
language sql stable
as $$
  with x as (
    select 'lead'::text as kind, o.ordinality::integer as sort_key, o.deal_id as item_id, coalesce(nullif(o.market, ''), 'unknown') as market, o.owner_user_id,
           case when o.past_target then 'past_target' when o.past_target is false then 'within_target' else 'no_hours' end as state,
           case when p_shape = '0009u' then to_jsonb(o) - 'tenant_id' - 'ordinality' - 'waiting_business_seconds'
                else to_jsonb(o) - 'tenant_id' - 'ordinality' end as row
    from pg_temp.v0009u_open_leads_at(p_tenant_id, p_at) with ordinality o
    union all
    select 'ticket', o.ordinality::integer, o.ticket_id, coalesce(nullif(o.market, ''), 'unknown'), o.owner_user_id, o.sla_state,
           case when p_shape = '0009u' then to_jsonb(o) - 'tenant_id' - 'ordinality' - 'open_business_seconds' - 'minutes_to_breach'
                else to_jsonb(o) - 'tenant_id' - 'ordinality' end
    from pg_temp.v0009u_open_tickets_at(p_tenant_id, p_at) with ordinality o
  )
  select x.kind, x.item_id, x.sort_key, x.state, x.row, cma.follow_up_item_print(x.sort_key, x.market, x.owner_user_id, x.state, x.row) from x
$$;

-- An ordered comparison of two texts of rows: null when equal, else where they first differ
create or replace function pg_temp.v0009u_diff(p_a jsonb, p_b jsonb)
returns text
language sql immutable
as $$
  select case when p_a is not distinct from p_b then null
              else format('%s against %s rows; first difference at %s', jsonb_array_length(coalesce(p_a, '[]')), jsonb_array_length(coalesce(p_b, '[]')),
                          (select min(i) from generate_series(0, greatest(jsonb_array_length(coalesce(p_a, '[]')), jsonb_array_length(coalesce(p_b, '[]'))) - 1) i
                           where (p_a -> i) is distinct from (p_b -> i))) end
$$;
grant execute on function pg_temp.v0009u_items_at(uuid, timestamptz, text), pg_temp.v0009u_diff(jsonb, jsonb) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- S. The addition, the grants, no audit trigger
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_ok boolean; v_txt text;
  f text;
begin
  v_ok := exists (select 1 from cma.schema_migration where version = '0009u')
          and (select applied_at from cma.schema_migration where version = '0009u') >= (select applied_at from cma.schema_migration where version = '0009t');
  insert into verify_0009u values (1, 'S1 addition 0009u recorded after 0009t', case when v_ok and not v_provoke then 'ok' else 'FAIL' end,
    case when v_ok then 'cma.schema_migration holds 0009u' else 'no 0009u row, or before 0009t' end);

  v_ok := true; v_txt := null;
  foreach f in array array[
    'cma.follow_up_clock_row(text,jsonb,integer,integer,integer)',
    'cma.refresh_follow_up_of(uuid,boolean)', 'cma.follow_up_list_of(uuid,text,text,uuid,boolean,boolean,integer)',
    'cma.open_leads()', 'cma.open_tickets()'] loop
    if to_regprocedure(f) is null or not has_function_privilege('cma_app', f, 'execute') or has_function_privilege('public', f, 'execute')
       or (select p.prosecdef from pg_proc p where p.oid = to_regprocedure(f)) then
      v_ok := false; v_txt := coalesce(v_txt || ', ', '') || f;
    end if;
  end loop;
  insert into verify_0009u values (2, 'S2 the five functions: the application may execute them, public may not, in the caller''s rights',
    case when v_ok and not v_provoke then 'ok' else 'FAIL' end, coalesce('wrong: ' || v_txt, 'as designed'));

  v_ok := not exists (select 1 from pg_trigger t
                      where t.tgrelid in ('cma.follow_up_item'::regclass, 'cma.follow_up_snapshot'::regclass, 'cma.follow_up_marker'::regclass)
                        and not t.tgisinternal and t.tgname = 'audit');
  insert into verify_0009u values (3, 'S3 the follow-up''s derived tables carry no audit trigger (their writes never reach cma.audit_log)',
    case when v_ok and not v_provoke then 'ok' else 'FAIL' end,
    case when v_ok then 'follow_up_item, follow_up_snapshot, follow_up_marker' else 'an audit trigger exists' end);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- E. Every tenant's own data, rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  t record; v_ord integer := 100; v_diff text; v_err text; v_note text; v_ok boolean;
  v_at timestamptz; v_day date; v_reader uuid; v_sched text;
  v_a jsonb; v_b jsonb; v_n integer; v_m integer; r jsonb;
  v_old_written integer; v_new_written integer; v_moved integer; v_flips integer; v_shifts integer; v_days integer; v_items integer;
  v_derive_at timestamptz := now() + case when current_setting('verify.provoke')::boolean then interval '1 minute' else interval '0' end;
  e_rows text[];
begin
  -- the next weekday at 11:06 UTC (the instant of the evidence of 16 November 2026), and a minute after it
  v_day := (now() at time zone 'UTC')::date + 1;
  while extract(isodow from v_day) in (6, 7) loop v_day := v_day + 1; end loop;
  v_at := (v_day + time '11:06') at time zone 'UTC';

  for t in select te.id, te.slug from cma.tenant te order by te.slug loop
    perform set_config('app.tenant_id', t.id::text, true);
    -- the tenant's Scheduler user, matched on its external id (never an email)
    v_sched := coalesce((select u.id::text from cma.app_user_external_id x
                         join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
                         where x.tenant_id = t.id and x.system = 'scheduler' and x.external_id = 'scheduler'
                           and u.status = 'active' limit 1), '');
    perform set_config('app.user_id', v_sched, true);

    -- E0 the copies at now() equal the functions, row for row and in order
    v_ord := v_ord + 1; v_err := null; v_diff := null;
    begin
      perform set_config('role', 'cma_app', true);
      select coalesce(jsonb_agg(to_jsonb(o) - 'ordinality' order by o.ordinality), '[]') into v_a from pg_temp.v0009u_open_tickets_at(t.id, now()) with ordinality o;
      select coalesce(jsonb_agg(to_jsonb(o) - 'ordinality' order by o.ordinality), '[]') into v_b from cma.open_tickets_of(t.id) with ordinality o;
      v_diff := 'tickets: ' || pg_temp.v0009u_diff(v_a, v_b);
      v_n := jsonb_array_length(v_b);
      select coalesce(jsonb_agg(to_jsonb(o) - 'ordinality' order by o.ordinality), '[]') into v_a from pg_temp.v0009u_open_leads_at(t.id, now()) with ordinality o;
      select coalesce(jsonb_agg(to_jsonb(o) - 'ordinality' order by o.ordinality), '[]') into v_b from cma.open_leads_of(t.id) with ordinality o;
      v_diff := coalesce(v_diff || '; ', '') || ('leads: ' || pg_temp.v0009u_diff(v_a, v_b));
      v_m := jsonb_array_length(v_b);
      select count(*) into v_items from (
        select * from pg_temp.v0009u_speed_to_lead_at(t.id, null, null, now()) except all select * from cma.speed_to_lead_of(t.id, null, null)
        union all
        (select * from cma.speed_to_lead_of(t.id, null, null) except all select * from pg_temp.v0009u_speed_to_lead_at(t.id, null, null, now()))) d;
      if v_items > 0 then v_diff := coalesce(v_diff || '; ', '') || format('speed to lead: %s rows differ', v_items); end if;
      raise exception using errcode = 'CMAOK';
    exception
      when sqlstate 'CMAOK' then null;
      when others then v_err := 'error ' || sqlstate || ': ' || sqlerrm;
    end;
    perform set_config('role', 'cma_owner', true);
    insert into verify_0009u values (v_ord, 'E0 the copies with the instant as a parameter equal the functions at now() (' || t.slug || ')',
      case when v_err is null and v_diff is null and not v_provoke then 'ok' else 'FAIL' end,
      coalesce(v_err, v_diff, format('%s tickets and %s leads equal in order; speed to lead equal', v_n, v_m)));

    -- E1 to E3 after a refresh in this transaction (so at the same instant as the live functions), rolled back; their
    -- rows are kept in e_rows and written after the rollback
    v_ord := v_ord + 1; v_err := null; v_diff := null; v_note := null; e_rows := '{}';
    begin
      -- the tenant's refresh lock first, waiting for a job's run to end (released with the subtransaction)
      perform pg_advisory_xact_lock(cma.follow_up_lock_key(t.id));
      perform set_config('role', 'cma_app', true);
      r := cma.refresh_follow_up_of(t.id, false);
      -- E1
      select count(*) filter (where i.kind = 'lead' and i.row ? 'waiting_business_seconds')
             + count(*) filter (where i.kind = 'ticket' and (i.row ? 'open_business_seconds' or i.row ? 'minutes_to_breach')),
             count(*) filter (where i.kind = 'lead'), count(*) filter (where i.kind = 'ticket')
        into v_items, v_n, v_m
      from cma.follow_up_item i where i.tenant_id = t.id;
      v_ok := v_items = 0 and v_n = (select count(*) from cma.open_leads_of(t.id)) and v_m = (select count(*) from cma.open_tickets_of(t.id));
      perform set_config('role', 'cma_owner', true);
      e_rows := e_rows || array[v_ord::text, 'E1 the stored lead and ticket rows hold no clock field, every item kept (' || t.slug || ')',
        case when v_ok and not v_provoke then 'ok' else 'FAIL' end,
        format('%s leads, %s tickets stored; %s rows with a clock field (rolled back)', v_n, v_m, v_items)];
      perform set_config('role', 'cma_app', true);

      -- E2 the lists, every row and the attention filter, against the live rows at the same instant
      v_ord := v_ord + 1; v_diff := null;
      foreach v_note in array array['lead', 'ticket'] loop
        for v_ok in select unnest(array[false, true]) loop
          select coalesce(jsonb_agg(e - 'owner_name' - 'record_url' order by n), '[]') into v_a
          from jsonb_array_elements(cma.follow_up_list_of(t.id, v_note, null, null, false, v_ok, null) -> 'rows') with ordinality x(e, n);
          if v_note = 'lead' then
            select coalesce(jsonb_agg(to_jsonb(o) - 'tenant_id' - 'ordinality' order by o.ordinality), '[]') into v_b
            from pg_temp.v0009u_open_leads_at(t.id, v_derive_at) with ordinality o
            where not v_ok or o.past_target is true;
          else
            select coalesce(jsonb_agg(to_jsonb(o) - 'tenant_id' - 'ordinality' order by o.ordinality), '[]') into v_b
            from pg_temp.v0009u_open_tickets_at(t.id, v_derive_at) with ordinality o
            where not v_ok or o.sla_state in ('at_risk', 'breached');
          end if;
          if pg_temp.v0009u_diff(v_a, v_b) is not null then
            v_diff := coalesce(v_diff || '; ', '') || v_note || case when v_ok then 's, attention: ' else 's: ' end || pg_temp.v0009u_diff(v_a, v_b);
          end if;
        end loop;
      end loop;
      perform set_config('role', 'cma_owner', true);
      e_rows := e_rows || array[v_ord::text, 'E2 the follow-up lists (every row, and attention) equal the live rows at the same instant, in order (' || t.slug || ')',
        case when v_diff is null and not v_provoke then 'ok' else 'FAIL' end,
        coalesce(v_diff, format('%s leads and %s tickets, the three fields and the state words derived at now()', v_n, v_m))];

      -- E3 cma.open_leads() and cma.open_tickets(), as an active person of the tenant who may read the report lists
      v_ord := v_ord + 1; v_diff := null;
      v_reader := (select u.id from cma.app_user u
                   where u.tenant_id = t.id and u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, 'reports.view')
                   order by u.id limit 1);
      if v_reader is null then
        e_rows := e_rows || array[v_ord::text, 'E3 cma.open_leads() and cma.open_tickets() equal the live functions at the same instant (' || t.slug || ')',
          'skip', 'no active person holds reports.view'];
      else
        perform set_config('app.user_id', v_reader::text, true);
        perform set_config('role', 'cma_app', true);
        select coalesce(jsonb_agg(to_jsonb(o) - 'ordinality' order by o.ordinality), '[]') into v_a from cma.open_leads() with ordinality o;
        select coalesce(jsonb_agg(to_jsonb(o) - 'ordinality' order by o.ordinality), '[]') into v_b from pg_temp.v0009u_open_leads_at(t.id, v_derive_at) with ordinality o;
        v_diff := 'leads: ' || pg_temp.v0009u_diff(v_a, v_b);
        select coalesce(jsonb_agg(to_jsonb(o) - 'ordinality' order by o.ordinality), '[]') into v_a from cma.open_tickets() with ordinality o;
        select coalesce(jsonb_agg(to_jsonb(o) - 'ordinality' order by o.ordinality), '[]') into v_b from pg_temp.v0009u_open_tickets_at(t.id, v_derive_at) with ordinality o;
        v_diff := coalesce(v_diff || '; ', '') || ('tickets: ' || pg_temp.v0009u_diff(v_a, v_b));
        perform set_config('role', 'cma_owner', true);
        perform set_config('app.user_id', v_sched, true);
        e_rows := e_rows || array[v_ord::text, 'E3 cma.open_leads() and cma.open_tickets() equal the live functions at the same instant (' || t.slug || ')',
          case when v_diff is null and not v_provoke then 'ok' else 'FAIL' end,
          coalesce(v_diff, format('%s leads and %s tickets, every column, in order', v_n, v_m))];
      end if;
      raise exception using errcode = 'CMAOK';
    exception
      when sqlstate 'CMAOK' then perform set_config('role', 'cma_owner', true); perform set_config('app.user_id', v_sched, true);
      when others then
        perform set_config('role', 'cma_owner', true); perform set_config('app.user_id', v_sched, true);
        e_rows := e_rows || array[v_ord::text, 'E1 to E3 ended early (' || t.slug || ')', 'FAIL', 'error ' || sqlstate || ': ' || sqlerrm];
    end;
    insert into verify_0009u (ord, check_name, result, detail)
    select e_rows[4 * i - 3]::integer, e_rows[4 * i - 2], e_rows[4 * i - 1], e_rows[4 * i] from generate_series(1, cardinality(e_rows) / 4) i;

    -- E4 a minute of office hours: the items a refresh would store at v_at and a minute later
    v_ord := v_ord + 1; v_err := null;
    begin
      perform set_config('role', 'cma_app', true);
      create temporary table v0009u_a on commit drop as
        select 'u'::text as shape, * from pg_temp.v0009u_items_at(t.id, v_at, '0009u') union all select 'o', * from pg_temp.v0009u_items_at(t.id, v_at, '0009o');
      create temporary table v0009u_b on commit drop as
        select 'u'::text as shape, * from pg_temp.v0009u_items_at(t.id, v_at + interval '1 minute', '0009u') union all select 'o', * from pg_temp.v0009u_items_at(t.id, v_at + interval '1 minute', '0009o');
      -- rows a refresh writes: 2 for an item whose fingerprint changed, 1 for an item on one side only
      select 2 * count(*) filter (where a.item_id is not null and b.item_id is not null and a.print <> b.print) + count(*) filter (where a.item_id is null or b.item_id is null)
        into v_old_written
      from (select * from v0009u_a where shape = 'o') a full join (select * from v0009u_b where shape = 'o') b on b.kind = a.kind and b.item_id = a.item_id;
      select 2 * count(*) filter (where a.item_id is not null and b.item_id is not null and a.print <> b.print) + count(*) filter (where a.item_id is null or b.item_id is null),
             count(*) filter (where a.state is distinct from b.state),
             count(*) filter (where a.sort_key is distinct from b.sort_key),
             count(*) filter (where a.item_row ->> 'age_business_days' is distinct from b.item_row ->> 'age_business_days'
                                 or a.item_row ->> 'last_call_days' is distinct from b.item_row ->> 'last_call_days'),
             count(*)
        into v_new_written, v_flips, v_shifts, v_days, v_items
      from (select * from v0009u_a where shape = (case when v_provoke then 'o' else 'u' end)) a
      full join (select * from v0009u_b where shape = (case when v_provoke then 'o' else 'u' end)) b on b.kind = a.kind and b.item_id = a.item_id;
      -- v_moved: items whose stored row changed in a key other than the day counts, with no state change (a state word in
      -- the row moves with the item's state): must be none
      select count(*) into v_moved
      from (select * from v0009u_a where shape = (case when v_provoke then 'o' else 'u' end)) a
      join (select * from v0009u_b where shape = (case when v_provoke then 'o' else 'u' end)) b on b.kind = a.kind and b.item_id = a.item_id
      where a.state = b.state
        and (a.item_row - 'age_business_days' - 'bucket_from' - 'bucket_to' - 'last_call_days') <> (b.item_row - 'age_business_days' - 'bucket_from' - 'bucket_to' - 'last_call_days');
      raise exception using errcode = 'CMAOK';
    exception
      when sqlstate 'CMAOK' then null;
      when others then v_err := 'error ' || sqlstate || ': ' || sqlerrm;
    end;
    perform set_config('role', 'cma_owner', true);
    insert into verify_0009u values (v_ord, 'E4 a minute of office hours moves nothing in the stored row but the day counts and the state words (' || t.slug || ')',
      case when v_err is null and v_moved = 0 and not v_provoke then 'ok' else 'FAIL' end,
      coalesce(v_err, format('%s to %s UTC, %s items: %s with another key moved; rows a refresh writes: %s as 0009o stored them, %s now (%s state changes, %s places moved, %s day counts)',
                             to_char(v_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI'), to_char((v_at + interval '1 minute') at time zone 'UTC', 'HH24:MI'),
                             v_items, v_moved, v_old_written, v_new_written, v_flips, v_shifts, v_days)));
    v_ord := (v_ord / 100 + 1) * 100;
  end loop;
  perform set_config('role', 'cma_owner', true);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- A. A throwaway tenant, rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_now     timestamptz := now();
  v_derive_at timestamptz := now() + case when current_setting('verify.provoke')::boolean then interval '1 minute' else interval '0' end;
  v_t uuid; v_admin uuid; v_agent uuid; v_ing uuid; v_sched uuid; v_crm uuid;
  v_ok boolean; v_diff text; v_txt text; v_a jsonb; v_b jsonb; r jsonb; v_page jsonb; v_mine jsonb;
  v_n integer; v_m integer; v_audit integer;
  rows_ text[] := '{}';
begin
  begin
    v_t := cma.create_tenant('verify-0009u', 'Verify 0009u', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-admin@example.invalid', 'Verify admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-agent@example.invalid', 'Verify agent') returning id into v_agent;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_admin, 'admin'), (v_agent, 'agent')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t and ar.key = x.role_key;
    select id into v_ing from cma.app_user where tenant_id = v_t and email = 'ingest@system.invalid';
    v_sched := (select x.user_id from cma.app_user_external_id x where x.tenant_id = v_t and x.system = 'scheduler' and x.external_id = 'scheduler');
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    -- a market open around the clock (every minute counts), the lead target of an hour, the response time of 240 minutes
    -- and its warning at 75 % (defaults), an owner linked to the agent
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.set_business_hours('*', d::smallint, '00:00-24:00') from generate_series(1, 7) d;
    perform cma.set_tenant_setting('intake.start_date', ((v_now at time zone 'Europe/Amsterdam')::date - 30)::text);
    perform cma.set_tenant_setting('speed_to_lead.target_minutes', '60');
    perform cma.set_user_external_id(v_agent, 'verifycrm_owner', 'o-1');
    select c.connection_id into v_crm from cma.upsert_connection('verifycrm', 'Verify CRM', 'portal-1', null, null) c;
    perform cma.set_connection_kind(v_crm, 'crm');
    perform set_config('app.user_id', v_ing::text, true);
    perform cma.ingest_upsert_pipelines(v_crm, '[
      {"recordType": "deal", "pipelineId": "sales", "label": "Sales", "stages": [
         {"stageId": "s1", "label": "Open", "order": 1, "isClosed": false}, {"stageId": "s9", "label": "Lost", "order": 9, "isClosed": true}]},
      {"recordType": "ticket", "pipelineId": "support", "label": "Support", "stages": [
         {"stageId": "t1", "label": "New", "order": 1, "isClosed": false}, {"stageId": "t9", "label": "Closed", "order": 9, "isClosed": true}]}]');
    -- leads past the target (3 days, 2 hours) and within it (30 minutes), one without a market; tickets ok (60 minutes),
    -- at risk (200), breached (300), one without a market; no state boundary within two minutes of now
    perform cma.ingest_upsert_records(v_crm, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd1', 'pipelineId', 'sales', 'stageId', 's1', 'ownerRef', 'o-1', 'market', 'NL',
                         'createdAt', v_now - interval '3 days', 'updatedAt', v_now - interval '3 days'),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd2', 'pipelineId', 'sales', 'stageId', 's1', 'ownerRef', 'o-1', 'market', 'NL',
                         'createdAt', v_now - interval '30 minutes', 'updatedAt', v_now - interval '30 minutes'),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd3', 'pipelineId', 'sales', 'stageId', 's1', 'ownerRef', 'o-2', 'market', 'NL',
                         'createdAt', v_now - interval '2 hours', 'updatedAt', v_now - interval '2 hours'),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd4', 'pipelineId', 'sales', 'stageId', 's1',
                         'createdAt', v_now - interval '1 day', 'updatedAt', v_now - interval '1 day'),
      jsonb_build_object('recordType', 'ticket', 'sourceId', 'x1', 'pipelineId', 'support', 'stageId', 't1', 'ownerRef', 'o-1', 'market', 'NL',
                         'createdAt', v_now - interval '60 minutes', 'updatedAt', v_now - interval '60 minutes'),
      jsonb_build_object('recordType', 'ticket', 'sourceId', 'x2', 'pipelineId', 'support', 'stageId', 't1', 'ownerRef', 'o-1', 'market', 'NL',
                         'createdAt', v_now - interval '200 minutes', 'updatedAt', v_now - interval '200 minutes'),
      jsonb_build_object('recordType', 'ticket', 'sourceId', 'x3', 'pipelineId', 'support', 'stageId', 't1', 'ownerRef', 'o-2', 'market', 'NL',
                         'createdAt', v_now - interval '300 minutes', 'updatedAt', v_now - interval '300 minutes'),
      jsonb_build_object('recordType', 'ticket', 'sourceId', 'x4', 'pipelineId', 'support', 'stageId', 't1', 'ownerRef', 'o-1',
                         'createdAt', v_now - interval '20 minutes', 'updatedAt', v_now - interval '20 minutes'),
      jsonb_build_object('recordType', 'ticket', 'sourceId', 'x5', 'pipelineId', 'support', 'stageId', 't1', 'ownerRef', 'o-1', 'market', 'NL',
                         'createdAt', v_now - interval '10 minutes', 'updatedAt', v_now - interval '10 minutes')));
    perform set_config('app.user_id', v_sched::text, true);
    r := cma.refresh_follow_up_of(v_t, false);

    -- A1 the page, an agent's own follow-up and the two report lists: the live rows at the same instant
    perform set_config('app.user_id', v_admin::text, true);
    v_page := cma.follow_up_page(null, null, null, 500);
    v_diff := null;
    select coalesce(jsonb_agg(e - 'owner_name' - 'record_url' order by n), '[]') into v_a from jsonb_array_elements(v_page -> 'leads' -> 'rows') with ordinality x(e, n);
    select coalesce(jsonb_agg(to_jsonb(o) - 'tenant_id' - 'ordinality' order by o.ordinality), '[]') into v_b
    from pg_temp.v0009u_open_leads_at(v_t, v_derive_at) with ordinality o;
    v_diff := 'page leads: ' || pg_temp.v0009u_diff(v_a, v_b);
    v_n := jsonb_array_length(v_b);
    select coalesce(jsonb_agg(e - 'owner_name' - 'record_url' order by n), '[]') into v_a from jsonb_array_elements(v_page -> 'tickets' -> 'rows') with ordinality x(e, n);
    select coalesce(jsonb_agg(to_jsonb(o) - 'tenant_id' - 'ordinality' order by o.ordinality), '[]') into v_b
    from pg_temp.v0009u_open_tickets_at(v_t, v_derive_at) with ordinality o;
    v_diff := coalesce(v_diff || '; ', '') || ('page tickets: ' || pg_temp.v0009u_diff(v_a, v_b));
    v_m := jsonb_array_length(v_b);
    select coalesce(jsonb_agg(to_jsonb(o) - 'ordinality' order by o.ordinality), '[]') into v_a from cma.open_leads() with ordinality o;
    select coalesce(jsonb_agg(to_jsonb(o) - 'ordinality' order by o.ordinality), '[]') into v_b
    from pg_temp.v0009u_open_leads_at(v_t, v_derive_at) with ordinality o;
    v_diff := coalesce(v_diff || '; ', '') || ('open_leads(): ' || pg_temp.v0009u_diff(v_a, v_b));
    select coalesce(jsonb_agg(to_jsonb(o) - 'ordinality' order by o.ordinality), '[]') into v_a from cma.open_tickets() with ordinality o;
    select coalesce(jsonb_agg(to_jsonb(o) - 'ordinality' order by o.ordinality), '[]') into v_b
    from pg_temp.v0009u_open_tickets_at(v_t, v_derive_at) with ordinality o;
    v_diff := coalesce(v_diff || '; ', '') || ('open_tickets(): ' || pg_temp.v0009u_diff(v_a, v_b));
    -- the agent's own rows: the live rows the agent owns, in order
    perform set_config('app.user_id', v_agent::text, true);
    v_mine := cma.my_follow_up();
    select coalesce(jsonb_agg(e - 'owner_name' - 'record_url' order by n), '[]') into v_a from jsonb_array_elements(v_mine -> 'tickets') with ordinality x(e, n);
    select coalesce(jsonb_agg(to_jsonb(o) - 'tenant_id' - 'ordinality' order by o.ordinality), '[]') into v_b
    from pg_temp.v0009u_open_tickets_at(v_t, v_derive_at) with ordinality o
    where o.owner_user_id = v_agent;
    v_diff := coalesce(v_diff || '; ', '') || ('own tickets: ' || pg_temp.v0009u_diff(v_a, v_b));
    select coalesce(jsonb_agg(e - 'owner_name' - 'record_url' order by n), '[]') into v_a from jsonb_array_elements(v_mine -> 'leads') with ordinality x(e, n);
    select coalesce(jsonb_agg(to_jsonb(o) - 'tenant_id' - 'ordinality' order by o.ordinality), '[]') into v_b
    from pg_temp.v0009u_open_leads_at(v_t, v_derive_at) with ordinality o
    where o.owner_user_id = v_agent;
    v_diff := coalesce(v_diff || '; ', '') || ('own leads: ' || pg_temp.v0009u_diff(v_a, v_b));
    v_txt := format('%s leads (%s past the target), %s tickets (states %s); the agent''s own %s leads and %s tickets',
                    v_n, (select count(*) from jsonb_array_elements(v_page -> 'leads' -> 'rows') e where (e ->> 'past_target')::boolean),
                    v_m, (select string_agg(e ->> 'sla_state', ',' order by n) from jsonb_array_elements(v_page -> 'tickets' -> 'rows') with ordinality x(e, n)),
                    jsonb_array_length(v_mine -> 'leads'), jsonb_array_length(v_mine -> 'tickets'));
    v_ok := v_diff is null and v_n = 4 and v_m = 5
            and (select string_agg(e ->> 'sla_state', ',' order by e ->> 'ticket_source_id' collate "C") from jsonb_array_elements(v_page -> 'tickets' -> 'rows') e) = 'ok,at_risk,breached,no_hours,ok';
    rows_ := rows_ || array['401', 'A1 the page, an agent''s own follow-up, open_leads() and open_tickets() equal the live rows at the same instant',
      case when v_ok and not v_provoke then 'ok' else 'FAIL' end, coalesce(v_diff, v_txt)];

    -- A2 a minute later, nothing else changed: the stored items the same, so a refresh writes 0 rows; 0009o's shape
    -- wrote every lead and ticket of a market in its hours; a second refresh at this instant writes 0
    select count(*) filter (where a.print is distinct from b.print), count(*) filter (where a.kind = 'lead'), count(*) filter (where a.kind = 'ticket')
      into v_n, v_m, v_audit
    from pg_temp.v0009u_items_at(v_t, now(), case when v_provoke then '0009o' else '0009u' end) a
    full join pg_temp.v0009u_items_at(v_t, now() + interval '1 minute', case when v_provoke then '0009o' else '0009u' end) b on b.kind = a.kind and b.item_id = a.item_id;
    select count(*) filter (where a.print is distinct from b.print) into v_txt
    from pg_temp.v0009u_items_at(v_t, now(), '0009o') a
    full join pg_temp.v0009u_items_at(v_t, now() + interval '1 minute', '0009o') b on b.kind = a.kind and b.item_id = a.item_id;
    perform set_config('app.user_id', v_sched::text, true);
    r := cma.refresh_follow_up_of(v_t, false);
    v_ok := v_n = 0 and v_txt::integer = 7 and (r ->> 'written')::integer = 0;
    rows_ := rows_ || array['402', 'A2 a minute later with nothing else changed a refresh writes 0 rows (0009o''s stored row: every lead and ticket with a market)',
      case when v_ok and not v_provoke then 'ok' else 'FAIL' end,
      format('%s leads and %s tickets: %s changed a minute later (0009o''s shape: %s); a second refresh now wrote %s', v_m, v_audit, v_n, v_txt, r ->> 'written')];

    -- A3 a real change is written: the owner of ticket x2 (o-1 to o-2) and the last ticket in order (x4, without a market,
    -- after every timed one, so no other ticket's place moves) closed: 2 rows for the owner (deleted and inserted), 1 for
    -- the closed ticket (deleted); the rest stays
    perform set_config('app.user_id', v_ing::text, true);
    if not v_provoke then
      perform cma.ingest_upsert_records(v_crm, jsonb_build_array(
        jsonb_build_object('recordType', 'ticket', 'sourceId', 'x2', 'pipelineId', 'support', 'stageId', 't1', 'ownerRef', 'o-2', 'market', 'NL',
                           'createdAt', v_now - interval '200 minutes', 'updatedAt', v_now),
        jsonb_build_object('recordType', 'ticket', 'sourceId', 'x4', 'pipelineId', 'support', 'stageId', 't9', 'ownerRef', 'o-1',
                           'createdAt', v_now - interval '20 minutes', 'updatedAt', v_now)));
    end if;
    perform set_config('app.user_id', v_sched::text, true);
    r := cma.refresh_follow_up_of(v_t, false);
    v_ok := (r ->> 'written')::integer = 3
            and (select i.row ->> 'owner_ref' from cma.follow_up_item i where i.tenant_id = v_t and i.kind = 'ticket' and i.row ->> 'ticket_source_id' = 'x2') = 'o-2'
            and (select i.owner_user_id from cma.follow_up_item i where i.tenant_id = v_t and i.kind = 'ticket' and i.row ->> 'ticket_source_id' = 'x2') is null
            and not exists (select 1 from cma.follow_up_item i where i.tenant_id = v_t and i.kind = 'ticket' and i.row ->> 'ticket_source_id' = 'x4')
            and (select count(*) from cma.follow_up_item i where i.tenant_id = v_t and i.kind = 'ticket') = 4;
    rows_ := rows_ || array['403', 'A3 a real change is written: an owner (2 rows) and the last ticket closed (1 row), the rest unchanged',
      case when v_ok and not v_provoke then 'ok' else 'FAIL' end,
      format('written %s (3 expected), unchanged %s; x2''s owner %s, x4 %s', r ->> 'written', r ->> 'unchanged',
             (select i.row ->> 'owner_ref' from cma.follow_up_item i where i.tenant_id = v_t and i.kind = 'ticket' and i.row ->> 'ticket_source_id' = 'x2'),
             case when exists (select 1 from cma.follow_up_item i where i.tenant_id = v_t and i.kind = 'ticket' and i.row ->> 'ticket_source_id' = 'x4') then 'still listed' else 'gone' end)];

    -- A4 the refreshes added no audit row for the follow-up's tables (their writes never reach cma.audit_log)
    perform set_config('role', 'cma_owner', true);
    select count(*) into v_audit from cma.audit_log a
    where a.tenant_id = v_t and a.table_name in ('follow_up_item', 'follow_up_snapshot', 'follow_up_marker');
    rows_ := rows_ || array['404', 'A4 three refreshes, no audit row for follow_up_item, follow_up_snapshot or follow_up_marker',
      case when v_audit = 0 and not v_provoke then 'ok' else 'FAIL' end,
      format('%s audit rows for the follow-up''s tables; %s for the tenant''s records (the ingest''s writes)', v_audit,
             (select count(*) from cma.audit_log a where a.tenant_id = v_t and a.table_name = 'crm_record'))];

    raise exception using errcode = 'CMAOK';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      rows_ := rows_ || array['499', 'A block ended early', 'FAIL', 'error ' || sqlstate || ': ' || sqlerrm];
  end;
  perform set_config('role', 'cma_owner', true);
  insert into verify_0009u (ord, check_name, result, detail)
  select rows_[4 * i - 3]::integer, rows_[4 * i - 2], rows_[4 * i - 1], rows_[4 * i] from generate_series(1, cardinality(rows_) / 4) i;
end
$$;

drop function if exists pg_temp.v0009u_items_at(uuid, timestamptz, text);
drop function if exists pg_temp.v0009u_diff(jsonb, jsonb);
drop function if exists pg_temp.v0009u_open_leads_at(uuid, timestamptz);
drop function if exists pg_temp.v0009u_open_tickets_at(uuid, timestamptz);
drop function if exists pg_temp.v0009u_speed_to_lead_at(uuid, timestamptz, timestamptz, timestamptz);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009u
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009u where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009u where result = 'ok') then 'FAIL'
                  else '0009u verified' end,
             format('191_verify_follow_up_clock_at_read: %s ok, %s FAIL, %s skip', (select count(*) from pg_temp.verify_0009u where result = 'ok'),
                    (select count(*) from pg_temp.verify_0009u where result = 'FAIL'), (select count(*) from pg_temp.verify_0009u where result = 'skip'))) x
order by ord;
