-- =============================================================================================
-- 247_verify_calls_per_tag.sql: verifies addition 0009zw, Calls per tag
-- =============================================================================================
-- Universal: no seed is assumed. S1 checks the structure on the database itself; block B builds a throwaway tenant inside a
-- subtransaction that is always rolled back, so nothing stays (synthetic data only: people v9zw-…@example.invalid, an
-- invented line and tags, calls on Tuesday 6 October 2026 in Europe/Amsterdam, so the verdict never depends on when it
-- runs); block E reads every active tenant of the database it runs in (the Pulse4all tenants in dev and prod) over its last
-- 14 dates, as the owner with the tenant's context set (each read filters on the tenant it is given), and prints counts only, never a row of anyone. Run as your
-- own IAM login after 246_calls_per_tag.sql, dev first, then prod. Cloud SQL Studio shows no notices: a check that fails
-- raises "FAIL <id>: …" and stops its block; every check that passed writes one row, and the last row is the verdict:
-- "calls_per_tag ok | 9 PASS, 0 FAIL" (provoked: "PROVOKED, NOT A PASS | 0 PASS, 9 FAIL"). A block that stopped counts
-- its checks as FAIL; the verdict is reached only when the client goes on after an error (psql -v ON_ERROR_STOP=0, as the
-- provoked run does; with ON_ERROR_STOP=1, and in Studio, the run ends at the first FAIL, which names the check).
--
--   S1  0009zw recorded, after 0009zv; cma.calls_per_tag_of a stable SQL function with jit off and 50 rows, its columns
--       tag_key, tag_name, meaning, is_counted, outbound, inbound, calls; cma.calls_per_tag a stable plpgsql function with
--       row_kind first; both invoker, owned by cma_owner, executable by cma_app only (not cma_readonly, not PUBLIC)
--   B1  per current tag on the synthetic date: a call with two tags under each, a missed inbound call with a tag under it,
--       a tag that does not count listed (is_counted false) with its meaning, a removed tag not counted and its call
--       untagged, a call of the next date left out; tags by calls, most first; Untagged last with tag_key null
--   B2  the application's read (an analyst): the tag rows, the Untagged row, then the total row with cma.calls_figures_of's
--       calls, inbound and outbound; with totals false no total row; a line without calls: only the Untagged row, 0 0 0
--   B3  the Untagged row equals cma.calls_figures_of's untagged; every tag's calls at least its conversations in
--       cma.calls_tag_use_of
--   B4  refused: an agent (CMA06), a range over 92 days and a malformed line (CMA04)
--   E1  per active tenant, per date of its last 14: the Untagged row (calls) equals cma.calls_figures_of's untagged
--   E2  the same dates: the Untagged row's outbound and inbound plus the distinct tagged calls per direction (cma.calls_of)
--       equal cma.calls_figures_of's outbound and inbound
--   E3  the same dates: every tag's calls at least its conversations in cma.calls_tag_use_of (whole period, group_key null)
--   E4  the same dates through the application's read: the total row equals cma.calls_figures_of's calls, inbound and
--       outbound (row-level security keeps the read to the tenant)
-- Provoke: set provoke below to true; every block must then stop with FAIL, and the verdict says PROVOKED, NOT A PASS.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);   -- 'true' to make every block fail

drop table if exists pg_temp.verify_0009zw;
create temp table verify_0009zw (ord int, check_name text, result text, detail text);

-- A synthetic call as the ingest takes it: five seconds of ringing (none for a missed call), then the talk
create or replace function pg_temp.v9zw_call(p_src text, p_dir text, p_start timestamptz, p_ring integer, p_talk integer, p_tags jsonb)
returns jsonb
language sql immutable
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'sourceId', p_src, 'direction', p_dir, 'startedAt', p_start,
    'answeredAt', p_start + make_interval(secs => p_ring),
    'endedAt', case when p_ring is null then p_start + interval '20 seconds'
                    else p_start + make_interval(secs => p_ring + p_talk) end,
    'numberRef', 'n-v9zw', 'counterpartHash', md5(p_src) || md5(p_src || 'x'), 'tags', p_tags,
    'versionAt', p_start + interval '1 hour'))
