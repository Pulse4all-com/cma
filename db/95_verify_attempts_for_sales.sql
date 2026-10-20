-- =============================================================================================
-- 95_verify_attempts_for_sales.sql: verifies addition 0008z, attempts per deal for sales and message withdrawal
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure and privileges;
-- blocks B and C work on throwaway tenants inside subtransactions that are always rolled back. Universal otherwise:
-- nothing of the seed is used; adapters, pipelines, deals, contacts, calls, lines, orders, owners and messages are
-- invented data values, and no row carries a name of a customer, an address or a phone number. Every check writes one
-- row, PASS or FAIL, and the last result lists them with the verdict, because Cloud SQL Studio shows no notices. Run
-- as your own IAM login in dev, after 94_attempts_for_sales.sql; then 93, 41, 61, 69, 73, 75, 77, 81, 83, 85, 89 and
-- 91 again (91 from the Terminal: it runs longer than Studio's 300 seconds on dev's shared core).
--   A  structure and privileges: the addition row after 0008y; every function the application's only and in the
--      caller's rights, the readers' function definer, the owner's, its search path pinned with pg_temp last, the
--      readers' only, and 0008y's reads with the scope gone; the reader view's exact columns, with no name, address,
--      email, phone, hash or raw; the three settings in the catalog; the calls, the orders and the window each written
--      once (cma.lead_calls_of over cma.deal_calls_of, cma.lead_to_order_of over cma.contact_store_orders_of, the
--      reads over cma.sales_deals_of and cma.deal_attempts_of); the message's withdrawal columns, trigger and grants,
--      cma_read.message, the permission on the default ladder's admin role of every tenant; nothing twice
--   B  attempts, on two throwaway tenants (Europe/Amsterdam; intake from 1 September 2026; pre-window 10 minutes;
--      market NL with office hours Monday to Friday 09:00-17:00). Tenant one holds a CRM connection with a lead
--      pipeline (open, won, lost and a closed stage without an outcome), an order pipeline still marked lead, a
--      counted pipeline that is no lead pipeline and an uncounted one; a telephony connection (a counted NL line, and
--      a line not yet in the catalog); a shop; owners o-1 Anna and o-2 Bram linked, o-3 not; telephony user tu-1
--      linked to Anna, tu-9 to nobody; and the deals of 5 to 11 October 2026 (one of the week before) with their
--      calls and orders: won after four attempts (29 s, 30 s, an outcome Connected with 5 s), a call logged without
--      the telephony call, a call after the close; lost (Left voicemail with 90 s, answered with 0 s, a store order
--      after the close); lost never attempted; open with a won order deal of its contact (a call before it in, one
--      after out); open with a store order after a test, a cancelled and a deleted one; open with an order before
--      its creation; open with an order deal on a contact no longer associated; open with a first CRM call logged
--      without the telephony call; open never attempted; closed without an outcome. Tenant two has a deal of the
--      same source id. Checked as of fixed instants: the population, the attempts under telephony and crm, the
--      window, reached and the setting's edge, talk time, the first reached attempt, the speed to lead against
--      0007d's, one deal's attempts with the agent's name gated, the filters, won against lost, the win rate by
--      attempts and by speed to lead, the figures, the list, per person, the setting and parameter refusals, the
--      reader view equal to the application's rows, tenant isolation, and 0007d's reads (Speed to lead's and lead to
--      order's) giving the rows of 0007d's bodies (copies in pg_temp)
--   C  messages, on two throwaway tenants: an admin withdraws a manual message and an alert; a sender without the
--      permission, an agent and another tenant refused; a recipient's inbox and unread count without them, a
--      delivery not yet made never made; the stats marking them; the audit row; a second withdrawal changing nothing;
--      nothing else of a message changing
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says PROVOKED instead of PASS.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);   -- 'true' to make every check fail

