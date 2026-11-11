-- =============================================================================================
-- 131_time_all.sql: every read a page, poll or report makes, timed on the database's own data, read only (night N06)
-- =============================================================================================
-- 124_time_flash.sql generalised to the whole Workspace: times every database read the web makes for a page, a poll or
-- a report, on the data the database holds, as the application (cma_app, row-level security on), per active tenant,
-- acting as the tenant's first active person holding the read's permission (kind person, the oldest; a read without such
-- a person reads skip). Each read is the best of two runs, every row fetched; a page then gets one row that sums its
-- reads (the sum is a ceiling: the web runs a page's reads in parallel). No addition, no write: the reads run in a
-- read-only subtransaction that is rolled back (its rows kept in variables), so the script runs alike as one transaction
-- (Cloud SQL Studio) and statement by statement (psql), in any database, at any time, as often as wanted. Run as your
-- own IAM login after 128_sources_last_read.sql (0008zq) and, since addition 0008zv (the identity read names
-- cma.organisation.is_contact_center), after 140_live_per_organisation.sql; since addition 0008zw (Reviews' period All),
-- after 142_reviews_all_order_kinds.sql; since addition 0009a (Customers → Courtesy), after 150_courtesy.sql; since
-- addition 0009e (the installed base's first paint from a stored current take), after 158_flash_current_take.sql; since
-- addition 0009j (Assets → Pledge lists), after 168_pledge_lists.sql; since addition 0009l (Customers → Active), after
-- 172_active_customers.sql. Prod is the proof; dev's shared core is for
-- information. The pledge reads need pledges.view, which no default role holds: in a tenant where no person holds it they
-- read skip, as any read without such a person.
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
-- in one go where the window allows it. The morning runbook runs a, b and c as three Studio runs.
-- A read that raises an error reads FAIL with its SQLSTATE and the others still run, except an error a read names as
-- nothing to time: an as-of read whose date has no snapshot (CMA02) reads skip with that reason, and its page's set too
-- (Martin, 6 November 2026; Decision log). A page's set sums the reads the reader waits for first: a Flash overview loads
-- in two parts since addition 0008zy (the document, then its records streamed after the first paint), so the Installed
-- base pages' sets are the document against verify.max_overview_ms, and their records read keeps its own list row.
-- Since addition 0009f Assets -> Installed base reads its lists on demand (a page of 50 records, the devices past due, the
-- devices without a subscription reference, the serial search): each is a list row of the page, outside its set.
-- Since addition 0009e the Installed base's document now is read from its stored current take: in part a each tenant's
-- current takes are refreshed first as its scheduler user (cma.flash_current_refresh, inside the timed part, so rolled
-- back with it; a row per tenant says what the refresh answered), and the document's row times the stored read the page
-- makes whenever the snapshot job keeps the take fresh. A take that cannot be made (a source not set up, an error)
-- leaves the live read, timed as it is.
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
end
$$;
select set_config('verify.provoke', 'false', false);                 -- 'true' to make every timed read fail
select set_config('verify.part', 'all', false);                      -- 'a', 'b', 'c' or 'all'
select set_config('verify.max_poll_ms', '20', false);                -- a poll (unread count, team now, inbound now, shifts today, the identity)
select set_config('verify.max_agent_ms', '50', false);               -- one read of an agent page or the Live board
select set_config('verify.max_agent_set_ms', '100', false);          -- an agent page's or the Live board's reads together
select set_config('verify.max_list_ms', '300', false);               -- a list's first page
select set_config('verify.max_overview_ms', '500', false);           -- an overview, a landing, a report core, a page's reads together
select set_config('verify.max_sources_ms', '150', false);            -- cma.sources()
select set_config('verify.max_dq_ms', '500', false);                 -- data quality's overview and first page
select set_config('verify.max_top_ms', '400', false);                -- Customers → Active: the live present of the tiles, and above the fold computed (decisions D15, D16)
select set_config('verify.max_refresh_ms', '15000', false);          -- the refresh of Customers → Active's stored take, the history and the documents written again
select set_config('verify.time_budget_s', '240', false);             -- stop starting reads after this, inside Studio's 300 s

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
                                   skip_state text, skip_why text, in_set boolean not null default true);
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
('a', 'welcome agent', 'waiting for you', $q$select cma.my_follow_up()$q$, 'agent', array['leads.accept', 'workday.own']),
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
-- Flash
('a', 'flash', 'landing', $q$select cma.flash_page(null, null, '{from}', '{to}')$q$, 'overview', array['reports.view', 'performance.team']),
('a', 'flash', 'snapshots', $q$select cma.flash_snapshots(null, null)$q$, 'agent', array['reports.view', 'performance.team']),
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
('b', 'maintenance now', 'maintenance 12 months', $q$select cma.maintenance_page('{month}', 12, null, null, null)$q$, 'overview', array['reports.view', 'performance.team']),
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
('b', 'active customers', 'active now (the live present)', $q$select cma.active_now(null, null, null)$q$, 'top', array['reports.view', 'performance.team']),
('b', 'active customers', 'active rest (stored document)', $q$select cma.active_rest(null, null, null, null, 'month')$q$, 'agent', array['reports.view', 'performance.team']),
('b', 'active customers', 'active list first page', $q$select cma.active_rows(null, null, null, 'monthly_amount', true, null, null, 50, false)$q$, 'list', array['reports.view', 'performance.team']),
('b', 'active customers', 'active top computed (two filters)', $q$select cma.active_top(null, null, 'unknown', 'direct')$q$, 'top', array['reports.view', 'performance.team']),
('b', 'active customers', 'active rest, a later first month by quarter (stored document)', $q$select cma.active_rest((date '{month}' - interval '12 months')::date, null, null, null, 'quarter')$q$, 'agent', array['reports.view', 'performance.team']),
('b', 'active customers', 'active rest computed (two filters)', $q$select cma.active_rest(null, null, 'unknown', 'direct', 'month')$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'active customers', 'active list filtered, by age', $q$select cma.active_rows(null, 'unknown', 'direct', 'age_months', false, null, null, 50, false)$q$, 'list', array['reports.view', 'performance.team']),
('b', 'active customers', 'active file', $q$select cma.active_rows(null, null, null, 'monthly_amount', true, null, null, null, true)$q$, 'overview', array['reports.view', 'performance.team']),
('b', 'pledge lists now', 'pledge page', $q$select cma.pledge_page()$q$, 'overview', array['pledges.view']),
('b', 'pledge lists now', 'pledge check serials', $q$select * from cma.pledge_finding_rows('no_language', 500)$q$, 'list', array['pledges.view']),
('b', 'pledge lists now', 'pledge file today', $q$select * from cma.pledge_file(null)$q$, 'overview', array['pledges.view']),
('b', 'pledge lists now', 'pledge file stored', $q$select * from cma.pledge_file(coalesce((select max(s.valuation_date) from cma.pledge_snapshot s), date '2000-01-01'))$q$, 'overview', array['pledges.view']);

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
  -- per page and tenant: the sum of its reads and whether one failed
  v_pages text[]; v_sums numeric[]; v_bad boolean[]; p integer;
  -- per page: a read in its set had nothing to time (and why); a read outside its set (a page that loads in two parts)
  v_skip text[]; v_out boolean[]; v_err text; v_skipped boolean;
  r_name text[] := '{}'; r_result text[] := '{}'; r_detail text[] := '{}'; r_ms numeric[] := '{}';
begin
  if v_part not in ('a', 'b', 'c', 'all') then
    raise exception 'verify.part is a, b, c or all, not %', v_part;
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
      -- the current takes (addition 0009e), refreshed as the tenant's scheduler before the reads (rolled back with them), so
      -- the installed base's document times the stored read; what the refresh answered is an info row
      if v_part in ('a', 'all') then
        select u.id into v_sched from cma.app_user u
        where u.tenant_id = t.id and u.kind = 'system' and u.email = 'scheduler@system.invalid' and u.status = 'active';
        v_cur := null;
        if v_sched is not null then
          perform set_config('role', 'cma_app', true);
          perform set_config('app.user_id', v_sched::text, true);
          begin
            v_cur := cma.flash_current_refresh(t.id);
          exception when others then
            v_cur := jsonb_build_object('error', sqlstate);
          end;
          perform set_config('role', 'cma_owner', true);
          perform set_config('app.user_id', '', true);
        end if;
        r_name := r_name || (t.slug || ' current takes'); r_result := r_result || 'info'::text;
        r_detail := r_detail || coalesce('refreshed before the reads: ' || v_cur::text, 'no active scheduler user: the documents read live');
        r_ms := r_ms || null::numeric;
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
      end if;
      for rd in
        select x.ord, x.page, x.name, x.sql, x.cls, x.perms, x.skip_state, x.skip_why, x.in_set, 1 as period
        from pg_temp.reads_0131 x where x.part = 'a' and v_part in ('a', 'all')
        union all
        select x.ord, x.page, x.name, x.sql, x.cls, x.perms, x.skip_state, x.skip_why, x.in_set, k.period
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
        v_ms := case when clock_timestamp() > v_stop then null else pg_temp.t0131_best_ms(v_sql, 2) end;
        v_err := case when v_ms = -1 then current_setting('t0131.error') end;
        -- an error the read names as nothing to time (CMA02: no snapshot, or no frozen list, for the as-of date) is a skip
        -- with the database's own words; any other a FAIL, and under provoke every read FAILs
        v_skipped := not v_provoke and v_err is not null and v_err = rd.skip_state;
        r_name := r_name || (t.slug || ' ' || v_page || ': ' || rd.name);
        r_result := r_result || case when v_skipped then 'skip' when v_ms is not null and v_ms >= 0 and v_ms < v_max then 'ok' else 'FAIL' end;
        r_detail := r_detail || case when v_ms is null then 'not timed: the run stopped starting reads at verify.time_budget_s'
                                     when v_skipped then rd.skip_why || ' (' || v_err || ': ' || current_setting('t0131.error_message') || '): nothing to time'
                                     when v_ms = -1 then 'error ' || v_err
                                     else v_ms || ' ms (best of 2) against ' || v_max || ' ms' end;
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
                          when v_pages[p] in ('welcome agent', 'welcome manager', 'welcome admin', 'my hours', 'my schedule', 'messages', 'my account', 'live board',
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
drop function if exists pg_temp.t0131_user(uuid, text[]);
drop table if exists pg_temp.reads_0131;

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.time_0131
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.time_0131 where result = 'FAIL') then 'FAIL'
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