$$;

-- The tag rows of cma.calls_per_tag_of as one text, in its own order (the order is the function's: compared as is)
create or replace function pg_temp.v9zw_rows(p_tenant uuid, p_from date, p_to date, p_market text, p_line text)
returns text
language sql stable
as $$
  select string_agg(coalesce(p.tag_name, 'untagged') || ':' || coalesce(p.meaning, '-') || ':'
                    || coalesce(case p.is_counted when true then 't' when false then 'f' end, '-') || ':'
                    || p.outbound || '/' || p.inbound || '/' || p.calls, ' | ' order by p.n)
  from cma.calls_per_tag_of(p_tenant, p_from, p_to, p_market, p_line) with ordinality p(tag_key, tag_name, meaning, is_counted, outbound, inbound, calls, n)
$$;

-- S1. The addition, the functions, their rights
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_of      text := 'cma.calls_per_tag_of(uuid,date,date,text,text)';
  v_app     text := 'cma.calls_per_tag(date,date,text,text,boolean)';
  f         text;
  p         pg_proc;
begin
  if v_provoke or not exists (select 1 from cma.schema_migration where version = '0009zw')
     or (select applied_at from cma.schema_migration where version = '0009zw')
        < (select applied_at from cma.schema_migration where version = '0009zv') then
    raise exception 'FAIL S1: addition 0009zw not recorded after 0009zv';
  end if;
  foreach f in array array[v_of, v_app] loop
    select * into p from pg_proc where oid = to_regprocedure(f);
    if p.oid is null or p.prosecdef or p.provolatile <> 's'
       or (select l.lanname from pg_language l where l.oid = p.prolang) <> (case when f = v_of then 'sql' else 'plpgsql' end)
       or p.proowner <> 'cma_owner'::regrole::oid
       or not has_function_privilege('cma_app', f, 'execute') or has_function_privilege('cma_readonly', f, 'execute')
       or exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0) then
      raise exception 'FAIL S1: % is not a stable invoker function of cma_owner for cma_app only', f;
    end if;
  end loop;
  select * into p from pg_proc where oid = to_regprocedure(v_of);
  if p.prorows <> 50 or not coalesce('jit=off' = any(p.proconfig), false)
     or array_to_string(p.proargnames[6:], ',') <> 'tag_key,tag_name,meaning,is_counted,outbound,inbound,calls' then
    raise exception 'FAIL S1: % without rows 50, jit off or its seven columns (%; %; %)', v_of, p.prorows, p.proconfig, p.proargnames;
  end if;
  select * into p from pg_proc where oid = to_regprocedure(v_app);
  if array_to_string(p.proargnames[6:], ',') <> 'row_kind,tag_key,tag_name,meaning,is_counted,outbound,inbound,calls' then
    raise exception 'FAIL S1: % columns are %', v_app, p.proargnames;
  end if;
  insert into verify_0009zw values (1, 'S1 addition, functions and rights', 'PASS',
    'calls_per_tag_of: stable sql, jit off, rows 50; calls_per_tag: stable plpgsql, row_kind first; invoker, cma_owner, cma_app only');
end
$$;

-- B. A throwaway tenant (rolled back): one line, three tags, calls on 6 October 2026
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  v_t uuid; v_admin uuid; v_analyst uuid; v_agent uuid; v_ing uuid; v_tel uuid;
  v_d       timestamptz := timestamptz '2026-10-06 08:00:00+00';   -- Tuesday 6 October 2026, 10:00 in Amsterdam
  v_day     date := date '2026-10-06';
  v_nr      jsonb := '[{"tagRef": "tg-nr", "name": "Not Reached"}]';
  v_nr_type jsonb := '[{"tagRef": "tg-nr", "name": "Not Reached"}, {"tagRef": "tg-type", "name": "Type"}]';
  v_type    jsonb := '[{"tagRef": "tg-type", "name": "Type"}]';
  v_off     jsonb := '[{"tagRef": "tg-off", "name": "Wrong Number"}]';
  v_txt text; v_exp text; v_got text;