-- Dev only: a verifier that writes refuses a database without the dev seed. The flag is kept for the session, so every
-- block below stops at once and the verdict says REFUSED, also where the client carries on after the error
select set_config('verify.is_dev', (exists (select 1 from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                            where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false) as is_dev;
do $$
begin
  if not current_setting('verify.is_dev')::boolean then
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 95 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008z;
create temp table verify_0008z (ord int, check_name text, result text, detail text);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008z_code(p_sql text)
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

-- The deals of 5 to 11 October 2026 as text: source id, attempts, reached, first reached, talk in all and in contact,
-- attempts without an outcome, calls logged without the telephony call
create or replace function pg_temp.v0008z_deals(p_tenant uuid, p_now timestamptz)
returns text
language sql
as $$
  select string_agg(format('%s:%s/%s/%s/%s/%s/%s/%s', x.deal_source_id, x.attempts, x.reached_attempts, coalesce(x.first_reached_attempt::text, '-'),
                           x.talk_seconds_total, x.talk_seconds_reached, x.attempts_without_outcome, x.logged_without_aircall),
                    ' ' order by x.deal_source_id)
  from cma.attempts_per_deal_of(p_tenant, timestamptz '2026-10-04 22:00:00+00', timestamptz '2026-10-11 22:00:00+00', p_now) x
$$;

-- The figures of a JSON object: deals/attempted/attempts/avg/median/reached_deals/first_reached/median speed/
-- called before noon of known/open/open never/won/lost/ordered/unknown/talk/talk in contact/without outcome/logged
-- without the telephony call
create or replace function pg_temp.v0008z_fig(f jsonb)
returns text
language sql immutable
as $$
  select format('%s/%s/%s/%s/%s/%s/%s/%s/%sof%s/%s/%s/%s/%s/%s/%s/%s/%s/%s/%s', f ->> 'deals', f ->> 'attempted', f ->> 'attempts',
                coalesce(f ->> 'avg_attempts', '-'), coalesce(f ->> 'median_attempts', '-'), f ->> 'reached_deals', f ->> 'first_reached',
                coalesce(f ->> 'median_speed_seconds', '-'), f ->> 'called_before_noon', f ->> 'noon_known', f ->> 'open_deals',
                f ->> 'open_never_attempted', f ->> 'won', f ->> 'lost', f ->> 'ordered', f ->> 'unknown', f ->> 'talk_seconds_total',
                f ->> 'talk_seconds_reached', f ->> 'attempts_without_outcome', f ->> 'logged_without_aircall')
$$;

-- 0007d's cma.lead_calls_of, copied as it was before 0008z, so B21 can prove the calls written once give its rows
create or replace function pg_temp.v0008z_lead_calls_0007d(p_tenant_id uuid, p_connection_id uuid, p_record_type text,
                                                          p_source_id text, p_contacts text[], p_not_before timestamptz)
returns table (call_id uuid, call_source_id text, source_system text, direction text, owner_ref text, effective_at timestamptz,
               is_linked boolean, is_connected boolean)
language sql stable
as $$
  select c.id, c.source_id, c.source_system, c.direction, c.owner_ref,
         coalesce(tc.started_at, c.occurred_at), tc.started_at is not null,
         coalesce(o.is_connected, false) or tc.answered_at is not null
  from cma.crm_call c
  left join cma.call_link l
    on l.tenant_id = c.tenant_id and l.crm_call_id = c.id and l.unlinked_at is null
  left join cma.telephony_call tc
    on tc.tenant_id = l.tenant_id and tc.id = l.telephony_call_id and tc.source_deleted_at is null
  left join cma.connection_call_outcome o
    on o.tenant_id = c.tenant_id and o.connection_id = c.connection_id and o.outcome_ref = c.outcome_ref
  where c.tenant_id = p_tenant_id
    and c.connection_id = p_connection_id
    and c.source_deleted_at is null
    and coalesce(tc.started_at, c.occurred_at) >= p_not_before
    and exists (select 1 from cma.crm_association a
                where a.tenant_id = c.tenant_id and a.connection_id = c.connection_id
                  and a.from_type = 'crm_call' and a.from_id = c.source_id and a.removed_at is null
                  and ((a.to_type = p_record_type and a.to_id = p_source_id)
                       or (a.to_type = 'contact' and a.to_id = any (p_contacts))))
$$;

-- 0007d's cma.lead_to_order_of, copied as it was before 0008z
create or replace function pg_temp.v0008z_lead_to_order_0007d(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns setof cma.lead_to_order_row
language sql stable
as $$
  with s as (
    select cma.setting_of(p_tenant_id, 'lead_to_order.max_days')::integer as max_days
  ),
  refs as (
    select d.deal_id, r.system, r.external_id
    from cma.lead_deals_of(p_tenant_id, p_from, p_to) d
    join cma.crm_contact k
      on k.tenant_id = p_tenant_id and k.connection_id = d.connection_id and k.source_id = any (d.contacts)
    join cma.crm_contact_ref r on r.tenant_id = k.tenant_id and r.contact_id = k.id
    group by 1, 2, 3
  )
  select p_tenant_id, d.deal_id, d.connection_id, d.source_id, d.pipeline_id, d.pipeline_label, d.business_date,
         d.created_at, d.market,
         (select count(*) from refs where refs.deal_id = d.deal_id)::integer,
         o.id, o.connection_id, o.source_id, o.handle, o.source_created_at, o.order_kind, o.currency, o.total_amount,
         case when o.id is not null then round(extract(epoch from o.source_created_at - d.created_at) / 86400, 2) end
  from cma.lead_deals_of(p_tenant_id, p_from, p_to) d
  cross join s
  left join lateral (
    select co.id, co.connection_id, co.source_id, st.handle, co.source_created_at, co.order_kind, co.currency, co.total_amount
    from refs
    join cma.commerce_order co
      on co.tenant_id = p_tenant_id and co.source_system = refs.system and co.customer_source_id = refs.external_id
    left join cma.commerce_store st on st.tenant_id = co.tenant_id and st.connection_id = co.connection_id
    where refs.deal_id = d.deal_id
      and not co.is_test and co.cancelled_at is null and co.source_deleted_at is null
      and co.source_created_at >= d.created_at
      and co.source_created_at <= d.created_at + make_interval(days => s.max_days)
    order by co.source_created_at, co.id
    limit 1) o on true
$$;

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text;
  v_fn      text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded, after 0008y
  insert into verify_0008z values (1, 'A1 addition 0008z recorded, after 0008y',
    case when exists (select 1 from cma.schema_migration where version = '0008z')
              and exists (select 1 from cma.schema_migration where version = '0008y') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. every function of the addition the application's only and in the caller's rights; the readers' function SECURITY
  --     DEFINER, owned by cma_owner, search path pinned with pg_temp last, the readers' only; 0008y's reads with the scope gone
  v_bad := '';
  foreach v_fn in array array[
    'cma.deal_calls_of(uuid,uuid,text,text,text[],timestamptz)', 'cma.lead_calls_of(uuid,uuid,text,text,text[],timestamptz)',
    'cma.contact_store_orders_of(uuid)', 'cma.lead_to_order_of(uuid,timestamptz,timestamptz)',
    'cma.sales_deals_of(uuid,timestamptz,timestamptz,timestamptz)',
    'cma.deal_attempts_of(uuid,uuid,text,text,text[],timestamptz,timestamptz,text,integer)',
    'cma.attempts_per_deal_of(uuid,timestamptz,timestamptz,timestamptz)', 'cma.attempts_choices_check(text,text)',
    'cma.attempts_rows_of(uuid,date,date,timestamptz)',
    'cma.attempts_in_period(cma.attempt_deal[],date,date,text,text,text,text,timestamptz,text)',
    'cma.attempts_figures_from(cma.attempt_deal[])', 'cma.attempts_buckets_from(cma.attempt_deal[],integer)',
    'cma.attempts_outcomes_from(cma.attempt_deal[])', 'cma.attempts_speed_buckets_from(cma.attempt_deal[],text)',
    'cma.attempts_since_last_from(cma.attempt_deal[],text)', 'cma.attempts_groups_from(cma.attempt_deal[],text)',
    'cma.attempts_list_from(cma.attempt_deal[],integer)', 'cma.attempts_filter_lists_from(cma.attempt_deal[])',
    'cma.attempts_settings_of(uuid)', 'cma.attempts_per_deal_page_of(uuid,date,date,text,text,text,text,text,integer,timestamptz)',
    'cma.attempts_per_person_of(uuid,date,date,text,text,text,text,timestamptz)',
    'cma.attempts_params_check(uuid,date,date,text,text,text,text)', 'cma.attempts_per_deal_page(date,date,text,text,text,text,text,integer)',
    'cma.attempts_per_person_page(date,date,text,text,text,text)', 'cma.attempts_of_deal(uuid)', 'cma.withdraw_message(uuid)',
    'cma.my_messages(timestamptz,integer)', 'cma.my_unread_count()', 'cma.mark_messages_read(uuid[])', 'cma.acknowledge_message(uuid)',
    'cma.message_stats(date,date)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or has_function_privilege('public', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' not the application''s only or not in the caller''s rights; ';
    end if;
  end loop;
  v_fn := 'cma_read.attempts_per_deal_rows()';
  if to_regprocedure(v_fn) is null then
    v_bad := v_bad || v_fn || ' missing; ';
  elsif not (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
        or (select pg_get_userbyid(proowner) from pg_proc where oid = to_regprocedure(v_fn)) <> 'cma_owner'
        or not coalesce((select array_to_string(proconfig, ',') from pg_proc where oid = to_regprocedure(v_fn)) like 'search_path=%pg_temp', false)
        or not has_function_privilege('cma_readonly', v_fn, 'execute') or has_function_privilege('cma_app', v_fn, 'execute')
        or has_function_privilege('public', v_fn, 'execute') then
    v_bad := v_bad || v_fn || ' not the readers'' pinned definer function; ';
  end if;
  foreach v_fn in array array['cma.attempts_scope_check(text)', 'cma.attempts_per_deal_of(uuid,timestamptz,timestamptz,text,timestamptz)',
                              'cma.attempts_rows_of(uuid,date,date,text,timestamptz)', 'cma.attempts_params_check(uuid,date,date,text,text,text)',
                              'cma.attempts_per_deal_page(date,date,text,text,text,text,integer)', 'cma.attempts_per_person_page(date,date,text,text,text)'] loop
    if to_regprocedure(v_fn) is not null then
      v_bad := v_bad || v_fn || ' still there; ';
    end if;
  end loop;
  insert into verify_0008z values (2, 'A2 every function the application''s only and invoker; the readers'' function definer, the owner''s, pinned, theirs only; the scope gone',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. the reader view's exact columns, readable by the readers, none named like a name, an address, an email, a phone, a
  --     hash or a payload
  v_bad := '';
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'attempts_per_deal')
     is distinct from 'tenant_id,deal_id,connection_id,deal_source_id,pipeline_id,pipeline_label,stage_id,market,owner_user_id,created_at,'
                      'business_date,is_closed,closed_at,ordered_at,window_end_reason,outcome,attempts,reached_attempts,first_reached_attempt,'
                      'talk_seconds_total,talk_seconds_reached,first_attempt_at,speed_to_lead_seconds,called_before_next_noon,last_attempt_at,'
                      'business_days_since_last,since_last_bucket,attempts_without_outcome,logged_without_aircall'
     or not has_table_privilege('cma_readonly', 'cma_read.attempts_per_deal', 'select') then
    v_bad := 'cma_read.attempts_per_deal; ';
  end if;
  select v_bad || coalesce(string_agg(column_name, ', '), '') into v_bad
  from information_schema.columns
  where table_schema = 'cma_read' and table_name = 'attempts_per_deal'
    and column_name ~* '(name|address|email|phone|number|_hash$|^raw$|_ref$)';
  insert into verify_0008z values (3, 'A3 the reader view with its exact columns; no name, address, email, phone, hash or payload',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. the three settings in the catalog with their types, defaults and allowed values
  select string_agg(format('%s:%s:%s:%s', s.key, s.value_type, s.default_value, coalesce(array_to_string(s.allowed_values, '|'), '-')), ' ' order by s.key)
    into v_bad
  from cma.setting s where s.key in ('attempts.source', 'attempts.reached_min_talk_seconds', 'attempts.speed_buckets_business_minutes');
  insert into verify_0008z values (4, 'A4 the three settings in the catalog',
    case when v_bad = 'attempts.reached_min_talk_seconds:integer:30:- attempts.source:text:telephony:telephony|crm attempts.speed_buckets_business_minutes:text:5,15,60,240,1440:-'
          and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A5. written once: the calls (cma.lead_calls_of over cma.deal_calls_of), the store orders (cma.lead_to_order_of and the
  --     window over cma.contact_store_orders_of), the window over cma.counted_deals_of, the attempts over cma.deal_calls_of,
  --     the definition and one deal's attempts over the window and the attempts; 0007d's business time reused
  v_bad := '';
  foreach v_fn in array array[
    'cma.lead_calls_of(uuid,uuid,text,text,text[],timestamptz)|cma\.deal_calls_of\(',
    'cma.lead_to_order_of(uuid,timestamptz,timestamptz)|cma\.contact_store_orders_of\(',
    'cma.sales_deals_of(uuid,timestamptz,timestamptz,timestamptz)|cma\.counted_deals_of\(',
    'cma.sales_deals_of(uuid,timestamptz,timestamptz,timestamptz)|cma\.contact_store_orders_of\(',
    'cma.deal_attempts_of(uuid,uuid,text,text,text[],timestamptz,timestamptz,text,integer)|cma\.deal_calls_of\(',
    'cma.attempts_per_deal_of(uuid,timestamptz,timestamptz,timestamptz)|cma\.sales_deals_of\(',
    'cma.attempts_per_deal_of(uuid,timestamptz,timestamptz,timestamptz)|cma\.deal_attempts_of\(',
    'cma.attempts_per_deal_of(uuid,timestamptz,timestamptz,timestamptz)|cma\.business_seconds_of\(',
    'cma.attempts_per_deal_of(uuid,timestamptz,timestamptz,timestamptz)|cma\.next_business_noon_of\(',
    'cma.attempts_of_deal(uuid)|cma\.sales_deals_of\(', 'cma.attempts_of_deal(uuid)|cma\.deal_attempts_of\('] loop
    if (select p.prosrc from pg_proc p where p.oid = to_regprocedure(split_part(v_fn, '|', 1))) !~ split_part(v_fn, '|', 2) then
      v_bad := v_bad || split_part(v_fn, '|', 1) || ' does not read ' || split_part(v_fn, '|', 2) || '; ';
    end if;
  end loop;
  if (select p.prosrc from pg_proc p where p.oid = to_regprocedure('cma.lead_calls_of(uuid,uuid,text,text,text[],timestamptz)')) ~ 'cma\.crm_call\M'
     or (select p.prosrc from pg_proc p where p.oid = to_regprocedure('cma.lead_to_order_of(uuid,timestamptz,timestamptz)')) ~ 'cma\.commerce_order\M' then
    v_bad := v_bad || 'a rule written twice; ';
  end if;
  insert into verify_0008z values (5, 'A5 the calls, the store orders and the window each written once; 0007d''s business time reused',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A6. the message's withdrawal: both columns, set together, by a person of the tenant; the trigger; the application
  --     updates those two columns only and deletes nothing; cma_read.message with both last; messages.withdraw in the
  --     catalog, on the default ladder's admin role (cma.seed_default_roles) and on every tenant's system admin role
  v_bad := '';
  if (select string_agg(column_name || ':' || data_type, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma' and table_name = 'message' and column_name in ('withdrawn_at', 'withdrawn_by'))
     is distinct from 'withdrawn_at:timestamp with time zone,withdrawn_by:uuid' then
    v_bad := v_bad || 'columns; ';
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'cma.message'::regclass and conname = 'message_withdrawn_check')
     or not exists (select 1 from pg_constraint where conrelid = 'cma.message'::regclass and conname = 'message_withdrawn_by_fkey')
     or not exists (select 1 from pg_trigger where tgrelid = 'cma.message'::regclass and tgname = 'check_withdraw_once' and not tgisinternal) then
    v_bad := v_bad || 'check, key or trigger; ';
  end if;
  if not has_column_privilege('cma_app', 'cma.message', 'withdrawn_at', 'update') or not has_column_privilege('cma_app', 'cma.message', 'withdrawn_by', 'update')
     or has_column_privilege('cma_app', 'cma.message', 'title', 'update') or has_column_privilege('cma_app', 'cma.message', 'body', 'update')
     or has_column_privilege('cma_app', 'cma.message', 'created_at', 'update') or has_table_privilege('cma_app', 'cma.message', 'delete') then
    v_bad := v_bad || 'cma_app''s privileges; ';
  end if;
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'message')
     is distinct from 'id,tenant_id,kind,urgency,title,body,ref_system,ref_type,ref_id,ref_url,rule_id,target,sender_user_id,created_at,expires_at,withdrawn_at,withdrawn_by' then
    v_bad := v_bad || 'cma_read.message; ';
  end if;
  if not exists (select 1 from cma.permission where key = 'messages.withdraw')
     or (select p.prosrc from pg_proc p where p.oid = to_regprocedure('cma.seed_default_roles(uuid)')) !~ '''tenant.configure'', ''messages.withdraw''\]'
     or exists (select 1 from cma.app_role ar where ar.key = 'admin' and ar.is_system
                and not exists (select 1 from cma.role_permission rp where rp.tenant_id = ar.tenant_id and rp.role_id = ar.id
                                and rp.permission_key = 'messages.withdraw'))
     or exists (select 1 from cma.role_permission rp join cma.app_role ar on ar.tenant_id = rp.tenant_id and ar.id = rp.role_id
                where rp.permission_key = 'messages.withdraw' and ar.key <> 'admin') then
    v_bad := v_bad || 'messages.withdraw; ';
  end if;
  insert into verify_0008z values (6, 'A6 the withdrawal columns, trigger and grants; cma_read.message; messages.withdraw on every default admin role only',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A7. nothing twice: one 0008z row, each setting once, messages.withdraw once per role, the row type in its new shape
  v_bad := '';
  if (select count(*) from cma.schema_migration where version = '0008z') <> 1
     or (select count(*) from cma.setting where key like 'attempts.%') <> 5
     or exists (select 1 from cma.role_permission where permission_key = 'messages.withdraw' group by tenant_id, role_id having count(*) > 1)
     or (select count(*) from pg_attribute a where a.attrelid = (select t.typrelid from pg_type t where t.oid = to_regtype('cma.attempt_deal'))
         and a.attnum > 0 and not a.attisdropped) <> 37 then
    v_bad := 'something is there twice or in the old shape';
  end if;
  insert into verify_0008z values (7, 'A7 nothing twice: one addition row, the settings once, the permission once per role, the row type''s 37 fields',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- B. Attempts on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_analyst1 uuid; v_reader1 uuid; v_super1 uuid; v_agent1 uuid; v_anna uuid; v_bram uuid; v_ing1 uuid;
  v_admin2 uuid; v_analyst2 uuid; v_ing2 uuid;
  v_crm uuid; v_tel uuid; v_shop uuid; v_crm2 uuid;
  v_role uuid; v_dw uuid; v_dl uuid; v_dord uuid;
  v_txt text; v_detail text; v_app text; v_view text;
  j jsonb;
  v_now  timestamptz := '2026-10-14 10:00:00+00';   -- Wednesday 14 October 2026, 12:00 in Amsterdam
  v_from timestamptz := '2026-10-04 22:00:00+00';   -- Monday 5 October, 00:00 in Amsterdam
  v_to   timestamptz := '2026-10-11 22:00:00+00';   -- Monday 12 October, 00:00 in Amsterdam
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    -- tenants, people and roles (as the owner, as 0008y's verify)
    v_t1 := cma.create_tenant('verify-0008z-one', 'Verify 0008z one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008z-two', 'Verify 0008z two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-reader1@example.invalid', 'reader1') returning id into v_reader1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-super1@example.invalid', 'super1') returning id into v_super1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'agent1') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-anna@example.invalid', 'Anna Verify') returning id into v_anna;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-bram@example.invalid', 'Bram Verify') returning id into v_bram;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-analyst2@example.invalid', 'analyst2') returning id into v_analyst2;
    insert into cma.app_role (tenant_id, key, name) values (v_t1, 'verify_reader', 'Verify reader') returning id into v_role;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_t1, v_role, 'reports.view');
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_analyst1, 'analytics'), (v_t1, v_reader1, 'verify_reader'), (v_t1, v_super1, 'supervisor'),
                 (v_t1, v_agent1, 'agent'), (v_t1, v_anna, 'agent'), (v_t1, v_bram, 'agent'),
                 (v_t2, v_admin2, 'admin'), (v_t2, v_analyst2, 'analytics')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, settings)
    values (v_t1, 'verifycrm', 'Verify attempts CRM', 'portal-1', '{"record_url_deal": "https://crm.example.invalid/{account}/deal/{id}"}')
    returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verifytel', 'Verify attempts telephony', 'tel-1') returning id into v_tel;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verifyshop', 'Verify attempts shop', 'shop-1.example.invalid') returning id into v_shop;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t2, 'verifycrm', 'Verify attempts CRM two', 'portal-2') returning id into v_crm2;
    perform set_config('role', 'cma_app', true);

    -- tenant one's configuration (the admin): the market, office hours, the settings, the owners and the telephony user
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.set_business_hours('*', d::smallint, '09:00-17:00') from generate_series(1, 5) d;
    perform cma.set_tenant_setting('intake.start_date', '2026-09-01');
    perform cma.set_tenant_setting('speed_to_lead.pre_window_minutes', '10');
    perform cma.set_tenant_setting('reports.per_person', 'attempts');
    perform cma.set_user_external_id(v_anna, 'verifycrm_owner', 'o-1');
    perform cma.set_user_external_id(v_bram, 'verifycrm_owner', 'o-2');
    perform cma.set_user_external_id(v_anna, 'verifytel_user', 'tu-1');
    perform cma.upsert_commerce_store(v_shop, 'verify-nl', 'Verify NL', 'NL', 'EUR', 'Europe/Amsterdam');

    -- the catalogs from the sources (the Ingest user)
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_pipelines(v_crm, '[
      {"recordType": "deal", "pipelineId": "sales", "label": "Sales", "stages": [
         {"stageId": "s1", "label": "Open", "order": 1, "isClosed": false, "outcome": null},
         {"stageId": "sw", "label": "Won", "order": 8, "isClosed": true, "outcome": "won"},
         {"stageId": "sl", "label": "Lost", "order": 9, "isClosed": true, "outcome": "lost"},
         {"stageId": "sx", "label": "Closed", "order": 10, "isClosed": true, "outcome": null}]},
      {"recordType": "deal", "pipelineId": "selfserve", "label": "Self Serve", "stages": [{"stageId": "o1", "label": "Won", "order": 1, "isClosed": true, "outcome": "won"}]},
      {"recordType": "deal", "pipelineId": "renew", "label": "Renewals", "stages": [{"stageId": "r1", "label": "Open", "order": 1, "isClosed": false}]},
      {"recordType": "deal", "pipelineId": "test", "label": "Test", "stages": [{"stageId": "x1", "label": "Open", "order": 1, "isClosed": false}]}]');
    perform cma.ingest_upsert_call_outcomes(v_crm, '[{"outcomeRef": "connected", "label": "Connected"}, {"outcomeRef": "no_answer", "label": "No answer"},
      {"outcomeRef": "voicemail", "label": "Left voicemail"}]');
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'number', '[{"numberRef": "n-nl", "name": "Verify NL line", "digits": "+31000000001"}]');

    -- their configuration (the admin): selfserve an order pipeline (still marked lead, as every pipeline is by default),
    -- renew counted but no lead pipeline, test not counted; Connected counts as connected, Left voicemail does not
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_pipeline_order(v_crm, 'deal', 'selfserve', true);
    perform cma.set_pipeline_lead(v_crm, 'deal', 'renew', false);
    perform cma.set_connection_pipeline(v_crm, 'deal', 'test', false, false, null);
    perform cma.set_call_outcome(v_crm, 'connected', true);
    perform cma.set_telephony_number(v_tel, 'n-nl', 'NL', true);

    -- the deals (UTC; Amsterdam is UTC+2 until 25 October)
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_records(v_crm, '[
      {"recordType": "deal", "sourceId": "dP",     "pipelineId": "sales",     "stageId": "sw", "ownerRef": "o-1", "contactId": "kP",  "market": "NL", "createdAt": "2026-09-30T08:00:00Z", "closedAt": "2026-10-01T08:00:00Z", "updatedAt": "2026-10-01T08:00:00Z"},
      {"recordType": "deal", "sourceId": "dW",     "pipelineId": "sales",     "stageId": "sw", "ownerRef": "o-1", "contactId": "kW",  "market": "NL", "createdAt": "2026-10-05T08:00:00Z", "closedAt": "2026-10-08T12:00:00Z", "updatedAt": "2026-10-08T12:00:00Z"},
      {"recordType": "deal", "sourceId": "dW2",    "pipelineId": "sales",     "stageId": "sw", "ownerRef": "o-1", "contactId": "kW2", "market": "NL", "createdAt": "2026-10-05T12:00:00Z", "closedAt": "2026-10-09T10:00:00Z", "updatedAt": "2026-10-09T10:00:00Z"},
      {"recordType": "deal", "sourceId": "dL",     "pipelineId": "sales",     "stageId": "sl", "ownerRef": "o-2", "contactId": "kL",  "market": "NL", "createdAt": "2026-10-05T09:00:00Z", "closedAt": "2026-10-07T15:00:00Z", "updatedAt": "2026-10-07T15:00:00Z"},
      {"recordType": "deal", "sourceId": "dL2",    "pipelineId": "sales",     "stageId": "sl", "ownerRef": "o-3", "contactId": "kL2", "market": "NL", "createdAt": "2026-10-06T12:00:00Z", "closedAt": "2026-10-08T13:00:00Z", "updatedAt": "2026-10-08T13:00:00Z"},
      {"recordType": "deal", "sourceId": "dO",     "pipelineId": "sales",     "stageId": "s1", "ownerRef": "o-1", "contactId": "kO",  "market": "NL", "createdAt": "2026-10-06T08:00:00Z", "updatedAt": "2026-10-06T08:00:00Z"},
      {"recordType": "deal", "sourceId": "dS",     "pipelineId": "sales",     "stageId": "s1", "ownerRef": "o-1", "contactId": "kS",  "market": "NL", "createdAt": "2026-10-06T09:00:00Z", "updatedAt": "2026-10-06T09:00:00Z"},
      {"recordType": "deal", "sourceId": "dB",     "pipelineId": "sales",     "stageId": "s1", "ownerRef": "o-2", "contactId": "kB",  "market": "NL", "createdAt": "2026-10-07T08:00:00Z", "updatedAt": "2026-10-07T08:00:00Z"},
      {"recordType": "deal", "sourceId": "dA",     "pipelineId": "sales",     "stageId": "s1", "ownerRef": "o-2", "contactId": "kA1", "market": "NL", "createdAt": "2026-10-07T09:00:00Z", "updatedAt": "2026-10-07T09:00:00Z"},
      {"recordType": "deal", "sourceId": "dT",     "pipelineId": "sales",     "stageId": "s1",                    "contactId": "kT",  "market": "NL", "createdAt": "2026-10-08T08:00:00Z", "updatedAt": "2026-10-08T08:00:00Z"},
      {"recordType": "deal", "sourceId": "dN",     "pipelineId": "sales",     "stageId": "s1", "ownerRef": "o-3", "contactId": "kN",  "market": "NL", "createdAt": "2026-10-09T08:30:00Z", "updatedAt": "2026-10-09T08:30:00Z"},
      {"recordType": "deal", "sourceId": "dU",     "pipelineId": "sales",     "stageId": "sx",                    "contactId": "kU",  "market": "NL", "createdAt": "2026-10-09T09:00:00Z", "closedAt": "2026-10-09T11:00:00Z", "updatedAt": "2026-10-09T11:00:00Z"},
      {"recordType": "deal", "sourceId": "dOrd",   "pipelineId": "selfserve", "stageId": "o1",                    "contactId": "kO",  "market": "NL", "createdAt": "2026-10-07T10:00:00Z", "closedAt": "2026-10-07T10:00:00Z", "updatedAt": "2026-10-07T10:00:00Z"},
      {"recordType": "deal", "sourceId": "dOrdB",  "pipelineId": "selfserve", "stageId": "o1",                    "contactId": "kB",  "market": "NL", "createdAt": "2026-10-04T10:00:00Z", "closedAt": "2026-10-04T10:00:00Z", "updatedAt": "2026-10-04T10:00:00Z"},
      {"recordType": "deal", "sourceId": "dOrdA",  "pipelineId": "selfserve", "stageId": "o1",                    "contactId": "kA2", "market": "NL", "createdAt": "2026-10-08T10:00:00Z", "closedAt": "2026-10-08T10:00:00Z", "updatedAt": "2026-10-08T10:00:00Z"},
      {"recordType": "deal", "sourceId": "dRen",   "pipelineId": "renew",     "stageId": "r1", "ownerRef": "o-1", "contactId": "kRen", "market": "NL", "createdAt": "2026-10-06T10:00:00Z", "updatedAt": "2026-10-06T10:00:00Z"},
      {"recordType": "deal", "sourceId": "dTest",  "pipelineId": "test",      "stageId": "x1", "ownerRef": "o-1", "contactId": "kTest", "market": "NL", "createdAt": "2026-10-06T10:00:00Z", "updatedAt": "2026-10-06T10:00:00Z"}]');
    perform cma.ingest_upsert_contacts(v_crm, (
      select jsonb_agg(jsonb_build_object('sourceId', k, 'country', 'NL', 'updatedAt', '2026-10-01T00:00:00Z'))
      from unnest(array['kP', 'kW', 'kW2', 'kL2', 'kO', 'kA1', 'kA2', 'kT', 'kN', 'kU', 'kRen', 'kTest']) k)
      || '[{"sourceId": "kL", "country": "NL", "refs": {"verifyshop": ["c-L"]}, "updatedAt": "2026-10-01T00:00:00Z"},
           {"sourceId": "kS", "country": "NL", "refs": {"verifyshop": ["c-S"]}, "updatedAt": "2026-10-01T00:00:00Z"},
           {"sourceId": "kB", "country": "NL", "refs": {"verifyshop": ["c-B"]}, "updatedAt": "2026-10-01T00:00:00Z"}]'::jsonb);
    -- dA's second contact: associated, then no longer
    perform cma.ingest_upsert_associations(v_crm, '[{"fromType": "deal", "fromId": "dA", "toType": "contact", "toId": "kA2", "removed": false, "changedAt": "2026-10-07T09:00:00Z"}]');
    perform cma.ingest_upsert_associations(v_crm, '[{"fromType": "deal", "fromId": "dA", "toType": "contact", "toId": "kA2", "removed": true, "changedAt": "2026-10-07T12:00:00Z"}]');
    -- the CRM calls, each on a contact; a hash where a telephony call logged it
    perform cma.ingest_upsert_calls(v_crm, (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('sourceId', c.id, 'occurredAt', c.at, 'direction', 'outbound', 'outcomeRef', c.outcome,
                                                            'ownerRef', c.owner, 'counterpartHash', case when c.linked then md5(c.id) || md5(c.id || 'x') end,
                                                            'updatedAt', c.at)))
      from (values
        ('cp1',  '2026-09-30T08:10:00Z', 'connected', 'o-1', true),
        ('cw1',  '2026-10-05T08:05:00Z', 'no_answer', 'o-1', true),
        ('cw2',  '2026-10-05T09:00:00Z', null,        'o-1', true),
        ('cwh',  '2026-10-05T10:00:00Z', null,        'o-1', false),
        ('cw3',  '2026-10-06T09:00:00Z', null,        'o-1', true),
        ('cw4',  '2026-10-07T09:00:00Z', 'connected', 'o-2', true),
        ('cw5',  '2026-10-09T09:00:00Z', 'connected', 'o-1', true),
        ('cw21', '2026-10-06T07:30:00Z', 'connected', 'o-1', true),
        ('cl1',  '2026-10-05T10:00:00Z', 'voicemail', 'o-2', true),
        ('cl2',  '2026-10-06T10:00:00Z', null,        'o-2', true),
        ('cl3',  '2026-10-08T09:00:00Z', 'connected', 'o-2', true),
        ('co1',  '2026-10-06T08:30:00Z', 'connected', 'o-1', true),
        ('co2',  '2026-10-08T09:00:00Z', 'connected', 'o-1', true),
        ('cs1',  '2026-10-07T10:00:00Z', null,        'o-1', true),
        ('cs2',  '2026-10-09T09:00:00Z', null,        'o-1', true),
        ('cb1',  '2026-10-08T09:00:00Z', 'no_answer', 'o-2', true),
        ('ca1',  '2026-10-09T09:00:00Z', null,        'o-2', true),
        ('ca2',  '2026-10-08T11:00:00Z', 'connected', 'o-2', true),
        ('ct0',  '2026-10-08T08:02:00Z', null,        null,  false),
        ('ct1',  '2026-10-08T09:30:00Z', null,        null,  true),
        ('cu1',  '2026-10-09T09:30:00Z', 'connected', null,  true),
        ('cren', '2026-10-06T11:00:00Z', 'connected', 'o-1', true),
        ('ctst', '2026-10-06T11:00:00Z', 'connected', 'o-1', true)) c(id, at, outcome, owner, linked)));
    perform cma.ingest_upsert_associations(v_crm, (
      select jsonb_agg(jsonb_build_object('fromType', 'crm_call', 'fromId', a.c, 'toType', 'contact', 'toId', a.k, 'removed', false,
                                          'changedAt', '2026-09-30T00:00:00Z'))
      from (values ('cp1', 'kP'), ('cw1', 'kW'), ('cw2', 'kW'), ('cwh', 'kW'), ('cw3', 'kW'), ('cw4', 'kW'), ('cw5', 'kW'), ('cw21', 'kW2'),
                   ('cl1', 'kL'), ('cl2', 'kL'), ('cl3', 'kL'), ('co1', 'kO'), ('co2', 'kO'), ('cs1', 'kS'), ('cs2', 'kS'), ('cb1', 'kB'),
                   ('ca1', 'kA1'), ('ca2', 'kA2'), ('ct0', 'kT'), ('ct1', 'kT'), ('cu1', 'kU'), ('cren', 'kRen'), ('ctst', 'kTest')) a(c, k)));
    -- the telephony calls that logged them, 10 seconds earlier, with the same hash: answered (or not), talk time as
    -- ended - answered, the user; cw3's on a line not yet in the catalog
    perform cma.ingest_upsert_telephony_calls(v_tel, (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'sourceId', 't' || t.c, 'direction', 'outbound', 'startedAt', t.started - interval '10 seconds',
               'answeredAt', case when t.talk is not null then t.started end,
               'endedAt', t.started + make_interval(secs => coalesce(t.talk, 20)), 'numberRef', t.line, 'userRef', t.usr,
               'counterpartHash', md5(t.c) || md5(t.c || 'x'), 'versionAt', t.started + interval '1 hour')))
      from (values
        ('cp1',  timestamptz '2026-09-30T08:10:00Z', 60,   'n-nl',  'tu-1'),
        ('cw1',  timestamptz '2026-10-05T08:05:00Z', null, 'n-nl',  'tu-1'),
        ('cw2',  timestamptz '2026-10-05T09:00:00Z', 29,   'n-nl',  'tu-1'),
        ('cw3',  timestamptz '2026-10-06T09:00:00Z', 30,   'n-new', 'tu-1'),
        ('cw4',  timestamptz '2026-10-07T09:00:00Z', 5,    'n-nl',  'tu-9'),
        ('cw5',  timestamptz '2026-10-09T09:00:00Z', 60,   'n-nl',  'tu-1'),
        ('cw21', timestamptz '2026-10-06T07:30:00Z', 300,  'n-nl',  'tu-1'),
        ('cl1',  timestamptz '2026-10-05T10:00:00Z', 90,   'n-nl',  'tu-1'),
        ('cl2',  timestamptz '2026-10-06T10:00:00Z', 0,    'n-nl',  'tu-1'),
        ('cl3',  timestamptz '2026-10-08T09:00:00Z', 60,   'n-nl',  'tu-1'),
        ('co1',  timestamptz '2026-10-06T08:30:00Z', 60,   'n-nl',  'tu-1'),
        ('co2',  timestamptz '2026-10-08T09:00:00Z', 60,   'n-nl',  'tu-1'),
        ('cs1',  timestamptz '2026-10-07T10:00:00Z', 45,   'n-nl',  'tu-1'),
        ('cs2',  timestamptz '2026-10-09T09:00:00Z', 45,   'n-nl',  'tu-1'),
        ('cb1',  timestamptz '2026-10-08T09:00:00Z', null, 'n-nl',  'tu-1'),
        ('ca1',  timestamptz '2026-10-09T09:00:00Z', null, 'n-nl',  'tu-1'),
        ('ca2',  timestamptz '2026-10-08T11:00:00Z', 60,   'n-nl',  'tu-1'),
        ('ct1',  timestamptz '2026-10-08T09:30:00Z', 10,   'n-nl',  'tu-1'),
        ('cu1',  timestamptz '2026-10-09T09:30:00Z', 120,  'n-nl',  'tu-1'),
        ('cren', timestamptz '2026-10-06T11:00:00Z', 60,   'n-nl',  'tu-1'),
        ('ctst', timestamptz '2026-10-06T11:00:00Z', 60,   'n-nl',  'tu-1')) t(c, started, talk, line, usr)));
    perform cma.link_calls('2026-09-01T00:00:00Z');
    -- the store's customers and orders: dL's after its close; dS's test, cancelled and deleted ones before its real one;
    -- dB's before its creation
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_commerce_customers(v_shop, '[{"sourceId": "c-L", "updatedAt": "2026-10-01T00:00:00Z"},
      {"sourceId": "c-S", "updatedAt": "2026-10-01T00:00:00Z"}, {"sourceId": "c-B", "updatedAt": "2026-10-01T00:00:00Z"}]');
    perform cma.ingest_upsert_commerce_orders(v_shop, '[
      {"sourceId": "oL",     "customerId": "c-L", "createdAt": "2026-10-08T10:00:00Z", "updatedAt": "2026-10-08T10:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "oStest", "customerId": "c-S", "createdAt": "2026-10-07T08:00:00Z", "updatedAt": "2026-10-07T08:00:00Z", "isTest": true, "priorOrdersCount": 0},
      {"sourceId": "oScanc", "customerId": "c-S", "createdAt": "2026-10-07T09:00:00Z", "updatedAt": "2026-10-07T09:30:00Z", "cancelledAt": "2026-10-07T09:30:00Z", "priorOrdersCount": 0},
      {"sourceId": "oSdel",  "customerId": "c-S", "createdAt": "2026-10-07T09:30:00Z", "updatedAt": "2026-10-07T09:30:00Z", "priorOrdersCount": 0},
      {"sourceId": "oS",     "customerId": "c-S", "createdAt": "2026-10-08T10:00:00Z", "updatedAt": "2026-10-08T10:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "oB",     "customerId": "c-B", "createdAt": "2026-10-05T10:00:00Z", "updatedAt": "2026-10-05T10:00:00Z", "priorOrdersCount": 0}]');
    perform cma.ingest_upsert_commerce_orders(v_shop, '[{"sourceId": "oSdel", "deletedAt": "2026-10-07T10:30:00Z"}]');

    -- tenant two: a deal of the same source id, never attempted
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    perform cma.set_tenant_setting('intake.start_date', '2026-09-01');
    perform set_config('app.user_id', v_ing2::text, true);
    perform cma.ingest_upsert_records(v_crm2, '[{"recordType": "deal", "sourceId": "dW", "pipelineId": "sales", "contactId": "kW", "createdAt": "2026-10-05T08:00:00Z", "updatedAt": "2026-10-05T08:00:00Z"}]');
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    select r.id into v_dw from cma.crm_record r where r.tenant_id = v_t1 and r.source_id = 'dW';
    select r.id into v_dl from cma.crm_record r where r.tenant_id = v_t1 and r.source_id = 'dL';
    select r.id into v_dord from cma.crm_record r where r.tenant_id = v_t1 and r.source_id = 'dOrd';

    -- B1. the population: the deals of the lead pipelines; the order pipeline (still marked lead), the counted pipeline that
    --     is no lead pipeline and the uncounted one out
    select string_agg(x.deal_source_id, ' ' order by x.deal_source_id) into v_txt
    from cma.attempts_per_deal_of(v_t1, v_from, v_to, v_now) x;
    v_rows := v_rows || array['11', 'B1 only sales deals: an order pipeline, a pipeline that is no lead pipeline and an uncounted one out',
      case when v_txt = 'dA dB dL dL2 dN dO dS dT dU dW dW2' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B2. telephony (the default): attempts, reached, the first reached attempt, talk in all and in contact, attempts without an
    --     outcome, the outbound CRM calls logged without the telephony call (dW's cwh, dT's ct0: never attempts)
    select pg_temp.v0008z_deals(v_t1, v_now) into v_txt;
    v_rows := v_rows || array['12', 'B2 telephony: attempts, reached, first reached, talk, without outcome; a CRM call without the telephony call counted apart',
      case when v_txt = 'dA:1/0/-/0/0/1/0 dB:1/0/-/0/0/0/0 dL:2/0/-/90/0/1/0 dL2:0/0/-/0/0/0/0 dN:0/0/-/0/0/0/0 dO:1/1/1/60/60/0/0 '
                        || 'dS:1/1/1/45/45/1/0 dT:1/0/-/10/0/1/1 dU:1/1/1/120/120/0/0 dW:4/2/3/64/35/2/1 dW2:1/1/1/300/300/0/0'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B3. the source crm: every outbound CRM call is an attempt (dW five, its first reached the fourth; dT two, the first the
    --     call logged by hand two minutes after the creation); back to telephony
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('attempts.source', 'crm');
    select string_agg(format('%s:%s/%s/%s/%s', x.deal_source_id, x.attempts, coalesce(x.first_reached_attempt::text, '-'),
                             to_char(x.first_attempt_at at time zone 'UTC', 'DD HH24:MI:SS'), x.speed_to_lead_seconds), ' ' order by x.deal_source_id)
      into v_txt
    from cma.attempts_per_deal_of(v_t1, v_from, v_to, v_now) x where x.deal_source_id in ('dT', 'dW');
    perform cma.set_tenant_setting('attempts.source', 'telephony');
    select v_txt || ' | ' || string_agg(format('%s:%s/%s/%s/%s', x.deal_source_id, x.attempts, coalesce(x.first_reached_attempt::text, '-'),
                                               to_char(x.first_attempt_at at time zone 'UTC', 'DD HH24:MI:SS'), x.speed_to_lead_seconds), ' ' order by x.deal_source_id)
      into v_txt
    from cma.attempts_per_deal_of(v_t1, v_from, v_to, v_now) x where x.deal_source_id in ('dT', 'dW');
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['13', 'B3 the source: crm counts every outbound CRM call, telephony only the telephony calls',
      case when v_txt = 'dT:2/-/08 08:02:00/120 dW:5/4/05 08:04:50/290 | dT:1/-/08 09:29:50/5390 dW:4/3/05 08:04:50/290'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B4. the window: a call after a won order deal of the contact out, one before it in (dO); a store order ends it, a test,
    --     a cancelled and a deleted one do not (dS); an order before the creation ends nothing (dB); an order deal on a
    --     contact no longer associated ends nothing, and its call is no attempt (dA); a lost deal's close ends it before a
    --     later order (dL); a won deal's close ends it (dW)
    select string_agg(format('%s:%s/%s/%s/%s', x.deal_source_id, x.window_end_reason, x.outcome,
                             coalesce(to_char(x.ordered_at at time zone 'UTC', 'DD HH24:MI'), '-'), x.attempts), ' ' order by x.deal_source_id)
      into v_txt
    from cma.attempts_per_deal_of(v_t1, v_from, v_to, v_now) x where x.deal_source_id in ('dA', 'dB', 'dL', 'dO', 'dS', 'dW');
    v_rows := v_rows || array['14', 'B4 the window ends at the close or the first order (a won order deal, a store order), else now',
      case when v_txt = 'dA:open/open/-/1 dB:open/open/-/1 dL:closed/lost/08 10:00/2 dO:ordered/ordered/07 10:00/1 dS:ordered/ordered/08 10:00/1 dW:closed/won/-/4'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B5. an ordered deal is no longer open: no business days since its last attempt, out of the open figures
    j := cma.attempts_per_deal_page_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', null, null, 'all', 'all', 100, v_now);
    select string_agg(format('%s:%s', x.deal_source_id, coalesce(x.business_days_since_last::text, '-')), ' ' order by x.deal_source_id) into v_txt
    from cma.attempts_per_deal_of(v_t1, v_from, v_to, v_now) x where x.deal_source_id in ('dA', 'dB', 'dN', 'dO', 'dS', 'dT');
    v_txt := v_txt || format(' open %s never %s', j -> 'current' ->> 'open_deals', j -> 'current' ->> 'open_never_attempted')
             || ' since ' || (select string_agg(format('%s:%s', b ->> 'label', b ->> 'deals'), ' ' order by (b ->> 'from')::int)
                              from jsonb_array_elements(j -> 'since_last' -> 'buckets') b);
    v_rows := v_rows || array['15', 'B5 an ordered deal is out of the open figures, without business days since its last attempt',
      case when v_txt = 'dA:3 dB:4 dN:3 dO:- dS:- dT:4 open 4 never 1 since 0–1:0 1–2:0 2–5:4 5+:0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B6. reached, per attempt (one deal's attempts as a supervisor reads them): an outcome without connected and 0 s, 29 s
    --     without an outcome not, 30 s without an outcome by the talk time, Connected with 5 s by the outcome; Left voicemail
    --     with 90 s not, answered with 0 s not
    perform set_config('app.user_id', v_super1::text, true);
    select string_agg(format('%s:%s/%s/%s/%s', a.n, a.answered, coalesce(a.talk_seconds::text, '-'), a.reached, coalesce(a.reached_by, '-')), ' ' order by a.n)
      into v_txt from cma.attempts_of_deal(v_dw) a;
    select v_txt || ' | ' || string_agg(format('%s:%s/%s/%s/%s', a.n, a.answered, coalesce(a.talk_seconds::text, '-'), a.reached, coalesce(a.reached_by, '-')), ' ' order by a.n)
      into v_txt from cma.attempts_of_deal(v_dl) a;
    v_rows := v_rows || array['16', 'B6 reached by the outcome first, else 30 s of talk; Left voicemail with 90 s and answered with 0 s not',
      case when v_txt = '1:f/-/f/- 2:t/29/f/- 3:t/30/t/talk_time 4:t/5/t/outcome | 1:t/90/f/- 2:t/0/f/-'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B7. the setting moves the edge: at 29 s dW's second attempt reaches (first reached 2, three reached), at 31 s its third
    --     no longer does (first reached 4, one reached)
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('attempts.reached_min_talk_seconds', '29');
    select format('29:%s/%s', x.reached_attempts, x.first_reached_attempt) into v_txt
    from cma.attempts_per_deal_of(v_t1, v_from, v_to, v_now) x where x.deal_source_id = 'dW';
    perform cma.set_tenant_setting('attempts.reached_min_talk_seconds', '31');
    select v_txt || format(' 31:%s/%s', x.reached_attempts, x.first_reached_attempt) into v_txt
    from cma.attempts_per_deal_of(v_t1, v_from, v_to, v_now) x where x.deal_source_id = 'dW';
    perform cma.set_tenant_setting('attempts.reached_min_talk_seconds', '30');
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['17', 'B7 attempts.reached_min_talk_seconds moves the edge',
      case when v_txt = '29:3/2 31:1/4' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B8. the speed to lead equals cma.speed_to_lead_of's business seconds and next-noon answer for every deal whose first
    --     outbound CRM call is the first attempt's (the same telephony call); dT differs: its first CRM call was logged without
    --     the telephony call (0007d measures 120 s to it, the attempts 5390 s to the telephony call)
    select format('%s equal of %s; differ: %s', count(*) filter (where e.same and e.equal), count(*) filter (where e.same),
                  coalesce(string_agg(format('%s %s<>%s', e.src, e.ours, e.theirs), ' ' order by e.src) filter (where not e.same), '-'))
      into v_txt
    from (select x.deal_source_id as src, x.speed_to_lead_seconds as ours, sl.business_seconds as theirs,
                 coalesce(sl.first_call_linked and sl.first_call_at = x.first_attempt_at, false) as same,
                 x.speed_to_lead_seconds is not distinct from sl.business_seconds
                   and x.called_before_next_noon is not distinct from sl.before_next_noon as equal
          from cma.attempts_per_deal_of(v_t1, v_from, v_to, v_now) x
          join cma.speed_to_lead_of(v_t1, v_from, v_to) sl on sl.deal_id = x.deal_id
          where x.first_attempt_at is not null) e;
    v_rows := v_rows || array['18', 'B8 the speed to lead is 0007d''s for the same first call; a first CRM call without the telephony call differs',
      case when v_txt = '8 equal of 8; differ: dT 5390<>120' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B9. one deal's attempts in time order with their fields: the start, answered, talk, reached and by what, the outcome's
    --     catalog label, the agent's name (the telephony user's person, else the CRM call's owner's) for performance.team while
    --     reports.per_person holds attempts
    perform set_config('app.user_id', v_super1::text, true);
    select string_agg(format('%s|%s|%s|%s', a.n, to_char(a.started_at at time zone 'UTC', 'DD HH24:MI:SS'), coalesce(a.outcome_label, '-'),
                             coalesce(a.agent_name, '-')), ' ' order by a.n)
      into v_txt from cma.attempts_of_deal(v_dw) a;
    v_rows := v_rows || array['19', 'B9 one deal''s attempts in order with the start, the outcome''s label and the agent',
      case when v_txt = '1|05 08:04:50|No answer|Anna Verify 2|05 08:59:50|-|Anna Verify 3|06 08:59:50|-|Anna Verify 4|07 08:59:50|Connected|Bram Verify'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B10. the agent's name only for performance.team with attempts in reports.per_person: none for reports.view alone, none once
    --      reports.per_person drops attempts; refused for an agent (CMA06) and without an acting user (CMA01); a deal of the
    --      order pipeline, an unknown id and tenant one's deal for tenant two not found (CMA02)
    perform set_config('app.user_id', v_reader1::text, true);
    select format('reader:%s', count(a.agent_name)) into v_txt from cma.attempts_of_deal(v_dw) a;
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('reports.per_person', 'email');
    perform set_config('app.user_id', v_super1::text, true);
    select v_txt || format(' off:%s', count(a.agent_name)) into v_txt from cma.attempts_of_deal(v_dw) a;
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('reports.per_person', 'attempts');
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008z_code(format('select cma.attempts_of_deal(%L)', v_dw));
    perform set_config('app.user_id', '', true);
    v_txt := v_txt || ' ' || pg_temp.v0008z_code(format('select cma.attempts_of_deal(%L)', v_dw));
    perform set_config('app.user_id', v_super1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008z_code(format('select cma.attempts_of_deal(%L)', v_dord))
             || ' ' || pg_temp.v0008z_code(format('select cma.attempts_of_deal(%L)', gen_random_uuid()));
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_analyst2::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008z_code(format('select cma.attempts_of_deal(%L)', v_dw));
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['20', 'B10 the agent''s name gated; an agent refused; another pipeline''s, an unknown and another tenant''s deal not found',
      case when v_txt = 'reader:0 off:0 CMA06 CMA01 CMA02 CMA02 CMA02' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B11. the filters attempted (none: no attempt yet; some) and outcome narrow every figure and the list
    v_txt := '';
    foreach v_detail in array array['none:all', 'some:all', 'all:open', 'all:won', 'all:lost', 'all:ordered', 'none:lost'] loop
      j := cma.attempts_per_deal_page_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', null, null, split_part(v_detail, ':', 1),
                                         split_part(v_detail, ':', 2), 100, v_now);
      v_txt := v_txt || format('%s=%s/%s/%s ', v_detail, j -> 'current' ->> 'deals', j -> 'list' ->> 'total',
                               (select string_agg(r ->> 'deal_source_id', ',' order by r ->> 'deal_source_id') from jsonb_array_elements(j -> 'list' -> 'rows') r));
    end loop;
    v_rows := v_rows || array['21', 'B11 the filters attempted and outcome',
      case when v_txt = 'none:all=2/2/dL2,dN some:all=9/9/dA,dB,dL,dO,dS,dT,dU,dW,dW2 all:open=4/4/dA,dB,dN,dT all:won=2/2/dW,dW2 '
                        || 'all:lost=2/2/dL,dL2 all:ordered=2/2/dO,dS none:lost=1/1/dL2 '
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B12. won against lost: deals, average and median attempts, the median speed to lead, called before the next noon of those
    --      known, reached at least once, the average talk time in contact of the deals reached; the deals not decided apart
    j := cma.attempts_per_deal_page_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', null, null, 'all', 'all', 100, v_now);
    select string_agg(format('%s:%s/%s/%s/%s/%sof%s/%s/%s', o ->> 'outcome', o ->> 'deals', o ->> 'avg_attempts', o ->> 'median_attempts',
                             coalesce(o ->> 'median_speed_seconds', '-'), o ->> 'called_before_noon', o ->> 'noon_known', o ->> 'reached_deals',
                             coalesce(o ->> 'avg_talk_reached_seconds', '-')), ' ')
           || format(' not_decided:%s open:%s ordered:%s unknown:%s', j -> 'outcomes' ->> 'not_decided', j -> 'outcomes' ->> 'open',
                     j -> 'outcomes' ->> 'ordered', j -> 'outcomes' ->> 'unknown')
      into v_txt from jsonb_array_elements(j -> 'outcomes' -> 'rows') o;
    v_rows := v_rows || array['22', 'B12 won against lost, the deals not decided counted apart',
      case when v_txt = 'won:2/2.50/2.5/6440/2of2/2/168 lost:2/1.00/1.0/3590/1of2/0/- not_decided:7 open:4 ordered:2 unknown:1'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B13. the win rate by attempts (0 to 5+) and by speed to lead (the business-minute buckets, the deals never attempted and
    --      those without business hours apart), won and lost of the decided deals
    select string_agg(format('%s:%s/%s', b ->> 'label', b ->> 'won', b ->> 'lost'), ' ' order by (b ->> 'bucket')::int) into v_txt
    from jsonb_array_elements(j -> 'buckets') b;
    select v_txt || ' | ' || string_agg(format('%s:%s/%s', b ->> 'label', b ->> 'won', b ->> 'lost'), ' ' order by (b ->> 'from')::int)
           || format(' none:%s/%s no_hours:%s', j -> 'speed_buckets' -> 'none' ->> 'won', j -> 'speed_buckets' -> 'none' ->> 'lost',
                     j -> 'speed_buckets' ->> 'no_hours')
      into v_txt from jsonb_array_elements(j -> 'speed_buckets' -> 'buckets') b;
    v_rows := v_rows || array['23', 'B13 the win rate by attempts and by speed to lead with their buckets',
      case when v_txt = '0:0/1 1:1/0 2:0/1 3:0/0 4:1/0 5+:0/0 | 0–5:1/0 5–15:0/0 15–60:0/1 60–240:1/0 240–1440:0/0 1440+:0/0 none:0/1 no_hours:0'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B14. the figures of the period and of the previous week (dP), and reached per attempt (the deals first reached on each)
    v_txt := pg_temp.v0008z_fig(j -> 'current') || ' | ' || pg_temp.v0008z_fig(j -> 'previous') || ' | '
             || (select string_agg(format('%s:%s', b ->> 'label', b ->> 'first_reached'), ' ' order by (b ->> 'bucket')::int)
                 from jsonb_array_elements(j -> 'buckets') b where (b ->> 'bucket')::int > 0);
    v_rows := v_rows || array['24', 'B14 the figures, the previous period and reached per attempt',
      case when v_txt = '11/9/13/1.18/1.0/5/4/5390/8of11/4/1/2/2/2/1/689/560/6/2 | 1/1/1/1.00/1.0/1/1/590/1of1/0/0/1/0/0/0/60/60/0/0 | 1:4 2:0 3:1 4:0 5+:0'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B15. the list: open first, the longest since the last attempt first (then the earlier last attempt or creation); then the
    --      decided, the newest end of the window first; the cap with the total; the deal's id for its attempts and the link
    select string_agg(r ->> 'deal_source_id', ' ' order by o) into v_txt from jsonb_array_elements(j -> 'list' -> 'rows') with ordinality as x(r, o);
    select v_txt || ' | ' || string_agg(r ->> 'deal_source_id', ' ' order by o) || ' of ' || (jj -> 'list' ->> 'total')
           || ' ' || ((jj -> 'list' -> 'rows' -> 0 ->> 'record_url') = 'https://crm.example.invalid/portal-1/deal/dB')::text
           || ' ' || ((jj -> 'list' -> 'rows' -> 0 ->> 'deal_id') = (select r.id::text from cma.crm_record r where r.tenant_id = v_t1 and r.source_id = 'dB'))::text
           || ' ' || (jj -> 'list' -> 'rows' -> 0 ->> 'stage_label')
      into v_txt
    from (select cma.attempts_per_deal_page_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', null, null, 'all', 'all', 4, v_now) as jj) p
    cross join lateral jsonb_array_elements(p.jj -> 'list' -> 'rows') with ordinality as x(r, o)
    group by p.jj;
    v_rows := v_rows || array['25', 'B15 the list''s order, its cap and total, the deal''s id, the link and the stage',
      case when v_txt = 'dB dT dN dA dU dW2 dL2 dW dS dL dO | dB dT dN dA of 11 true true Open' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B16. per deal owner by name, never ranked, the not-linked row with one owner id, the total
    perform set_config('app.user_id', v_super1::text, true);
    j := cma.attempts_per_person_of(v_t1, date '2026-10-05', date '2026-10-11', null, null, 'all', 'all', v_now);
    select string_agg(format('%s:%s/%s/%s/%s/%s/%s', p ->> 'display_name', p ->> 'deals', p ->> 'attempts', p ->> 'reached_deals',
                             coalesce(p ->> 'median_speed_seconds', '-'), p ->> 'talk_seconds_reached', p ->> 'open_never_attempted'), ' ' order by o)
      into v_txt from jsonb_array_elements(j -> 'rows') with ordinality as x(p, o);
    v_txt := v_txt || format(' not_linked(%s):%s/%s/%s/%s/%s/%s total:%s/%s', j -> 'not_linked' ->> 'unlinked_owners', j -> 'not_linked' ->> 'deals',
                             j -> 'not_linked' ->> 'attempts', j -> 'not_linked' ->> 'reached_deals', j -> 'not_linked' ->> 'median_speed_seconds',
                             j -> 'not_linked' ->> 'talk_seconds_reached', j -> 'not_linked' ->> 'open_never_attempted',
                             j -> 'total' ->> 'deals', j -> 'total' ->> 'attempts');
    v_rows := v_rows || array['26', 'B16 per deal owner by name with the not-linked row and the total',
      case when v_txt = 'Anna Verify:4/7/4/7190/440/0 Bram Verify:3/4/0/32390/0/0 not_linked(1):4/2/1/3590/120/1 total:11/13'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B17. the settings refuse what the catalog does not take, and the speed buckets drop their spaces
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := '';
    foreach v_detail in array array['attempts.source=calls', 'attempts.source=crm', 'attempts.source=telephony',
                                    'attempts.reached_min_talk_seconds=-1', 'attempts.reached_min_talk_seconds=601', 'attempts.reached_min_talk_seconds=x',
                                    'attempts.reached_min_talk_seconds=0', 'attempts.reached_min_talk_seconds=600',
                                    'attempts.speed_buckets_business_minutes=0,5', 'attempts.speed_buckets_business_minutes=5,5',
                                    'attempts.speed_buckets_business_minutes=1,2,3,4,5,6,7', 'attempts.speed_buckets_business_minutes=1,2,3,4,5,6'] loop
      v_txt := v_txt || pg_temp.v0008z_code(format('select cma.set_tenant_setting(%L, %L)', split_part(v_detail, '=', 1), substr(v_detail, strpos(v_detail, '=') + 1))) || ' ';
    end loop;
    perform cma.set_tenant_setting('attempts.speed_buckets_business_minutes', ' 5, 15 ,60');
    v_txt := v_txt || cma.setting_of(v_t1, 'attempts.speed_buckets_business_minutes');
    perform cma.set_tenant_setting('attempts.speed_buckets_business_minutes', '5,15,60,240,1440');
    perform cma.set_tenant_setting('attempts.reached_min_talk_seconds', '30');
    v_rows := v_rows || array['27', 'B17 the settings'' refusals and the speed buckets'' spaces',
      case when v_txt = 'CMA04 ok ok CMA04 CMA04 CMA04 ok ok CMA04 CMA04 CMA04 ok 5,15,60' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B18. the parameters: attempted and outcome outside their lists, a scope, more than 92 days refused; the pages for their
    --      permissions only (the deal page reports.view or performance.team, per agent performance.team with attempts in
    --      reports.per_person)
    perform set_config('app.user_id', v_reader1::text, true);
    v_txt := pg_temp.v0008z_code('select cma.attempts_per_deal_page(date ''2026-10-05'', date ''2026-10-11'', ''day'', null, null, ''never'')') || ' '
      || pg_temp.v0008z_code('select cma.attempts_per_deal_page(date ''2026-10-05'', date ''2026-10-11'', ''day'', null, null, ''all'', ''unknown'')') || ' '
      || pg_temp.v0008z_code('select cma.attempts_per_deal_page(date ''2026-10-05'', date ''2026-10-11'', ''day'', null, null, ''lead'')') || ' '
      || pg_temp.v0008z_code('select cma.attempts_per_deal_page(date ''2026-01-01'', date ''2026-10-11'', ''day'', null, null)') || ' '
      || pg_temp.v0008z_code('select cma.attempts_per_deal_page(date ''2026-10-05'', date ''2026-10-11'', ''pipeline'', null, null, ''none'', ''open'', 5)') || ' '
      || pg_temp.v0008z_code('select cma.attempts_per_person_page(date ''2026-10-05'', date ''2026-10-11'', null, null)') || ' ';
    perform set_config('app.user_id', v_super1::text, true);
    v_txt := v_txt || pg_temp.v0008z_code('select cma.attempts_per_person_page(date ''2026-10-05'', date ''2026-10-11'', null, null, ''some'', ''won'')') || ' ';
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := v_txt || pg_temp.v0008z_code('select cma.attempts_per_deal_page(date ''2026-10-05'', date ''2026-10-11'', ''day'', null, null)');
    v_rows := v_rows || array['28', 'B18 the parameters refused; each page for its permissions',
      case when v_txt = 'CMA04 CMA04 CMA04 CMA04 ok CMA06 ok CMA06' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B19. the reader view: scoped to tenant one, the application's rows since the intake start (the week's eleven and dP),
    --      column by column; scoped to tenant two none of tenant one's
    perform set_config('app.user_id', v_analyst1::text, true);
    select string_agg(concat_ws('|', r.deal_id, r.connection_id, r.deal_source_id, r.pipeline_id, r.pipeline_label, r.stage_id, r.market, r.owner_user_id,
                                r.created_at, r.business_date, r.is_closed, r.closed_at, r.ordered_at, r.window_end_reason, r.outcome, r.attempts,
                                r.reached_attempts, r.first_reached_attempt, r.talk_seconds_total, r.talk_seconds_reached, r.first_attempt_at,
                                r.speed_to_lead_seconds, r.called_before_next_noon, r.last_attempt_at, r.business_days_since_last, r.since_last_bucket,
                                r.attempts_without_outcome, r.logged_without_aircall), ';' order by r.deal_id) into v_app
    from cma.attempts_per_deal_of(v_t1, null, null) r;
    perform set_config('role', 'cma_readonly', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    select string_agg(concat_ws('|', r.deal_id, r.connection_id, r.deal_source_id, r.pipeline_id, r.pipeline_label, r.stage_id, r.market, r.owner_user_id,
                                r.created_at, r.business_date, r.is_closed, r.closed_at, r.ordered_at, r.window_end_reason, r.outcome, r.attempts,
                                r.reached_attempts, r.first_reached_attempt, r.talk_seconds_total, r.talk_seconds_reached, r.first_attempt_at,
                                r.speed_to_lead_seconds, r.called_before_next_noon, r.last_attempt_at, r.business_days_since_last, r.since_last_bucket,
                                r.attempts_without_outcome, r.logged_without_aircall), ';' order by r.deal_id) into v_view
    from cma_read.attempts_per_deal r where r.tenant_id = v_t1;
    select format('%s %s', (select count(*) from cma_read.attempts_per_deal where tenant_id = v_t1), (v_view = v_app)::text) into v_txt;
    perform set_config('app.tenant_id', v_t2::text, true);
    select v_txt || format(' %s', (select count(*) from cma_read.attempts_per_deal where tenant_id = v_t1)) into v_txt;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    v_rows := v_rows || array['29', 'B19 the reader view equals the application''s rows for its tenant and shows no other tenant''s',
      case when v_txt = '12 true 0' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B20. tenant isolation: tenant two's page holds its own deal only, never attempted (none of tenant one's calls or orders;
    --      without a market, so no next noon is known)
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_analyst2::text, true);
    j := cma.attempts_per_deal_page(date '2026-10-05', date '2026-10-11', 'day', null, null);
    v_txt := pg_temp.v0008z_fig(j -> 'current') || ' ' || (j -> 'list' -> 'rows' -> 0 ->> 'deal_source_id');
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['30', 'B20 tenant isolation for the pages',
      case when v_txt = '1/0/0/0.00/0.0/0/0/-/0of0/1/1/0/0/0/0/0/0/0/0 dW' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B21. 0007d's reads unchanged: cma.lead_calls_of gives 0007d's rows for every counted deal (0 apart, both ways), and
    --      cma.lead_to_order_of hashes the same over every column as 0007d's body gives it (a copy in pg_temp); Speed to lead reads
    --      nothing else that changed, so its rows follow from the calls'. 24 calls of the sixteen counted deals; three first orders:
    --      dL's, dS's (after the test, cancelled and deleted ones) and dOrdB's (0007d's lead population still holds the order
    --      pipeline marked lead)
    select format('%s/%s', count(*) filter (where x.side = 'new'), count(*) filter (where x.side = 'old')) into v_txt
    from (select 'new' as side, n.* from cma.counted_deals_of(v_t1, null, null) d
          cross join lateral (select * from cma.lead_calls_of(v_t1, d.connection_id, d.record_type, d.source_id, d.contacts, d.created_at - interval '10 minutes')
                              except select * from pg_temp.v0008z_lead_calls_0007d(v_t1, d.connection_id, d.record_type, d.source_id, d.contacts,
                                                                                   d.created_at - interval '10 minutes')) n
          union all
          select 'old', o.* from cma.counted_deals_of(v_t1, null, null) d
          cross join lateral (select * from pg_temp.v0008z_lead_calls_0007d(v_t1, d.connection_id, d.record_type, d.source_id, d.contacts,
                                                                            d.created_at - interval '10 minutes')
                              except select * from cma.lead_calls_of(v_t1, d.connection_id, d.record_type, d.source_id, d.contacts,
                                                                     d.created_at - interval '10 minutes')) o) x;
    select v_txt || format(' calls:%s', count(*)) into v_txt
    from cma.counted_deals_of(v_t1, null, null) d
    cross join lateral cma.lead_calls_of(v_t1, d.connection_id, d.record_type, d.source_id, d.contacts, d.created_at - interval '10 minutes') c;
    select v_txt || ' ' || ((select md5(string_agg(to_jsonb(r)::text, '|' order by r.deal_id)) from cma.lead_to_order_of(v_t1, null, null) r)
                            = (select md5(string_agg(to_jsonb(r)::text, '|' order by r.deal_id)) from pg_temp.v0008z_lead_to_order_0007d(v_t1, null, null) r))::text
           || format(' orders:%s', (select count(r.order_id) from cma.lead_to_order_of(v_t1, null, null) r))
      into v_txt;
    v_rows := v_rows || array['31', 'B21 0007d''s calls of a deal and lead to order give their rows as before (copies of 0007d''s bodies)',
      case when v_txt = '0/0 calls:24 true orders:3' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B22. the page's settings, history start and filter lists (the lead pipelines only)
    j := cma.attempts_per_deal_page_of(v_t1, date '2026-10-05', date '2026-10-11', 'pipeline', null, null, 'all', 'all', 100, v_now);
    v_txt := (j -> 'settings' ->> 'source') || '/' || (j -> 'settings' ->> 'reached_min_talk_seconds') || '/' || (j -> 'settings' ->> 'speed_buckets')
             || '/' || (j -> 'settings' ->> 'max_bucket') || ' ' || (j ->> 'history_start') || ' ' || (j ->> 'markets') || ' '
             || (select string_agg(p ->> 'label', ',') from jsonb_array_elements(j -> 'pipelines') p) || ' '
             || (select string_agg(format('%s=%s', g ->> 'label', g ->> 'deals'), ',') from jsonb_array_elements(j -> 'groups') g);
    v_rows := v_rows || array['32', 'B22 the settings, the history start and the filter lists of the lead pipelines only',
      case when v_txt = 'telephony/30/5,15,60,240,1440/5 2026-09-30 ["NL"] Sales Sales=11' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['49', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008z (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008z values (49, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- C. Messages withdrawn, on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_super1 uuid; v_a1 uuid; v_a2 uuid; v_admin2 uuid;
  v_manual uuid; v_alert uuid; v_other uuid;
  v_at1 timestamptz; v_at2 timestamptz;
  v_txt text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    v_t1 := cma.create_tenant('verify-0008z-msg-one', 'Verify 0008z messages one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008z-msg-two', 'Verify 0008z messages two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-madmin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-msuper1@example.invalid', 'super1') returning id into v_super1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-ma1@example.invalid', 'a1') returning id into v_a1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-ma2@example.invalid', 'a2') returning id into v_a2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-madmin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_super1, 'supervisor'), (v_t1, v_a1, 'agent'), (v_t1, v_a2, 'agent'),
                 (v_t2, v_admin2, 'admin')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    -- an alert as the ingest's rules write one (a reference, no rule here), delivered to both agents
    insert into cma.message (tenant_id, kind, urgency, title, body, ref_system, ref_type, ref_id)
    values (v_t1, 'alert', 'urgent', 'New deal', 'NL · Sales · created 10:00', 'verifycrm', 'deal', 'd-1') returning id into v_alert;
    perform set_config('app.tenant_id', v_t1::text, true);
    perform cma.deliver_message(v_alert, array[v_a1, v_a2]);
    perform set_config('role', 'cma_app', true);
    -- the supervisor's two messages to both agents
    perform set_config('app.user_id', v_super1::text, true);
    v_manual := cma.send_message('Verify withdrawn', 'A test message', 'normal', jsonb_build_object('users', jsonb_build_array(v_a1, v_a2)));
    v_other := cma.send_message('Verify kept', 'A test message', 'normal', jsonb_build_object('users', jsonb_build_array(v_a1, v_a2)));
    -- a1 polls before the withdrawal (delivered); a2 not yet
    perform set_config('app.user_id', v_a1::text, true);
    perform cma.my_messages();

    -- C1. a sender without messages.withdraw and an agent refused (CMA06), no acting user CMA01, an unknown message CMA02,
    --     another tenant's admin CMA02
    perform set_config('app.user_id', v_super1::text, true);
    v_txt := pg_temp.v0008z_code(format('select cma.withdraw_message(%L)', v_manual));
    perform set_config('app.user_id', v_a1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008z_code(format('select cma.withdraw_message(%L)', v_manual));
    perform set_config('app.user_id', '', true);
    v_txt := v_txt || ' ' || pg_temp.v0008z_code(format('select cma.withdraw_message(%L)', v_manual));
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008z_code(format('select cma.withdraw_message(%L)', gen_random_uuid()));
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008z_code(format('select cma.withdraw_message(%L)', v_manual));
    perform set_config('app.tenant_id', v_t1::text, true);
    v_rows := v_rows || array['51', 'C1 refused for a sender without the permission, an agent, no acting user, an unknown and another tenant''s message',
      case when v_txt = 'CMA06 CMA06 CMA01 CMA02 CMA02' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- C2. the admin withdraws the manual message and the alert: each answers its time, the withdrawer set
    perform set_config('app.user_id', v_admin1::text, true);
    v_at1 := cma.withdraw_message(v_manual);
    v_at2 := cma.withdraw_message(v_alert);
    select format('%s %s %s', v_at1 is not null and v_at2 is not null,
                  (select count(*) from cma.message m where m.id in (v_manual, v_alert) and m.withdrawn_by = v_admin1 and m.withdrawn_at is not null),
                  (select count(*) from cma.message m where m.id = v_other and m.withdrawn_at is null))
      into v_txt;
    v_rows := v_rows || array['52', 'C2 an admin withdraws a manual message and an alert',
      case when v_txt = 't 2 1' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- C3. the recipients: a1's inbox lists only the kept message, unread 1, marking the withdrawn ones read changes nothing and
    --     acknowledging the alert is not found; a2, who never polled, gets only the kept one, and the withdrawn ones stay
    --     undelivered for a2 (no delivery, so no notification)
    perform set_config('app.user_id', v_a1::text, true);
    select string_agg(x.title, ',' order by x.title) || format(' unread:%s read:%s ack:%s', cma.my_unread_count(),
             cma.mark_messages_read(array[v_manual, v_alert]), pg_temp.v0008z_code(format('select cma.acknowledge_message(%L)', v_alert)))
      into v_txt from cma.my_messages() x;
    perform set_config('app.user_id', v_a2::text, true);
    select v_txt || ' | ' || string_agg(x.title, ',' order by x.title) || format(' unread:%s', cma.my_unread_count()) into v_txt from cma.my_messages() x;
    select v_txt || format(' undelivered:%s', count(*)) into v_txt
    from cma.message_delivery d where d.user_id = v_a2 and d.message_id in (v_manual, v_alert) and d.delivered_at is null;
    v_rows := v_rows || array['53', 'C3 a recipient''s inbox and unread count without them; a delivery not yet made never made',
      case when v_txt = 'Verify kept unread:1 read:0 ack:CMA02 | Verify kept unread:1 undelivered:2' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- C4. the stats mark them withdrawn, with who, and keep their recipients
    perform set_config('app.user_id', v_super1::text, true);
    select string_agg(format('%s:%s/%s/%s', s.title, s.recipients, s.withdrawn_at is not null, s.withdrawn_by = v_admin1), ' ' order by s.title)
      into v_txt from cma.message_stats(current_date - 1, current_date + 1) s;
    v_rows := v_rows || array['54', 'C4 the stats mark a withdrawn message',
      case when v_txt = 'New deal:2/t/t Verify kept:2/f/ Verify withdrawn:2/t/t' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- C5. the audit keeps who and when: one update row per withdrawn message, by the admin, the time from null to the time
    perform set_config('role', 'cma_owner', true);
    select format('%s/%s', count(*), count(*) filter (where a.actor_user_id = v_admin1 and a.action = 'update'
                                                         and a.old_row ->> 'withdrawn_at' is null and (a.new_row ->> 'withdrawn_at')::timestamptz = v_at1))
      into v_txt
    from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'message' and a.row_id = v_manual::text and a.action = 'update';
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['55', 'C5 the audit row names the admin and the time',
      case when v_txt = '1/1' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- C6. withdrawing twice changes nothing: the same time answered, no second audit row, the withdrawer kept
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := (cma.withdraw_message(v_manual) = v_at1)::text;
    perform set_config('role', 'cma_owner', true);
    select v_txt || format(' %s %s', (select count(*) from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'message'
                                       and a.row_id = v_manual::text and a.action = 'update'),
                           (select m.withdrawn_by = v_admin1 and m.withdrawn_at = v_at1 from cma.message m where m.id = v_manual))
      into v_txt;
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['56', 'C6 withdrawing twice changes nothing',
      case when v_txt = 'true 1 t' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- C7. nothing else of a message changes: the application cannot update its title (no privilege), the owner cannot either
    --     (the trigger), and a withdrawn message's time never moves (the trigger)
    v_txt := pg_temp.v0008z_code(format('update cma.message set title = ''x'' where id = %L', v_other));
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' ' || pg_temp.v0008z_code(format('update cma.message set title = ''x'' where id = %L', v_other))
             || ' ' || pg_temp.v0008z_code(format('update cma.message set withdrawn_at = now() + interval ''1 hour'' where id = %L', v_manual))
             || ' ' || pg_temp.v0008z_code(format('update cma.message set withdrawn_at = now() where id = %L', v_other));
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['57', 'C7 nothing else of a message changes, and a withdrawal never moves',
      case when v_txt = '42501 CMA04 CMA03 23514' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['59', 'C the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008z (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008z values (59, 'C the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008z
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008z where result = 'PASS') = 36
                       and not exists (select 1 from verify_0008z where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008z where result = 'PASS'),
                                        (select count(*) from verify_0008z where result <> 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0008z_code(text);
drop function if exists pg_temp.v0008z_deals(uuid, timestamptz);
drop function if exists pg_temp.v0008z_fig(jsonb);
drop function if exists pg_temp.v0008z_lead_calls_0007d(uuid, uuid, text, text, text[], timestamptz);
drop function if exists pg_temp.v0008z_lead_to_order_0007d(uuid, timestamptz, timestamptz);
