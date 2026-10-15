-- =============================================================================================
-- 67_verify_invitations.sql: verifies addition 0008l, invitations by email
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure
-- and privileges; block B works on two throwaway tenants inside a subtransaction that is always
-- rolled back. Universal otherwise: nothing of the seed is used; employers, teams, skills, addresses
-- and sign-in ids are invented data values. Every check writes one row, PASS or FAIL, and the last
-- result lists them with the verdict, because Cloud SQL Studio shows no notices.
-- Run as your own IAM login in dev, after 66_invitations.sql; then 63 and 65 again.
--   A  structure and privileges: the addition after 0008k; the table with row-level security, audit,
--      the hash unique and hidden from the application, no delete, the reader's view without the hash;
--      the application's functions in the caller's rights, the invitee's two SECURITY DEFINER with a
--      pinned search path, owned by cma_owner, executable by the application only; the two settings
--   B  behaviour on two tenants: create (the token once, its hash stored, the list without it); one
--      invitation per assignable role of the default ladder, each accepted with that role; the system
--      role refused; the role ceiling of users.manage_agents; every refusal at creation; the domain
--      setting; the settings' validation; renew and revoke; acceptance with teams, skills and the audit
--      naming the inviter; expired; wrong account; reuse; a sign-in id already linked, and one that works
--      in another tenant (refused, until a tenant picker exists); another tenant's context; the hash out of reach of the application and the audit; the preview changing nothing;
--      the inviter's rights and the address checked again at acceptance; malformed input
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says
-- PROVOKED instead of PASS.
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