begin
  begin
    v_t := cma.create_tenant('verify-0009zw', 'Verify 0009zw', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'v9zw-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'v9zw-analyst@example.invalid', 'analyst') returning id into v_analyst;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'v9zw-agent@example.invalid', 'agent') returning id into v_agent;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_admin, 'admin'), (v_analyst, 'analytics'), (v_agent, 'agent')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t and ar.key = x.role_key;
    select x.user_id into v_ing from cma.app_user_external_id x where x.tenant_id = v_t and x.system = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t, 'verifytel', 'Verify 0009zw telephony', 'tel-v9zw', 'telephony') returning id into v_tel;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);

    -- the catalogs (the Ingest user), then the configuration (the admin): the line, the meanings, Wrong Number not counted
    perform set_config('app.user_id', v_ing::text, true);
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'number', '[{"numberRef": "n-v9zw", "name": "Verify 0009zw line", "digits": "+31000000009"}]');
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'tag', '[{"tagRef": "tg-nr", "name": "Not Reached"},
      {"tagRef": "tg-type", "name": "Type"}, {"tagRef": "tg-off", "name": "Wrong Number"}]');
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.set_telephony_number(v_tel, 'n-v9zw', 'NL', true);
    perform cma.set_telephony_tag_meaning(v_tel, 'tg-nr', 'not_reached');
    perform cma.set_telephony_tag_meaning(v_tel, 'tg-type', 'call_type');
    perform cma.set_telephony_tag_meaning(v_tel, 'tg-off', 'incorrect_data');
    perform cma.set_telephony_tag(v_tel, 'tg-off', false);

    -- the calls (the Ingest user): o1 Not Reached (8 s), o2 Not Reached and Type (40 s), o3 no answer and no tag, o4 Wrong
    -- Number (not counted), o5 Not Reached removed later (untagged), i1 answered with Type (45 s, a conversation), i2 missed
    -- without a tag, i3 missed with Not Reached; x1 the next date with Not Reached (outside the period)
    perform set_config('app.user_id', v_ing::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      pg_temp.v9zw_call('o1', 'outbound', v_d,                            5, 8,    v_nr),
      pg_temp.v9zw_call('o2', 'outbound', v_d + interval '10 minutes',   5, 40,   v_nr_type),
      pg_temp.v9zw_call('o3', 'outbound', v_d + interval '20 minutes',   null, null, null),
      pg_temp.v9zw_call('o4', 'outbound', v_d + interval '30 minutes',   5, 12,   v_off),
      pg_temp.v9zw_call('o5', 'outbound', v_d + interval '40 minutes',   5, 3,    v_nr),
      pg_temp.v9zw_call('i1', 'inbound',  v_d + interval '50 minutes',   5, 45,   v_type),
      pg_temp.v9zw_call('i2', 'inbound',  v_d + interval '60 minutes',   null, null, null),
      pg_temp.v9zw_call('i3', 'inbound',  v_d + interval '70 minutes',   null, null, v_nr),
      pg_temp.v9zw_call('x1', 'outbound', v_d + interval '1 day',        5, 8,    v_nr)));
    -- o5's Not Reached removed later: an empty tag set closes it
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      pg_temp.v9zw_call('o5', 'outbound', v_d + interval '40 minutes', 5, 3, '[]'::jsonb)
        || jsonb_build_object('versionAt', v_d + interval '5 hours')));

    -- B1. the tag rows and the Untagged row of the date, in the function's order
    perform set_config('app.user_id', v_analyst::text, true);
    v_txt := pg_temp.v9zw_rows(v_t, v_day, v_day, null, null);
    v_exp := 'Not Reached:not_reached:t:2/1/3 | Type:call_type:t:1/1/2 | Wrong Number:incorrect_data:f:1/0/1 | untagged:-:-:2/1/3';
    if v_provoke or v_txt is distinct from v_exp then
      raise exception 'FAIL B1: % (expected %)', coalesce(v_txt, 'no rows'), v_exp;
    end if;
    v_rows := v_rows || array['11', 'B1 per tag by direction: two tags under each, a missed call under its tag, a tag that does not count listed, a removed tag not counted, the next date left out; Untagged last', 'PASS', v_txt];

    -- B2. the application's read: tag rows, Untagged, the total (cma.calls_figures_of's); totals false; a line without calls
    select string_agg(c.row_kind || coalesce(':' || c.tag_name, '') || ':' || c.outbound || '/' || c.inbound || '/' || c.calls, ' | ' order by c.n)
      into v_txt
    from cma.calls_per_tag(v_day, v_day, null, null) with ordinality c(row_kind, tag_key, tag_name, meaning, is_counted, outbound, inbound, calls, n);
    select v_txt || ' || ' || string_agg(c.row_kind, ',' order by c.n)
      into v_txt
    from cma.calls_per_tag(v_day, v_day, null, null, false) with ordinality c(row_kind, tag_key, tag_name, meaning, is_counted, outbound, inbound, calls, n);
    select v_txt || ' || ' || string_agg(c.row_kind || ':' || c.outbound || '/' || c.inbound || '/' || c.calls, ',' order by c.n)
      into v_txt
    from cma.calls_per_tag(v_day, v_day, null, v_tel::text || ':n-none', false) with ordinality c(row_kind, tag_key, tag_name, meaning, is_counted, outbound, inbound, calls, n);
    select v_txt || ' || figures ' || f.outbound || '/' || f.inbound || '/' || f.calls into v_txt
    from cma.calls_figures_of(v_t, v_day, v_day, null, null, 'day') f where f.group_key is null;
    v_exp := 'tag:Not Reached:2/1/3 | tag:Type:1/1/2 | tag:Wrong Number:1/0/1 | untagged:2/1/3 | total:5/3/8 || tag,tag,tag,untagged || untagged:0/0/0 || figures 5/3/8';
    if v_provoke or v_txt is distinct from v_exp then
      raise exception 'FAIL B2: % (expected %)', coalesce(v_txt, 'no rows'), v_exp;
    end if;
    v_rows := v_rows || array['12', 'B2 the application''s read: the rows, Untagged, the total as cma.calls_figures_of; totals false; a line without calls', 'PASS', v_txt];

    -- B3. Untagged as cma.calls_figures_of; every tag's calls at least its conversations
    select format('untagged %s against %s; tags below their conversations: %s',
                  (select p.calls from cma.calls_per_tag_of(v_t, v_day, v_day, null, null) p where p.tag_key is null),
                  (select f.untagged from cma.calls_figures_of(v_t, v_day, v_day, null, null, 'day') f where f.group_key is null),
                  (select count(*) from cma.calls_tag_use_of(v_t, v_day, v_day, null, null, 'day') u
                   left join cma.calls_per_tag_of(v_t, v_day, v_day, null, null) p on p.tag_key = u.tag_key
                   where u.group_key is null and coalesce(p.calls, 0) < u.conversations))
      into v_txt;
    if v_provoke or v_txt is distinct from 'untagged 3 against 3; tags below their conversations: 0'
       or (select count(*) from cma.calls_tag_use_of(v_t, v_day, v_day, null, null, 'day') u where u.group_key is null) <> 1 then
      raise exception 'FAIL B3: %', v_txt;
    end if;
    v_rows := v_rows || array['13', 'B3 Untagged as cma.calls_figures_of; every tag''s calls at least its conversations (Type: 2 calls, 1 conversation)', 'PASS', v_txt];

    -- B4. refused: an agent, more than 92 days, a malformed line
    v_got := '';
    perform set_config('app.user_id', v_agent::text, true);
    begin
      perform * from cma.calls_per_tag(v_day, v_day, null, null);
      v_got := v_got || 'ok ';
    exception when others then v_got := v_got || sqlstate || ' ';
    end;
    perform set_config('app.user_id', v_analyst::text, true);
    begin
      perform * from cma.calls_per_tag(v_day - 100, v_day, null, null);
      v_got := v_got || 'ok ';
    exception when others then v_got := v_got || sqlstate || ' ';
    end;
    begin
      perform * from cma.calls_per_tag(v_day, v_day, null, 'not-a-line');
      v_got := v_got || 'ok';
    exception when others then v_got := v_got || sqlstate;
    end;
    if v_provoke or v_got <> 'CMA06 CMA04 CMA04' then
      raise exception 'FAIL B4: % (expected CMA06 CMA04 CMA04)', v_got;
    end if;
    v_rows := v_rows || array['14', 'B4 refused: an agent (CMA06), more than 92 days and a malformed line (CMA04)', 'PASS', v_got];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
  end;
  perform set_config('role', 'cma_owner', true);
  insert into verify_0009zw select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- E. Every active tenant of this database, its last 14 dates (counts only)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  t record;
  v_user uuid;
  v_today date; v_day date;
  v_dates integer := 0; v_calls bigint := 0; v_tags bigint := 0;
  v_e1 text; v_e2 text; v_e3 text; v_e4 text;
  v_detail text := '';
