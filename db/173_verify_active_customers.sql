-- =============================================================================================
-- 173_verify_active_customers.sql: verifies addition 0009l, Customers → Active
-- =============================================================================================
-- Universal: no seed is assumed, so it runs in dev and in prod. Block S checks the addition, the functions, the grants,
-- the settings and the readers' views. Block P proves the pure functions on arrays made here (random ones against a brute
-- force, hand-made ones against hand-computed tables): no table is read. Block B works on two throwaway tenants inside a
-- subtransaction that is always rolled back, so nothing stays: synthetic people (example.invalid), invented stores,
-- customers, contacts, subscriptions, events, devices, orders and deals with fixed times, every figure counted by hand in
-- the comments beside it; no row carries a name, an address, an email or a phone number. Block N compares, per tenant of
-- the database with a stored Flash snapshot, the reconstructed month ends with the snapshots' figures and reports the
-- difference as a notice (info), never a failure: a past pause counts as holding in the reconstruction. Block E times
-- the page and the list per tenant with a subscription against 131's budgets, the seventh call of the session included.
-- Every check writes one row (PASS, FAIL, info or skip) and the last row is the verdict, because Cloud SQL Studio shows
-- no notices. Run as your own IAM login after 172_active_customers.sql; then 14, 123, 137 and 151 (they read
-- cma.check_tenant_setting(), which 172 re-creates; unchanged, still PASS) and 85 (cma.first_orders_of is read by 172, not
-- re-created). Expected verdict: "PASS | 173_verify_active_customers: <n> PASS, 0 FAIL, <i> info, <k> skip".
--   S1  the addition 0009l is recorded, after 0009k
--   S2  every function of the addition the application's only and in the caller's rights; the two readers' functions
--       SECURITY DEFINER, owned by cma_owner, search path pinned with pg_temp last, the readers' only; the set-returning
--       ones say their rows; cma.active_base_of, cma.active_page_of and cma.active_rows_of with jit off
--   S3  the four settings with their defaults
--   S4  the readers' views: their columns, none of a customer, a contact, a level or a payload
--   P1  (A2) cma.active_spells_from equals a day-by-day reconstruction on 200 random sets (overlaps, gaps, an interval
--       that begins where another ends, one without an end, one of no length)
--   P2  (A3) cma.active_month_cube_from on random intervals: per month net change = this month end - the previous one =
--       inflow - outflow, and every month end equals a count of the intervals holding at that instant
--   P3  (A4) the unit factors per billing interval, and the billing words
--   P4  (A5) cma.active_cohort_cube_from against hand counts: sizes, still active per age, the maturity flag
--   P5  (A12) cma.active_km_from against a hand-computed table: ties, a spell censored at the age of an event, a set of
--       one spell, a curve that never reaches 50 % (median none) and one that does
--   P6  cma.active_fx_ok and cma.active_eur_of: the forms taken and refused, never a rate guessed
--   B1  (A1) the live headline equals Flash's: per market and segment cma.flash_customer_figures_of's Active customers and
--       holding subscriptions, and Flash's own Active customers and Total subscriptions (cma.flash_compute_of)
--   B2  the base: each subscription's holding interval (a pause, a cancel and a reactivation, an expiry by its event, an
--       expiry without a time left out, a merged one absent, one without a creation time left out), its customer's
--       Customer start, and cma.active_spells_of's spells against the hand's
--   B3  (A3) the page's month ends, inflow, outflow and net change against the hand's; the running month is "now" and
--       equals the headline; the change lines' month ends
--   B4  (A4) the Monthly recurring amount per currency (never added across currencies), its customers and average, and
--       its month ends
--   B5  (A5) the customer cohorts by month and by quarter against hand counts, with the dominant-cohort note
--   B6  (A6) the euro line: absent while reports.fx_eur_rates is empty or lacks a shown currency's rate, present with
--       every rate and the setting's date
--   B7  (A7) the placeholders carry a key and the status pending, and nothing else
--   B8  (A8) the other tenant sees nothing of tenant one; a person without reports.view or performance.team gets CMA06 on
--       the page, the list and the file record; a parameter out of its form CMA04
--   B9  (A9) cma_read.active_customer_month and cma_read.customer_cohort equal the page's month ends and cohorts
--   B10 (A11) the acquisition channel equals First orders' attribution for every customer whose first order First orders
--       lists, row for row; the Unknown reasons by hand; attribution.assisted_levels without lead_deal moves that
--       customer from indirect to direct and changes nothing else
--   B11 (A12) the page's survival: the curve over all spells and per segment against the hand's, the median reached for
--       one segment and "not reached" for the others, cma.active_survival_of the same
--   B12 (A13) the comparison of the first two segments: values, differences and ratios; a currency on one side only gives
--       no difference and no ratio; the unknown segment beside, never in the difference
--   B13 (A14) each filter's values add up to the unfiltered totals: the three channels, the segments, the markets
--   B14 the rest of the page: the split lines, customer age, the age bands, the markets with their totals row, the
--       subscription mix, the payment states as cma.subscription_payment_state_of, the notes, Churned over 30 days as
--       Flash's
--   B15 the list: its rows' keys (none of a name, an email, a phone or an address), order, paging and cap, the file's
--       record in the audit log
--   B16 the settings' refusals and normalisation
--   N1  (A10) per tenant with stored Flash snapshots of the customers: the reconstructed month end beside the snapshot's
--       Active customers, the difference as a notice
--   E1, E2  per tenant with a subscription: the page (budget verify.max_overview_ms, 500) and the list's first page
--       (verify.max_list_ms, 300), best of the runs after six untimed calls
-- Provoke: verify.provoke below. 'true': every check reads FAIL and the verdict says PROVOKED, NOT A PASS. A check's id
-- (S1 … B16, P1 … P6, E1, E2): that check alone compares with a deliberate difference, so the run fails exactly it.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);                 -- 'true' for every check, or one check's id such as 'B3'
select set_config('verify.max_overview_ms', '500', false);           -- the page's read (131's class overview)
select set_config('verify.max_list_ms', '300', false);               -- the list's first page (131's class list)
select set_config('verify.timing_runs', '3', false);                 -- timed runs per read in E, after six untimed ones

drop table if exists pg_temp.verify_0009l;
create temporary table verify_0009l (ord integer, check_name text, result text, detail text);
grant select, insert on pg_temp.verify_0009l to cma_app;

-- Whether a check is provoked: the switch is true, or names the check
create or replace function pg_temp.v0009l_p(p_id text)
returns boolean
language sql stable
as $$
  select current_setting('verify.provoke') in ('true', p_id)
$$;

-- One check's row: PASS when what was found equals what is expected; provoked, the expectation carries a deliberate
-- difference, so the comparison itself fails
create or replace function pg_temp.v0009l_row(p_ord integer, p_id text, p_name text, p_found text, p_expected text)
returns void
language plpgsql
as $$
declare
  v_exp text := case when pg_temp.v0009l_p(p_id) then coalesce(p_expected, '') || ' [provoked: a deliberate difference]' else p_expected end;
begin
  insert into pg_temp.verify_0009l values (p_ord, p_id || ' ' || p_name,
    case when p_found is not distinct from v_exp then 'PASS' else 'FAIL' end,
    case when p_found is not distinct from v_exp then left(coalesce(p_found, 'null'), 300)
         else left('found ' || coalesce(p_found, 'null') || ' | expected ' || coalesce(v_exp, 'null'), 1500) end);
end
$$;

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0009l_code(p_sql text)
returns text
language plpgsql
as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- S. Structure and privileges
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_bad text := '';
  v_fn  text;
  v_txt text;