-- Dev only: a verifier that writes refuses a database without the dev seed. The flag is kept for the
-- session, so every block below stops at once and the verdict says REFUSED, also where the client
-- carries on after the error
select set_config('verify.is_dev', (exists (select 1 from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                            where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false) as is_dev;
do $$
begin
  if not current_setting('verify.is_dev')::boolean then
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 67 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008l;
create temp table verify_0008l (ord int, check_name text, result text, detail text);

-- The SQLSTATE a statement raises, or 'ok' (inside a subtransaction, so a refusal writes nothing)
create or replace function pg_temp.v8l_err(p_sql text)
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

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn      text;
  v_bad     text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded, after 0008k
  insert into verify_0008l values (1, 'A1 addition 0008l recorded, after 0008k',
    case when exists (select 1 from cma.schema_migration where version = '0008l')
              and exists (select 1 from cma.schema_migration where version = '0008k') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the table: row-level security with the tenant policy, the audit trigger, the hash unique; the
  --     application may insert, may not delete, may not read the hash and may update only what renewal
  --     and revocation change; readers have no rights on it and their view has no hash
  v_bad := '';
  if to_regclass('cma.invitation') is null then
    v_bad := 'cma.invitation is missing';
  else
    if not (select relrowsecurity from pg_class where oid = 'cma.invitation'::regclass) then v_bad := v_bad || 'no row-level security; '; end if;
    if not exists (select 1 from pg_policies where schemaname = 'cma' and tablename = 'invitation' and policyname = 'tenant_app') then v_bad := v_bad || 'no tenant policy; '; end if;
    if not exists (select 1 from pg_trigger where tgrelid = 'cma.invitation'::regclass and tgname = 'audit') then v_bad := v_bad || 'no audit trigger; '; end if;
    if not exists (select 1 from pg_indexes where schemaname = 'cma' and tablename = 'invitation' and indexdef like 'CREATE UNIQUE INDEX%(token_hash)') then v_bad := v_bad || 'the hash is not unique; '; end if;
    if not has_table_privilege('cma_app', 'cma.invitation', 'insert') then v_bad := v_bad || 'the application cannot insert; '; end if;
    if has_table_privilege('cma_app', 'cma.invitation', 'delete') then v_bad := v_bad || 'the application may delete; '; end if;
    if has_column_privilege('cma_app', 'cma.invitation', 'token_hash', 'select') then v_bad := v_bad || 'the application may read the hash; '; end if;
    if not has_column_privilege('cma_app', 'cma.invitation', 'email', 'select') then v_bad := v_bad || 'the application cannot read the address; '; end if;
    if has_column_privilege('cma_app', 'cma.invitation', 'role_id', 'update') or has_column_privilege('cma_app', 'cma.invitation', 'email', 'update')
       or has_column_privilege('cma_app', 'cma.invitation', 'accepted_user_id', 'update') then v_bad := v_bad || 'the application may update the role, address or acceptance; '; end if;
    if has_table_privilege('cma_readonly', 'cma.invitation', 'select') then v_bad := v_bad || 'readers read the base table; '; end if;
    if to_regclass('cma_read.invitation') is null then v_bad := v_bad || 'no reader view; ';
    elsif exists (select 1 from information_schema.columns where table_schema = 'cma_read' and table_name = 'invitation' and column_name = 'token_hash') then
      v_bad := v_bad || 'the reader view shows the hash; ';
    end if;
  end if;
  insert into verify_0008l values (2, 'A2 the table: RLS, audit, the hash unique and hidden, no delete, the reader view without the hash',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. the functions: the application's in the caller's rights; the invitee's two SECURITY DEFINER,
  --     owned by cma_owner, with the search path pinned; all executable by the application only; the
  --     acceptance answers the result, the tenant and the person only
  v_bad := '';
  foreach v_fn in array array['cma.create_invitation(text,text,text,text,text,text[],jsonb)', 'cma.renew_invitation(uuid)',
                              'cma.revoke_invitation(uuid)', 'cma.invitations()',
                              'cma.invitation_preview(text,text,text,text)', 'cma.accept_invitation(text,text,text,text)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' is missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
      v_bad := v_bad || v_fn || ' is not the application''s only; ';
    elsif v_fn in ('cma.invitation_preview(text,text,text,text)', 'cma.accept_invitation(text,text,text,text)') then
      if not (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
         or (select pg_get_userbyid(proowner) from pg_proc where oid = to_regprocedure(v_fn)) <> 'cma_owner'
         or not coalesce((select 'search_path=pg_catalog, cma, pg_temp' = any (proconfig) from pg_proc where oid = to_regprocedure(v_fn)), false) then
        v_bad := v_bad || v_fn || ' is not SECURITY DEFINER owned by cma_owner with a pinned search path; ';
      end if;
    elsif (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' runs in the owner''s rights; ';
    end if;
  end loop;
  foreach v_fn in array array['cma.invitation_new_token()', 'cma.invitation_token_hash(text)', 'cma.assert_invitation_allowed(uuid,text)',
                              'cma.invitation_other_tenant(uuid,text,text)'] loop
    if to_regprocedure(v_fn) is null or has_function_privilege('cma_readonly', v_fn, 'execute')
       or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
      v_bad := v_bad || v_fn || ' is missing or public; ';
    end if;
  end loop;
  -- the tenant-crossing lookup is the owner's only: the application reaches it through the invitee's functions
  if has_function_privilege('cma_app', 'cma.invitation_other_tenant(uuid,text,text)', 'execute') then
    v_bad := v_bad || 'the application may execute cma.invitation_other_tenant; ';
  end if;
  if (select array_to_string(proargnames[5:], ',') from pg_proc where oid = to_regprocedure('cma.accept_invitation(text,text,text,text)'))
     is distinct from 'result,tenant_id,user_id' then
    v_bad := v_bad || 'acceptance answers more than the result, the tenant and the person; ';
  end if;
  insert into verify_0008l values (3, 'A3 the functions: the application''s only; the invitee''s SECURITY DEFINER, owned, path pinned',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. the two settings in the catalog with their defaults
  select string_agg(key || '=' || value_type || ':' || default_value, ' ' order by key) into v_bad
  from cma.setting where key in ('auth.invitation_valid_days', 'auth.invitation_email_domains');
  insert into verify_0008l values (4, 'A4 the settings auth.invitation_valid_days (7) and auth.invitation_email_domains (empty)',
    case when v_bad = 'auth.invitation_email_domains=text: auth.invitation_valid_days=integer:7' and not v_provoke then 'PASS' else 'FAIL' end,
    coalesce(v_bad, 'missing'));
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_manager1 uuid; v_agent1 uuid; v_people1 uuid; v_old1 uuid; v_admin2 uuid;
  v_role     uuid;
  v_id       uuid; v_id2 uuid; v_id3 uuid;
  v_tok      text; v_tok2 text; v_tok3 text; v_tok4 text;
  v_exp      timestamptz;
  v_txt      text;
  v_detail   text;
  v_n        integer; v_m integer;
  rr         record;
  k          text;
  v_audit    bigint;
  v_users    bigint;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    v_t1 := cma.create_tenant('verify-0008l-one', 'Verify 0008l one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008l-two', 'Verify 0008l two', 'Europe/Amsterdam');
    insert into cma.organisation (tenant_id, key, name) values (v_t1, 'verify-org', 'Verify employer'), (v_t2, 'verify-org', 'Verify employer two');
    insert into cma.organisation (tenant_id, key, name, status) values (v_t1, 'verify-old', 'Verify old employer', 'inactive');
    insert into cma.team (tenant_id, key, name) values (v_t1, 'verify-team-a', 'Verify team A'), (v_t1, 'verify-team-b', 'Verify team B');
    insert into cma.skill (tenant_id, dimension, key, name) values (v_t1, 'language', 'verify-dutch', 'Verify Dutch'),
                                                                   (v_t1, 'work_type', 'verify-sales', 'Verify sales');
    insert into cma.app_user (tenant_id, organisation_id, email, display_name)
      select v_t1, o.id, x.email, x.name from cma.organisation o,
             (values ('verify-admin1@example.invalid', 'admin1'), ('verify-manager1@example.invalid', 'manager1'),
                     ('verify-agent1@example.invalid', 'agent1'), ('verify-people1@example.invalid', 'people1'),
                     ('verify-old1@example.invalid', 'old1')) as x(email, name)
      where o.tenant_id = v_t1 and o.key = 'verify-org';
    select id into v_admin1 from cma.app_user where tenant_id = v_t1 and email = 'verify-admin1@example.invalid';
    select id into v_manager1 from cma.app_user where tenant_id = v_t1 and email = 'verify-manager1@example.invalid';
    select id into v_agent1 from cma.app_user where tenant_id = v_t1 and email = 'verify-agent1@example.invalid';
    select id into v_people1 from cma.app_user where tenant_id = v_t1 and email = 'verify-people1@example.invalid';
    select id into v_old1 from cma.app_user where tenant_id = v_t1 and email = 'verify-old1@example.invalid';
    update cma.app_user set status = 'inactive' where id = v_old1;
    insert into cma.app_user (tenant_id, organisation_id, email, display_name)
      select v_t2, o.id, 'verify-admin2@example.invalid', 'admin2' from cma.organisation o where o.tenant_id = v_t2 and o.key = 'verify-org'
      returning id into v_admin2;
    -- a role with users.manage_agents and nothing else: it adds people, without skills.manage
    insert into cma.app_role (tenant_id, key, name) values (v_t1, 'verify_people', 'Verify people') returning id into v_role;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_t1, v_role, 'users.manage_agents');
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_manager1, 'manager'), (v_t1, v_agent1, 'agent'), (v_t1, v_people1, 'verify_people'),
                 (v_t1, v_old1, 'agent'), (v_t2, v_admin2, 'admin')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    insert into cma.app_user_external_id (tenant_id, user_id, system, external_id)
    values (v_t1, v_admin1, 'google', '800000000000000000001'), (v_t1, v_agent1, 'google', '800000000000000000003'),
           (v_t2, v_admin2, 'google', '800000000000000000002');
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);

    -- B1. create: the token once (43 url-safe characters), its SHA-256 stored and not the token, open,
    --     valid for the default 7 days, listed without a token or a hash
    select c.invitation_id, c.token, c.expires_at into v_id, v_tok, v_exp
    from cma.create_invitation('Verify-New1@Example.Invalid', '  New one  ', 'NL', 'agent', 'verify-org') c;
    perform set_config('role', 'cma_owner', true);
    select format('%s chars, url-safe %s, hash %s, raw %s, %s days', length(v_tok), (v_tok ~ '^[A-Za-z0-9_-]{43}$')::text,
                  (i.token_hash = encode(sha256(convert_to(v_tok, 'UTF8')), 'hex'))::text, (i.token_hash = v_tok)::text,
                  round(extract(epoch from (i.expires_at - i.created_at)) / 86400))
      into v_txt
    from cma.invitation i where i.id = v_id;
    perform set_config('role', 'cma_app', true);
    select v_txt || format(' | %s %s %s %s %s', i.email, i.display_name, i.locale, i.role_key, i.state) into v_txt
    from cma.invitations() i where i.invitation_id = v_id;
    v_txt := v_txt || ' | list columns ' || coalesce((select string_agg(a, ',') from unnest((select proargnames from pg_proc
                                              where oid = 'cma.invitations()'::regprocedure)) a where a in ('token', 'token_hash')), 'none');
    v_rows := v_rows || array['11', 'B1 create: the token once, its hash stored, open for 7 days, listed without token or hash',
      case when v_txt = '43 chars, url-safe true, hash true, raw false, 7 days | verify-new1@example.invalid New one nl agent open | list columns none' and not v_provoke then 'PASS' else 'FAIL' end,
      coalesce(v_txt, 'null')];

    -- B2. one invitation per assignable role of the default ladder, each accepted by its own sign-in id
    --     with that role and the employer; the ladder the admin may give is exactly these roles
    v_txt := (select string_agg(rl.key, ',' order by rl.key) from cma.roles() rl where rl.assignable and rl.is_system);
    v_n := 0;
    foreach k in array array['agent', 'supervisor', 'manager', 'admin', 'analytics'] loop
      v_n := v_n + 1;
      perform set_config('app.tenant_id', v_t1::text, true);
      perform set_config('app.user_id', v_admin1::text, true);
      select c.token into v_tok2 from cma.create_invitation(format('verify-role-%s@example.invalid', k), 'Role ' || k, 'en', k, 'verify-org') c;
      perform set_config('app.tenant_id', '', true);
      perform set_config('app.user_id', '', true);
      select a.* into rr from cma.accept_invitation(v_tok2, 'google', '80000000000000000010' || v_n, format('verify-role-%s@example.invalid', k)) a;
      perform set_config('role', 'cma_owner', true);
      v_txt := v_txt || ' ' || rr.result || ':' || coalesce((select ar.key || '/' || o.key from cma.user_role ur
                                           join cma.app_role ar on ar.tenant_id = ur.tenant_id and ar.id = ur.role_id
                                           join cma.app_user u on u.tenant_id = ur.tenant_id and u.id = ur.user_id
                                           join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
                                           where ur.tenant_id = rr.tenant_id and ur.user_id = rr.user_id), 'none');
      perform set_config('role', 'cma_app', true);
    end loop;
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    v_rows := v_rows || array['12', 'B2 one invitation per assignable role of the default ladder, each accepted with that role',
      case when v_txt = 'admin,agent,analytics,manager,supervisor accepted:agent/verify-org accepted:supervisor/verify-org accepted:manager/verify-org accepted:admin/verify-org accepted:analytics/verify-org'
           and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B3. the system role is refused at creation (CMA06), and a row naming it (written past the function)
    --     is refused at acceptance, writing nothing
    v_txt := pg_temp.v8l_err($q$select cma.create_invitation('verify-sched@example.invalid', 'Sched', 'en', 'scheduler', 'verify-org')$q$);
    perform set_config('role', 'cma_owner', true);
    v_tok2 := cma.invitation_new_token();
    insert into cma.invitation (tenant_id, email, display_name, locale, role_id, organisation_id, token_hash, created_by, expires_at)
    select v_t1, 'verify-sched@example.invalid', 'Sched', 'en', ar.id, o.id, cma.invitation_token_hash(v_tok2), v_admin1, now() + interval '1 day'
    from cma.app_role ar, cma.organisation o where ar.tenant_id = v_t1 and ar.key = 'scheduler' and o.tenant_id = v_t1 and o.key = 'verify-org';
    v_users := (select count(*) from cma.app_user where tenant_id = v_t1);
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', '', true);
    v_txt := v_txt || ' ' || (select a.result from cma.accept_invitation(v_tok2, 'google', '800000000000000000201', 'verify-sched@example.invalid') a);
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || format(' people +%s, scheduler holders %s', (select count(*) from cma.app_user where tenant_id = v_t1) - v_users,
                             (select count(*) from cma.user_role ur join cma.app_role ar on ar.tenant_id = ur.tenant_id and ar.id = ur.role_id
                              where ur.tenant_id = v_t1 and ar.key = 'scheduler'));
    update cma.invitation set revoked_at = now(), revoked_by = v_admin1 where tenant_id = v_t1 and email = 'verify-sched@example.invalid';
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    v_rows := v_rows || array['13', 'B3 the system role is refused at creation and at acceptance',
      case when v_txt = 'CMA06 invalid people +0, scheduler holders 1' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B4. the role ceiling: users.manage_agents (the manager) invites agent, supervisor and analytics, not
    --     manager or admin (CMA06); sees only those invitations; cannot renew or revoke an admin's
    --     invitation for a managing role; the role picker offers it exactly what it may grant; an agent
    --     cannot invite (CMA06), nor anyone without an acting user (CMA01)
    perform set_config('app.user_id', v_manager1::text, true);
    v_txt := (select string_agg(rl.key, ',' order by rl.key) from cma.roles() rl where rl.assignable);
    foreach k in array array['agent', 'supervisor', 'analytics', 'manager', 'admin'] loop
      v_txt := v_txt || ' ' || k || '=' || pg_temp.v8l_err(format($q$select cma.create_invitation('verify-ceiling-%s@example.invalid', 'C', 'en', %L, 'verify-org')$q$, k, k));
    end loop;
    perform set_config('app.user_id', v_admin1::text, true);
    select c.invitation_id, c.token into v_id2, v_tok4 from cma.create_invitation('verify-mgr-by-admin@example.invalid', 'M', 'en', 'manager', 'verify-org') c;
    perform set_config('app.user_id', v_manager1::text, true);
    v_txt := v_txt || format(' | sees managing %s, renew %s, revoke %s',
      (select count(*) from cma.invitations() i where i.role_key in ('manager', 'admin')),
      pg_temp.v8l_err(format('select cma.renew_invitation(%L)', v_id2)), pg_temp.v8l_err(format('select cma.revoke_invitation(%L)', v_id2)));
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := v_txt || ' | agent ' || pg_temp.v8l_err($q$select cma.create_invitation('verify-agentinv@example.invalid', 'A', 'en', 'agent', 'verify-org')$q$)
             || ' list ' || pg_temp.v8l_err('select cma.invitations()');
    perform set_config('app.user_id', '', true);
    v_txt := v_txt || ' | nobody ' || pg_temp.v8l_err($q$select cma.create_invitation('verify-nobody@example.invalid', 'A', 'en', 'agent', 'verify-org')$q$);
    perform set_config('app.user_id', v_admin1::text, true);
    v_rows := v_rows || array['14', 'B4 the role ceiling of users.manage_agents; an agent and no acting user refused',
      case when v_txt = 'agent,analytics,supervisor agent=ok supervisor=ok analytics=ok manager=CMA06 admin=CMA06 | sees managing 0, renew CMA06, revoke CMA06 | agent CMA06 list CMA06 | nobody CMA01'
           and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B5. refusals at creation, each writing nothing: the address, the name and the language (CMA04);
    --     an unknown or inactive employer, an unknown role, team or skill (CMA02); a level outside the
    --     scale or a level on a binary skill (CMA04); skills without skills.manage (CMA06); an active or
    --     inactive person with the address, and a pending invitation for it (CMA03)
    v_n := (select count(*) from cma.invitations());
    v_txt := '';
    foreach v_detail in array array[
      $q$select cma.create_invitation('not-an-address', 'X', 'en', 'agent', 'verify-org')$q$,
      $q$select cma.create_invitation('verify-x@example.invalid', '   ', 'en', 'agent', 'verify-org')$q$,
      $q$select cma.create_invitation('verify-x@example.invalid', 'X', 'english', 'agent', 'verify-org')$q$,
      $q$select cma.create_invitation('verify-x@example.invalid', 'X', 'en', 'agent', 'verify-none')$q$,
      $q$select cma.create_invitation('verify-x@example.invalid', 'X', 'en', 'agent', 'verify-old')$q$,
      $q$select cma.create_invitation('verify-x@example.invalid', 'X', 'en', 'verify_none', 'verify-org')$q$,
      $q$select cma.create_invitation('verify-x@example.invalid', 'X', 'en', 'agent', 'verify-org', array['verify-team-z'])$q$,
      $q$select cma.create_invitation('verify-x@example.invalid', 'X', 'en', 'agent', 'verify-org', '{}', '[{"key": "verify-none"}]')$q$,
      $q$select cma.create_invitation('verify-x@example.invalid', 'X', 'en', 'agent', 'verify-org', '{}', '[{"key": "verify-dutch", "level": 7}]')$q$,
      $q$select cma.create_invitation('verify-x@example.invalid', 'X', 'en', 'agent', 'verify-org', '{}', '[{"key": "verify-sales", "level": 1}]')$q$,
      $q$select cma.create_invitation('verify-agent1@example.invalid', 'X', 'en', 'agent', 'verify-org')$q$,
      $q$select cma.create_invitation('verify-old1@example.invalid', 'X', 'en', 'agent', 'verify-org')$q$,
      $q$select cma.create_invitation('VERIFY-NEW1@example.invalid', 'X', 'en', 'agent', 'verify-org')$q$] loop
      v_txt := v_txt || pg_temp.v8l_err(v_detail) || ' ';
    end loop;
    perform set_config('app.user_id', v_people1::text, true);
    v_txt := v_txt || '| people ' || pg_temp.v8l_err($q$select cma.create_invitation('verify-x@example.invalid', 'X', 'en', 'agent', 'verify-org', '{}', '[{"key": "verify-sales"}]')$q$)
             || ' ' || pg_temp.v8l_err($q$select cma.create_invitation('verify-x@example.invalid', 'X', 'en', 'agent', 'verify-org', array['verify-team-a'])$q$);
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := v_txt || format(' | listed +%s', (select count(*) from cma.invitations()) - v_n);
    v_rows := v_rows || array['15', 'B5 every refusal at creation writes nothing',
      case when v_txt = 'CMA04 CMA04 CMA04 CMA02 CMA02 CMA02 CMA02 CMA02 CMA04 CMA04 CMA03 CMA03 CMA03 | people CMA06 ok | listed +1' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B6. the domain setting: with example.org set, an address at example.invalid is refused (CMA04) and
    --     one at example.org created; empty again, any domain; set after an invitation, it refuses the
    --     acceptance (invalid, nothing written)
    select c.token into v_tok3 from cma.create_invitation('verify-dom-late@example.invalid', 'Late', 'en', 'agent', 'verify-org') c;
    perform cma.set_tenant_setting('auth.invitation_email_domains', 'example.org');
    v_txt := pg_temp.v8l_err($q$select cma.create_invitation('verify-dom@example.invalid', 'D', 'en', 'agent', 'verify-org')$q$)
             || ' ' || pg_temp.v8l_err($q$select cma.create_invitation('verify-dom@example.org', 'D', 'en', 'agent', 'verify-org')$q$)
             || ' ' || pg_temp.v8l_err($q$select cma.create_invitation('verify-dom@sub.example.org', 'D', 'en', 'agent', 'verify-org')$q$);
    perform set_config('app.tenant_id', '', true);
    v_txt := v_txt || ' late ' || (select a.result from cma.accept_invitation(v_tok3, 'google', '800000000000000000301', 'verify-dom-late@example.invalid') a);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform cma.set_tenant_setting('auth.invitation_email_domains', '');
    v_txt := v_txt || ' | empty ' || pg_temp.v8l_err($q$select cma.create_invitation('verify-dom2@example.invalid', 'D', 'en', 'agent', 'verify-org')$q$);
    v_txt := v_txt || ' | person ' || (select count(*) from cma.directory() d where d.email = 'verify-dom-late@example.invalid');
    v_rows := v_rows || array['16', 'B6 the domain setting at creation and at acceptance; empty allows any domain',
      case when v_txt = 'CMA04 ok CMA04 late invalid | empty ok | person 0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B7. the settings' validation: valid days from 1 to 30 only, the expiry following the setting; the
    --     domain list normalised (lower case, no spaces) and refused when it is not a list of domains;
    --     the manager cannot set either (CMA06)
    v_txt := '';
    foreach v_detail in array array['0', '31', '-1', 'x', '1000', '7.5', '1', '30'] loop
      v_txt := v_txt || v_detail || '=' || pg_temp.v8l_err(format($q$select cma.set_tenant_setting('auth.invitation_valid_days', %L)$q$, v_detail)) || ' ';
    end loop;
    perform cma.set_tenant_setting('auth.invitation_valid_days', '3');
    select round(extract(epoch from (c.expires_at - now())) / 86400)::text into v_detail
    from cma.create_invitation('verify-days@example.invalid', 'Days', 'en', 'agent', 'verify-org') c;
    v_txt := v_txt || '| expires in ' || v_detail || ' | ';
    perform cma.set_tenant_setting('auth.invitation_valid_days', null);
    perform cma.set_tenant_setting('auth.invitation_email_domains', ' Example.ORG , other.example.org ');
    v_txt := v_txt || (select value from cma.tenant_settings() where key = 'auth.invitation_email_domains');
    foreach v_detail in array array['@example.org', 'example', 'example.org;other.org', 'exa mple.org,', '-bad.org'] loop
      v_txt := v_txt || ' ' || pg_temp.v8l_err(format($q$select cma.set_tenant_setting('auth.invitation_email_domains', %L)$q$, v_detail));
    end loop;
    perform cma.set_tenant_setting('auth.invitation_email_domains', null);
    perform set_config('app.user_id', v_manager1::text, true);
    v_txt := v_txt || ' | manager ' || pg_temp.v8l_err($q$select cma.set_tenant_setting('auth.invitation_valid_days', '10')$q$);
    perform set_config('app.user_id', v_admin1::text, true);
    v_rows := v_rows || array['17', 'B7 the settings'' validation and the expiry following the days',
      case when v_txt = '0=CMA04 31=CMA04 -1=CMA04 x=CMA04 1000=CMA04 7.5=CMA04 1=ok 30=ok | expires in 3 | example.org,other.example.org CMA04 CMA04 CMA04 CMA04 CMA04 | manager CMA06'
           and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B8. renew: a new token, the old one invalid at the preview and the acceptance, the new one open; the
    --     expiry from now; the renewing person recorded and, from then on, the inviter of the link (it is
    --     accepted in their rights); an expired invitation renewed is open again; an accepted or revoked
    --     one is CMA03
    select c.token into v_tok2 from cma.renew_invitation(v_id) c;
    perform set_config('app.tenant_id', '', true);
    v_txt := format('%s %s', (v_tok2 <> v_tok)::text, length(v_tok2))
             || ' old ' || (select p.result from cma.invitation_preview(v_tok, 'google', '800000000000000000401', 'verify-new1@example.invalid') p)
             || '/' || (select a.result from cma.accept_invitation(v_tok, 'google', '800000000000000000401', 'verify-new1@example.invalid') a)
             || ' new ' || (select p.result from cma.invitation_preview(v_tok2, 'google', '800000000000000000401', 'verify-new1@example.invalid') p);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || format(' renewed by admin %s', (select (renewed_by = v_admin1 and renewed_at is not null)::text from cma.invitation where id = v_id));
    -- make one expired, then renew it
    select i.id into v_id3 from cma.invitation i where i.tenant_id = v_t1 and i.email = 'verify-days@example.invalid';
    update cma.invitation set created_at = now() - interval '10 days', expires_at = now() - interval '1 day' where id = v_id3;
    perform set_config('role', 'cma_app', true);
    v_txt := v_txt || ' | ' || (select i.state from cma.invitations() i where i.invitation_id = v_id3);
    perform cma.renew_invitation(v_id3);
    v_txt := v_txt || '>' || (select i.state || ' ' || round(extract(epoch from (i.expires_at - now())) / 86400) from cma.invitations() i where i.invitation_id = v_id3);
    perform cma.revoke_invitation(v_id3);
    v_txt := v_txt || ' | revoked ' || pg_temp.v8l_err(format('select cma.renew_invitation(%L)', v_id3))
             || ' accepted ' || pg_temp.v8l_err(format('select cma.renew_invitation(%L)', (select i.invitation_id from cma.invitations() i where i.email = 'verify-role-agent@example.invalid')))
             || ' unknown ' || pg_temp.v8l_err(format('select cma.renew_invitation(%L)', uuidv7()));
    -- a link the manager created and the admin renewed is the admin's: accepted with the manager inactive,
    -- the audit naming the admin
    perform set_config('app.user_id', v_manager1::text, true);
    select c.invitation_id into v_id3 from cma.create_invitation('verify-renewer@example.invalid', 'Renewer', 'en', 'agent', 'verify-org') c;
    perform set_config('app.user_id', v_admin1::text, true);
    select c.token into v_tok3 from cma.renew_invitation(v_id3) c;
    perform set_config('role', 'cma_owner', true);
    update cma.app_user set status = 'inactive' where id = v_manager1;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', '', true);
    select a.* into rr from cma.accept_invitation(v_tok3, 'google', '800000000000000000402', 'verify-renewer@example.invalid') a;
    perform set_config('role', 'cma_owner', true);
    update cma.app_user set status = 'active' where id = v_manager1;
    v_txt := v_txt || format(' | renewed by another %s, actor the renewer %s', rr.result,
                             (select (al.actor_user_id = v_admin1)::text from cma.audit_log al
                              where al.tenant_id = v_t1 and al.table_name = 'app_user' and al.action = 'insert' and al.new_row ->> 'id' = rr.user_id::text));
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    v_rows := v_rows || array['18', 'B8 renew: a new token, the old one invalid, the renewer the inviter; expired renewed; accepted or revoked refused',
      case when v_txt = 'true 43 old invalid/invalid new open renewed by admin true | expired>open 7 | revoked CMA03 accepted CMA03 unknown CMA02 | renewed by another accepted, actor the renewer true'
           and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B9. revoke: the link stops working; a second revoke changes nothing; an accepted invitation is
    --     CMA03; revoked and accepted rows stay listed with who and when (never deleted)
    v_n := (select count(*) from cma.invitations());
    perform cma.revoke_invitation(v_id2);
    v_txt := pg_temp.v8l_err(format('select cma.revoke_invitation(%L)', v_id2));
    perform set_config('app.tenant_id', '', true);
    v_txt := v_txt || ' ' || (select p.result from cma.invitation_preview(v_tok4, 'google', '800000000000000000501', 'verify-mgr-by-admin@example.invalid') p)
             || '/' || (select a.result from cma.accept_invitation(v_tok4, 'google', '800000000000000000501', 'verify-mgr-by-admin@example.invalid') a);
    perform set_config('app.tenant_id', v_t1::text, true);
    v_txt := v_txt || ' accepted ' || pg_temp.v8l_err(format('select cma.revoke_invitation(%L)', (select i.invitation_id from cma.invitations() i where i.email = 'verify-role-agent@example.invalid')));
    select v_txt || format(' | %s by %s; %s by %s', r1.state, r1.revoked_by_name, r2.state, r2.accepted_name) into v_txt
    from cma.invitations() r1, cma.invitations() r2
    where r1.invitation_id = v_id2 and r2.email = 'verify-role-agent@example.invalid';
    v_txt := v_txt || format(' | listed as before %s', ((select count(*) from cma.invitations()) = v_n)::text);
    v_rows := v_rows || array['19', 'B9 revoke: the link stops working, idempotent, accepted refused, rows kept with who and when',
      case when v_txt = 'ok invalid/invalid accepted CMA03 | revoked by admin1; accepted by Role agent | listed as before true'
           and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B10. acceptance: teams and skills as chosen, a team dissolved since left out; the person's rows
    --      audited with the inviter as actor and the label invitation; the role granted by the inviter;
    --      the invitation marked accepted with the person; the login lookup finds the tenant for the id
    select c.token into v_tok2 from cma.create_invitation('verify-full@example.invalid', 'Full person', 'nl', 'supervisor', 'verify-org',
      array['verify-team-a', 'verify-team-b'], '[{"key": "verify-dutch", "level": 3}, {"key": "verify-sales"}]') c;
    perform set_config('role', 'cma_owner', true);
    update cma.team set valid_to = now() where tenant_id = v_t1 and key = 'verify-team-b';
    v_audit := (select count(*) from cma.audit_log where tenant_id = v_t1);
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', '', true);
    perform set_config('app.user_id', '', true);
    select a.* into rr from cma.accept_invitation(v_tok2, 'google', '800000000000000000601', 'Verify-Full@example.invalid') a;
    perform set_config('role', 'cma_owner', true);
    select format('%s | %s %s | teams %s | skills %s | granted by inviter %s | audit actor %s label %s | accepted %s | lookup %s',
                  rr.result, u.display_name, u.email,
                  (select string_agg(t.key, ',' order by t.key) from cma.team_member m join cma.team t on t.tenant_id = m.tenant_id and t.id = m.team_id
                   where m.tenant_id = u.tenant_id and m.user_id = u.id and m.valid_to is null),
                  (select string_agg(s.key || ':' || coalesce(us.level::text, '-'), ',' order by s.key) from cma.user_skill us
                   join cma.skill s on s.tenant_id = us.tenant_id and s.id = us.skill_id where us.tenant_id = u.tenant_id and us.user_id = u.id and us.valid_to is null),
                  (select bool_and(ur.granted_by = v_admin1)::text from cma.user_role ur where ur.tenant_id = u.tenant_id and ur.user_id = u.id),
                  (select string_agg(distinct coalesce(al.actor_user_id = v_admin1, false)::text, ',') from cma.audit_log al
                   where al.tenant_id = v_t1 and al.table_name in ('app_user', 'app_user_external_id', 'user_role', 'team_member', 'user_skill', 'invitation')
                     and (al.new_row ->> 'user_id' = u.id::text or al.new_row ->> 'id' = u.id::text or al.new_row ->> 'accepted_user_id' = u.id::text)),
                  (select string_agg(distinct coalesce(al.actor_label, 'none'), ',') from cma.audit_log al
                   where al.tenant_id = v_t1 and (al.new_row ->> 'user_id' = u.id::text or al.new_row ->> 'id' = u.id::text)),
                  (select (i.accepted_user_id = u.id and i.accepted_at is not null)::text from cma.invitation i where i.tenant_id = v_t1 and i.email = 'verify-full@example.invalid'),
                  (select count(*) from cma.find_tenants_for_identity('google', '800000000000000000601') f where f.tenant_id = v_t1))
      into v_txt
    from cma.app_user u where u.tenant_id = rr.tenant_id and u.id = rr.user_id;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    v_rows := v_rows || array['20', 'B10 acceptance: teams and skills, the audit naming the inviter, the invitation accepted, the login found',
      case when v_txt = 'accepted | Full person verify-full@example.invalid | teams verify-team-a | skills verify-dutch:3,verify-sales:- | granted by inviter true | audit actor true label invitation | accepted true | lookup 1'
           and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B11. expired: the preview and the acceptance say expired, nothing is written, the list says expired
    select c.invitation_id, c.token into v_id3, v_tok3 from cma.create_invitation('verify-expired@example.invalid', 'Expired', 'en', 'agent', 'verify-org') c;
    perform set_config('role', 'cma_owner', true);
    update cma.invitation set created_at = now() - interval '10 days', expires_at = now() - interval '1 second' where id = v_id3;
    v_users := (select count(*) from cma.app_user where tenant_id = v_t1);
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', '', true);
    v_txt := (select p.result || ' ' || p.tenant_name from cma.invitation_preview(v_tok3, 'google', '800000000000000000701', 'verify-expired@example.invalid') p)
             || ' / ' || (select a.result from cma.accept_invitation(v_tok3, 'google', '800000000000000000701', 'verify-expired@example.invalid') a);
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || format(' people +%s', (select count(*) from cma.app_user where tenant_id = v_t1) - v_users);
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    v_txt := v_txt || ' ' || (select i.state from cma.invitations() i where i.invitation_id = v_id3);
    v_rows := v_rows || array['21', 'B11 an expired invitation: preview and acceptance say expired, nothing written',
      case when v_txt = 'expired Verify 0008l one / expired people +0 expired' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B12. wrong account: the preview names the invited address and the acceptance refuses, writing
    --      nothing; the address compared without case
    select c.token into v_tok3 from cma.create_invitation('verify-wrong@example.invalid', 'Wrong', 'en', 'agent', 'verify-org') c;
    perform set_config('role', 'cma_owner', true);
    v_users := (select count(*) from cma.app_user where tenant_id = v_t1);
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', '', true);
    v_txt := (select p.result || ' ' || p.invited_email from cma.invitation_preview(v_tok3, 'google', '800000000000000000801', 'someone.else@example.invalid') p)
             || ' / ' || (select a.result from cma.accept_invitation(v_tok3, 'google', '800000000000000000801', 'someone.else@example.invalid') a);
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || format(' people +%s', (select count(*) from cma.app_user where tenant_id = v_t1) - v_users);
    perform set_config('role', 'cma_app', true);
    v_txt := v_txt || ' | ' || (select a.result from cma.accept_invitation(v_tok3, 'google', '800000000000000000801', 'VERIFY-WRONG@Example.Invalid') a);
    perform set_config('app.tenant_id', v_t1::text, true);
    v_rows := v_rows || array['22', 'B12 wrong account: the invited address shown, the acceptance refused, the address without case',
      case when v_txt = 'wrong_account verify-wrong@example.invalid / wrong_account people +0 | accepted' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B13. reuse: the same link again is already_member for the person it made and invalid for anyone
    --      else, also once that person no longer holds the address; nothing written
    perform set_config('role', 'cma_owner', true);
    v_users := (select count(*) from cma.app_user where tenant_id = v_t1);
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', '', true);
    v_txt := (select a.result from cma.accept_invitation(v_tok3, 'google', '800000000000000000801', 'verify-wrong@example.invalid') a)
             || ' ' || (select a.result from cma.accept_invitation(v_tok3, 'google', '800000000000000000802', 'verify-wrong@example.invalid') a)
             || ' ' || (select p.result from cma.invitation_preview(v_tok3, 'google', '800000000000000000802', 'verify-wrong@example.invalid') p);
    -- the link stays used when the person it made no longer holds the address
    perform set_config('role', 'cma_owner', true);
    update cma.app_user set email = 'verify-wrong-moved@example.invalid' where tenant_id = v_t1 and email = 'verify-wrong@example.invalid';
    perform set_config('role', 'cma_app', true);
    v_txt := v_txt || ' moved ' || (select a.result from cma.accept_invitation(v_tok3, 'google', '800000000000000000803', 'verify-wrong@example.invalid') a);
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || format(' people +%s', (select count(*) from cma.app_user where tenant_id = v_t1) - v_users);
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    v_rows := v_rows || array['23', 'B13 a used link: already_member for its person, invalid for anyone else',
      case when v_txt = 'already_member invalid invalid moved invalid people +0' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B14. a sign-in id already linked in the tenant (the agent's) cannot accept another invitation there
    --      (already_member, nothing written); in another tenant the same id, while it works here, is
    --      other_tenant (two tenants for one sign-in is "no access yet" without a tenant picker), nothing
    --      written; once its person here is inactive, it is free there
    select c.token into v_tok3 from cma.create_invitation('verify-linked@example.invalid', 'Linked', 'en', 'agent', 'verify-org') c;
    perform set_config('role', 'cma_owner', true);
    v_users := (select count(*) from cma.app_user where tenant_id = v_t1);
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', '', true);
    v_txt := (select p.result || ' ' || p.tenant_name from cma.invitation_preview(v_tok3, 'google', '800000000000000000003', 'verify-linked@example.invalid') p)
             || ' / ' || (select a.result || ' ' || (a.tenant_id = v_t1)::text from cma.accept_invitation(v_tok3, 'google', '800000000000000000003', 'verify-linked@example.invalid') a);
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || format(' people +%s', (select count(*) from cma.app_user where tenant_id = v_t1) - v_users);
    v_m := (select count(*) from cma.app_user where tenant_id = v_t2);
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    select c.token into v_tok2 from cma.create_invitation('verify-elsewhere@example.invalid', 'Elsewhere', 'en', 'agent', 'verify-org') c;
    perform set_config('app.tenant_id', '', true);
    perform set_config('app.user_id', '', true);
    v_txt := v_txt || ' | other tenant ' || (select p.result from cma.invitation_preview(v_tok2, 'google', '800000000000000000003', 'verify-elsewhere@example.invalid') p)
             || '/' || (select a.result from cma.accept_invitation(v_tok2, 'google', '800000000000000000003', 'verify-elsewhere@example.invalid') a);
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || format(' people +%s', (select count(*) from cma.app_user where tenant_id = v_t2) - v_m);
    update cma.app_user set status = 'inactive' where id = v_agent1;
    perform set_config('role', 'cma_app', true);
    v_txt := v_txt || ' | inactive here ' || (select a.result || ' ' || (a.tenant_id = v_t2)::text from cma.accept_invitation(v_tok2, 'google', '800000000000000000003', 'verify-elsewhere@example.invalid') a);
    perform set_config('role', 'cma_owner', true);
    update cma.app_user set status = 'active' where id = v_agent1;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    v_rows := v_rows || array['24', 'B14 a sign-in id linked in the tenant is a member; working in another tenant it is refused there',
      case when v_txt = 'already_member Verify 0008l one / already_member true people +0 | other tenant other_tenant/other_tenant people +0 | inactive here accepted true' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B15. another tenant's context: with tenant two set (its admin acting), a tenant-one link creates the
    --      person in tenant one only, and the context is as before afterwards; tenant two's admin cannot
    --      see, renew or revoke tenant one's invitations (CMA02 under row-level security)
    select c.invitation_id, c.token into v_id3, v_tok3 from cma.create_invitation('verify-cross@example.invalid', 'Cross', 'en', 'agent', 'verify-org') c;
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    select a.* into rr from cma.accept_invitation(v_tok3, 'google', '800000000000000000901', 'verify-cross@example.invalid') a;
    v_txt := format('%s in one %s | context %s %s', rr.result, (rr.tenant_id = v_t1)::text,
                    (current_setting('app.tenant_id') = v_t2::text)::text, (current_setting('app.user_id') = v_admin2::text)::text);
    v_txt := v_txt || format(' | two sees %s, renew %s, revoke %s', (select count(*) from cma.invitations() i where i.invitation_id = v_id3),
                             pg_temp.v8l_err(format('select cma.renew_invitation(%L)', v_id)), pg_temp.v8l_err(format('select cma.revoke_invitation(%L)', v_id)));
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || format(' | people in two %s, in one %s', (select count(*) from cma.app_user where tenant_id = v_t2 and email = 'verify-cross@example.invalid'),
                             (select count(*) from cma.app_user where tenant_id = v_t1 and email = 'verify-cross@example.invalid'));
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    v_rows := v_rows || array['25', 'B15 another tenant''s context: the link acts on its own tenant only; RLS hides the other tenant''s rows',
      case when v_txt = 'accepted in one true | context true true | two sees 0, renew CMA02, revoke CMA02 | people in two 0, in one 1' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B16. the hash is out of the application's reach: selecting it is refused, a lookup by it is refused,
    --      and no audit row of an invitation (created, renewed, revoked, accepted) holds it
    v_txt := pg_temp.v8l_err('select token_hash from cma.invitation limit 1')
             || ' ' || pg_temp.v8l_err(format('select id from cma.invitation where token_hash = %L', repeat('a', 64)))
             || ' ' || pg_temp.v8l_err('select * from cma.invitation');
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || format(' | audit rows %s, with a hash %s',
      (select (count(*) > 10)::text from cma.audit_log where tenant_id = v_t1 and table_name = 'invitation'),
      (select count(*) from cma.audit_log where tenant_id in (v_t1, v_t2) and table_name = 'invitation' and (new_row ? 'token_hash' or old_row ? 'token_hash')));
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['26', 'B16 the application cannot read or match the hash; no audit row holds it',
      case when v_txt = '42501 42501 42501 | audit rows true, with a hash 0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B17. the preview changes nothing: an open, a wrong-account and an expired link previewed leave the
    --      invitations and the audit log as they were
    select c.token into v_tok3 from cma.create_invitation('verify-preview@example.invalid', 'Preview', 'en', 'agent', 'verify-org') c;
    perform set_config('role', 'cma_owner', true);
    v_audit := (select count(*) from cma.audit_log where tenant_id = v_t1);
    v_detail := (select md5(string_agg(i::text, '' order by i.id)) from cma.invitation i where i.tenant_id = v_t1);
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', '', true);
    perform set_config('app.user_id', '', true);
    v_txt := (select string_agg(p.result, ',') from (
      select p1.result from cma.invitation_preview(v_tok3, 'google', '800000000000000001001', 'verify-preview@example.invalid') p1
      union all select p2.result from cma.invitation_preview(v_tok3, 'google', '800000000000000001001', 'other@example.invalid') p2
      union all select p3.result from cma.invitation_preview(case when left(v_tok3, 1) = 'x' then 'y' else 'x' end || substr(v_tok3, 2), 'google', '800000000000000001001', 'verify-preview@example.invalid') p3) p);
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || format(' | audit +%s, invitations same %s', (select count(*) from cma.audit_log where tenant_id = v_t1) - v_audit,
                             ((select md5(string_agg(i::text, '' order by i.id)) from cma.invitation i where i.tenant_id = v_t1) = v_detail)::text);
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    v_rows := v_rows || array['27', 'B17 the preview changes nothing',
      case when v_txt = 'open,wrong_account,invalid | audit +0, invitations same true' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B18. checked again at acceptance, each writing nothing: the inviter deactivated (invalid); the
    --      inviter's role lowered below the ceiling (invalid); a person with the address added meanwhile
    --      by Add a person (invalid, and the sign-in id is not linked to that person: no match on an address)
    perform set_config('app.user_id', v_manager1::text, true);
    select c.token into v_tok2 from cma.create_invitation('verify-gone@example.invalid', 'Gone', 'en', 'agent', 'verify-org') c;
    perform set_config('app.user_id', v_admin1::text, true);
    select c.token into v_tok3 from cma.create_invitation('verify-meanwhile@example.invalid', 'Meanwhile', 'en', 'agent', 'verify-org') c;
    select c.token into v_tok4 from cma.create_invitation('verify-demoted@example.invalid', 'Demoted', 'en', 'supervisor', 'verify-org') c;
    perform cma.add_person('verify-meanwhile@example.invalid', 'Meanwhile', 'verify-org', 'agent', 'verifylogin', 'm-1', null);
    perform set_config('role', 'cma_owner', true);
    v_users := (select count(*) from cma.app_user where tenant_id = v_t1);
    update cma.app_user set status = 'inactive' where id = v_manager1;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', '', true);
    perform set_config('app.user_id', '', true);
    v_txt := (select a.result from cma.accept_invitation(v_tok2, 'google', '800000000000000001101', 'verify-gone@example.invalid') a);
    perform set_config('role', 'cma_owner', true);
    update cma.app_user set status = 'active' where id = v_manager1;
    update cma.user_role set role_id = (select id from cma.app_role where tenant_id = v_t1 and key = 'agent') where tenant_id = v_t1 and user_id = v_admin1;
    perform set_config('role', 'cma_app', true);
    v_txt := v_txt || ' ' || (select a.result from cma.accept_invitation(v_tok4, 'google', '800000000000000001102', 'verify-demoted@example.invalid') a);
    perform set_config('role', 'cma_owner', true);
    update cma.user_role set role_id = (select id from cma.app_role where tenant_id = v_t1 and key = 'admin') where tenant_id = v_t1 and user_id = v_admin1;
    perform set_config('role', 'cma_app', true);
    v_txt := v_txt || ' ' || (select a.result from cma.accept_invitation(v_tok3, 'google', '800000000000000001103', 'verify-meanwhile@example.invalid') a);
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || format(' | people +%s, google ids on the meanwhile person %s', (select count(*) from cma.app_user where tenant_id = v_t1) - v_users,
                             (select count(*) from cma.app_user_external_id x join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
                              where u.tenant_id = v_t1 and u.email = 'verify-meanwhile@example.invalid' and x.system = 'google'));
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    v_rows := v_rows || array['28', 'B18 the inviter''s rights and the address checked again at acceptance; no match on an address',
      case when v_txt = 'invalid invalid invalid | people +0, google ids on the meanwhile person 0' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B19. malformed input: a token of another shape is invalid without a lookup; an empty sign-in id, an
    --      id with a space and a system reserved for linked accounts are refused (CMA04)
    perform set_config('app.tenant_id', '', true);
    v_txt := (select a.result from cma.accept_invitation('short', 'google', '800000000000000001201', 'x@example.invalid') a)
             || ' ' || (select a.result from cma.accept_invitation(null, 'google', '800000000000000001201', 'x@example.invalid') a)
             || ' ' || (select p.result from cma.invitation_preview(repeat('a', 44), 'google', '1', 'x@example.invalid') p)
             || ' ' || pg_temp.v8l_err(format('select cma.accept_invitation(%L, %L, %L, %L)', v_tok2, 'google', '', 'verify-gone@example.invalid'))
             || ' ' || pg_temp.v8l_err(format('select cma.accept_invitation(%L, %L, %L, %L)', v_tok2, 'google', '1 2', 'verify-gone@example.invalid'))
             || ' ' || pg_temp.v8l_err(format('select cma.accept_invitation(%L, %L, %L, %L)', v_tok2, 'hubspot_user', '1', 'verify-gone@example.invalid'));
    perform set_config('app.tenant_id', v_t1::text, true);
    v_rows := v_rows || array['29', 'B19 malformed input: another token shape invalid; a bad sign-in system or id refused',
      case when v_txt = 'invalid invalid invalid CMA04 CMA04 CMA04' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['39', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008l (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008l values (39, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008l
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008l where result = 'PASS') = 23
                       and not exists (select 1 from verify_0008l where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008l where result = 'PASS'),
                                        (select count(*) from verify_0008l where result <> 'PASS'))) x
order by ord;
drop function if exists pg_temp.v8l_err(text);
reset role;