begin
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.tenant_id', t.id::text, true);
    perform set_config('app.user_id', '', true);
    v_today := cma.tenant_today_of(t.id);
    v_dates := 0; v_calls := 0; v_tags := 0;
    for v_day in select d::date from generate_series(v_today - 13, v_today, interval '1 day') d loop
      -- E1, E2, E3 as the owner; each read filters on the tenant it is given (the owner is not held to row-level security)
      select format('%s/%s/%s', p.outbound, p.inbound, p.calls) into v_e1
      from cma.calls_per_tag_of(t.id, v_day, v_day, null, null) p where p.tag_key is null;
      select format('%s/%s/%s|%s/%s', f.untagged, f.outbound, f.inbound, f.outbound, f.inbound), f.calls
        into v_e2, v_calls
      from cma.calls_figures_of(t.id, v_day, v_day, null, null, 'day') f where f.group_key is null;
      -- the Untagged row's calls equal untagged (E1); its outbound and inbound plus the distinct tagged calls per direction
      -- equal the figures' outbound and inbound (E2)
      if v_provoke or split_part(v_e1, '/', 3) <> split_part(split_part(v_e2, '|', 1), '/', 1) then
        raise exception 'FAIL E1 %, %: the Untagged row % against calls_figures_of''s untagged %', t.slug, v_day, v_e1, split_part(v_e2, '/', 1);
      end if;
      select format('%s/%s', split_part(v_e1, '/', 1)::integer + count(*) filter (where c.is_tagged and c.direction = 'outbound'),
                             split_part(v_e1, '/', 2)::integer + count(*) filter (where c.is_tagged and c.direction = 'inbound'))
        into v_e4
      from cma.calls_of(t.id, (v_day - 1)::timestamp at time zone (select z.timezone from cma.tenant z where z.id = t.id),
                        (v_day + 2)::timestamp at time zone (select z.timezone from cma.tenant z where z.id = t.id), null, null) c
      where c.business_date = v_day;
      if v_e4 is distinct from split_part(v_e2, '|', 2) then
        raise exception 'FAIL E2 %, %: untagged plus distinct tagged calls % against calls_figures_of''s outbound/inbound %', t.slug, v_day, v_e4, split_part(v_e2, '|', 2);
      end if;
      select count(*) into v_e3
      from cma.calls_tag_use_of(t.id, v_day, v_day, null, null, 'day') u
      left join cma.calls_per_tag_of(t.id, v_day, v_day, null, null) p on p.tag_key = u.tag_key
      where u.group_key is null and coalesce(p.calls, 0) < u.conversations;
      if v_e3 <> '0' then
        raise exception 'FAIL E3 %, %: % tag(s) with fewer calls than conversations', t.slug, v_day, v_e3;
      end if;
      v_tags := v_tags + (select count(*) from cma.calls_per_tag_of(t.id, v_day, v_day, null, null) p where p.tag_key is not null);
      v_dates := v_dates + 1;
    end loop;
    v_detail := v_detail || format('%s: %s dates, %s calls on the last, %s tag rows; ', t.slug, v_dates, v_calls, v_tags);
  end loop;
  perform set_config('role', 'cma_owner', true);
  insert into verify_0009zw values (21, 'E1 per active tenant and date of the last 14: the Untagged row equals cma.calls_figures_of''s untagged', 'PASS', v_detail);
  insert into verify_0009zw values (22, 'E2 the same dates: Untagged plus the distinct tagged calls per direction equal cma.calls_figures_of''s outbound and inbound', 'PASS', v_detail);
  insert into verify_0009zw values (23, 'E3 the same dates: every tag''s calls at least its conversations in cma.calls_tag_use_of', 'PASS', v_detail);
