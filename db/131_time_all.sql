-- =============================================================================================
-- 131_time_all.sql: every read a page, poll or report makes, timed on the database's own data, read only (night N06)
-- =============================================================================================
-- 124_time_flash.sql generalised to the whole Workspace: times every database read the web makes for a page, a poll or
-- a report, on the data the database holds, as the application (cma_app, row-level security on), per active tenant,
-- acting as the tenant's first active person holding the read's permission (kind person, the oldest; a read without such
-- a person reads skip). Each read is the best of two runs, every row fetched, except a poll's (below); a page then gets
-- one row that sums its reads (the sum is a ceiling: the web runs a page's reads in parallel). No addition, no write: the reads run in a
-- read-only subtransaction that is rolled back (its rows kept in variables), so the script runs alike as one transaction
-- (Cloud SQL Studio) and statement by statement (psql), in any database, at any time, as often as wanted. Run as your
-- own IAM login after 128_sources_last_read.sql (0008zq) and, since addition 0008zv (the identity read names
-- cma.organisation.is_contact_center), after 140_live_per_organisation.sql; since addition 0008zw (Reviews' period All),
-- after 142_reviews_all_order_kinds.sql; since addition 0009a (Customers → Courtesy), after 150_courtesy.sql; since
-- addition 0009e (the installed base's first paint from a stored current take), after 158_flash_current_take.sql; since
-- addition 0009j (Assets → Pledge lists), after 168_pledge_lists.sql; since addition 0009l (Customers → Active), after
-- 172_active_customers.sql; since addition 0009m (the quiet run of its refresh), after 174_active_refresh_quiet.sql;
-- since addition 0009p (the Flash landing's stored cards), after 180_flash_stored_cards.sql; since addition 0009r (the
-- customer list under a device band), after 184_active_device_bands.sql; since addition 0009t (Assets -> Fleet
-- management), after 188_fleet_management.sql; since addition 0009u (Welcome's Waiting for you reads
-- cma.my_follow_up_counts(); the follow-up's report lists and /me/follow-up's rows, whose clock fields it derives at the
-- read, are timed too), after 190_follow_up_clock_at_read.sql; since addition 0009v (Assets -> Fleet management's page in one read),
-- after 192_fleet_page.sql; since addition 0009ze (the subscription facts' refresh and the variant mapping's list, timed
-- where 210_subscription_facts.sql has run, skip before; since addition 0009zf, 212, the refresh's budget is 10,000 ms
-- until prod's runs set it, and its answer names each step's milliseconds; since addition 0009zg the source figures' due
-- check, part a, and their comparison of today under Data quality, outside its set, both skip before
-- 214_source_figures.sql; since addition 0009zm Maintenance's read is the page's form with the debt status filter, its
-- default unpaused, and its device list, the installed base's records under a debt status filter and its measure
-- under_debt_status are timed, each skipping before 226_device_debt_status.sql). Prod is the proof; dev's shared core is for
-- information. The pledge reads need pledges.view, which no default role holds: in a tenant where no person holds it they
-- read skip, as any read without such a person. A per-person read (email, orders, attempts and deals per person) needs
-- performance.team and the tenant's reports.per_person holding its key (cma.assert_per_person): while the key is off the
-- web makes no such read (Email per agent, Orders per person and Attempts per agent answer 404, Funnel leaves out its
-- per-person section), so the read reads skip with that reason, and so does its page's set when the page has no other
-- read (Funnel's set sums its own two), where they read FAIL with CMA06 before (backlog CMA-102 point 1, 15 November
-- 2026; prod's pulse4all-subscriptions holds email only).
-- The statements are the web's own (web/src/lib/data/postgres.ts), with the parameters the pages pass by default:
-- flows over the tenant's previous calendar month, and again over the last 92 days (the longest period a report takes);
-- stocks at now; a list's first page as the page asks it; ids, codes and milliseconds only in the output.
-- Unlike 124 the timed part is not set read only: two of the web's reads write as they read (cma.my_messages marks the
-- messages it lists delivered, the follow-up's reads compute a missing snapshot once), and a read-only transaction
-- refuses them (25006) even when they change no row. The subtransaction is always rolled back instead, and the first
-- row proves it: the timed part sets app.actor_label to 'time-0131' and, after its rollback, no audit row carries that
-- label (a count over this session's own writes, so other sessions' writes meanwhile do not disturb it).
-- Budgets (verify.max_*_ms below; Decision log, 5 November 2026, night N06): a poll 20 ms; a read of an agent page or
-- the Live board 50 ms and the page's set 100 ms; a list's first page 300 ms; an overview, a landing or a report core
-- 500 ms and a page's set 500 ms; Sources 150 ms; data quality's overview and first page 500 ms (on stored results since
-- addition 0008zr). 124's budgets (800, 1,500, 2,500 ms) stay as they are for Flash's own verify; this script holds the
-- tighter ones, so a read that holds 124's and misses these reads FAIL here, as intended.
-- Within Studio's 300 seconds: the script stops starting reads after verify.time_budget_s (240 s); a read it did not
-- reach reads FAIL ("not timed"). One run of everything does not fit the window at three times prod's volume locally
-- (the night's before run: the 92-day reads were not reached), so verify.part splits it: 'a' (the polls, the agent
-- pages, the Live board, Team, Roster, Follow-up, Sources, System health, Data quality, the Flash landing, Campaigns),
-- 'b' (the report cores over the previous month), 'c' (the report cores over the last 92 days); 'all' runs the three
-- in one go where the window allows it. The morning runbook runs a, b and c as three Studio runs. Since addition 0009zb
-- (after 204_subscription_audit.sql) 'audit' times the subscription audit alone, once per tenant as its owner, for
-- information (no budget: Martin runs the audit by hand, never a page or a job; a database without 204 reads skip, an
-- error FAIL); 'all' leaves it out, as it would take a large share of Studio's window. Its verdict is INFO without a FAIL.
-- A read that raises an error reads FAIL with its SQLSTATE and the others still run, except an error a read names as
-- nothing to time: an as-of read whose date has no snapshot (CMA02) reads skip with that reason, and its page's set too
-- (Martin, 6 November 2026; Decision log). A page's set sums the reads the reader waits for first: a Flash overview loads
-- in two parts since addition 0008zy (the document, then its records streamed after the first paint), so the Installed
-- base pages' sets are the document against verify.max_overview_ms, and their records read keeps its own list row.
-- Since addition 0009f Assets -> Installed base reads its lists on demand (a page of 50 records, the devices past due, the
-- devices without a subscription reference, the serial search): each is a list row of the page, outside its set.
-- Since addition 0009e the Installed base's document now is read from its stored current take: in part a each tenant's
-- current takes are taken again first under its scheduler user (every overview of its setting, forced, by the owner's
-- writer; inside the timed part, so rolled back with it), and the document's row times the stored read the page
-- makes whenever the snapshot job keeps the take fresh. Since addition 0009p that refresh is a timed row of its own
-- against verify.max_takes_ms (six takes by default, where it was one). A take that cannot be made (a source not set up, an error)
-- leaves the live read, timed as it is.
-- A poll's row (class poll; since 16 November 2026, Martin's brief on 131's poll timings) is the median of
-- verify.poll_runs runs after verify.poll_warmup untimed ones (5 after 6), not the best of two: a poll runs every few
-- seconds on a connection the pool keeps, so it pays neither a session's first calls (its plans built, its functions'
-- statements planned with each call's values) nor a single fast run, and it does pay the generic plan a plpgsql
-- function's statements turn to after five calls on a connection (CLAUDE.md, Performance). The best of a fresh session's
-- first two calls measured the first and missed the last: in prod on 14 November it read team now 61.2 ms, inbound now
-- 35.7 ms and the board's calls 31.0 ms, where tools/perf/live-poll-breakdown.sql read the same functions at medians of
-- 4 to 9 ms after six calls on 16 November (first calls 10 to 20 ms); locally a fresh session's second call of
-- cma.roster_today() took 9.7 ms against 2.4 ms from the third on. Most of that Saturday's gap was the instance itself
-- (183's E3, warmed, read cma.inbound_now() at 20.1 ms then with 18 callers listed, against 4.0 ms on Monday with 20; prod is one
-- vCPU shared with the minute jobs), which no method removes: a run at such a moment still reads FAIL, as it should.
-- The row's detail also gives the first untimed run (what a new connection pays after a deploy) and the worst timed one
-- (a minute job's contention), for information; the verdict is the median's. The rows before 16 November 2026 are the
-- best of two: the series breaks there, a change of method, not of speed.
-- Provoke: set verify.provoke below to true; every budget is then 0 ms, every timed read FAILs, and the verdict says
-- PROVOKED, NOT A PASS.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0008zq') then
    raise exception 'addition 0008zq (128_sources_last_read.sql) has not run in this database';
  end if;
  -- the identity read names cma.organisation.is_contact_center since addition 0008zv
  if not exists (select 1 from cma.schema_migration where version = '0008zv') then
    raise exception 'addition 0008zv (140_live_per_organisation.sql) has not run in this database';
  end if;
  -- Reviews' period All (the read without a start, by month) since addition 0008zw
  if not exists (select 1 from cma.schema_migration where version = '0008zw') then
    raise exception 'addition 0008zw (142_reviews_all_order_kinds.sql) has not run in this database';
  end if;
  -- Customers → Courtesy (cma.courtesy_page) since addition 0009a
  if not exists (select 1 from cma.schema_migration where version = '0009a') then
    raise exception 'addition 0009a (150_courtesy.sql) has not run in this database';
  end if;
  -- the installed base's current take (cma.flash_current_refresh) since addition 0009e
  if not exists (select 1 from cma.schema_migration where version = '0009e') then
    raise exception 'addition 0009e (158_flash_current_take.sql) has not run in this database';
  end if;
  -- Assets → Pledge lists (cma.pledge_page, cma.pledge_file) since addition 0009j
  if not exists (select 1 from cma.schema_migration where version = '0009j') then
    raise exception 'addition 0009j (168_pledge_lists.sql) has not run in this database';
  end if;
  -- Customers → Active (cma.active_top, cma.active_now, cma.active_rest, cma.active_rows, cma.active_refresh_of) since addition 0009l
  if not exists (select 1 from cma.schema_migration where version = '0009l') then
    raise exception 'addition 0009l (172_active_customers.sql) has not run in this database';
  end if;
  -- the refresh's quiet run and its inputs' markers (cma.active_inputs_key_of) since addition 0009m
  if not exists (select 1 from cma.schema_migration where version = '0009m') then
    raise exception 'addition 0009m (174_active_refresh_quiet.sql) has not run in this database';
  end if;
  -- the Flash landing's stored cards (cma.flash_cards_now) since addition 0009p
  if not exists (select 1 from cma.schema_migration where version = '0009p') then
    raise exception 'addition 0009p (180_flash_stored_cards.sql) has not run in this database';
  end if;
  -- the customer list under a band of Devices per active customer (cma.active_rows' band) since addition 0009r
  if not exists (select 1 from cma.schema_migration where version = '0009r') then
    raise exception 'addition 0009r (184_active_device_bands.sql) has not run in this database';
  end if;
  -- Assets -> Fleet management's two reads since addition 0009t
  if not exists (select 1 from cma.schema_migration where version = '0009t') then
    raise exception 'addition 0009t (188_fleet_management.sql) has not run in this database';
  end if;
  -- Welcome's Waiting for you reads cma.my_follow_up_counts() since addition 0009u
  if not exists (select 1 from cma.schema_migration where version = '0009u') then
    raise exception 'addition 0009u (190_follow_up_clock_at_read.sql) has not run in this database';
  end if;
  -- Assets -> Fleet management's page in one read (cma.fleet_page) since addition 0009v
  if not exists (select 1 from cma.schema_migration where version = '0009v') then
    raise exception 'addition 0009v (192_fleet_page.sql) has not run in this database';
  end if;
end
$$;
select set_config('verify.provoke', 'false', false);                 -- 'true' to make every timed read fail
select set_config('verify.part', 'all', false);                      -- 'a', 'b', 'c', 'all' or 'audit' (0009zb, the subscription audit alone)
select set_config('verify.max_poll_ms', '20', false);                -- a poll (unread count, team now, inbound now, shifts today, the identity)
select set_config('verify.max_agent_ms', '50', false);               -- one read of an agent page or the Live board
select set_config('verify.max_agent_set_ms', '100', false);          -- an agent page's or the Live board's reads together
select set_config('verify.max_list_ms', '300', false);               -- a list's first page
select set_config('verify.max_overview_ms', '500', false);           -- an overview, a landing, a report core, a page's reads together
select set_config('verify.max_sources_ms', '150', false);            -- cma.sources()
select set_config('verify.max_dq_ms', '500', false);                 -- data quality's overview and first page
select set_config('verify.max_top_ms', '400', false);                -- Customers → Active: the live present of the tiles, and above the fold computed (decisions D15, D16)
select set_config('verify.max_refresh_ms', '15000', false);          -- the refresh of Customers → Active's stored take, the history and the documents written again
select set_config('verify.max_markers_ms', '300', false);            -- the inputs' change markers of Customers → Active's take, read by the job's every due run (addition 0009m)
select set_config('verify.max_facts_ms', '10000', false);            -- the subscription facts' refresh, forced: every take computed again (addition 0009ze, brief B39c C.9). Since 0009zf (Martin, 21 November 2026: 10,000 ms until prod's runs set it): prod read 10,156 ms that day and 7 to 9 s is expected after 212, so a run that gained nothing reads FAIL; set from prod's runs after 212 (PROD_RUNBOOK 21.7 and 21.9)
select set_config('verify.max_takes_ms', '5000', false);             -- the refresh of Flash's current takes, every overview of the tenant's setting (0009p; to confirm from prod's first runs)
select set_config('verify.time_budget_s', '240', false);             -- stop starting reads after this, inside Studio's 300 s
select set_config('verify.poll_warmup', '6', false);                 -- a poll's untimed runs first (the plans a pooled connection keeps)
select set_config('verify.poll_runs', '5', false);                   -- then its timed runs; the row is their median

drop table if exists pg_temp.time_0131;
create temporary table time_0131 (ord integer, check_name text, result text, detail text, ms numeric);

-- The fastest of p_runs runs of a read, in milliseconds, every row fetched; -1 when the read raises an error, its
-- SQLSTATE then in t0131.error (a subtransaction of its own, so the run goes on)
create or replace function pg_temp.t0131_best_ms(p_sql text, p_runs integer)
returns numeric
language plpgsql
as $$
declare
  v_t0 timestamptz; v_ms numeric; v_best numeric; r record;
begin
  perform set_config('t0131.error', '', true);
  perform set_config('t0131.error_message', '', true);
  begin
    for i in 1 .. p_runs loop
      v_t0 := clock_timestamp();
      for r in execute p_sql loop
        null;
      end loop;
      v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
      v_best := least(coalesce(v_best, v_ms), v_ms);
    end loop;
  exception when others then
    perform set_config('t0131.error', sqlstate, true);
    perform set_config('t0131.error_message', left(sqlerrm, 80), true);
    return -1;
  end;
  return v_best;
end
$$;

-- A poll's time (class poll): p_warmup untimed runs, then the median of p_runs timed runs, in milliseconds, every row
-- fetched, as t0131_best_ms otherwise (-1 on an error, its SQLSTATE in t0131.error). The same session, role, tenant and
-- person as every other read; only the runs differ, so the row times the plans a pooled connection runs the poll with
create or replace function pg_temp.t0131_poll_ms(p_sql text, p_warmup integer, p_runs integer)
returns numeric
language plpgsql
as $$
declare
  v_t0 timestamptz; a numeric[] := '{}'; r record; v_ms numeric;
  v_warmup integer := greatest(0, coalesce(p_warmup, 0));
  v_runs integer := greatest(1, coalesce(p_runs, 1));          -- at least one timed run, whatever the setting says
begin
  perform set_config('t0131.error', '', true);
  perform set_config('t0131.error_message', '', true);
  perform set_config('t0131.poll_first', '', true);
  begin
    for i in 1 .. v_warmup + v_runs loop
      v_t0 := clock_timestamp();
      for r in execute p_sql loop
        null;
      end loop;
      v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
      if i = 1 then
        perform set_config('t0131.poll_first', v_ms::text, true);
      end if;
      if i > v_warmup then
        a := a || v_ms;
      end if;
    end loop;
    perform set_config('t0131.poll_worst', (select max(x) from unnest(a) x)::text, true);
  exception when others then
    perform set_config('t0131.error', sqlstate, true);
    perform set_config('t0131.error_message', left(sqlerrm, 80), true);
    return -1;
  end;
  return (select percentile_disc(0.5) within group (order by x) from unnest(a) x);
end
$$;

-- The tenant's first active person (the oldest) holding any of the permissions ('*': anyone with a role), as the owner
create or replace function pg_temp.t0131_user(p_tenant uuid, p_perms text[])
returns uuid
language sql
as $$
  select u.id
  from cma.app_user u
  where u.tenant_id = p_tenant and u.status = 'active' and u.kind = 'person'
    and exists (select 1 from cma.user_role ur where ur.tenant_id = u.tenant_id and ur.user_id = u.id)
    and (p_perms = array['*'] or exists (select 1 from unnest(p_perms) p where cma.has_permission(u.id, p)))
  order by u.created_at, u.id
  limit 1
$$;

-- The reads, in the pages' order: part, page, name, the statement (with {from} {to} the previous month, {from92} {to92}
-- the last 92 days, {today}, {monday} this week's Monday, {month} this month's first day, {conn} the tenant's first
-- active connection, {sys} and {ext} the acting person's first external id), the budget class, the permissions
drop table if exists pg_temp.reads_0131;
create temporary table reads_0131 (ord serial, part text, page text, name text, sql text, cls text, perms text[],
                                   skip_state text, skip_why text, in_set boolean not null default true, per_person text);
insert into pg_temp.reads_0131 (part, page, name, sql, cls, perms) values
-- polls
('a', 'polls', 'identity principal', $q$select u.id, u.display_name, t.name, coalesce(o.name, ''), cma.user_timezone(u.id),
   (select r.key from cma.user_role ur join cma.app_role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
     where ur.tenant_id = u.tenant_id and ur.user_id = u.id order by ur.granted_at, r.key limit 1),
   array(select p from cma.user_permissions(u.id) p order by 1),
   (select string_to_array(nullif(s.value, ''), ',') from cma.tenant_settings() s where s.key = 'reports.per_person'),
   coalesce((select json_agg(json_build_object('key', c.key, 'name', c.name) order by c.name, c.key) from cma.organisation c
     where c.tenant_id = u.tenant_id and c.is_contact_center and c.status = 'active'), '[]'::json)
   from cma.app_user_external_id x join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
   join cma.tenant t on t.id = u.tenant_id left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
   where x.tenant_id = cma.current_tenant_id() and x.system = '{sys}' and x.external_id = '{ext}' and u.status = 'active'$q$, 'poll', array['*']),
('a', 'polls', 'messages poll (since now)', $q$select (select count(*) from cma.my_messages(now(), 200)), cma.my_unread_count()$q$, 'poll', array['*']),
('a', 'polls', 'team now', $q$select n.*, cma.business_day_end(n.business_date, n.timezone) as day_ends_at,
   coalesce(se.sessions, 0)::int as sessions, se.session_started_at,
   (select coalesce(cma.setting_of(cma.current_tenant_id(), 'workday.clock_in_again') = 'true', false)) as clock_in_again,
   cma.workday_can_clock_in_again(n.workday_id) as can_clock_in_again
   from cma.team_now() n left join lateral (select count(*) as sessions, max(e.occurred_at) as session_started_at
   from cma.time_event_effective e where e.workday_id = n.workday_id and e.kind = 'start') se on true$q$, 'poll', array['monitoring.live']),
('a', 'polls', 'work status flags', $q$select is_working, is_productive, is_paid from cma.work_status where status = 'active' order by sort_order, key$q$, 'poll', array['monitoring.live']),
('a', 'polls', 'inbound today', $q$select * from cma.inbound_today()$q$, 'poll', array['monitoring.live']),
('a', 'polls', 'missed callbacks', $q$select m.*, cma.record_url(m.connection_id, 'call', m.source_id) as record_url from cma.missed_callbacks() m$q$, 'poll', array['monitoring.live']),
('a', 'polls', 'missed callbacks summary', $q$select * from cma.missed_callbacks_summary()$q$, 'poll', array['monitoring.live']),
('a', 'polls', 'inbound now (one statement)', $q$select cma.inbound_now()$q$, 'poll', array['monitoring.live']),
('a', 'polls', 'outbound now', $q$select cma.outbound_now()$q$, 'poll', array['monitoring.live']),
('a', 'polls', 'live board calls (one statement)', $q$select cma.inbound_now() as j, cma.outbound_now() as o$q$, 'poll', array['monitoring.live']),
-- Inbound today by hour, the Live board's chart (10 November 2026): Reports → Inbound's read for today, once a minute per open board
('a', 'polls', 'inbound today by hour (the board chart)', $q$select * from cma.inbound_service('{today}', '{today}', 'hour')$q$, 'poll', array['reports.view', 'performance.team']),
('a', 'polls', 'shifts today', $q$select * from cma.roster_today()$q$, 'poll', array['monitoring.live']),
-- agent pages
('a', 'welcome agent', 'own day today', $q$select s.business_date, s.status, s.started_at, s.ended_at, ws.key, ws.name, coalesce(c.closed_seconds, 0)::int, c.running_since, c.status_since,
   cma.business_day_end(s.business_date, s.timezone), coalesce(se.sessions, 0)::int, se.session_started_at,
   (select coalesce(cma.setting_of(cma.current_tenant_id(), 'workday.clock_in_again') = 'true', false)), cma.workday_can_clock_in_again(s.workday_id)
   from cma.workday_summary s left join cma.work_status ws on ws.tenant_id = cma.current_tenant_id() and ws.id = s.current_status_id
   left join lateral (select sum(i.seconds) filter (where iws.is_working and (not i.is_open or i.is_capped)) as closed_seconds,
     max(i.from_at) filter (where iws.is_working and i.is_open and not i.is_capped) as running_since,
     max(i.from_at) filter (where i.is_open and not i.is_capped) as status_since
     from cma.time_interval i join cma.work_status iws on iws.tenant_id = cma.current_tenant_id() and iws.id = i.status_id where i.workday_id = s.workday_id) c on true
   left join lateral (select count(*) as sessions, max(e.occurred_at) as session_started_at from cma.time_event_effective e where e.workday_id = s.workday_id and e.kind = 'start') se on true
   where s.user_id = cma.current_user_id() and s.business_date = cma.business_date(now(), cma.user_timezone(cma.current_user_id()))$q$, 'agent', array['workday.own']),
('a', 'welcome agent', 'statuses', $q$select key, name, is_working, is_productive, is_default from cma.work_status where tenant_id = cma.current_tenant_id() and status = 'active' order by sort_order, key$q$, 'agent', array['workday.own']),
('a', 'welcome agent', 'app links', $q$select key, label, address from cma.app_links()$q$, 'agent', array['*']),
('a', 'welcome agent', 'my roster today', $q$select * from cma.my_roster('{today}', '{today}')$q$, 'agent', array['roster.view']),
('a', 'welcome agent', 'updates (5 messages)', $q$select (select count(*) from cma.my_messages(null, 5)), cma.my_unread_count()$q$, 'agent', array['*']),
-- Waiting for you reads the three counts since addition 0009u (cma.my_follow_up_counts); the rows are /me/follow-up's
('a', 'welcome agent', 'waiting for you', $q$select * from cma.my_follow_up_counts()$q$, 'agent', array['leads.accept', 'workday.own']),
('a', 'my follow-up', 'my rows', $q$select cma.my_follow_up()$q$, 'agent', array['leads.accept', 'workday.own']),
('a', 'welcome manager', 'team hours 31 days', $q$select t.* from cma.team_hours(date '{today}' - 31, date '{today}' - 1, null) t order by t.business_date, t.display_name, t.user_id$q$, 'agent', array['workday.team']),
('a', 'welcome manager', 'follow-up summary', $q$select * from cma.follow_up_summary()$q$, 'agent', array['monitoring.live', 'performance.team', 'workday.team']),
('a', 'welcome admin', 'roles', $q$select * from cma.roles()$q$, 'agent', array['users.manage_all']),
('a', 'my hours', 'own days 7 days', $q$select s.business_date, s.status, s.started_at, s.ended_at, s.working_seconds,
   coalesce((select sum(i.seconds) from cma.time_interval i join cma.work_status ws on ws.tenant_id = cma.current_tenant_id() and ws.id = i.status_id
     where i.workday_id = s.workday_id and not ws.is_working), 0)::bigint,
   s.sessions
   from cma.workday_summary s where s.user_id = cma.current_user_id() and s.business_date between date '{today}' - 6 and '{today}' order by s.business_date$q$, 'agent', array['workday.own']),
('a', 'my schedule', 'my roster week', $q$select * from cma.my_roster('{monday}', date '{monday}' + 6)$q$, 'agent', array['roster.view']),
('a', 'messages', 'inbox (50 messages)', $q$select (select count(*) from cma.my_messages(null, 50)), cma.my_unread_count()$q$, 'agent', array['*']),
('a', 'my account', 'my profile', $q$select * from cma.my_profile()$q$, 'agent', array['*']),
-- the Live board
('a', 'live board', 'team members now', $q$select * from cma.team_members_now()$q$, 'agent', array['monitoring.live']),
('a', 'live board', 'tenant settings', $q$select * from cma.tenant_settings()$q$, 'agent', array['monitoring.live']),
-- Team, Roster, Follow-up
('a', 'team people', 'directory', $q$select * from cma.directory()$q$, 'agent', array['users.manage_agents', 'users.manage_all']),
('a', 'team people', 'teams', $q$select * from cma.teams()$q$, 'agent', array['users.manage_agents', 'users.manage_all']),
('a', 'team people', 'skills', $q$select * from cma.skills()$q$, 'agent', array['users.manage_agents', 'users.manage_all']),
('a', 'team people', 'organisations', $q$select * from cma.organisations()$q$, 'agent', array['users.manage_agents', 'users.manage_all']),
('a', 'team people', 'linked accounts', $q$select * from cma.linked_account_systems(), cma.linked_accounts()$q$, 'agent', array['users.manage_agents', 'users.manage_all']),
('a', 'team people', 'invitations', $q$select * from cma.invitations()$q$, 'agent', array['users.manage_agents', 'users.manage_all']),
('a', 'team hours', 'team people', $q$select * from cma.team_people()$q$, 'agent', array['workday.team']),
('a', 'team hours', 'team hours 7 days', $q$select t.* from cma.team_hours(date '{today}' - 6, '{today}', null) t order by t.business_date, t.display_name, t.user_id$q$, 'agent', array['workday.team']),
('a', 'roster week', 'roster week', $q$select * from cma.roster_week('{monday}', null)$q$, 'agent', array['roster.manage']),
('a', 'roster week', 'roster people', $q$select * from cma.roster_people('{monday}', null)$q$, 'agent', array['roster.manage']),
('a', 'roster week', 'roster entries', $q$select * from cma.roster_entries('{monday}', null)$q$, 'agent', array['roster.manage']),
('a', 'roster week', 'roster coverage', $q$select * from cma.roster_coverage('{monday}', null)$q$, 'agent', array['roster.manage']),
('a', 'roster week', 'roster weeks around', $q$select * from cma.roster_weeks(null, date '{monday}' - 84, date '{monday}' + 90)$q$, 'agent', array['roster.manage']),
('a', 'roster week', 'absence types', $q$select * from cma.absence_types()$q$, 'agent', array['roster.manage']),
('a', 'follow-up', 'follow-up page with callbacks', $q$select cma.follow_up_page(null, null, null, null) as j,
   (select coalesce(json_agg(r order by r.ordinality), '[]'::json) from cma.callbacks_kept_report(date '{today}' - 55, '{today}') with ordinality r) as callback_rows,
   cma.callbacks_kept_connected() as callbacks_connected,
   array(select s.value from cma.tenant_settings() s where s.key = 'tasks.callback_window_minutes') as callback_window,
   (select coalesce(json_agg(o order by o.ordinality), '[]'::json) from cma.callbacks_kept_per_owner(date '{today}' - 55, '{today}') with ordinality o) as callback_owners$q$, 'overview', array['performance.team']),
-- the follow-up's report lists, every row (GET /api/v1/reports/follow-up/leads and /tickets; since addition 0009u each
-- row's clock fields are derived at the read, so they are timed here)
('a', 'follow-up lists', 'open leads, every row', $q$select r.*, u.display_name as owner_name, cma.record_url(r.connection_id, 'deal', r.deal_source_id) as record_url from cma.open_leads() r left join cma.app_user u on u.tenant_id = r.tenant_id and u.id = r.owner_user_id$q$, 'overview', array['reports.view', 'performance.team', 'monitoring.live']),
('a', 'follow-up lists', 'open tickets, every row', $q$select r.*, u.display_name as owner_name, cma.record_url(r.connection_id, 'ticket', r.ticket_source_id) as record_url from cma.open_tickets() r left join cma.app_user u on u.tenant_id = r.tenant_id and u.id = r.owner_user_id$q$, 'overview', array['reports.view', 'performance.team', 'monitoring.live']),
-- Sources, a connection's page, System health
('a', 'sources', 'sources', $q$select * from cma.sources()$q$, 'sources', array['tenant.configure']),
('a', 'sources', 'form categories', $q$select * from cma.form_categories()$q$, 'agent', array['tenant.configure']),
('a', 'sources', 'record kinds', $q$select * from cma.record_kinds()$q$, 'agent', array['tenant.configure']),
('a', 'connection page', 'the connection', $q$select * from cma.sources() where connection_id = '{conn}'$q$, 'sources', array['tenant.configure']),
('a', 'connection page', 'connection config', $q$select cma.connection_config('{conn}')$q$, 'agent', array['tenant.configure']),
('a', 'connection page', 'connection catalogs', $q$select cma.connection_catalogs('{conn}')$q$, 'agent', array['tenant.configure']),
('a', 'connection page', 'pipeline response times', $q$select record_type, source_pipeline_id, sla_minutes from cma.connection_pipeline where connection_id = '{conn}'$q$, 'agent', array['tenant.configure']),
('a', 'connection page', 'reads', $q$select * from cma.source_reads('{conn}')$q$, 'agent', array['tenant.configure']),
('a', 'connection page', 'markets, hours, holidays', $q$select (select count(*) from cma.markets_all()), (select count(*) from cma.business_hours_all()), (select count(*) from cma.business_holidays_all())$q$, 'agent', array['tenant.configure']),
('a', 'system health', 'storage round trip', $q$select 1$q$, 'poll', array['tenant.configure']),
('a', 'system health', 'system health runs', $q$select * from cma.system_health_runs()$q$, 'overview', array['tenant.configure']),
('a', 'system health', 'outbox status', $q$select * from cma.outbox_status()$q$, 'overview', array['tenant.configure']),
-- Data quality
('a', 'data quality', 'data quality checks', $q$select * from cma.data_quality()$q$, 'dq', array['reports.view', 'tenant.configure']),
('a', 'data quality', 'outbox late', $q$select count(*)::integer from cma.outbox_action o join cma.integration_connection c on c.tenant_id = o.tenant_id and c.id = o.connection_id and c.status = 'active'
   where o.tenant_id = cma.current_tenant_id() and o.status in ('pending', 'failed', 'in_flight') and o.next_attempt_at < now() - make_interval(mins => 10)$q$, 'agent', array['reports.view', 'tenant.configure']),
('a', 'data quality', 'flash data quality overview', $q$select cma.flash_overview('data_quality', null, null, null, null)$q$, 'dq', array['reports.view', 'performance.team', 'tenant.configure']),
('a', 'data quality', 'flash data quality first page', $q$select cma.flash_rows('data_quality', '{}', 'check', true, 500, 0, null, null, null)$q$, 'dq', array['reports.view', 'performance.team', 'tenant.configure']),
('a', 'data quality', 'source figures compared today', $q$select * from cma.source_figure_compare_of(cma.current_tenant_id(), '{today}'::date)$q$, 'dq', array['reports.view', 'tenant.configure']),
-- Flash
('a', 'flash', 'landing', $q$select cma.flash_page(null, null, '{from}', '{to}')$q$, 'overview', array['reports.view', 'performance.team']),
('a', 'flash', 'snapshots', $q$select cma.flash_snapshots(null, null)$q$, 'agent', array['reports.view', 'performance.team']),
-- The landing's cards (addition 0009p): the stock overviews' figures from their stored current takes in one read (the
-- takes are refreshed before the reads, above), and the cards the page still reads live, each its own read: the four
-- flows over today and data quality's own stored result
('a', 'flash', 'cards now (the stored cards)', $q$select cma.flash_cards_now(null)$q$, 'agent', array['reports.view', 'performance.team']),
('a', 'flash', 'headline churn today', $q$select cma.flash_headline('churn', null, '{today}', '{today}')$q$, 'agent', array['reports.view', 'performance.team']),
('a', 'flash', 'headline orders today', $q$select cma.flash_headline('orders', null, '{today}', '{today}')$q$, 'agent', array['reports.view', 'performance.team']),
('a', 'flash', 'headline payments today', $q$select cma.flash_headline('payments', null, '{today}', '{today}')$q$, 'agent', array['reports.view', 'performance.team']),
('a', 'flash', 'headline reviews today', $q$select cma.flash_headline('reviews', null, '{today}', '{today}')$q$, 'agent', array['reports.view', 'performance.team']),
('a', 'flash', 'headline data quality', $q$select cma.flash_headline('data_quality', null, null, null)$q$, 'agent', array['reports.view', 'performance.team']),
-- Reviews' period All (addition 0008zw): every counted review from the tenant's first to today by month, no cap and no
-- previous period; the same read whatever the report period, so it is timed once, in part a
('a', 'reviews all', 'reviews all by month', $q$select cma.reviews_page(null, '{today}', null, 'month')$q$, 'overview', array['reports.view', 'performance.team']),
-- Installed base (addition 0008zy; Flash's overview and Assets -> Installed base): the page's two reads apart, the document
-- (totals, per market, the breakdown sets) and the first page of records, now and as of the previous month end (the
-- stored document and the month end's frozen list; where that date has no snapshot both raise CMA02 and read skip, below).
-- The set is the document alone, the first paint; the records stream after it and keep their list row (below). Now's
-- document is the stored current take's since addition 0009e (refreshed first, above the reads)
('a', 'installed base', 'document now (the current take)', $q$select cma.flash_overview('installed_base', null, null, null, null)$q$, 'overview', array['reports.view', 'performance.team']),
('a', 'installed base', 'records first page live', $q$select cma.flash_rows('installed_base', '{}', 'serial', false, 500, 0, null, null, null)$q$, 'list', array['reports.view', 'performance.team']),
-- Assets -> Installed base's own lists (addition 0009f): a page of 50 records, the devices past due, the devices in the field
-- without a subscription reference (the list's own filter), and the serial search (one serial of the tenant's register, the
-- list's own filter serial), each read on demand after the first paint
('a', 'installed base', 'records page of 50 live', $q$select cma.flash_rows('installed_base', '{}', 'serial', false, 50, 0, null, null, null)$q$, 'list', array['reports.view', 'performance.team']),
('a', 'installed base', 'devices past due page of 50', $q$select cma.flash_rows('installed_base', '{"measure": "components_past_due"}', 'serial', false, 50, 0, null, null, null)$q$, 'list', array['reports.view', 'performance.team']),
('a', 'installed base', 'without subscription reference page of 50', $q$select cma.flash_rows('installed_base', '{"without_subscription_ref": "true"}', 'serial', false, 50, 0, null, null, null)$q$, 'list', array['reports.view', 'performance.team']),
('a', 'installed base', 'serial search', $q$select cma.flash_rows('installed_base', jsonb_build_object('serial', coalesce((select d.serial from cma.device d where d.serial is not null order by d.id limit 1), 'none')), 'serial', false, 50, 0, null, null, null)$q$, 'list', array['reports.view', 'performance.team']),
('a', 'installed base as of month end', 'document as of the month end', $q$select cma.flash_overview('installed_base', null, '{to}', null, null)$q$, 'overview', array['reports.view', 'performance.team']),
('a', 'installed base as of month end', 'frozen list first page', $q$select cma.flash_rows('installed_base', '{}', null, false, 500, 0, '{to}', null, null)$q$, 'list', array['reports.view', 'performance.team']),
-- Assets -> Fleet management: since addition 0009v the page makes one read (cma.fleet_page: the tiles, the areas and the
-- list of the devices that need attention, page 1, from one computation of the devices); the list's further pages read
-- cma.fleet_rows after the first paint (a set of its own, page 2), and the API's areas cma.fleet_areas (addition 0009t; not
-- a page's read since 0009v, so not timed here). While the tenant's fleet_management.dummy_preview is off both answer set
-- up false, a settings lookup; 193's E1 and E2 (300 ms at prod's volume, E6 as amended 16 November 2026) and 189's E2
-- time the computations themselves whatever the setting. The page's read holds a list's first page: class list (300 ms)
('a', 'fleet management', 'page', $q$select cma.fleet_page(null, null, null, null)$q$, 'list', array['reports.view', 'performance.team']),
('a', 'fleet management further page', 'devices that need attention page 2', $q$select cma.fleet_rows(null, null, null, null, true, 2)$q$, 'list', array['reports.view', 'performance.team']),
-- Campaigns
('a', 'campaigns', 'journeys', $q$select * from cma.journeys()$q$, 'agent', array['reports.view', 'performance.team']),
-- report cores, the previous month then 92 days ({P} is replaced by the period's name, {f} and {t} by its bounds)
('b', 'dashboard {P}', 'team status time', $q$select * from cma.team_status_time('{f}', '{t}', null)$q$, 'overview', array['performance.team']),
('b', 'dashboard {P}', 'intake per day', $q$select * from cma.intake_per_day('{f}', '{t}')$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'dashboard {P}', 'crm records per day', $q$select * from cma.crm_records_per_day('{f}', '{t}')$q$, 'overview', array['performance.team']),
('b', 'dashboard {P}', 'speed to lead rows', $q$select r.*, cma.record_url(r.connection_id, 'deal', r.deal_source_id) from cma.speed_to_lead_rows('{f}', '{t}') r$q$, 'list', array['reports.view', 'performance.team']),
('b', 'dashboard {P}', 'callbacks kept', $q$select * from cma.callbacks_kept_report('{f}', '{t}')$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'speed to lead {P}', 'summary by day', $q$select * from cma.speed_to_lead_summary('{f}', '{t}', 'day')$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'calls {P}', 'overview by day', $q$select * from cma.calls_overview('{f}', '{t}', null, null, 'day')$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'calls {P}', 'overview by market', $q$select * from cma.calls_overview('{f}', '{t}', null, null, 'market') where period = 'current' and group_key is not null$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'calls {P}', 'overview by line', $q$select * from cma.calls_overview('{f}', '{t}', null, null, 'line') where period = 'current' and group_key is not null$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'calls {P}', 'history start', $q$select cma.telephony_history_start()$q$, 'agent', array['reports.view', 'performance.team']),
('b', 'calls {P}', 'tag use', $q$select * from cma.calls_tag_use('{f}', '{t}', null, null, 'day')$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'calls per agent {P}', 'per person', $q$select * from cma.calls_per_person('{f}', '{t}', null, null)$q$, 'overview', array['performance.team']),
('b', 'calls per agent {P}', 'tags per person', $q$select * from cma.calls_per_person_tags('{f}', '{t}', null, null)$q$, 'overview', array['performance.team']),
('b', 'inbound {P}', 'inbound service', $q$select * from cma.inbound_service('{f}', '{t}', 'day')$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'intake {P}', 'intake per day', $q$select * from cma.intake_per_day('{f}', '{t}')$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'email {P}', 'email report', $q$select * from cma.email_report_page('{f}', '{t}', 'day', null, null, null)$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'email {P}', 'email waiting', $q$select * from cma.email_waiting(null, null, null, 100)$q$, 'list', array['reports.view', 'performance.team']),
('b', 'email {P}', 'email not responding', $q$select * from cma.email_not_responding(null, 100)$q$, 'list', array['reports.view', 'performance.team']),
('b', 'email per agent {P}', 'email per person', $q$select * from cma.email_per_person_page('{f}', '{t}', null, null, null)$q$, 'overview', array['performance.team']),
('b', 'first orders {P}', 'first orders', $q$select * from cma.first_orders_page('{f}', '{t}', 'day', null, null, 100)$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'orders per person {P}', 'first orders per person', $q$select * from cma.first_orders_per_person('{f}', '{t}', null, null)$q$, 'overview', array['performance.team']),
('b', 'attempts {P}', 'attempts per deal', $q$select cma.attempts_per_deal_page('{f}', '{t}', 'day', null, null, 'all', 'all', 100)$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'attempts per agent {P}', 'attempts per person', $q$select cma.attempts_per_person_page('{f}', '{t}', null, null, 'all', 'all')$q$, 'overview', array['performance.team']),
('b', 'funnel {P}', 'deal funnel', $q$select cma.deal_funnel_page('{f}', '{t}', null, null, null)$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'funnel {P}', 'lost reasons', $q$select cma.lost_reasons_page('{f}', '{t}', null, null, null, 'week')$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'funnel {P}', 'deals per person', $q$select cma.deals_per_person_page('{f}', '{t}', null, null, null)$q$, 'overview', array['performance.team']),
('b', 'cancellations {P}', 'cancellations', $q$select cma.cancellations_page('{f}', '{t}', null, 'week')$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'reviews {P}', 'reviews', $q$select cma.reviews_page('{f}', '{t}', null, 'week')$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'lead cohorts {P}', 'lead cohorts', $q$select cma.lead_cohorts_report('{f}', '{t}', 'week', null, null, 'none', null)$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'courtesy {P}', 'courtesy', $q$select cma.courtesy_page('{f}', '{t}', 'week', 'week', null, null, null, null)$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'forms {P}', 'forms report', $q$select * from cma.forms_report('{f}', '{t}', 'day', null, null, null)$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'forms {P}', 'forms whole period', $q$select * from cma.forms_report('{f}', '{t}', 'week', null, null, null) where period = 'current' and group_key is null$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'forms {P}', 'forms answers', $q$select * from cma.forms_answers('{f}', '{t}', null, null, null, null, null)$q$, 'list', array['reports.view', 'performance.team']),
('b', 'maintenance now', 'maintenance 12 months', $q$select cma.maintenance_page('{month}', 12, null, null, null, 'unpaused')$q$, 'overview', array['reports.view', 'performance.team']),
-- since addition 0009zm: the device list of every bucket under the page's default filter, and the installed base's
-- records under a debt status filter and the measure under_debt_status (each a list of its own request)
('b', 'maintenance now', 'maintenance list all buckets', $q$select * from cma.maintenance_rows('{month}', 12, 'all', null, null, null, 'unpaused', 'exchanges', 500)$q$, 'list', array['reports.view', 'performance.team']),
('a', 'installed base', 'records with a debt status page of 50', $q$select cma.flash_rows('installed_base', '{"debt_status": "any"}', 'serial', false, 50, 0, null, null, null)$q$, 'list', array['reports.view', 'performance.team']),
('a', 'installed base', 'records without a debt status page of 50', $q$select cma.flash_rows('installed_base', '{"debt_status": "none"}', 'serial', false, 50, 0, null, null, null)$q$, 'list', array['reports.view', 'performance.team']),
('a', 'installed base', 'under a debt status page of 50', $q$select cma.flash_rows('installed_base', '{"measure": "under_debt_status"}', 'serial', false, 50, 0, null, null, null)$q$, 'list', array['reports.view', 'performance.team']),
-- Customers → Active (addition 0009l, decisions D13, D15 and D16): the page's four reads, each its own transaction,
-- on one page here so their sum is held against the overview budget (the one live read they replace took 1.4 to 2.0 s at
-- three times prod's volume): above and below the fold from their stored documents (class agent, 50 ms: a key lookup),
-- the live present of the tiles (class top, 400 ms) and the list's first page as the page asks it. Outside the set, on
-- their own rows: below the fold from a later first month with the cohorts by quarter (still the stored document: its
-- months are cut and the cohorts read from the stored cohort rows), what a request without a stored document computes
-- from the take's rows (two filters together, above the fold and below it), a filtered list page in another sort, and
-- the file's read (every row, the worst payment state of each as the take holds it). The take is refreshed before them
-- (below), on its own row
-- against verify.max_refresh_ms; stocks at now, so timed once
('b', 'active customers', 'active top (stored document)', $q$select cma.active_top(null, null, null, null)$q$, 'agent', array['reports.view', 'performance.team']),
('b', 'active customers', 'active now (the present by the tenant''s setting: live or from the take)', $q$select cma.active_now(null, null, null)$q$, 'top', array['reports.view', 'performance.team']),
('b', 'active customers', 'active now, the take''s path (the present from the stored take)', $q$select cma.active_now_of(cma.current_tenant_id(), null, null, null, now(), true)$q$, 'top', array['reports.view', 'performance.team']),
('b', 'active customers', 'active rest (stored document)', $q$select cma.active_rest(null, null, null, null, 'month')$q$, 'agent', array['reports.view', 'performance.team']),
('b', 'active customers', 'active list first page', $q$select cma.active_rows(null, null, null, 'monthly_amount', true, null, null, 50, false)$q$, 'list', array['reports.view', 'performance.team']),
('b', 'active customers', 'active top computed (two filters)', $q$select cma.active_top(null, null, 'unknown', 'direct')$q$, 'top', array['reports.view', 'performance.team']),
('b', 'active customers', 'active rest, a later first month by quarter (stored document)', $q$select cma.active_rest((date '{month}' - interval '12 months')::date, null, null, null, 'quarter')$q$, 'agent', array['reports.view', 'performance.team']),
('b', 'active customers', 'active rest computed (two filters)', $q$select cma.active_rest(null, null, 'unknown', 'direct', 'month')$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'active customers', 'active list filtered, by age', $q$select cma.active_rows(null, 'unknown', 'direct', 'age_months', false, null, null, 50, false)$q$, 'list', array['reports.view', 'performance.team']),
('b', 'active customers', 'active list under a device band', $q$select cma.active_rows(null, null, null, 'monthly_amount', true, null, null, 50, false, '0')$q$, 'list', array['reports.view', 'performance.team']),
('b', 'active customers', 'active list under the last device band', $q$select cma.active_rows(null, null, null, 'monthly_amount', true, null, null, 50, false,
   (select u.b from unnest(cma.flash_count_bands_of(cma.flash_bounds_of(cma.setting_of(cma.current_tenant_id(), 'customers.device_bands')))) with ordinality u(b, o)
    order by u.o desc limit 1))$q$, 'list', array['reports.view', 'performance.team']),
('b', 'active customers', 'active file', $q$select cma.active_rows(null, null, null, 'monthly_amount', true, null, null, null, true)$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'pledge lists now', 'pledge page', $q$select cma.pledge_page()$q$, 'overview', array['pledges.view']),
('b', 'pledge lists now', 'pledge check serials', $q$select * from cma.pledge_finding_rows('no_language', 500)$q$, 'list', array['pledges.view']),
('b', 'pledge lists now', 'pledge file today', $q$select * from cma.pledge_file(null)$q$, 'overview', array['pledges.view']),
('b', 'pledge lists now', 'pledge file stored', $q$select * from cma.pledge_file(coalesce((select max(s.valuation_date) from cma.pledge_snapshot s), date '2000-01-01'))$q$, 'overview', array['pledges.view']);

-- The per-person reads: timed only while the tenant's reports.per_person holds their key (cma.assert_per_person)
update pg_temp.reads_0131 set per_person = case name when 'email per person' then 'email' when 'first orders per person' then 'orders'
                                                     when 'attempts per person' then 'attempts' when 'deals per person' then 'deals' end
 where part = 'b' and name in ('email per person', 'first orders per person', 'attempts per person', 'deals per person');
-- An as-of read of a date without a snapshot has nothing to time (CMA02): skip with that reason, never a FAIL
update pg_temp.reads_0131 set skip_state = 'CMA02', skip_why = 'no snapshot for that date'
where page = 'installed base as of month end';
-- A page that loads in two parts: its set is the first paint's reads; the records read keeps its own list row
update pg_temp.reads_0131 set in_set = false
where page in ('installed base', 'installed base as of month end') and cls = 'list';
-- Pledge lists (addition 0009j): the files are downloads of their own, outside the page's set; the stored file's read
-- has nothing to time while the tenant holds no quarter file (CMA02)
update pg_temp.reads_0131 set in_set = false
where page = 'pledge lists now' and name in ('pledge file today', 'pledge file stored');
update pg_temp.reads_0131 set skip_state = 'CMA02', skip_why = 'no quarter file yet'
where page = 'pledge lists now' and name = 'pledge file stored';
-- The source figures' comparison (addition 0009zg): no page reads it yet (Customers → Subscriptions will, B39d), so it is
-- outside Data quality's set; a database without 214 has nothing to time (42883)
update pg_temp.reads_0131 set in_set = false, skip_state = '42883', skip_why = 'addition 0009zg has not run'
where page = 'data quality' and name = 'source figures compared today';
-- Maintenance's read with the debt status filter (addition 0009zm), the page's default: a database without 226 has no such
-- form (42883)
update pg_temp.reads_0131 set skip_state = '42883', skip_why = 'addition 0009zm has not run'
where page = 'maintenance now' and name = 'maintenance 12 months';
-- the device list is a read of its own request; the records under a debt status filter or its measure are refused (CMA04)
-- by a database without 226
update pg_temp.reads_0131 set in_set = false, skip_state = '42883', skip_why = 'addition 0009zm has not run'
where page = 'maintenance now' and name = 'maintenance list all buckets';
update pg_temp.reads_0131 set skip_state = 'CMA04', skip_why = 'addition 0009zm has not run'
where page = 'installed base' and name in ('records with a debt status page of 50', 'records without a debt status page of 50', 'under a debt status page of 50');
-- Customers → Active: the set is the page's four reads; what is computed without a stored document, the filtered list
-- and the file are reads of other requests
update pg_temp.reads_0131 set in_set = false
where page = 'active customers' and name in ('active top computed (two filters)', 'active rest, a later first month by quarter (stored document)',
                                             'active rest computed (two filters)', 'active list filtered, by age', 'active file');

do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_part    text := current_setting('verify.part');
  v_stop    timestamptz := clock_timestamp() + make_interval(secs => current_setting('verify.time_budget_s')::numeric);
  t record; rd record; o record;
  v_user uuid; v_sys text; v_ext text; v_conn uuid; v_today date; v_monday date; v_month date; v_from date; v_to date; v_from92 date;
  v_ms numeric; v_max numeric; v_sql text; v_page text; v_set_max numeric; v_audit_after bigint; v_sched uuid; v_cur jsonb;
  v_t0 timestamptz; v_key text; v_mark0 timestamptz;
  v_fig_user uuid; v_fig_conn uuid;   -- the source figures' due check (0009zg): its own, so {conn} keeps the tenant's first connection
  -- per page and tenant: the sum of its reads and whether one failed
  v_pages text[]; v_sums numeric[]; v_bad boolean[]; p integer;
  -- per page: a read in its set had nothing to time (and why); a read outside its set (a page that loads in two parts)
  v_skip text[]; v_out boolean[]; v_err text; v_skipped boolean;
  r_name text[] := '{}'; r_result text[] := '{}'; r_detail text[] := '{}'; r_ms numeric[] := '{}';
begin
  if v_part not in ('a', 'b', 'c', 'all', 'audit') then
    raise exception 'verify.part is a, b, c, all or audit, not %', v_part;
  end if;
  begin
    perform set_config('app.actor_label', 'time-0131', true);
    for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
      perform set_config('role', 'cma_owner', true);
      perform set_config('app.user_id', '', true);
      perform set_config('app.tenant_id', t.id::text, true);
      v_today := cma.tenant_today_of(t.id);
      v_monday := v_today - ((extract(isodow from v_today)::integer) - 1);
      v_month := date_trunc('month', v_today)::date;
      v_from := (date_trunc('month', v_today) - interval '1 month')::date;
      v_to := (date_trunc('month', v_today) - interval '1 day')::date;
      v_from92 := v_today - 91;
      select c.id into v_conn from cma.integration_connection c where c.tenant_id = t.id order by (c.status = 'active') desc, c.created_at, c.id limit 1;
      v_pages := '{}'; v_sums := '{}'; v_bad := '{}'; v_skip := '{}'; v_out := '{}';
      r_name := r_name || (t.slug || ' periods'); r_result := r_result || 'info'::text;
      r_detail := r_detail || format('previous month %s to %s; 92 days %s to %s; today %s; connection %s', v_from, v_to, v_from92, v_today, v_today, coalesce(v_conn::text, 'none'));
      r_ms := r_ms || null::numeric;
      -- the current takes (addition 0009e; every stock overview's since 0009p), taken again under the tenant's scheduler
      -- before the reads (rolled back with them), so the documents and the landing's cards time the stored read. The
      -- refresh itself is timed against verify.max_takes_ms: every overview of the tenant's setting, forced, by the
      -- owner's writer (the job's entry takes only what is due), which is what the snapshot job does when all are due
      if v_part in ('a', 'all') then
        select u.id into v_sched from cma.app_user u
        where u.tenant_id = t.id and u.kind = 'system' and u.email = 'scheduler@system.invalid' and u.status = 'active';
        v_cur := null; v_ms := null;
        if v_sched is not null then
          perform set_config('app.user_id', v_sched::text, true);
          begin
            v_t0 := clock_timestamp();
            foreach v_key in array cma.flash_current_overviews_of(t.id) loop
              perform cma.flash_current_refresh_of(t.id, v_key, true);
            end loop;
            v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
            v_cur := jsonb_build_object('overviews', to_jsonb(cma.flash_current_overviews_of(t.id)),
                                        'rows', (select count(*) from cma.flash_current_take c where c.tenant_id = t.id));
          exception when others then
            v_cur := jsonb_build_object('error', sqlstate); v_ms := null;
          end;
          perform set_config('app.user_id', '', true);
        end if;
        v_max := case when v_provoke then 0 else current_setting('verify.max_takes_ms')::numeric end;
        r_name := r_name || (t.slug || ' current takes refresh');
        r_result := r_result || case when v_provoke then 'FAIL' when v_sched is null then 'skip'
                                     when v_ms is not null and v_ms < v_max then 'ok' else 'FAIL' end;
        r_detail := r_detail || case when v_sched is null then 'no active scheduler user: nothing to time, the documents and the cards read live'
                                     else coalesce(v_ms || ' ms (every overview of the setting taken again, once) against ' || v_max || ' ms: ', '') || v_cur::text end;
        r_ms := r_ms || v_ms;
      end if;
      -- the stored take of Customers → Active (addition 0009l, decision D13), refreshed as the tenant's scheduler: the
      -- history and the documents written again, timed once against verify.max_refresh_ms, in a step of its own that is
      -- rolled back at once (so the take's row is not held locked through the timed part: a settings save that marks the
      -- take stale would wait for it). The reads below then read the take the job keeps; a tenant without one yet (a
      -- database where the job never ran) gets one here, rolled back with the timed part. A refresh the job is running
      -- at this moment has nothing to time here (skip)
      if v_part in ('b', 'all') then
        select u.id into v_sched from cma.app_user u
        where u.tenant_id = t.id and u.kind = 'system' and u.email = 'scheduler@system.invalid' and u.status = 'active';
        v_cur := null; v_ms := null;
        if v_sched is not null then
          perform set_config('role', 'cma_app', true);
          perform set_config('app.user_id', v_sched::text, true);
          begin
            v_cur := cma.active_refresh_of(t.id, true);
            v_ms := (v_cur ->> 'duration_ms')::numeric;
            raise exception using errcode = 'CMAOK', message = 'the refresh is timed: rolled back';
          exception
            when sqlstate 'CMAOK' then null;
            when others then v_cur := jsonb_build_object('error', sqlstate);
          end;
          if not exists (select 1 from cma.active_take k where k.tenant_id = t.id) then
            begin
              perform cma.active_refresh_of(t.id, true);
            exception when others then null;
            end;
          end if;
          perform set_config('role', 'cma_owner', true);
          perform set_config('app.user_id', '', true);
        end if;
        v_max := case when v_provoke then 0 else current_setting('verify.max_refresh_ms')::numeric end;
        r_name := r_name || (t.slug || ' active customers refresh');
        r_result := r_result || case when v_provoke then 'FAIL'
                                     when v_sched is null or v_cur ->> 'reason' in ('not_set_up', 'running') then 'skip'
                                     when v_ms is not null and v_ms < v_max then 'ok' else 'FAIL' end;
        r_detail := r_detail || case when v_sched is null then 'no active scheduler user: nothing to time'
                                     when v_cur ->> 'reason' = 'not_set_up' then 'the sources are not set up: nothing to take'
                                     when v_cur ->> 'reason' = 'running' then 'the job is refreshing this tenant now: nothing to time'
                                     else coalesce(v_ms || ' ms (the history and the documents written again, once) against ' || v_max || ' ms: ', '') || v_cur::text end;
        r_ms := r_ms || v_ms;
        -- the inputs' change markers (addition 0009m): what the job's every due run reads before it decides to compute,
        -- as the tenant's scheduler, the best of three
        v_ms := null;
        if v_sched is not null then
          perform set_config('role', 'cma_app', true);
          perform set_config('app.user_id', v_sched::text, true);
          begin
            for i in 1 .. 3 loop
              v_mark0 := clock_timestamp();
              perform cma.active_inputs_key_of(t.id);
              v_ms := least(coalesce(v_ms, 1e9), round(extract(epoch from clock_timestamp() - v_mark0) * 1000, 1));
            end loop;
          exception
            when others then v_ms := null;                     -- an error reads FAIL below, the other rows go on
          end;
          perform set_config('role', 'cma_owner', true);
          perform set_config('app.user_id', '', true);
        end if;
        v_max := case when v_provoke then 0 else current_setting('verify.max_markers_ms')::numeric end;
        r_name := r_name || (t.slug || ' active customers inputs markers');
        r_result := r_result || case when v_provoke then 'FAIL' when v_sched is null then 'skip'
                                     when v_ms is not null and v_ms < v_max then 'ok' else 'FAIL' end;
        r_detail := r_detail || case when v_sched is null then 'no active scheduler user: nothing to time'
                                     else coalesce(v_ms || ' ms (best of 3)', 'the read failed') || ' against ' || v_max || ' ms' end;
        r_ms := r_ms || v_ms;
      end if;
      -- the subscription facts (addition 0009ze, brief B39c C.9), part b: their refresh as the tenant's scheduler, every
      -- take computed again (forced), once, against verify.max_facts_ms, rolled back at once as Active's above. Since
      -- addition 0009zf (212) the two large takes are written as differences, so on a take the job keeps fresh this row
      -- times the computation and few writes: the floor of a run, not its usual cost (a run of the job that finds the
      -- inputs unchanged computes nothing; the job's own runs keep their times in cma.sync_run's counts); and the
      -- variant mapping's list (Configuration → Sources, the panel of a subscriptions connection), as the application
      -- (cma_app, row-level security on, the tenant's scheduler), the best of two, against verify.max_list_ms. A database
      -- without 210 reads skip
      if v_part in ('b', 'all') then
        v_cur := null; v_ms := null;
        if to_regprocedure('cma.subscription_facts_refresh_of(uuid,boolean,timestamptz)') is not null and v_sched is not null then
          perform set_config('role', 'cma_app', true);
          perform set_config('app.user_id', v_sched::text, true);
          begin
            v_cur := cma.subscription_facts_refresh_of(t.id, true);
            v_ms := (v_cur ->> 'duration_ms')::numeric;
            raise exception using errcode = 'CMAOK', message = 'the refresh is timed: rolled back';
          exception
            when sqlstate 'CMAOK' then null;
            when others then v_cur := jsonb_build_object('error', sqlstate);
          end;
          perform set_config('role', 'cma_owner', true);
          perform set_config('app.user_id', '', true);
        end if;
        v_max := case when v_provoke then 0 else current_setting('verify.max_facts_ms')::numeric end;
        r_name := r_name || (t.slug || ' subscription facts refresh');
        r_result := r_result || case when v_provoke then 'FAIL'
                                     when to_regprocedure('cma.subscription_facts_refresh_of(uuid,boolean,timestamptz)') is null or v_sched is null
                                          or v_cur ->> 'reason' in ('not_set_up', 'running') then 'skip'
                                     when v_ms is not null and v_ms < v_max then 'ok' else 'FAIL' end;
        r_detail := r_detail || case when to_regprocedure('cma.subscription_facts_refresh_of(uuid,boolean,timestamptz)') is null then 'addition 0009ze has not run: nothing to time'
                                     when v_sched is null then 'no active scheduler user: nothing to time'
                                     when v_cur ->> 'reason' = 'not_set_up' then 'the subscriptions source is not set up: nothing to take'
                                     when v_cur ->> 'reason' = 'running' then 'the job is refreshing this tenant now: nothing to time'
                                     else coalesce(v_ms || ' ms (every take computed again, once) against ' || v_max || ' ms: ', '') || v_cur::text end;
        r_ms := r_ms || v_ms;
        v_ms := null; v_cur := null;
        if to_regprocedure('cma.subscription_variants_of(uuid,uuid)') is not null then
          perform set_config('role', 'cma_app', true);
          perform set_config('app.user_id', coalesce(v_sched::text, ''), true);
          begin
            for i in 1 .. 2 loop
              v_mark0 := clock_timestamp();
              select jsonb_build_object('rows', count(*)) into v_cur from cma.subscription_variants_of(t.id, null) x;
              v_ms := least(coalesce(v_ms, 1e9), round(extract(epoch from clock_timestamp() - v_mark0) * 1000, 1));
            end loop;
          exception
            when others then v_ms := null; v_cur := jsonb_build_object('error', sqlstate);
          end;
          perform set_config('role', 'cma_owner', true);
          perform set_config('app.user_id', '', true);
        end if;
        v_max := case when v_provoke then 0 else current_setting('verify.max_list_ms')::numeric end;
        r_name := r_name || (t.slug || ' subscription variants list');
        r_result := r_result || case when v_provoke then 'FAIL' when to_regprocedure('cma.subscription_variants_of(uuid,uuid)') is null then 'skip'
                                     when v_ms is not null and v_ms < v_max then 'ok' else 'FAIL' end;
        r_detail := r_detail || case when to_regprocedure('cma.subscription_variants_of(uuid,uuid)') is null then 'addition 0009ze has not run: nothing to time'
                                     else coalesce(v_ms || ' ms (best of 2) against ' || v_max || ' ms: ', 'the read failed: ') || coalesce(v_cur::text, '') end;
        r_ms := r_ms || v_ms;
      end if;
      -- the source figures' due check (addition 0009zg), part a: what the hourly job ingest-source-figures asks first for
      -- every subscriptions connection, as the tenant's ingest (ingest.write), the best of three, against verify.max_poll_ms.
      -- A job's read, not a page's poll: one call a connection an hour, each in a fresh job process, so the best of three
      -- is its cost (the generic plan after five calls never comes; its seventh call read 0.14 ms on the volume fixture,
      -- one CPU). A database without 214, or a tenant without an active subscriptions connection or an ingest user, reads skip
      if v_part in ('a', 'all') then
        v_ms := null; v_cur := null; v_fig_user := null; v_fig_conn := null;
        select x.user_id into v_fig_user from cma.app_user_external_id x
        join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id and u.status = 'active'
        where x.tenant_id = t.id and x.system = 'ingest' and x.external_id = 'ingest';
        select c.id into v_fig_conn from cma.integration_connection c
        where c.tenant_id = t.id and c.kind = 'subscriptions' and c.status = 'active' order by c.id limit 1;
        if to_regprocedure('cma.source_figures_due_of(uuid)') is not null and v_fig_user is not null and v_fig_conn is not null then
          perform set_config('role', 'cma_app', true);
          perform set_config('app.user_id', v_fig_user::text, true);
          begin
            for i in 1 .. 3 loop
              v_mark0 := clock_timestamp();
              select jsonb_build_object('due', d.due) into v_cur from cma.source_figures_due_of(v_fig_conn) d;
              v_ms := least(coalesce(v_ms, 1e9), round(extract(epoch from clock_timestamp() - v_mark0) * 1000, 1));
            end loop;
          exception
            when others then v_ms := null; v_cur := jsonb_build_object('error', sqlstate);
          end;
          perform set_config('role', 'cma_owner', true);
          perform set_config('app.user_id', '', true);
        end if;
        v_max := case when v_provoke then 0 else current_setting('verify.max_poll_ms')::numeric end;
        r_name := r_name || (t.slug || ' source figures due check');
        r_result := r_result || case when v_provoke then 'FAIL'
                                     when to_regprocedure('cma.source_figures_due_of(uuid)') is null or v_fig_user is null or v_fig_conn is null then 'skip'
                                     when v_ms is not null and v_ms < v_max then 'ok' else 'FAIL' end;
        r_detail := r_detail || case when to_regprocedure('cma.source_figures_due_of(uuid)') is null then 'addition 0009zg has not run: nothing to time'
                                     when v_fig_user is null or v_fig_conn is null then 'no active subscriptions connection or ingest user: nothing to time'
                                     else coalesce(v_ms || ' ms (best of 3) against ' || v_max || ' ms: ', 'the read failed: ') || coalesce(v_cur::text, '') end;
        r_ms := r_ms || v_ms;
      end if;
      -- the subscription audit (addition 0009zb), part audit only: as the owner (it is executable by cma_owner only), once,
      -- for information; its rows' verdicts counted, never listed (Martin reads the audit itself in Studio). Not started
      -- after verify.time_budget_s; a statement timeout inside it reads FAIL (the session's statement_timeout bounds the
      -- whole run, every tenant's audit together); provoked, the row FAILs as every timed row does
      if v_part = 'audit' then
        v_ms := null; v_cur := null;
        if to_regprocedure('cma.subscription_audit_of(uuid)') is not null and clock_timestamp() < v_stop then
          begin
            v_mark0 := clock_timestamp();
            select jsonb_build_object('rows', count(*), 'ok', count(*) filter (where a.verdict = 'ok'),
                                      'explain', count(*) filter (where a.verdict = 'explain'), 'fail', count(*) filter (where a.verdict = 'fail'))
            into v_cur from cma.subscription_audit_of(t.id) a;
            v_ms := round(extract(epoch from clock_timestamp() - v_mark0) * 1000, 1);
          exception
            when query_canceled then v_cur := jsonb_build_object('error', '57014 (statement_timeout)');
            when others then v_cur := jsonb_build_object('error', sqlstate);
          end;
        end if;
        r_name := r_name || (t.slug || ' subscription audit');
        r_result := r_result || case when to_regprocedure('cma.subscription_audit_of(uuid)') is null then 'skip'
                                     when v_provoke or v_cur is null or v_cur ? 'error' then 'FAIL' else 'info' end;
        r_detail := r_detail || case when to_regprocedure('cma.subscription_audit_of(uuid)') is null then 'addition 0009zb has not run: nothing to time'
                                     when v_cur is null then 'not timed: the run stopped starting reads at verify.time_budget_s'
                                     else coalesce(v_ms || ' ms, once, no budget: ', '') || v_cur::text end;
        r_ms := r_ms || v_ms;
      end if;
      for rd in
        select x.ord, x.page, x.name, x.sql, x.cls, x.perms, x.skip_state, x.skip_why, x.in_set, 1 as period, x.per_person
        from pg_temp.reads_0131 x where x.part = 'a' and v_part in ('a', 'all')
        union all
        select x.ord, x.page, x.name, x.sql, x.cls, x.perms, x.skip_state, x.skip_why, x.in_set, k.period, x.per_person
        from pg_temp.reads_0131 x cross join (values (1), (2)) k(period)
        where x.part = 'b' and ((k.period = 1 and v_part in ('b', 'all')) or (k.period = 2 and v_part in ('c', 'all')))
        order by 10, 1
      loop
        perform set_config('role', 'cma_owner', true);
        perform set_config('app.user_id', '', true);
        v_user := pg_temp.t0131_user(t.id, rd.perms);
        v_page := replace(rd.page, '{P}', case when rd.period = 1 then 'previous month' else '92 days' end);
        p := array_position(v_pages, v_page);
        if p is null then
          v_pages := v_pages || v_page; v_sums := v_sums || 0::numeric; v_bad := v_bad || false; v_skip := v_skip || null::text;
          v_out := v_out || false; p := cardinality(v_pages);
        end if;
        -- a per-person read while the tenant's reports.per_person lacks its key: the web makes no such read, nothing to time
        if rd.per_person is not null and not cma.per_person_on(t.id, rd.per_person) then
          r_name := r_name || (t.slug || ' ' || v_page || ': ' || rd.name); r_result := r_result || 'skip'::text;
          r_detail := r_detail || ('reports.per_person does not hold ' || rd.per_person || ' (the web makes no such read): not timed'); r_ms := r_ms || null::numeric;
          -- the page's set too when it has no other read (the email, orders and attempts per-person pages); Funnel's set sums its own two
          if not exists (select 1 from pg_temp.reads_0131 y where y.page = rd.page and y.per_person is null) then
            v_skip[p] := coalesce(v_skip[p], 'reports.per_person does not hold ' || rd.per_person);
          end if;
          continue;
        end if;
        if v_user is null then
          r_name := r_name || (t.slug || ' ' || v_page || ': ' || rd.name); r_result := r_result || 'skip'::text;
          r_detail := r_detail || ('no active person holds ' || array_to_string(rd.perms, ' or ') || ': not timed'); r_ms := r_ms || null::numeric;
          continue;
        end if;
        select x.system, x.external_id into v_sys, v_ext from cma.app_user_external_id x where x.tenant_id = t.id and x.user_id = v_user order by x.system limit 1;
        v_sql := replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(rd.sql,
                   '{f}', case when rd.period = 1 then v_from::text else v_from92::text end), '{t}', case when rd.period = 1 then v_to::text else v_today::text end),
                   '{from}', v_from::text), '{to}', v_to::text), '{today}', v_today::text), '{monday}', v_monday::text), '{month}', v_month::text),
                   '{conn}', coalesce(v_conn::text, '00000000-0000-0000-0000-000000000000')), '{sys}', coalesce(v_sys, 'none')), '{ext}', coalesce(v_ext, 'none'));
        v_max := case when v_provoke then 0 else current_setting(case rd.cls when 'poll' then 'verify.max_poll_ms' when 'agent' then 'verify.max_agent_ms'
                                                                  when 'list' then 'verify.max_list_ms' when 'sources' then 'verify.max_sources_ms'
                                                                  when 'dq' then 'verify.max_dq_ms' when 'top' then 'verify.max_top_ms'
                                                                  else 'verify.max_overview_ms' end)::numeric end;
        perform set_config('role', 'cma_app', true);
        perform set_config('app.user_id', v_user::text, true);
        v_ms := case when clock_timestamp() > v_stop then null
                     when rd.cls = 'poll' then pg_temp.t0131_poll_ms(v_sql, current_setting('verify.poll_warmup')::integer,
                                                                    greatest(1, current_setting('verify.poll_runs')::integer))
                     else pg_temp.t0131_best_ms(v_sql, 2) end;
        v_err := case when v_ms = -1 then current_setting('t0131.error') end;
        -- an error the read names as nothing to time (CMA02: no snapshot, or no frozen list, for the as-of date) is a skip
        -- with the database's own words; any other a FAIL, and under provoke every read FAILs
        v_skipped := not v_provoke and v_err is not null and v_err = rd.skip_state;
        r_name := r_name || (t.slug || ' ' || v_page || ': ' || rd.name);
        r_result := r_result || case when v_skipped then 'skip' when v_ms is not null and v_ms >= 0 and v_ms < v_max then 'ok' else 'FAIL' end;
        r_detail := r_detail || case when v_ms is null then 'not timed: the run stopped starting reads at verify.time_budget_s'
                                     when v_skipped then rd.skip_why || ' (' || v_err || ': ' || current_setting('t0131.error_message') || '): nothing to time'
                                     when v_ms = -1 then 'error ' || v_err
                                     else v_ms || ' ms (' || case when rd.cls = 'poll'
                                                                 then 'median of ' || greatest(1, current_setting('verify.poll_runs')::integer)
                                                                      || ' after ' || current_setting('verify.poll_warmup') || ' untimed; first '
                                                                      || current_setting('t0131.poll_first') || ', worst '
                                                                      || current_setting('t0131.poll_worst')
                                                                 else 'best of 2' end || ') against ' || v_max || ' ms' end;
        r_ms := r_ms || case when v_ms >= 0 then v_ms end;
        if rd.in_set then
          v_sums[p] := v_sums[p] + coalesce(nullif(v_ms, -1), 0);
          v_bad[p] := v_bad[p] or v_ms is null or (v_ms < 0 and not v_skipped);
          v_skip[p] := coalesce(v_skip[p], case when v_skipped then rd.skip_why end);
        else
          v_out[p] := true;
        end if;
      end loop;
      -- one row per page: its reads together against the set's budget
      perform set_config('role', 'cma_owner', true);
      for p in 1 .. cardinality(v_pages) loop
        v_set_max := case when v_provoke then 0
                          when v_pages[p] in ('welcome agent', 'welcome manager', 'welcome admin', 'my hours', 'my schedule', 'my follow-up', 'messages', 'my account', 'live board',
                                              'team people', 'team hours', 'roster week') then current_setting('verify.max_agent_set_ms')::numeric
                          else current_setting('verify.max_overview_ms')::numeric end;
        if v_pages[p] in ('polls', 'campaigns') then continue; end if;
        r_name := r_name || (t.slug || ' ' || v_pages[p] || ' (set)');
        r_result := r_result || case when v_bad[p] then 'FAIL' when v_skip[p] is not null then 'skip' when v_sums[p] < v_set_max then 'ok' else 'FAIL' end;
        r_detail := r_detail || case when v_bad[p] then 'a read of the page failed or was not timed'
                                     when v_skip[p] is not null then v_skip[p] || ': nothing to time'
                                     else v_sums[p] || ' ms, ' || case when v_out[p] then 'the first paint''s reads (the records stream after it, on their own row)'
                                                                      else 'the reads summed' end || ', against ' || v_set_max || ' ms' end;
        r_ms := r_ms || case when v_bad[p] or v_skip[p] is not null then null else v_sums[p] end;
      end loop;
    end loop;
    raise exception using errcode = 'CMAOK', message = 'the timed part ends: rolled back';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      r_name := r_name || 'the timed part'::text; r_result := r_result || 'FAIL'::text;
      r_detail := r_detail || ('ended early: ' || sqlstate || ' ' || left(sqlerrm, 120)); r_ms := r_ms || null::numeric;
  end;
  select count(*) into v_audit_after from cma.audit_log a where a.actor_label = 'time-0131';
  r_name := array['rolled back'] || r_name; r_result := array[case when v_audit_after = 0 then 'info' else 'FAIL' end] || r_result;
  r_detail := array[format('the timed part is rolled back: %s audit row(s) of its writes remain', v_audit_after)] || r_detail; r_ms := array[null::numeric] || r_ms;
  insert into pg_temp.time_0131 (ord, check_name, result, detail, ms)
  select i, r_name[i], r_result[i], r_detail[i], r_ms[i] from generate_series(1, cardinality(r_name)) i;
end
$$;

drop function if exists pg_temp.t0131_best_ms(text, integer);
drop function if exists pg_temp.t0131_poll_ms(text, integer, integer);
drop function if exists pg_temp.t0131_user(uuid, text[]);
drop table if exists pg_temp.reads_0131;

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.time_0131
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.time_0131 where result = 'FAIL') then 'FAIL'
                  when current_setting('verify.part') = 'audit' then 'INFO'
                  when not exists (select 1 from pg_temp.time_0131 where result = 'ok') then 'FAIL'
                  else 'PASS' end,
             format('131_time_all (part %s): %s ok, %s FAIL, %s skip; worst %s ms (%s)', current_setting('verify.part'),
                    (select count(*) from pg_temp.time_0131 where result = 'ok'),
                    (select count(*) from pg_temp.time_0131 where result = 'FAIL'), (select count(*) from pg_temp.time_0131 where result = 'skip'),
                    coalesce((select max(ms)::text from pg_temp.time_0131 where check_name not like '%(set)'), '-'),
                    coalesce((select check_name from pg_temp.time_0131 where ms is not null and check_name not like '%(set)' order by ms desc, ord limit 1), '-'))) x
order by ord;
drop table if exists pg_temp.time_0131;
reset role;