begin
  perform pg_temp.v0009l_row(1, 'S1', 'the addition 0009l is recorded, after 0009k',
    (select string_agg(m.version, ',' order by m.version) from cma.schema_migration m where m.version in ('0009k', '0009l')), '0009k,0009l');

  foreach v_fn in array array[
    'cma.active_fx_ok(text)', 'cma.active_fx_of(uuid)', 'cma.active_eur_of(numeric,text,jsonb)', 'cma.active_month_factor_of(text,integer)',
    'cma.active_billing_of(text,integer)', 'cma.active_spells_from(text[],timestamptz[],timestamptz[])',
    'cma.active_month_cube_from(text[],text[],text[],numeric[],timestamptz[],timestamptz[],text,timestamptz)',
    'cma.active_cohort_cube_from(text[],text[],text[],text[],timestamptz[],timestamptz[],timestamptz[],integer[],text,text,timestamptz)',
    'cma.active_km_from(integer[],boolean[])', 'cma.active_km_json(integer[],boolean[])',
    'cma.active_base_of(uuid,timestamptz,boolean,date,boolean)', 'cma.active_customers_of(uuid,timestamptz,boolean)', 'cma.active_spells_of(uuid)',
    'cma.active_channel_of(uuid)', 'cma.active_spell_lengths_of(uuid,timestamptz,boolean)', 'cma.active_survival_of(uuid,text)',
    'cma.assert_active_filter(text,text,text)', 'cma.active_page_of(uuid,date,text,text,text,text,timestamptz)',
    'cma.active_page(date,text,text,text,text)', 'cma.active_rows_of(uuid,text,text,text,text,boolean,integer,integer,timestamptz)',
    'cma.active_rows(text,text,text,text,boolean,integer,integer,boolean)', 'cma.active_file_record(text,text,text,integer)',
    'cma.active_months_of(uuid,timestamptz)', 'cma.active_cohorts_of(uuid,text,timestamptz)'
  ] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    else
      select v_bad || case when p.prosecdef then v_fn || ' is security definer; ' else '' end
                   || case when pg_get_userbyid(p.proowner) <> 'cma_owner' then v_fn || ' not owned by cma_owner; ' else '' end
                   || case when has_function_privilege('public', p.oid, 'execute') then v_fn || ' executable by public; ' else '' end
                   || case when not has_function_privilege('cma_app', p.oid, 'execute') then v_fn || ' not executable by cma_app; ' else '' end
                   || case when has_function_privilege('cma_readonly', p.oid, 'execute') then v_fn || ' executable by cma_readonly; ' else '' end
                   || case when p.proretset and p.prorows = 1000 then v_fn || ' leaves rows at the default; ' else '' end
      into v_bad from pg_proc p where p.oid = to_regprocedure(v_fn);
    end if;
  end loop;
  foreach v_fn in array array['cma_read.active_customer_month_rows()', 'cma_read.customer_cohort_rows()'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    else
      select v_bad || case when not p.prosecdef then v_fn || ' is not security definer; ' else '' end
                   || case when pg_get_userbyid(p.proowner) <> 'cma_owner' then v_fn || ' not owned by cma_owner; ' else '' end
                   || case when not ('search_path=pg_catalog, cma, pg_temp' = any (coalesce(p.proconfig, '{}'))) then v_fn || ' search path not pinned; ' else '' end
                   || case when has_function_privilege('public', p.oid, 'execute') then v_fn || ' executable by public; ' else '' end
                   || case when has_function_privilege('cma_app', p.oid, 'execute') then v_fn || ' executable by cma_app; ' else '' end
                   || case when not has_function_privilege('cma_readonly', p.oid, 'execute') then v_fn || ' not executable by cma_readonly; ' else '' end
                   || case when p.prorows = 1000 then v_fn || ' leaves rows at the default; ' else '' end
      into v_bad from pg_proc p where p.oid = to_regprocedure(v_fn);
    end if;
  end loop;
  foreach v_fn in array array['cma.active_base_of(uuid,timestamptz,boolean,date,boolean)', 'cma.active_page_of(uuid,date,text,text,text,text,timestamptz)',
                              'cma.active_rows_of(uuid,text,text,text,text,boolean,integer,integer,timestamptz)'] loop
    if to_regprocedure(v_fn) is not null
       and not ('jit=off' = any (coalesce((select p.proconfig from pg_proc p where p.oid = to_regprocedure(v_fn)), '{}'))) then
      v_bad := v_bad || v_fn || ' without jit off; ';
    end if;
  end loop;
  perform pg_temp.v0009l_row(2, 'S2', 'the functions: the application''s in the caller''s rights, the readers'' definer and pinned, rows said, jit off', v_bad, '');

  select string_agg(s.key || '=' || s.value_type || ':' || s.default_value, ' | ' order by s.key) into v_txt
  from cma.setting s where s.key in ('customers.cohort_ages_months', 'customers.age_months', 'customers.history_months', 'reports.fx_eur_rates');
  perform pg_temp.v0009l_row(3, 'S3', 'the four settings with their defaults', v_txt,
    'customers.age_months=text:12,24,36,48,60 | customers.cohort_ages_months=text:3,6,12,24,36 | customers.history_months=integer:60 | reports.fx_eur_rates=text:{}');

  select string_agg(c.table_name || ':' || c.cols, ' | ' order by c.table_name) into v_txt
  from (select x.table_name, string_agg(x.column_name, ',' order by x.ordinal_position) as cols
        from information_schema.columns x
        where x.table_schema = 'cma_read' and x.table_name in ('active_customer_month', 'customer_cohort') group by 1) c;
  perform pg_temp.v0009l_row(4, 'S4', 'the readers'' views: counts per month or cohort, market, segment and channel; no customer, contact, level or payload', v_txt,
    'active_customer_month:tenant_id,month,market,segment,acquisition_channel,active_customers,holding_subscriptions,inflow,outflow'
    || ' | customer_cohort:tenant_id,cohort,grouping,market,segment,acquisition_channel,started,age_months,still_active,mature');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- P. The pure functions, on arrays made here
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_diff  integer := 0;
  v_cases integer := 0;
  v_txt   text;
  v_k text[]; v_s timestamptz[]; v_e timestamptz[];
  v_fn text; v_bf text;
  i integer;
  d0 constant date := date '2024-01-01';
begin
  -- P1 (A2). 200 random sets of intervals on whole days over 120 days, three keys, up to eight intervals each: some without
  -- an end, some of no length, many overlapping or touching. The brute force walks the days: a key holds on a day when an
  -- interval covers that day's start; a spell is a run of held days (its end the first day not held; none when the last
  -- day is held by an interval without an end)
  perform setseed(0.172);
  for i in 1 .. 200 loop
    select array_agg(q.k), array_agg(q.s), array_agg(q.e) into v_k, v_s, v_e
    from (select 'k' || (1 + floor(random() * 3))::int as k, (d0 + (floor(random() * 100))::int)::timestamp at time zone 'UTC' as s,
                 floor(random() * 30)::int as len, random() as r
          from generate_series(1, 2 + (floor(random() * 7))::int)) g
    cross join lateral (select g.k, g.s, case when g.r < 0.15 then null when g.r < 0.25 then g.s else g.s + make_interval(days => 1 + g.len) end as e) q;
    select coalesce(string_agg(x.key || ':' || to_char(x.spell_start at time zone 'UTC', 'MMDD') || '-' || coalesce(to_char(x.spell_end at time zone 'UTC', 'MMDD'), 'open'),
                               ' ' order by x.key, x.spell_start), '') into v_fn
    from cma.active_spells_from(v_k, v_s, v_e) x;
    with iv as (
      select u.k, u.s, u.e from unnest(v_k, v_s, v_e) u(k, s, e)
    ), day as (
      -- every day of the walk (one more than the longest interval can reach), per key: held or not
      select k.k, d.d, exists (select 1 from iv where iv.k = k.k and iv.s <= d.d and (iv.e is null or iv.e > d.d) and (iv.e is null or iv.e > iv.s)) as held
      from (select distinct iv.k from iv) k
      cross join (select (d0 + n)::timestamp at time zone 'UTC' as d from generate_series(0, 140) n) d
    ), run as (
      select day.k, day.d, day.held, lag(day.held, 1, false) over (partition by day.k order by day.d) as before from day
    ), st as (
      select run.k, run.d as s,
             (select min(r2.d) from run r2 where r2.k = run.k and r2.d > run.d and not r2.held) as e
      from run where run.held and not run.before
    )
    select coalesce(string_agg(st.k || ':' || to_char(st.s at time zone 'UTC', 'MMDD') || '-' || coalesce(to_char(st.e at time zone 'UTC', 'MMDD'), 'open'),
                               ' ' order by st.k, st.s), '') into v_bf
    from st;
    v_cases := v_cases + 1;
    if v_fn is distinct from v_bf then
      v_diff := v_diff + 1;
      v_txt := coalesce(v_txt, format('set %s: function [%s] brute force [%s]', i, v_fn, v_bf));
    end if;
  end loop;
  perform pg_temp.v0009l_row(11, 'P1', '(A2) cma.active_spells_from equals the day-by-day reconstruction on 200 random sets',
    format('%s sets, %s differ%s', v_cases, v_diff, coalesce(': ' || v_txt, '')), '200 sets, 0 differ');

  -- P2 (A3). 40 random sets over 500 days: per month and dimension net = at_end - previous at_end = inflow - outflow, and
  -- at_end equals the weight of the intervals holding at the month's end (started before it, not ended before it)
  v_diff := 0; v_txt := null;
  for i in 1 .. 40 loop
    select array_agg(q.k), array_agg(q.s), array_agg(q.e) into v_k, v_s, v_e
    from (select (array['x', 'y'])[1 + floor(random() * 2)::int] as k, (d0 + (floor(random() * 400))::int)::timestamp at time zone 'UTC' + interval '9 hours' as s,
                 floor(random() * 200)::int as len, random() as r
          from generate_series(1, 30)) g
    cross join lateral (select g.k, g.s, case when g.r < 0.3 then null else g.s + make_interval(days => g.len) end as e) q;
    select v_diff + count(*) into v_diff
    from (select c.month, c.d1, c.inflow, c.outflow, c.at_end,
                 c.at_end - lag(c.at_end, 1, 0::numeric) over (partition by c.d1 order by c.month) as net,
                 (select count(*) from unnest(v_k, v_s, v_e) u(k, s, e)
                  where u.k = c.d1 and (u.e is null or u.e > u.s)
                    and case when c.month = date '2025-06-01'
                             then u.s <= timestamptz '2025-06-15 12:00+00' and (u.e is null or u.e > timestamptz '2025-06-15 12:00+00')
                             else u.s < ((c.month + interval '1 month')::timestamp at time zone 'UTC')
                                  and (u.e is null or u.e >= ((c.month + interval '1 month')::timestamp at time zone 'UTC')) end) as brute
          from cma.active_month_cube_from(v_k, v_k, v_k, array_fill(1::numeric, array[30]), v_s, v_e, 'UTC', timestamptz '2025-06-15 12:00+00') c) q
    where q.net <> q.inflow - q.outflow or q.at_end <> q.brute;
  end loop;
  perform pg_temp.v0009l_row(12, 'P2', '(A3) net change = month end - previous month end = inflow - outflow, and each month end equals the brute count, on 40 random sets',
    format('%s months differ', v_diff), '0 months differ');

  -- P3 (A4). the unit factors: a day 365.25/12, a week 365.25/84, a month 1, a year 1/12, each divided by the count
  select format('%s %s %s %s %s %s %s %s | %s %s %s %s %s %s',
                round(cma.active_month_factor_of('day', 1), 6), round(cma.active_month_factor_of('day', 30), 6),
                round(cma.active_month_factor_of('week', 1), 6), round(cma.active_month_factor_of('week', 4), 6),
                round(cma.active_month_factor_of('month', 1), 6), round(cma.active_month_factor_of('month', 3), 6),
                round(cma.active_month_factor_of('year', 1), 6), coalesce(cma.active_month_factor_of(null, 1)::text, 'null') || coalesce(cma.active_month_factor_of('month', null)::text, 'null'),
                cma.active_billing_of('month', 1), cma.active_billing_of('year', 1), cma.active_billing_of('month', 12), cma.active_billing_of('week', 4),
                cma.active_billing_of('month', 3), cma.active_billing_of(null, 1)) into v_txt;
  perform pg_temp.v0009l_row(13, 'P3', '(A4) the unit factors per billing interval and the billing words', v_txt,
    '30.437500 1.014583 4.348214 1.087054 1.000000 0.333333 0.083333 nullnull | monthly yearly yearly other other unknown');

  -- P4 (A5). three customers of two spell sets, zone UTC, as of 15 July 2024, ages 1, 3 and 6 months, by month and by quarter:
  --   a (segment m) starts 10 Jan: spells 10 Jan to 1 Mar and 1 Jun on: at 1 month (10 Feb) active, at 3 (10 Apr) not, at 6 (10 Jul) active
  --   b (segment m) starts 20 Jan: a spell from 1 Feb on: at 1 (20 Feb) active, at 3 (20 Apr) active, at 6 (20 Jul) not that old yet
  --   c (segment n) starts 5 Mar, a spell 5 Mar to 1 Apr: at 1 (5 Apr) not, at 3 (5 Jun) not, at 6 (5 Sep) not that old yet
  -- month: Jan m: started 2; 1: 2 mature; 3: 1 mature; 6: 1 of those old enough, not mature. Mar n: started 1; 1: 0 mature; 3: 0 mature; 6: 0 not mature
  -- quarter: Q1 m and Q1 n the same rows under 1 January
  select string_agg(format('%s %s %s:%s/%s/%s', to_char(x.cohort, 'MMDD'), x.d1, x.age_months, x.started, x.still_active, x.mature), ' ' order by x.cohort, x.d1, x.age_months)
         || ' || ' ||
         (select string_agg(format('%s %s %s:%s/%s/%s', to_char(y.cohort, 'MMDD'), y.d1, y.age_months, y.started, y.still_active, y.mature), ' ' order by y.cohort, y.d1, y.age_months)
          from cma.active_cohort_cube_from(array['a', 'a', 'b', 'c'], array['m', 'm', 'm', 'n'], array['', '', '', ''], array['', '', '', ''],
                 array['2024-01-10', '2024-01-10', '2024-01-20', '2024-03-05']::timestamptz[], array['2024-01-10', '2024-06-01', '2024-02-01', '2024-03-05']::timestamptz[],
                 array['2024-03-01', null, null, '2024-04-01']::timestamptz[], array[1, 3, 6], 'quarter', 'UTC', timestamptz '2024-07-15 00:00+00') y)
  into v_txt
  from cma.active_cohort_cube_from(array['a', 'a', 'b', 'c'], array['m', 'm', 'm', 'n'], array['', '', '', ''], array['', '', '', ''],
         array['2024-01-10', '2024-01-10', '2024-01-20', '2024-03-05']::timestamptz[], array['2024-01-10', '2024-06-01', '2024-02-01', '2024-03-05']::timestamptz[],
         array['2024-03-01', null, null, '2024-04-01']::timestamptz[], array[1, 3, 6], 'month', 'UTC', timestamptz '2024-07-15 00:00+00') x;
  perform pg_temp.v0009l_row(14, 'P4', '(A5) the cohort cube against hand counts: sizes, still active per age, maturity', v_txt,
    '0101 m 1:2/2/t 0101 m 3:2/1/t 0101 m 6:2/1/f 0301 n 1:1/0/t 0301 n 3:1/0/t 0301 n 6:1/0/f'
    || ' || 0101 m 1:2/2/t 0101 m 3:2/1/t 0101 m 6:2/1/f 0101 n 1:1/0/t 0101 n 3:1/0/t 0101 n 6:1/0/f');

  -- P5 (A12). Kaplan–Meier by hand. Ten spells: lengths 1 ended, 2 ended, 2 ended (a tie), 2 still active (censored at the
  -- age of an event), 3 ended, 5 still, 5 ended, 6 still, 8 ended, 8 still.
  --   age 0: at risk 10, events 0, survival 1        retained 1
  --   age 1: at risk 10, events 1, survival 0.9      retained 1
  --   age 2: at risk 9,  events 2, survival 0.7      retained 0.9
  --   age 3: at risk 6,  events 1, survival 0.583333 retained 0.7
  --   age 4: at risk 5,  events 0, survival 0.583333 retained 0.583333
  --   age 5: at risk 5,  events 1, survival 0.466667 retained 0.583333   <- the median: the first age at or below 0.5
  --   age 6: at risk 3,  events 0, survival 0.466667
  --   age 7: at risk 2,  events 0
  --   age 8: at risk 2,  events 1, survival 0.233333 retained 0.466667
  -- one spell of 4 months still active: survival 1 throughout, no median ("not reached", longest 4); two spells of 3 ended
  -- and 3 still: survival 0.5 at age 3, the median 3
  select (select string_agg(format('%s:%s/%s/%s/%s', k.age_months, k.at_risk, k.events, round(k.survival, 6), round(k.retained, 6)), ' ' order by k.age_months)
          from cma.active_km_from(array[1, 2, 2, 2, 3, 5, 5, 6, 8, 8], array[true, true, true, false, true, false, true, false, true, false]) k)
         || ' | median ' || coalesce(cma.active_km_json(array[1, 2, 2, 2, 3, 5, 5, 6, 8, 8], array[true, true, true, false, true, false, true, false, true, false]) ->> 'median', 'none')
         || ' | one: ' || coalesce(cma.active_km_json(array[4], array[false]) ->> 'median', 'none') || '/' || (cma.active_km_json(array[4], array[false]) ->> 'longest')
         || '/' || (select string_agg(round(k.survival, 2)::text, ',' order by k.age_months) from cma.active_km_from(array[4], array[false]) k)
         || ' | two: ' || coalesce(cma.active_km_json(array[3, 3], array[true, false]) ->> 'median', 'none')
         || ' | empty: ' || (cma.active_km_json('{}'::integer[], '{}'::boolean[]) ->> 'spells') || coalesce(cma.active_km_json('{}'::integer[], '{}'::boolean[]) ->> 'median', 'none')
  into v_txt;
  perform pg_temp.v0009l_row(15, 'P5', '(A12) Kaplan–Meier against the hand-computed table: ties, censoring at an event''s age, one spell, not reached', v_txt,
    '0:10/0/1.000000/1.000000 1:10/1/0.900000/1.000000 2:9/2/0.700000/0.900000 3:6/1/0.583333/0.700000 4:5/0/0.583333/0.583333 5:5/1/0.466667/0.583333'
    || ' 6:3/0/0.466667/0.466667 7:2/0/0.466667/0.466667 8:2/1/0.233333/0.466667 | median 5 | one: none/4/1.00,1.00,1.00,1.00,1.00 | two: 3 | empty: 0none');

  -- P6. the rates' form and the euros of an amount: never a rate guessed
  select format('%s%s%s%s%s%s%s%s%s%s | %s %s %s %s',
                cma.active_fx_ok('{}')::int, cma.active_fx_ok('{"as_of": "2026-11-01", "GBP": 1.15}')::int, cma.active_fx_ok('{"GBP": 1.15}')::int,
                cma.active_fx_ok('{"as_of": "2026-02-30", "GBP": 1.15}')::int, cma.active_fx_ok('{"as_of": "2026-11-01"}')::int,
                cma.active_fx_ok('{"as_of": "2026-11-01", "gbp": 1.15}')::int, cma.active_fx_ok('{"as_of": "2026-11-01", "GBP": 0}')::int,
                cma.active_fx_ok('{"as_of": "2026-11-01", "GBP": "1.15"}')::int, cma.active_fx_ok('[1]')::int, cma.active_fx_ok('{"as_of": "2026-11-01", "GBP": 1.15, "note": "a@b"}')::int,
                cma.active_eur_of(100, 'EUR', '{}'), cma.active_eur_of(100, 'GBP', '{"as_of": "2026-11-01", "GBP": 1.15}'),
                coalesce(cma.active_eur_of(100, 'USD', '{"as_of": "2026-11-01", "GBP": 1.15}')::text, 'none'), coalesce(cma.active_eur_of(100, 'GBP', '{}')::text, 'none'))
  into v_txt;
  perform pg_temp.v0009l_row(16, 'P6', 'the rates'' form (cma.active_fx_ok) and the euros of an amount, none without a rate', v_txt, '1100000000 | 100 115.00 none none');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- B. Two throwaway tenants with a hand-computed customer base (rolled back)