end
$$;

-- E4. The application's read per active tenant: the total row is cma.calls_figures_of's (as a person holding reports.view)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  t record;
  v_user uuid; v_today date; v_day date;
  v_a text; v_b text; v_n integer;
  v_detail text := '';
begin
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.tenant_id', t.id::text, true);
    perform set_config('app.user_id', '', true);
    select u.id into v_user from cma.app_user u
    where u.tenant_id = t.id and u.status = 'active' and cma.has_permission(u.id, 'reports.view')
    order by u.id limit 1;
    if v_user is null then
      v_detail := v_detail || t.slug || ': no active person holds reports.view, not read; ';
      continue;
    end if;
    v_today := cma.tenant_today_of(t.id);
    v_n := 0;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_user::text, true);
    for v_day in select d::date from generate_series(v_today - 13, v_today, interval '1 day') d loop
      select format('%s/%s/%s', c.calls, c.inbound, c.outbound) into v_a
      from cma.calls_per_tag(v_day, v_day, null, null) c where c.row_kind = 'total';
      select format('%s/%s/%s', f.calls, f.inbound, f.outbound) into v_b
      from cma.calls_figures_of(t.id, v_day, v_day, null, null, 'day') f where f.group_key is null;
      if v_provoke or v_a is distinct from v_b then
        perform set_config('role', 'cma_owner', true);
        raise exception 'FAIL E4 %, %: total row % against calls_figures_of %', t.slug, v_day, coalesce(v_a, 'none'), coalesce(v_b, 'none');
      end if;
      v_n := v_n + 1;
    end loop;
    perform set_config('role', 'cma_owner', true);
    v_detail := v_detail || format('%s: %s dates; ', t.slug, v_n);
  end loop;
  perform set_config('role', 'cma_owner', true);
  insert into verify_0009zw values (24, 'E4 the application''s read: the total row equals cma.calls_figures_of''s calls, inbound and outbound', 'PASS', v_detail);
end
$$;

-- Verdict: one row per check that passed, then the verdict (9 checks; a block that stopped counts its checks as FAIL)
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0009zw
      union all
      select 999, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0009zw where result = 'PASS') = 9 then 'calls_per_tag ok'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0009zw where result = 'PASS'),
                                        9 - (select count(*) from verify_0009zw where result = 'PASS'))) x
order by ord;
drop function if exists pg_temp.v9zw_rows(uuid, date, date, text, text);
drop function if exists pg_temp.v9zw_call(text, text, timestamptz, integer, integer, jsonb);
drop table if exists pg_temp.verify_0009zw;
reset role;