-- ---------------------------------------------------------------------------------------------
-- Tenant one (Europe/Amsterdam), as of Wednesday 11 November 2026 12:00 UTC; every time below is 09:00 UTC. Settings: the
-- segments B2B,B2C; device-holding statuses active,failed (paying: active; ended: canceled,expired);
-- intake.start_date 1 June 2025 (attribution.window_days 90). Stores v-nl (NL, EUR) and v-gb (GB, GBP), each with its
-- subscriptions connection.
--   store customers  created      contact (segment)   amount spent   Customer start
--   NL c1            10 Jan 2025  k1 (B2B)            600 EUR        10 Jan 2025  (age 22)
--   NL c2             5 Mar 2025  k2 (B2C)            300 EUR         5 Mar 2025  (age 20)
--   NL c3            20 Jun 2025  none                999 EUR         1 Dec 2024  (its subscription s8; not active)
--   NL c4             1 Feb 2026  k4 (B2C)            200 EUR         1 Dec 2025  (its subscription s10; age 11)
--   NL c5            20 Oct 2026  k5 (b2b: B2B)       100 EUR        20 Oct 2026  (age 0)
--   NL c6             1 May 2026  k8 (B2C)             50 EUR         1 May 2026  (age 6)
--   NL c7             1 Jun 2026  k9 (no segment)      80 EUR         1 Jun 2026  (age 5)
--   NL cx (no subscription: not in the base);  GB g1 15 Feb 2025, k6 (B2C), 500 GBP (age 20);  GB g2 1 Aug 2025, k7
--   (segment Other: unknown), 400 GBP (age 15)
--   subscriptions (store, customer, status, created, what ends it, amount per cycle)
--   s1  NL c1 active    15 Jan 2025  -                              30 EUR a month
--   s2  NL c1 canceled   1 Apr 2025  canceled_at 10 Sep 2025        20 EUR a month
--   s12 NL c1 active     1 Feb 2025  - (canceled_at 1 Jun 2025 kept from before its reactivation: ignored)  10 EUR a month
--   s16 NL c1 canceled  no creation time, canceled_at 1 May 2025: left out (no_created_time)
--   s3  NL c2 canceled  10 Mar 2025  canceled_at 20 Jul 2025        20 EUR a month
--   s4  NL c2 active     5 Nov 2025  -                              240 EUR a year (20 a month)
--   s11 NL c2 merged     1 Jan 2025: not in the base
--   s5  NL c3 paused    25 Jun 2025  paused_at 15 Sep 2026          28 EUR per 4 weeks (30.4375 a month)
--   s8  NL c3 expired    1 Dec 2024  no time and no event: left out (no_ended_time)
--   s10 NL c4 expired    1 Dec 2025  its status_changed event to expired, 20 Jan 2026   25 EUR a month
--   s6  NL c4 failed     3 Feb 2026  - (holds, does not pay)        25 EUR a month
--   s7  NL c5 active    21 Oct 2026  -                              15 EUR per 30 days (15.21875 a month)
--   s13 NL c6 active     2 May 2026  - (a failed renewal of cycle 3 not followed by a renewal: in retry)  12 EUR a month
--   s14 NL c7 active     2 Jun 2026  -                              14 EUR a month
--   s9  NL ghost active 10 Jan 2026  - (a customer the store does not hold)   10 EUR a month
--   s20 GB g1 active    20 Feb 2025  -                              40 GBP a month
--   s21 GB g2 canceled   5 Aug 2025  canceled_at 10 Mar 2026        45 GBP a month
--   s22 GB g2 active    10 Mar 2026  - (begins where s21 ends: one spell)   50 GBP a month
-- The spells: c1 15 Jan 2025 on (A); c2 10 Mar to 20 Jul 2025 (B) and 5 Nov 2025 on (C); c3 25 Jun 2025 to 15 Sep 2026 (D);
-- c4 1 Dec 2025 to 20 Jan 2026 (E) and 3 Feb 2026 on (F); c5 21 Oct 2026 on (G); c6 2 May 2026 on (J); c7 2 Jun 2026 on
-- (K); g1 20 Feb 2025 on (H); g2 5 Aug 2025 on (I). Eleven spells, three ended.
-- Now: 8 active customers (NL c1 c2 c4 c5 c6 c7, GB g1 g2; B2B 2, B2C 4, unknown 2), 10 holding subscriptions (9 active, 1
-- failed), EUR 30 + 10 + 20 + 15.21875 + 12 + 14 + 10 = 111.22 over 6 customers (18.54), GBP 40 + 50 = 90 over 2 (45).
-- First orders: the order pipeline v-orders with its won stage, the lead pipeline v-leads. c2: a first store order and its
-- won order deal on 5 Nov 2025, with a lead deal of its contact on 20 Oct 2025 (level lead_deal: call_center, indirect).
-- c4: a first order and its deal on 3 Feb 2026, no evidence (self_service: direct). c5: a deal on 21 Oct 2026 whose
-- store order is a repeat order (not a first order: unknown, no_first_order). c7: a deal on 2 Jun 2026 whose store order
-- lies four days later (first, not matched: unknown, order_not_matched). c6: no deal (no_order_deal). The history starts
-- on 5 Nov 2025 (the first order deal; later than 1 June + 90 days), so c1, g1 and g2 are before_history; c3 no_contact.
-- Devices (statuses v_field in the field, v_stock not; models vm1, vm2): d1 (m1, c1, s1), d2 (m1, c1, s12), d3 (m2, g1,
-- s20) in the field; d4 (m1, c2, s4) in stock. A canceled event of s2 on 1 Nov 2026 (Flash's churn of the last 30 days: 1).
-- Tenant two: a store and its subscriptions connection, no customer and no subscription.
do $$
declare
  v_rows text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_analyst1 uuid; v_agent1 uuid; v_admin2 uuid; v_analyst2 uuid;
  v_crm uuid; v_nl uuid; v_gb uuid; v_snl uuid; v_sgb uuid; v_reg uuid; v_shop2 uuid; v_sub2 uuid;
  v_now timestamptz := '2026-11-11 12:00:00+00';
  j jsonb; j2 jsonb; j3 jsonb;
  v_txt text; v_txt2 text; v_n integer; v_m integer;
  r record;
  -- a time of the fixture: 09:00 UTC on a date
  -- (written as text below; t() is no function here, the casts are plain)
begin
  begin
    v_t1 := cma.create_tenant('verify-0009l-one', 'Verify 0009l one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0009l-two', 'Verify 0009l two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'agent1') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-analyst2@example.invalid', 'analyst2') returning id into v_analyst2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_analyst1, 'analytics'), (v_t1, v_agent1, 'agent'), (v_t2, v_admin2, 'admin'),
                 (v_t2, v_analyst2, 'analytics')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id, settings)
    values (v_t1, 'verifycrm', 'crm', 'Verify active CRM', 'portal-1', '{"record_url_contact": "https://crm.example.invalid/{account}/contact/{id}"}')
    returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id)
    values (v_t1, 'verifyshop', 'commerce', 'Verify active shop NL', 'v-nl.shop.example.invalid') returning id into v_nl;
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id)
    values (v_t1, 'verifyshop', 'commerce', 'Verify active shop GB', 'v-gb.shop.example.invalid') returning id into v_gb;
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id)
    values (v_t1, 'verifysubs', 'subscriptions', 'Verify active subscriptions NL', 'v-nl.shop.example.invalid') returning id into v_snl;
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id)
    values (v_t1, 'verifysubs', 'subscriptions', 'Verify active subscriptions GB', 'v-gb.shop.example.invalid') returning id into v_sgb;
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id)
    values (v_t1, 'verifyreg', 'assets', 'Verify active register', 'base-1') returning id into v_reg;
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id)
    values (v_t2, 'verifyshop', 'commerce', 'Verify active shop two', 'v-two.shop.example.invalid') returning id into v_shop2;
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id)
    values (v_t2, 'verifysubs', 'subscriptions', 'Verify active subscriptions two', 'v-two.shop.example.invalid') returning id into v_sub2;

    -- tenant two before its store exists: not set up, no figure
    j2 := cma.active_page_of(v_t2, null, null, null, null, 'month', v_now);
    v_txt2 := format('%s/%s/%s/%s', j2 -> 'set_up' ->> 'commerce', j2 -> 'set_up' ->> 'subscriptions', j2 ->> 'figures', (j2 ? 'tiles')::text);

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    perform cma.set_tenant_setting('crm.customer_segments', 'B2B,B2C');
    perform cma.set_tenant_setting('flash.device_holding_statuses', 'active,failed');
    perform cma.set_tenant_setting('intake.start_date', '2025-06-01');
    perform cma.upsert_commerce_store(v_nl, 'v-nl', 'Verify NL', 'NL', 'EUR', 'Europe/Amsterdam');
    perform cma.upsert_commerce_store(v_gb, 'v-gb', 'Verify GB', 'GB', 'GBP', 'Europe/London');
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_commerce_store(v_shop2, 'v-two', 'Verify two', 'NL', 'EUR', 'Europe/Amsterdam');
    perform set_config('role', 'cma_owner', true);

    -- the rows, as the owner (invented ids; no name, address, email or phone)
    insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, segment)
    values (v_t1, v_crm, 'verifycrm', 'k1', 'B2B'), (v_t1, v_crm, 'verifycrm', 'k2', 'B2C'), (v_t1, v_crm, 'verifycrm', 'k4', 'B2C'),
           (v_t1, v_crm, 'verifycrm', 'k5', 'b2b'), (v_t1, v_crm, 'verifycrm', 'k6', 'B2C'), (v_t1, v_crm, 'verifycrm', 'k7', 'Other'),
           (v_t1, v_crm, 'verifycrm', 'k8', 'B2C'), (v_t1, v_crm, 'verifycrm', 'k9', null);
    insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id, amount_spent, amount_currency, source_created_at,
                                       crm_connection_id, crm_contact_source_id, matched_at)
    select v_t1, case x.store when 'nl' then v_nl else v_gb end, 'verifyshop', x.id, x.spent, x.cur, (x.created || ' 09:00+00')::timestamptz,
           case when x.contact is not null then v_crm end, x.contact, case when x.contact is not null then v_now end
    from (values ('nl', 'c1', 600, 'EUR', '2025-01-10', 'k1'), ('nl', 'c2', 300, 'EUR', '2025-03-05', 'k2'), ('nl', 'c3', 999, 'EUR', '2025-06-20', null),
                 ('nl', 'c4', 200, 'EUR', '2026-02-01', 'k4'), ('nl', 'c5', 100, 'EUR', '2026-10-20', 'k5'), ('nl', 'c6', 50, 'EUR', '2026-05-01', 'k8'),
                 ('nl', 'c7', 80, 'EUR', '2026-06-01', 'k9'), ('nl', 'cx', 70, 'EUR', '2025-01-01', null),
                 ('gb', 'g1', 500, 'GBP', '2025-02-15', 'k6'), ('gb', 'g2', 400, 'GBP', '2025-08-01', 'k7')) x(store, id, spent, cur, created, contact);
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, billing_interval, billing_interval_count,
                                  amount_per_cycle, currency, source_created_at, paused_at, canceled_at)
    select v_t1, case x.store when 'nl' then v_snl else v_sgb end, 'verifysubs', x.id, x.customer, x.status, x.unit, x.n, x.amount, x.cur,
           (x.created || ' 09:00+00')::timestamptz, (x.paused || ' 09:00+00')::timestamptz, (x.canceled || ' 09:00+00')::timestamptz
    from (values
      ('nl', 's1', 'c1', 'active', 'month', 1, 30, 'EUR', '2025-01-15', null, null),
      ('nl', 's2', 'c1', 'canceled', 'month', 1, 20, 'EUR', '2025-04-01', null, '2025-09-10'),
      ('nl', 's12', 'c1', 'active', 'month', 1, 10, 'EUR', '2025-02-01', null, '2025-06-01'),
      ('nl', 's16', 'c1', 'canceled', 'month', 1, 20, 'EUR', null, null, '2025-05-01'),
      ('nl', 's3', 'c2', 'canceled', 'month', 1, 20, 'EUR', '2025-03-10', null, '2025-07-20'),
      ('nl', 's4', 'c2', 'active', 'year', 1, 240, 'EUR', '2025-11-05', null, null),
      ('nl', 's11', 'c2', 'merged', 'month', 1, 20, 'EUR', '2025-01-01', null, null),
      ('nl', 's5', 'c3', 'paused', 'week', 4, 28, 'EUR', '2025-06-25', '2026-09-15', null),
      ('nl', 's8', 'c3', 'expired', 'month', 1, 20, 'EUR', '2024-12-01', null, null),
      ('nl', 's10', 'c4', 'expired', 'month', 1, 25, 'EUR', '2025-12-01', null, null),
      ('nl', 's6', 'c4', 'failed', 'month', 1, 25, 'EUR', '2026-02-03', null, null),
      ('nl', 's7', 'c5', 'active', 'day', 30, 15, 'EUR', '2026-10-21', null, null),
      ('nl', 's13', 'c6', 'active', 'month', 1, 12, 'EUR', '2026-05-02', null, null),
      ('nl', 's14', 'c7', 'active', 'month', 1, 14, 'EUR', '2026-06-02', null, null),
      ('nl', 's9', 'ghost', 'active', 'month', 1, 10, 'EUR', '2026-01-10', null, null),
      ('gb', 's20', 'g1', 'active', 'month', 1, 40, 'GBP', '2025-02-20', null, null),
      ('gb', 's21', 'g2', 'canceled', 'month', 1, 45, 'GBP', '2025-08-05', null, '2026-03-10'),
      ('gb', 's22', 'g2', 'active', 'month', 1, 50, 'GBP', '2026-03-10', null, null)
    ) x(store, id, customer, status, unit, n, amount, cur, created, paused, canceled);
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at, cycle_index,
                                        status_from, status_to)
    values (v_t1, v_snl, 'verifysubs', 'e1', 's10', 'status_changed', '2026-01-20 09:00+00', null, 'active', 'expired'),
           (v_t1, v_snl, 'verifysubs', 'e2', 's13', 'renewed', '2026-07-02 09:00+00', 2, null, null),
           (v_t1, v_snl, 'verifysubs', 'e3', 's13', 'renew_failed', '2026-11-02 09:00+00', 3, null, null),
           (v_t1, v_snl, 'verifysubs', 'e4', 's2', 'canceled', '2026-11-01 09:00+00', null, null, 'canceled'),
           (v_t1, v_snl, 'verifysubs', 'e5', 's1', 'renew_failed', '2026-03-15 09:00+00', 14, null, null),
           (v_t1, v_snl, 'verifysubs', 'e6', 's1', 'renewed', '2026-03-17 09:00+00', 14, null, null);
    insert into cma.device_status (tenant_id, key, name, is_in_field, is_in_stock) values (v_t1, 'v_field', 'In the field', true, false), (v_t1, 'v_stock', 'In stock', false, true);
    insert into cma.device_model (tenant_id, key, name) values (v_t1, 'vm1', 'Model one'), (v_t1, 'vm2', 'Model two');
    insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key, customer_ref, subscription_ref)
    values (v_t1, v_reg, 'verifyreg', 'd1', 'VSN-1', 'vm1', 'NL', 'v_field', 'c1', 's1'), (v_t1, v_reg, 'verifyreg', 'd2', 'VSN-2', 'vm1', 'NL', 'v_field', 'c1', 's12'),
           (v_t1, v_reg, 'verifyreg', 'd3', 'VSN-3', 'vm2', 'GB', 'v_field', 'g1', 's20'), (v_t1, v_reg, 'verifyreg', 'd4', 'VSN-4', 'vm1', 'NL', 'v_stock', 'c2', 's4');
    insert into cma.connection_pipeline (tenant_id, connection_id, record_type, source_pipeline_id, label, is_counted, is_lead, is_order)
    values (v_t1, v_crm, 'deal', 'v-leads', 'Verify leads', true, true, false), (v_t1, v_crm, 'deal', 'v-orders', 'Verify orders', true, false, true);
    insert into cma.connection_stage (tenant_id, connection_id, record_type, source_pipeline_id, source_stage_id, label, display_order, is_closed, outcome, outcome_source)
    values (v_t1, v_crm, 'deal', 'v-leads', 'l1', 'New', 1, false, null, null), (v_t1, v_crm, 'deal', 'v-orders', 'o8', 'Won', 8, true, 'won', 'person');
    insert into cma.commerce_order (tenant_id, connection_id, source_system, source_id, customer_source_id, source_created_at, is_test, currency, total_amount, order_kind)
    values (v_t1, v_nl, 'verifyshop', 'o2', 'c2', '2025-11-05 09:00+00', false, 'EUR', 100, 'first'),
           (v_t1, v_nl, 'verifyshop', 'o4', 'c4', '2026-02-03 09:00+00', false, 'EUR', 100, 'first'),
           (v_t1, v_nl, 'verifyshop', 'o5', 'c5', '2026-10-21 09:00+00', false, 'EUR', 100, 'repeat'),
           (v_t1, v_nl, 'verifyshop', 'o7', 'c7', '2026-06-06 09:00+00', false, 'EUR', 100, 'first');
    insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id, contact_source_id, is_closed,
                                source_created_at, amount, currency)
    values (v_t1, v_crm, 'verifycrm', 'deal', 'L2', 'v-leads', 'l1', 'k2', false, '2025-10-20 09:00+00', null, null),
           (v_t1, v_crm, 'verifycrm', 'deal', 'D2', 'v-orders', 'o8', 'k2', true, '2025-11-05 09:00+00', 100, 'EUR'),
           (v_t1, v_crm, 'verifycrm', 'deal', 'D4', 'v-orders', 'o8', 'k4', true, '2026-02-03 09:00+00', 100, 'EUR'),
           (v_t1, v_crm, 'verifycrm', 'deal', 'D5', 'v-orders', 'o8', 'k5', true, '2026-10-21 09:00+00', 100, 'EUR'),
           (v_t1, v_crm, 'verifycrm', 'deal', 'D7', 'v-orders', 'o8', 'k9', true, '2026-06-02 09:00+00', 100, 'EUR');

    j := cma.active_page_of(v_t1, null, null, null, null, 'month', v_now);

    -- B1 (A1). The headline equals Flash's, for every market and segment: the page under the filter against
    -- cma.flash_customer_figures_of's customers with a holding subscription and their holding subscriptions (a
    -- subscription whose customer the store does not hold counts under segment unknown in Total subscriptions alone),
    -- and against Flash's own figures (cma.flash_compute_of: Active customers per market and per market and segment,
    -- Total subscriptions per market)
    select count(*) filter (where q.page_customers is distinct from q.fig_customers + case when pg_temp.v0009l_p('B1') then 1 else 0 end
                               or q.page_subs is distinct from q.fig_subs
                               or (q.flash_customers is not null and q.page_customers is distinct from q.flash_customers)
                               or (q.flash_subs is not null and q.page_subs is distinct from q.flash_subs)),
           string_agg(format('%s/%s:%s,%s', coalesce(q.market, '*'), coalesce(q.segment, '*'), q.page_customers, q.page_subs), ' ' order by q.market nulls first, q.segment nulls first)
    into v_n, v_txt
    from (
      select m.market, s.segment,
             (p.j -> 'tiles' -> 'active_customers' ->> 'value')::bigint as page_customers,
             (p.j -> 'tiles' -> 'total_subscriptions' ->> 'value')::bigint as page_subs,
             (select count(*) from cma.flash_customer_figures_of(v_t1) f
              where f.holding_subscriptions > 0 and (m.market is null or f.market = m.market) and (s.segment is null or f.segment = s.segment)) as fig_customers,
             (select coalesce(sum(f.holding_subscriptions), 0) from cma.flash_customer_figures_of(v_t1) f
              where (m.market is null or f.market = m.market) and (s.segment is null or f.segment = s.segment))
             + case when s.segment is null or s.segment = 'unknown'
                    then (select count(*) from cma.flash_subscriptions_of(v_t1, (v_now at time zone 'Europe/Amsterdam')::date) x
                          where x.is_holding and (m.market is null or x.market = m.market)
                            and not exists (select 1 from cma.flash_customer_figures_of(v_t1) f
                                            where f.source_id = x.customer_source_id and f.store = x.store))
                    else 0 end as fig_subs,
             (select (c.measures ->> 'active_customers')::bigint from cma.flash_compute_of(v_t1, 'customers') c
              where c.dims = case when m.market is null and s.segment is null then '{}'::jsonb
                                  when s.segment is null then jsonb_build_object('market', m.market)
                                  when m.market is not null then jsonb_build_object('market', m.market, 'segment', s.segment) end) as flash_customers,
             case when s.segment is null
                  then (select (c.measures ->> 'holding_subscriptions')::bigint from cma.flash_compute_of(v_t1, 'subscriptions') c
                        where c.dims = case when m.market is null then '{}'::jsonb else jsonb_build_object('market', m.market) end) end as flash_subs
      from (values (null::text), ('NL'), ('GB')) m(market)
      cross join (values (null::text), ('B2B'), ('B2C'), ('unknown')) s(segment)
      cross join lateral (select cma.active_page_of(v_t1, null, m.market, s.segment, null, 'month', v_now) as j) p
    ) q;
    v_rows := v_rows || array['101', 'B1', '(A1) the live headline equals Flash''s Active customers and Total subscriptions for every market and segment',
      format('%s differ: %s', v_n, v_txt),
      '0 differ: */*:8,10 */B2B:2,3 */B2C:4,4 */unknown:2,3 GB/*:2,2 GB/B2B:0,0 GB/B2C:1,1 GB/unknown:1,1 NL/*:6,8 NL/B2B:2,3 NL/B2C:3,3 NL/unknown:1,2'];

    -- B2. the base's holding intervals, the Customer starts and the spells
    select string_agg(format('%s:%s%s%s %s-%s', b.source_id, case when b.is_holding then 'H' else '-' end, case when b.in_history then 'in' else 'out' end,
                             coalesce('(' || b.left_out || ')', ''), coalesce(to_char(b.started_at at time zone 'UTC', 'YYMMDD'), 'none'),
                             coalesce(to_char(b.ended_at at time zone 'UTC', 'YYMMDD'), case when b.is_holding then 'open' else 'none' end)),
                      ' ' order by length(b.source_id), b.source_id)
    into v_txt from cma.active_base_of(v_t1, v_now, false, null, false) b;
    select v_txt || ' | ' || string_agg(format('%s:%s/%s', c.source_id, to_char(c.customer_start at time zone 'UTC', 'YYMMDD'), c.age_months), ' ' order by c.source_id)
    into v_txt from cma.active_customers_of(v_t1, v_now, false) c;
    select v_txt || ' | ' || string_agg(format('%s:%s-%s', s.source_id, to_char(s.spell_start at time zone 'UTC', 'YYMMDD'), coalesce(to_char(s.spell_end at time zone 'UTC', 'YYMMDD'), 'open')),
                                         ' ' order by s.source_id, s.spell_start)
    into v_txt from cma.active_spells_of(v_t1) s;
    v_rows := v_rows || array['102', 'B2', 'the base: holding intervals (pause, reactivation, expiry by event, left out, merged absent), Customer starts and spells', v_txt,
      's1:Hin 250115-open s2:-in 250401-250910 s3:-in 250310-250720 s4:Hin 251105-open s5:-in 250625-260915 s6:Hin 260203-open s7:Hin 261021-open'
      || ' s8:-out(no_ended_time) 241201-none s9:Hin 260110-open s10:-in 251201-260120 s12:Hin 250201-open s13:Hin 260502-open s14:Hin 260602-open'
      || ' s16:-out(no_created_time) none-250501 s20:Hin 250220-open s21:-in 250805-260310 s22:Hin 260310-open'
      || ' | c1:250110/22 c2:250305/20 c3:241201/23 c4:251201/11 c5:261020/0 c6:260501/6 c7:260601/5 g1:250215/20 g2:250801/15'
      || ' | c1:250115-open c2:250310-250720 c2:251105-open c3:250625-260915 c4:251201-260120 c4:260203-open c5:261021-open c6:260502-open c7:260602-open'
      || ' g1:250220-open g2:250805-open'];

    -- B3 (A3). the month ends: customers +inflow -outflow /subscriptions, the net change identity, "now", the change lines
    select string_agg(format('%s:%s+%s-%s/%s%s', to_char(q.month, 'YYMM'), q.customers, q.inflow, q.outflow, q.subscriptions, case when q.is_now then 'now' else '' end),
                      ' ' order by q.month),
           count(*) filter (where q.net <> q.inflow - q.outflow or q.customers - q.before <> q.net)
    into v_txt, v_n
    from (select (m ->> 'month')::date as month, (m ->> 'customers')::numeric as customers, (m ->> 'inflow')::numeric as inflow, (m ->> 'outflow')::numeric as outflow,
                 (m ->> 'subscriptions')::numeric as subscriptions, (m ->> 'net')::numeric as net, (m ->> 'is_now')::boolean as is_now,
                 coalesce(lag((m ->> 'customers')::numeric) over (order by m ->> 'month'), 0) as before
          from jsonb_array_elements(j -> 'months') m) q;
    v_txt := v_txt || format(' | identity broken in %s months | prev %s/%s and %s/%s', v_n,
                             j -> 'tiles' -> 'active_customers' ->> 'prev_month', j -> 'tiles' -> 'active_customers' ->> 'prev_year',
                             j -> 'tiles' -> 'total_subscriptions' ->> 'prev_month', j -> 'tiles' -> 'total_subscriptions' ->> 'prev_year');
    v_rows := v_rows || array['103', 'B3', '(A3) the month ends, inflow and outflow; net change = month end - previous = inflow - outflow; now equals the headline', v_txt,
      '2501:1+1-0/1 2502:2+1-0/3 2503:3+1-0/4 2504:3+0-0/5 2505:3+0-0/5 2506:4+1-0/6 2507:3+0-1/5 2508:4+1-0/6 2509:4+0-0/5 2510:4+0-0/5 2511:5+1-0/6 2512:6+1-0/7'
      || ' 2601:5+0-1/7 2602:6+1-0/8 2603:6+0-0/8 2604:6+0-0/8 2605:7+1-0/9 2606:8+1-0/10 2607:8+0-0/10 2608:8+0-0/10 2609:7+0-1/9 2610:8+1-0/10 2611:8+0-0/10now'
      || ' | identity broken in 0 months | prev 8/4 and 10/5'];

    -- B4 (A4). the Monthly recurring amount: per currency, never one figure across currencies
    select string_agg(format('%s %s over %s = %s (prev %s/%s, average prev %s/%s)', a ->> 'currency', a ->> 'amount', a ->> 'customers', a ->> 'average', a ->> 'prev_month',
                             a ->> 'prev_year', a ->> 'average_prev_month', a ->> 'average_prev_year'), ' | ' order by a ->> 'currency')
    into v_txt from jsonb_array_elements(j -> 'tiles' -> 'amounts') a;
    v_txt := v_txt || format(' | eur %s | Oct 2025 %s | Oct 2026 %s | keys %s', coalesce(j -> 'tiles' ->> 'eur', 'none'),
                             (select m -> 'amounts' from jsonb_array_elements(j -> 'months') m where m ->> 'month' = '2025-10-01'),
                             (select m -> 'amounts' from jsonb_array_elements(j -> 'months') m where m ->> 'month' = '2026-10-01'),
                             (select string_agg(k, ',' order by k) from jsonb_object_keys(j -> 'tiles') k));
    v_rows := v_rows || array['104', 'B4', '(A4) the Monthly recurring amount per currency with its customers, average and month ends; no figure across currencies', v_txt,
      'EUR 111.22 over 6 = 18.54 (prev 111.22/70.44, average prev 18.54/35.22) | GBP 90.00 over 2 = 45.00 (prev 90.00/85.00, average prev 45.00/42.50)'
      || ' | eur none | Oct 2025 {"EUR": 70.44, "GBP": 85.00} | Oct 2026 {"EUR": 111.22, "GBP": 90.00}'
      || ' | keys active_customers,amounts,clv,customer_age,eur,lifetime,total_subscriptions'];

    -- B5 (A5). the customer cohorts by month and by quarter: started, then per age (3, 6, 12, 24, 36 months) still active and t/f for Mature
    select string_agg(format('%s:%s %s', to_char((c ->> 'cohort')::date, 'YYMM'), c ->> 'started',
                             (select string_agg((a ->> 'still_active') || left(a ->> 'mature', 1), '/' order by (a ->> 'age')::int) from jsonb_array_elements(c -> 'ages') a)),
                      ' ' order by c ->> 'cohort')
    into v_txt from jsonb_array_elements(j -> 'cohorts') c;
    j2 := cma.active_page_of(v_t1, null, null, null, null, 'quarter', v_now);
    select v_txt || ' || ' || string_agg(format('%s:%s %s', to_char((c ->> 'cohort')::date, 'YYMM'), c ->> 'started',
                             (select string_agg((a ->> 'still_active') || left(a ->> 'mature', 1), '/' order by (a ->> 'age')::int) from jsonb_array_elements(c -> 'ages') a)),
                      ' ' order by c ->> 'cohort')
    into v_txt from jsonb_array_elements(j2 -> 'cohorts') c;
    select v_txt || ' || ' || string_agg(format('%s:%s %s', s ->> 'value', s ->> 'started',
                             (select string_agg((a ->> 'started') || '>' || (a ->> 'still_active'), '/' order by (a ->> 'age')::int) from jsonb_array_elements(s -> 'ages') a)),
                      ' ' order by s ->> 'value')
    into v_txt from jsonb_array_elements(j -> 'cohort_splits' -> 'segment') s;
    j2 := cma.active_page_of(v_t1, date '2025-08-01', 'GB', null, null, 'month', v_now);
    v_txt := v_txt || format(' || dominant %s, GB from Aug 2025 %s', coalesce(j -> 'notes' ->> 'dominant_cohort', 'none'), j2 -> 'notes' ->> 'dominant_cohort');
    v_rows := v_rows || array['105', 'B5', '(A5) the customer cohorts by month and by quarter, the segments'' pooled retention, the dominant-cohort note', v_txt,
      '2412:1 0t/0t/1t/0f/0f 2501:1 1t/1t/1t/0f/0f 2502:1 1t/1t/1t/0f/0f 2503:1 1t/0t/1t/0f/0f 2508:1 1t/1t/1t/0f/0f 2512:1 1t/1t/0f/0f/0f 2605:1 1t/1t/0f/0f/0f'
      || ' 2606:1 1t/0f/0f/0f/0f 2610:1 0f/0f/0f/0f/0f'
      || ' || 2410:1 0t/0t/1t/0f/0f 2501:3 3t/2t/3t/0f/0f 2507:1 1t/1t/1t/0f/0f 2510:1 1t/1t/0f/0f/0f 2604:2 2t/1f/0f/0f/0f 2610:1 0f/0f/0f/0f/0f'
      || ' || B2B:2 1>1/1>1/1>1/0>0/0>0 B2C:4 4>4/4>3/2>2/0>0/0>0 unknown:3 3>2/2>1/2>2/0>0/0>0'
      || ' || dominant none, GB from Aug 2025 {"share": 1.0000, "cohort": "2025-08-01"}'];

    -- B6 (A6). the euro line: none while the rates are empty; none while a shown currency has no rate; with every rate, the
    -- total and the setting's date; under a filter that shows euros alone, the euros without any other rate
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := coalesce(j -> 'tiles' ->> 'eur', 'none');
    perform cma.set_tenant_setting('reports.fx_eur_rates', '{"as_of": "2026-11-01", "USD": 0.9}');
    j2 := cma.active_page_of(v_t1, null, null, null, null, 'month', v_now);
    j3 := cma.active_page_of(v_t1, null, 'NL', null, null, 'month', v_now);
    v_txt := v_txt || ' | ' || coalesce(j2 -> 'tiles' ->> 'eur', 'none') || ' | NL ' || (j3 -> 'tiles' -> 'eur' ->> 'amount') || ' of ' || (j3 -> 'tiles' -> 'eur' ->> 'as_of');
    perform cma.set_tenant_setting('reports.fx_eur_rates', '{"as_of": "2026-11-01", "GBP": 1.15}');
    j2 := cma.active_page_of(v_t1, null, null, null, null, 'month', v_now);
    v_txt := v_txt || format(' | %s of %s (prev %s/%s), now row %s, Oct 2025 row %s', j2 -> 'tiles' -> 'eur' ->> 'amount', j2 -> 'tiles' -> 'eur' ->> 'as_of',
                             j2 -> 'tiles' -> 'eur' ->> 'prev_month', j2 -> 'tiles' -> 'eur' ->> 'prev_year', j2 -> 'months' -> -1 ->> 'eur',
                             (select m ->> 'eur' from jsonb_array_elements(j2 -> 'months') m where m ->> 'month' = '2025-10-01'));
    perform cma.set_tenant_setting('reports.fx_eur_rates', '{}');
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['106', 'B6', '(A6) the euro line is absent unless every shown currency has a rate; with them, the total and the rates'' date', v_txt,
      'none | none | NL 111.22 of 2026-11-01 | 214.72 of 2026-11-01 (prev 214.72/168.19), now row 214.72, Oct 2025 row 168.19'];

    -- B7 (A7). the placeholders: a key and the status pending, nothing else; no number in a slot
    select string_agg((s ->> 'key') || ':' || (s ->> 'status'), ' ' order by ord) || ' | keys '
           || (select string_agg(distinct k, ',') from jsonb_array_elements(j -> 'unit_economics' -> 'slots') s2 cross join jsonb_object_keys(s2) k)
           || ' | ' || case when (j -> 'unit_economics' -> 'slots')::text ~ '[0-9]' then 'a digit in the slots' else 'no digit' end
           || ' | ' || (select string_agg(k, ',' order by k) from jsonb_object_keys(j -> 'unit_economics') k)
    into v_txt from jsonb_array_elements(j -> 'unit_economics' -> 'slots') with ordinality x(s, ord);
    v_rows := v_rows || array['107', 'B7', '(A7) the placeholders carry a key and the status pending, no figure', v_txt,
      'churn_rate:pending cac:pending cost_per_subscription:pending clv_projected:pending clv_to_cac:pending payback_months:pending | keys key,status | no digit | churned_30d,slots'];

    -- B8 (A8). tenant two sees nothing of tenant one (as its analyst, through the application's role and row-level
    -- security); an agent gets CMA06; a parameter out of its form CMA04; tenant two before its store was not set up
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_analyst2::text, true);
    j2 := cma.active_page();
    v_txt := format('not set up %s | two: figures %s, customers %s, subscriptions %s, months %s, list %s, rows visible %s/%s/%s', v_txt2, j2 ->> 'figures',
                    j2 -> 'tiles' -> 'active_customers' ->> 'value', j2 -> 'tiles' -> 'total_subscriptions' ->> 'value', jsonb_array_length(j2 -> 'months'),
                    cma.active_rows() ->> 'total', (select count(*) from cma.subscription), (select count(*) from cma.commerce_customer),
                    (select count(*) from cma.active_spells_of(v_t1)));
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := v_txt || ' | agent ' || pg_temp.v0009l_code('select cma.active_page()') || ' ' || pg_temp.v0009l_code('select cma.active_rows()')
             || ' ' || pg_temp.v0009l_code($q$select cma.active_file_record(null, null, null, 1)$q$);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := v_txt || ' | analyst ' || pg_temp.v0009l_code('select cma.active_page()') || ' ' || pg_temp.v0009l_code('select cma.active_rows()');
    v_txt := v_txt || ' | ' || (select string_agg(pg_temp.v0009l_code(q), ' ' order by o)
                                from unnest(array[$q$select cma.active_page(date '2026-11-02')$q$, $q$select cma.active_page(null, 'nl')$q$,
                                                  $q$select cma.active_page(null, null, 'a b')$q$, $q$select cma.active_page(null, null, null, 'assisted')$q$,
                                                  $q$select cma.active_page(null, null, null, null, 'week')$q$, $q$select cma.active_rows(p_sort => 'name')$q$,
                                                  $q$select cma.active_rows(p_limit => 201)$q$, $q$select cma.active_rows(p_offset => -1)$q$,
                                                  $q$select cma.active_file_record(null, null, null, -1)$q$]) with ordinality u(q, o));
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['108', 'B8', '(A8) the other tenant sees nothing; an agent gets CMA06; a parameter out of its form CMA04; no store: not set up', v_txt,
      'not set up false/false/false/false | two: figures true, customers 0, subscriptions 0, months 0, list 0, rows visible 0/0/0'
      || ' | agent CMA06 CMA06 CMA06 | analyst ok ok | CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04'];

    -- B9 (A9). the readers' views (as a reader of tenant one: app.tenant_id set) against the page read at the same instant
    perform set_config('app.tenant_id', v_t1::text, true);
    j2 := cma.active_page_of(v_t1, null, null, null, null, 'month', now());
    select count(*) into v_n
    from (select v.month, sum(v.active_customers) as customers, sum(v.holding_subscriptions) as subs, sum(v.inflow) as inflow, sum(v.outflow) as outflow
          from cma_read.active_customer_month v where v.tenant_id = v_t1 group by 1) v
    full join (select (m ->> 'month')::date as month, (m ->> 'customers')::numeric as customers, (m ->> 'subscriptions')::numeric as subs,
                      (m ->> 'inflow')::numeric as inflow, (m ->> 'outflow')::numeric as outflow
               from jsonb_array_elements(j2 -> 'months') m) p on p.month = v.month
    where v.customers is distinct from p.customers + case when pg_temp.v0009l_p('B9') then 1 else 0 end
       or v.subs is distinct from p.subs or v.inflow is distinct from p.inflow or v.outflow is distinct from p.outflow;
    select count(*) into v_m
    from (select v.cohort, v.age_months, sum(v.started) as started, sum(v.still_active) as still_active, bool_and(v.mature) as mature
          from cma_read.customer_cohort v where v.tenant_id = v_t1 and v."grouping" = 'month' group by 1, 2) v
    full join (select (c ->> 'cohort')::date as cohort, (a ->> 'age')::int as age_months, (c ->> 'started')::numeric as started,
                      (a ->> 'still_active')::numeric as still_active, (a ->> 'mature')::boolean as mature
               from jsonb_array_elements(j2 -> 'cohorts') c cross join jsonb_array_elements(c -> 'ages') a) p
      on p.cohort = v.cohort and p.age_months = v.age_months
    where v.started is distinct from p.started or v.still_active is distinct from p.still_active or v.mature is distinct from p.mature;
    select format('months differ %s, cohort rows differ %s; rows %s and %s; of another tenant %s; channels %s', v_n, v_m,
                  (select count(*) from cma_read.active_customer_month v where v.tenant_id = v_t1),
                  (select count(*) from cma_read.customer_cohort v where v.tenant_id = v_t1),
                  (select count(*) from cma_read.active_customer_month v where v.tenant_id <> v_t1),
                  (select string_agg(distinct v.acquisition_channel, ',') from cma_read.active_customer_month v where v.tenant_id = v_t1))
    into v_txt;
    v_rows := v_rows || array['109', 'B9', '(A9) cma_read.active_customer_month and cma_read.customer_cohort equal the page; a reader of one tenant sees it alone', v_txt,
      format('months differ 0, cohort rows differ 0; rows %s and %s; of another tenant 0; channels direct,indirect,unknown',
             (select count(*) from cma.active_months_of(v_t1, now())),
             (select count(*) from cma.active_cohorts_of(v_t1, 'month', now())) + (select count(*) from cma.active_cohorts_of(v_t1, 'quarter', now())))];

    -- B10 (A11). the channel equals First orders' attribution, row for row, for every customer whose first order First
    -- orders lists with its store order; the reasons by hand; attribution.assisted_levels without lead_deal moves c2 alone
    select count(*), count(*) filter (where ch.channel is distinct from case o.attribution when 'call_center' then case when pg_temp.v0009l_p('B10') then 'direct' else 'indirect' end
                                                                                          when 'self_service' then 'direct' end
                                         or ch.level is distinct from o.level)
    into v_n, v_m
    from cma.first_orders_of(v_t1, ((select h.history_start from cma.first_orders_history_start_of(v_t1) h)::timestamp at time zone 'Europe/Amsterdam'), now()) o
    join cma.commerce_order co on co.tenant_id = v_t1 and co.id = o.order_id
    join cma.commerce_customer cu on cu.tenant_id = v_t1 and cu.connection_id = co.connection_id and cu.source_id = co.customer_source_id
    left join cma.active_channel_of(v_t1) ch on ch.customer_id = cu.id
    where o.kind = 'first';
    select format('history from %s; %s first orders with a store order, %s differ | ', (select h.history_start from cma.first_orders_history_start_of(v_t1) h), v_n, v_m)
           || string_agg(format('%s:%s/%s', c.source_id, c.channel, coalesce(c.level, c.unknown_reason)), ' ' order by c.source_id)
    into v_txt from cma.active_channel_of(v_t1) c;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('attribution.assisted_levels', 'conversation,email,phone_match');
    select v_txt || ' | without lead_deal: ' || string_agg(format('%s:%s/%s', c.source_id, c.channel, coalesce(c.level, c.unknown_reason)), ' ' order by c.source_id)
    into v_txt from cma.active_channel_of(v_t1) c;
    perform cma.set_tenant_setting('attribution.assisted_levels', 'lead_deal,conversation,email,phone_match');
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' | note ' || (j -> 'notes' ->> 'unknown_channel') || ' split ' || (j -> 'tiles' -> 'active_customers' ->> 'by_channel');
    v_rows := v_rows || array['110', 'B10', '(A11) the channel equals First orders'' attribution row for row; the Unknown reasons; assisted_levels moves one customer', v_txt,
      'history from 2025-11-05; 2 first orders with a store order, 0 differ | c1:unknown/before_history c2:indirect/lead_deal c3:unknown/no_contact c4:direct/self_service'
      || ' c5:unknown/no_first_order c6:unknown/no_order_deal c7:unknown/order_not_matched g1:unknown/before_history g2:unknown/before_history'
      || ' | without lead_deal: c1:unknown/before_history c2:direct/lead_deal c3:unknown/no_contact c4:direct/self_service'
      || ' c5:unknown/no_first_order c6:unknown/no_order_deal c7:unknown/order_not_matched g1:unknown/before_history g2:unknown/before_history'
      || ' | note {"reasons": {"no_order_deal": 1, "before_history": 3, "no_first_order": 1, "order_not_matched": 1}, "customers": 6}'
      || ' split {"direct": 1, "unknown": 6, "indirect": 1}'];

    -- B11 (A12). survival: over all eleven spells (lengths 21, 4 ended, 12, 14 ended, 1 ended, 9, 0, 20, 15, 6, 5): events at 1
    -- (10 at risk: 0.9), at 4 (9 at risk: 0.8) and at 14 (4 at risk: 0.6): never at or below 0.5, the longest 21; B2B (21, 0)
    -- no event; B2C (4 ended, 12, 1 ended, 9, 6, 20): 5/6 then 2/3; unknown (14 ended, 5, 15): 0.5 at 14, the median
    select format('all %s spells %s ended, longest %s, median %s; ', j -> 'survival' -> 'all' ->> 'spells', j -> 'survival' -> 'all' ->> 'ended',
                  j -> 'survival' -> 'all' ->> 'longest', coalesce(j -> 'survival' -> 'all' ->> 'median', 'not reached'))
           || (select string_agg(format('%s:%s/%s/%s', p ->> 'age', p ->> 'at_risk', p ->> 'events', round((p ->> 'survival')::numeric, 4)), ' ' order by (p ->> 'age')::int)
               from jsonb_array_elements(j -> 'survival' -> 'all' -> 'curve') p where (p ->> 'events')::int > 0 or (p ->> 'age')::int in (0, 12, 21))
           || ' | ' || (select string_agg(format('%s %s spells median %s longest %s at 12 %s', s ->> 'value', s ->> 'spells', coalesce(s ->> 'median', 'not reached'), s ->> 'longest',
                                                 (select round((p ->> 'retained')::numeric, 4) from jsonb_array_elements(s -> 'curve') p where (p ->> 'age')::int = 12)), '; ' order by ord)
                        from jsonb_array_elements(j -> 'survival' -> 'segment') with ordinality x(s, ord))
           || ' | ' || (select string_agg(format('%s %s', s ->> 'value', s ->> 'spells'), '; ' order by ord)
                        from jsonb_array_elements(j -> 'survival' -> 'channel') with ordinality x(s, ord))
           || ' | function ' || (select string_agg(distinct format('%s:%s/%s', k.split_value, coalesce(k.median_months::text, 'not reached'), k.longest_months), ' ')
                                 from cma.active_survival_of(v_t1, 'segment') k)
    into v_txt;
    v_rows := v_rows || array['111', 'B11', '(A12) the survival curves over all spells, per segment and per channel; a median reached and "not reached"', v_txt,
      'all 11 spells 3 ended, longest 21, median not reached; 0:11/0/1.0000 1:10/1/0.9000 4:9/1/0.8000 12:5/0/0.8000 14:4/1/0.6000 21:1/0/0.6000'
      || ' | B2B 2 spells median not reached longest 21 at 12 1.0000; B2C 6 spells median not reached longest 20 at 12 0.6667; unknown 3 spells median 14 longest 15 at 12 1.0000'
      || ' | indirect 2; direct 2; unknown 7 | function B2B:not reached/21 B2C:not reached/20 unknown:14/15'];

    -- B12 (A13). the comparison B2B against B2C with unknown beside: a | b | unknown | difference | ratio
    select (j -> 'comparison' ->> 'a') || ' vs ' || (j -> 'comparison' ->> 'b') || ': '
           || string_agg(format('%s%s%s %s|%s|%s d %s r %s', x ->> 'measure', coalesce(' ' || (x ->> 'months'), ''), coalesce(' ' || (x ->> 'currency'), ''),
                                coalesce(x ->> 'a', '-'), coalesce(x ->> 'b', '-'), coalesce(x ->> 'unknown', '-'), coalesce(x ->> 'difference', '-'), coalesce(x ->> 'ratio', '-')),
                         '; ' order by ord)
    into v_txt from jsonb_array_elements(j -> 'comparison' -> 'rows') with ordinality q(x, ord);
    v_rows := v_rows || array['112', 'B12', '(A13) the comparison: values, differences and ratios; a currency on one side only gives neither; unknown beside', v_txt,
      'B2B vs B2C: customers 2|4|2 d -2 r 0.50; share 0.2500|0.5000|0.2500 d -0.2500 r 0.50; lifetime_median -|-|14 d - r -'
      || '; retention 12 1.000000|0.666667|1.000000 d 0.333333 r 1.50; retention 24 -|-|- d - r -; retention 36 -|-|- d - r -'
      || '; median_age 11.0|15.5|10.0 d -4.5 r 0.71; clv_average EUR 350.00|183.33|80.00 d 166.67 r 1.91; clv_average GBP -|500.00|400.00 d - r -'
      || '; clv_median EUR 350.00|200.00|80.00 d 150.00 r 1.75; clv_median GBP -|500.00|400.00 d - r -'
      || '; clv_per_month EUR 63.64|13.84|16.00 d 49.80 r 4.60; clv_per_month GBP -|25.00|26.67 d - r -'
      || '; average_monthly_amount EUR 27.61|10.67|24.00 d 16.94 r 2.59; average_monthly_amount GBP -|40.00|50.00 d - r -'
      || '; subscriptions_per_customer 1.50|1.00|1.00 d 0.50 r 1.50; devices_per_customer 1.00|0.50|0.00 d 0.50 r 2.00; indirect_share -|0.5000|- d - r -'];

    -- B13 (A14). each filter's values add up to the unfiltered totals: customers, subscriptions, the amounts per currency
    select string_agg(format('%s %s=%s %s=%s %s=%s %s=%s', f.dim, f.customers, (j -> 'tiles' -> 'active_customers' ->> 'value'),
                             f.subs + case when pg_temp.v0009l_p('B13') then 1 else 0 end, (j -> 'tiles' -> 'total_subscriptions' ->> 'value'),
                             f.eur, (select a ->> 'amount' from jsonb_array_elements(j -> 'tiles' -> 'amounts') a where a ->> 'currency' = 'EUR'),
                             f.gbp, (select a ->> 'amount' from jsonb_array_elements(j -> 'tiles' -> 'amounts') a where a ->> 'currency' = 'GBP')), ' | ' order by f.dim)
    into v_txt
    from (select x.dim, sum((p.j -> 'tiles' -> 'active_customers' ->> 'value')::numeric) as customers,
                 sum((p.j -> 'tiles' -> 'total_subscriptions' ->> 'value')::numeric) as subs,
                 sum(coalesce((select (a ->> 'amount')::numeric from jsonb_array_elements(p.j -> 'tiles' -> 'amounts') a where a ->> 'currency' = 'EUR'), 0)) as eur,
                 sum(coalesce((select (a ->> 'amount')::numeric from jsonb_array_elements(p.j -> 'tiles' -> 'amounts') a where a ->> 'currency' = 'GBP'), 0)) as gbp
          from (values ('channel', 'indirect'), ('channel', 'direct'), ('channel', 'unknown'), ('segment', 'B2B'), ('segment', 'B2C'), ('segment', 'unknown'),
                       ('market', 'NL'), ('market', 'GB')) x(dim, v)
          cross join lateral (select cma.active_page_of(v_t1, null, case when x.dim = 'market' then x.v end, case when x.dim = 'segment' then x.v end,
                                                        case when x.dim = 'channel' then x.v end, 'month', v_now) as j) p
          group by x.dim) f;
    v_rows := v_rows || array['113', 'B13', '(A14) the channel filter''s three values, the segments and the markets each add up to the unfiltered totals', v_txt,
      'channel 8=8 10=10 111.22=111.22 90.00=90.00 | market 8=8 10=10 111.22=111.22 90.00=90.00 | segment 8=8 10=10 111.22=111.22 90.00=90.00'];

    -- B14. the rest of the page
    select format('split %s %s | status %s | age %s over %s prev %s/%s | clv %s | lifetime %s',
                  j -> 'tiles' -> 'active_customers' ->> 'by_segment', j -> 'tiles' -> 'active_customers' ->> 'by_channel',
                  j -> 'tiles' -> 'total_subscriptions' ->> 'by_status', j -> 'tiles' -> 'customer_age' ->> 'median',
                  (select string_agg(format('%s:%s/%s', o ->> 'months', o ->> 'customers', o ->> 'share'), ',' order by (o ->> 'months')::int)
                   from jsonb_array_elements(j -> 'tiles' -> 'customer_age' -> 'over') o),
                  j -> 'tiles' -> 'customer_age' ->> 'prev_month', j -> 'tiles' -> 'customer_age' ->> 'prev_year',
                  (select string_agg(format('%s %s/%s/%s/%s', e.key, e.value ->> 'customers', e.value ->> 'average', e.value ->> 'median', e.value ->> 'per_month'), ', ' order by e.key)
                   from jsonb_each(j -> 'tiles' -> 'clv') e),
                  j -> 'tiles' ->> 'lifetime')
           || ' | bands ' || (select string_agg(format('%s:%s', b ->> 'band', b ->> 'customers'), ' ' order by ord) from jsonb_array_elements(j -> 'age_bands') with ordinality x(b, ord))
           || ' | markets ' || (select string_agg(format('%s %s/%s/%s/%s/%s age %s churn %s net %s ind %s %s spark %s', m ->> 'market', m ->> 'customers', m ->> 'share',
                                                         m ->> 'subscriptions', m ->> 'devices', m ->> 'amounts', m ->> 'median_age', m ->> 'churned_30d', m ->> 'net_30d',
                                                         coalesce(m ->> 'indirect_share', '-'), m ->> 'by_segment', m ->> 'spark'), ' ; ' order by ord)
                                from jsonb_array_elements(j -> 'markets') with ordinality x(m, ord))
           || format(' ; total %s/%s/%s/%s age %s churn %s net %s ind %s', j -> 'markets_total' ->> 'customers', j -> 'markets_total' ->> 'share',
                     j -> 'markets_total' ->> 'subscriptions', j -> 'markets_total' ->> 'devices', j -> 'markets_total' ->> 'median_age', j -> 'markets_total' ->> 'churned_30d',
                     j -> 'markets_total' ->> 'net_30d', j -> 'markets_total' ->> 'indirect_share')
           || ' | mix ' || (select string_agg(e.key || ' ' || (select string_agg(format('%s:%s', x ->> 'key', coalesce(x ->> 'subscriptions', x ->> 'devices')), ',' order by ord)
                                                                from jsonb_array_elements(e.value) with ordinality y(x, ord)), ' ; ' order by e.key)
                            from jsonb_each(j -> 'mix') e)
           || ' | payment states differ ' || (select count(*) from cma.active_base_of(v_t1, v_now, false, null, true) b
                                              full join cma.subscription_payment_state_of(v_t1) p on p.subscription_id = b.subscription_id
                                              where b.payment_state is distinct from p.payment_state)
           || ' | churn ' || (j -> 'unit_economics' ->> 'churned_30d') || '=' || (select count(*) from cma.flash_churn_of(v_t1, date '2026-10-13', date '2026-11-11'))
           || ' | notes ' || ((j -> 'notes') - 'unknown_channel')::text
    into v_txt;
    v_rows := v_rows || array['114', 'B14', 'the split lines, customer age, age bands, markets with totals, the subscription mix, payment states, churn, the notes', v_txt,
      'split {"B2B": 2, "B2C": 4, "unknown": 2} {"direct": 1, "unknown": 6, "indirect": 1} | status {"active": 9, "failed": 1}'
      || ' | age 13.0 over 12:4/0.5000,24:0/0.0000,36:0/0.0000 prev 12.0/8.5'
      || ' | clv EUR 6/221.67/150.00/30.80, GBP 2/450.00/450.00/25.83 | lifetime {"ended": 3, "median": null, "spells": 11, "longest": 21}'
      || ' | bands <12:4 12-24:4 24-36:0 36-48:0 48-60:0 60+:0'
      || ' | markets NL 6/0.7500/8/3/{"EUR": {"amount": 111.22, "average": 18.54, "customers": 6}} age 8.5 churn 1 net 1 ind 0.5000 {"B2B": 2, "B2C": 3, "unknown": 1}'
      || ' spark [3, 4, 3, 4, 4, 4, 5, 6, 6, 6, 5, 6, 6]'
      || ' ; GB 2/0.2500/2/1/{"GBP": {"amount": 90.00, "average": 45.00, "customers": 2}} age 17.5 churn 0 net 0 ind - {"B2C": 1, "unknown": 1}'
      || ' spark [2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2]'
      || ' ; total 8/1/10/4 age 13.0 churn 1 net 1 ind 0.5000'
      || ' | mix billing monthly:8,yearly:1,other:1 ; device_band 0:7,1:3,2:0,3+:0 ; model vm1:2,vm2:1 ; payment_state paid:8,in_retry:1,failed:1,paused:1'
      || ' | payment states differ 0 | churn 1=1'
      || ' | notes {"no_amount": 0, "no_ended_time": 1, "history_starts": [{"date": "2024-12-01", "store": "v-nl", "market": "NL"}, {"date": "2025-02-20", "store": "v-gb", "market": "GB"}],'
      || ' "dominant_cohort": null, "no_created_time": 1, "reconstruction_gap": 0, "unmatched_subscriptions": 1}'];

    -- B15. the list: keys, order (the amount within its currency, the customers without a paying amount last), the worst
    -- payment state, the contact's link, paging, the cap, the file and its record
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_analyst1::text, true);
    j2 := cma.active_rows_of(v_t1, null, null, null, 'monthly_amount', true, 0, 50, v_now);
    select format('total %s: ', j2 ->> 'total')
           || string_agg(format('%s %s %s %s/%s %s%s %s %s %s/%s %s/%s %s', x ->> 'store_customer', x ->> 'market', x ->> 'segment', x ->> 'customer_start', x ->> 'age_months',
                                coalesce(x ->> 'monthly_amount', '-'), coalesce(x ->> 'currency', ''), x ->> 'subscriptions', x ->> 'devices', x ->> 'clv', x ->> 'clv_currency',
                                x ->> 'channel', coalesce(x ->> 'level', '-'), x ->> 'payment_state'), '; ' order by ord)
           || ' | keys ' || (select string_agg(distinct k, ',') from jsonb_array_elements(j2 -> 'rows') x2 cross join jsonb_object_keys(x2) k)
           || ' | link ' || (j2 -> 'rows' -> 0 ->> 'contact_id') || ' ' || (j2 -> 'rows' -> 0 ->> 'contact_url')
    into v_txt from jsonb_array_elements(j2 -> 'rows') with ordinality q(x, ord);
    v_txt := v_txt || ' | page ' || (select string_agg(x ->> 'store_customer', ',' order by ord)
                                     from jsonb_array_elements(cma.active_rows_of(v_t1, null, null, null, 'monthly_amount', true, 2, 3, v_now) -> 'rows') with ordinality q(x, ord))
             || ' | by id ' || (select string_agg(x ->> 'store_customer', ',' order by ord)
                                from jsonb_array_elements(cma.active_rows(p_sort => 'store_customer', p_descending => false) -> 'rows') with ordinality q(x, ord))
             || ' | B2C ' || (cma.active_rows('NL', 'B2C') ->> 'total') || ' indirect ' || (cma.active_rows(p_channel => 'indirect') ->> 'total')
             || ' | file ' || jsonb_array_length(cma.active_rows(p_file => true) -> 'rows');
    perform cma.active_file_record('NL', null, 'unknown', 4);
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' | record ' || (select a.new_row::text || (a.actor_user_id = v_analyst1)::text from cma.audit_log a
                                       where a.tenant_id = v_t1 and a.table_name = 'active_file' order by a.changed_at desc limit 1);
    v_rows := v_rows || array['115', 'B15', 'the list: its keys, order, worst payment state, link, paging, filters, the file and its audit record', v_txt,
      'total 8: c1 NL B2B 2025-01-10/22 40.00EUR 2 2 600.00/EUR unknown/- paid; c2 NL B2C 2025-03-05/20 20.00EUR 1 1 300.00/EUR indirect/lead_deal paid'
      || '; c5 NL B2B 2026-10-20/0 15.22EUR 1 0 100.00/EUR unknown/- paid; c7 NL unknown 2026-06-01/5 14.00EUR 1 0 80.00/EUR unknown/- paid'
      || '; c6 NL B2C 2026-05-01/6 12.00EUR 1 0 50.00/EUR unknown/- in_retry; g2 GB unknown 2025-08-01/15 50.00GBP 1 0 400.00/GBP unknown/- paid'
      || '; g1 GB B2C 2025-02-15/20 40.00GBP 1 1 500.00/GBP unknown/- paid; c4 NL B2C 2025-12-01/11 - 1 0 200.00/EUR direct/self_service failed'
      || ' | keys age_months,channel,clv,clv_currency,contact_id,contact_url,currency,customer_start,devices,level,market,monthly_amount,other_amounts,payment_state,segment,store,store_customer,subscriptions'
      || ' | link k1 https://crm.example.invalid/portal-1/contact/k1 | page c5,c7,c6 | by id c1,c2,c4,c5,c6,c7,g1,g2 | B2C 3 indirect 1 | file 8'
      || ' | record {"rows": 4, "market": "NL", "channel": "unknown"}true'];

    -- B16. the settings: out of range refused (CMA04), a list kept without spaces, the rates in jsonb's own form
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_admin1::text, true);
    select string_agg(pg_temp.v0009l_code(q), ' ' order by o) into v_txt
    from unnest(array[$q$select cma.set_tenant_setting('customers.cohort_ages_months', '3,2')$q$, $q$select cma.set_tenant_setting('customers.cohort_ages_months', '1,2,3,4,5,6,7,8,9')$q$,
                      $q$select cma.set_tenant_setting('customers.cohort_ages_months', '3,121')$q$, $q$select cma.set_tenant_setting('customers.cohort_ages_months', '')$q$,
                      $q$select cma.set_tenant_setting('customers.age_months', '0,12')$q$, $q$select cma.set_tenant_setting('customers.age_months', '12,12')$q$,
                      $q$select cma.set_tenant_setting('customers.history_months', '11')$q$, $q$select cma.set_tenant_setting('customers.history_months', '121')$q$,
                      $q$select cma.set_tenant_setting('customers.history_months', '-24')$q$, $q$select cma.set_tenant_setting('reports.fx_eur_rates', '{"GBP": 1.15}')$q$,
                      $q$select cma.set_tenant_setting('reports.fx_eur_rates', 'GBP=1.15')$q$]) with ordinality u(q, o);
    perform cma.set_tenant_setting('customers.cohort_ages_months', ' 3, 6 ');
    perform cma.set_tenant_setting('customers.age_months', '6, 12');
    perform cma.set_tenant_setting('customers.history_months', '12');
    perform cma.set_tenant_setting('reports.fx_eur_rates', '{ "GBP":1.15,"as_of":"2026-11-01" }');
    j2 := cma.active_page_of(v_t1, null, null, null, null, 'month', v_now);
    v_txt := v_txt || format(' | %s | %s | %s | %s | page ages %s bands %s from %s first month %s over %s', cma.setting_of(v_t1, 'customers.cohort_ages_months'),
                             cma.setting_of(v_t1, 'customers.age_months'), cma.setting_of(v_t1, 'customers.history_months'), cma.setting_of(v_t1, 'reports.fx_eur_rates'),
                             j2 -> 'settings' ->> 'cohort_ages_months', j2 -> 'settings' ->> 'age_months', j2 ->> 'from_month', j2 -> 'months' -> 0 ->> 'month',
                             (select string_agg(o ->> 'months', ',' order by (o ->> 'months')::int) from jsonb_array_elements(j2 -> 'tiles' -> 'customer_age' -> 'over') o));
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['116', 'B16', 'the settings: out of range refused (CMA04), lists kept without spaces, the rates in jsonb''s form, the page follows them', v_txt,
      'CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 | 3,6 | 6,12 | 12 | {"GBP": 1.15, "as_of": "2026-11-01"}'
      || ' | page ages [3, 6] bands [6, 12] from 2025-11-01 first month 2025-11-01 over 6,12'];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then
      v_rows := v_rows || array['149', 'B', 'ran to the end', 'yes', 'yes'];
    when others then
      v_rows := v_rows || array['149', 'B', 'ran to the end', sqlerrm, 'yes'];
  end;
  perform set_config('role', 'cma_owner', true);
  perform pg_temp.v0009l_row(v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3], v_rows[i + 4])
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 5) as i;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- N. The stored Flash snapshots beside the reconstruction (a notice, never a failure)
-- ---------------------------------------------------------------------------------------------
-- Per tenant with a stored snapshot of the customers' totals on a month's last day, of the current definition: the
-- snapshot's Active customers beside the reconstructed month end. A difference is expected where a subscription was
-- paused at the time (the reconstruction counts a past pause as holding), where one has no Ended time, and where a
-- customer or a subscription has left the store's or the subscription app's full read since
do $$
declare
  t record;
  v_txt text;
  v_any boolean := false;
begin
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug loop
    select string_agg(format('%s: snapshot %s, reconstructed %s (%s)', s.snapshot_date, s.snap, coalesce(m.n, 0),
                             to_char(coalesce(m.n, 0) - s.snap, 'SG999999990')), '; ' order by s.snapshot_date)
    into v_txt
    from (select f.snapshot_date, (f.measures ->> 'active_customers')::numeric as snap
          from cma.flash_snapshot f
          where f.tenant_id = t.id and f.overview = 'customers' and f.dims = '{}'::jsonb
            and f.definition_version = cma.flash_definition_version('customers')
            and f.snapshot_date = (date_trunc('month', f.snapshot_date) + interval '1 month - 1 day')::date
            and f.measures ? 'active_customers') s
    left join (select r.month, sum(r.active_customers) as n from cma.active_months_of(t.id, now()) r group by 1) m
      on m.month = date_trunc('month', s.snapshot_date)::date;
    if v_txt is not null then
      v_any := true;
      insert into pg_temp.verify_0009l values (200, 'N1 (A10) ' || t.slug || ': stored month-end snapshots beside the reconstructed month ends', 'info', left(v_txt, 1500));
    end if;
  end loop;
  if not v_any then
    insert into pg_temp.verify_0009l values (200, 'N1 (A10) stored month-end snapshots beside the reconstructed month ends', 'info',
                                             'no tenant holds a month-end snapshot of the customers'' totals in the current definition yet');
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- E. Timings against 131's budgets, as the application
-- ---------------------------------------------------------------------------------------------
-- Per active tenant with a subscription: the page's read and the list's first page, each called six times untimed (a
-- plpgsql function's statements turn to the generic plan after five calls on a connection: CLAUDE.md, Performance) and
-- then timed, the best of verify.timing_runs
do $$
declare
  t record;
  v_runs integer := current_setting('verify.timing_runs')::integer;
  v_t0 timestamptz; v_ms numeric; v_page numeric; v_list numeric;
  v_any boolean := false;
  j jsonb;
begin
  for t in select x.id, x.slug from cma.tenant x
           where x.status = 'active' and exists (select 1 from cma.subscription s where s.tenant_id = x.id) order by x.slug loop
    v_any := true;
    v_page := null; v_list := null;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', t.id::text, true);
    for i in 1 .. 6 + v_runs loop
      v_t0 := clock_timestamp();
      j := cma.active_page_of(t.id, null, null, null, null, 'month', now());
      v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
      if i > 6 then v_page := least(coalesce(v_page, v_ms), v_ms); end if;
      v_t0 := clock_timestamp();
      j := cma.active_rows_of(t.id, null, null, null, 'monthly_amount', true, 0, 50, now());
      v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
      if i > 6 then v_list := least(coalesce(v_list, v_ms), v_ms); end if;
    end loop;
    perform set_config('role', 'cma_owner', true);
    insert into pg_temp.verify_0009l values (301, 'E1 ' || t.slug || ': the page''s read within the overview budget',
      case when v_page <= case when pg_temp.v0009l_p('E1') then 0 else current_setting('verify.max_overview_ms')::numeric end then 'PASS' else 'FAIL' end,
      format('%s ms (best of %s, after six calls) against %s ms', v_page, v_runs, case when pg_temp.v0009l_p('E1') then '0' else current_setting('verify.max_overview_ms') end));
    insert into pg_temp.verify_0009l values (302, 'E2 ' || t.slug || ': the list''s first page within the list budget',
      case when v_list <= case when pg_temp.v0009l_p('E2') then 0 else current_setting('verify.max_list_ms')::numeric end then 'PASS' else 'FAIL' end,
      format('%s ms (best of %s, after six calls) against %s ms', v_list, v_runs, case when pg_temp.v0009l_p('E2') then '0' else current_setting('verify.max_list_ms') end));
  end loop;
  if not v_any then
    insert into pg_temp.verify_0009l values (301, 'E1, E2 the page and the list within their budgets',
      case when current_setting('verify.provoke') in ('true', 'E1', 'E2') then 'FAIL' else 'skip' end, 'no active tenant holds a subscription');
  end if;
end
$$;

drop function if exists pg_temp.v0009l_code(text);
drop function if exists pg_temp.v0009l_row(integer, text, text, text, text);
drop function if exists pg_temp.v0009l_p(text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009l
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke') <> 'false' then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009l where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009l where result = 'PASS') then 'FAIL'
                  else 'PASS' end,
             format('173_verify_active_customers: %s PASS, %s FAIL, %s info, %s skip', (select count(*) from pg_temp.verify_0009l where result = 'PASS'),
                    (select count(*) from pg_temp.verify_0009l where result = 'FAIL'), (select count(*) from pg_temp.verify_0009l where result = 'info'),
                    (select count(*) from pg_temp.verify_0009l where result = 'skip'))) x
order by ord;
drop table if exists pg_temp.verify_0009l;
reset role;
