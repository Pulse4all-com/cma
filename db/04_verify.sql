-- CMA verify for migration 0001
-- Run as yourself (IAM login), no SET ROLE, after 00 to 03. Run the blocks A to H one at a time;
-- blocks F, G and H each end in an expected error. Keep the output as the release record.
-- Block A is universal (structure). Blocks B to H use the Pulse4all seed and the dev test data;
-- in prod, where 03 is not run, B shows the tenants' user counts and D's lines that list people
-- run in dev only: the flag verify.is_dev (set below, as the dev-only verifies set it: true where the
-- dev seed's active agent.two@example.com exists, which prod never holds) guards them, and in prod D
-- prints one line saying they were skipped (the flag is set once per session by the statement after the
-- postgres guard; a block run on its own without it reads as not dev). B's audit summary prints <you>, <another login> or the role
-- name for the actor, never the login itself (Decision log, 9 Nov 2026, verify output from prod).

-- Guard: scripts run under a personal IAM login so the audit trail names a person. postgres is
-- for emergencies only; to use it deliberately, run first:  set cma.emergency = 'on';
do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;

-- Dev only for the people lines of block D: the dev seed's active test person (db/03) exists in dev, never in prod
set role cma_owner;
select set_config('verify.is_dev', (exists (select 1 from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                            where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false) as is_dev;
reset role;

-- A. Roles, ownership, RLS, policies, audit triggers, reader access ------------------------------------
select rolname, rolcanlogin
from pg_roles
where rolname like 'cma\_%' or rolname = 'bq_reader'
order by 1;
-- expect: bq_reader (login), cma_app, cma_owner, cma_readonly (no login)

select c.relname, pg_get_userbyid(c.relowner) as owner, c.relrowsecurity as rls_on
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'cma' and c.relkind = 'r'
order by 1;
-- expect: owner cma_owner on every table; rls_on true everywhere except permission, schema_migration, tenant

select tablename, policyname, roles, cmd
from pg_policies
where schemaname = 'cma'
order by 1, 2;
-- expect: one policy tenant_app (ALL, cma_app) on the seven tenant-scoped tables and on audit_log; nothing for readers

select tgrelid::regclass as table_name
from pg_trigger
where tgname = 'audit' and not tgisinternal
order by 1;
-- expect: the seven tenant-scoped tables (not audit_log, not the catalogs)

select table_name
from information_schema.views
where table_schema = 'cma_read'
order by 1;
-- expect: 10 views: app_role, app_user, app_user_external_id, audit_log, channel, organisation,
--         permission, role_permission, tenant, user_role

select has_schema_privilege('cma_readonly', 'cma',      'usage') as reader_on_base_tables,   -- false
       has_schema_privilege('cma_readonly', 'cma_read', 'usage') as reader_on_views,         -- true
       has_schema_privilege('cma_app',      'cma_read', 'usage') as app_on_views,            -- false
       pg_has_role('bq_reader', 'cma_readonly', 'member')       as bq_reader_is_reader;      -- true

-- B. As yourself: the reader view, all tenants, seed history ----------------------------------------------
select t.slug, count(u.id) as users
from cma_read.tenant t
left join cma_read.app_user u on u.tenant_id = t.id
group by t.slug
order by 1;
-- expect: pulse4all-invest 1, pulse4all-subscriptions 4

select table_name, action, count(*) as changes,
       case when min(actor_login) = session_user then '<you>' when min(actor_login) like '%@%' then '<another login>'
            else min(actor_login) end as actor_login,
       bool_and(actor_user_id is null and actor_label is null) as system_actor
from cma_read.audit_log
group by 1, 2
order by 1, 2;
-- expect: inserts only, from the seed: app_role 8, app_user 5, app_user_external_id 2, channel 4,
--         organisation 4, role_permission 62, user_role 5; actor_login <you> (your IAM login, never shown);
--         system_actor true (no app.user_id or app.actor_label was set)

-- C. As yourself with a tenant setting: a reader limited to one tenant --------------------------------------
begin;
select set_config('app.tenant_id',
                  (select id::text from cma_read.tenant where slug = 'pulse4all-invest'),
                  true);
select slug from cma_read.tenant;                       -- expect: pulse4all-invest only
select count(*) as invest_users from cma_read.app_user; -- expect: 1
rollback;

-- D. As the application with tenant, user and label set: one tenant, audited writes ----------------------
begin;
set local role cma_app;
select set_config('app.tenant_id',
                  (select id::text from cma.tenant where slug = 'pulse4all-subscriptions'),
                  true);
-- second statement on purpose: app_user is only visible once the tenant is set
select set_config('app.user_id',
                  (select id::text from cma.app_user where email = 'manager@example.com'),
                  true);
select set_config('app.actor_label', 'verify-script', true);

select email, display_name
from cma.app_user
where coalesce(current_setting('verify.is_dev', true), 'false')::boolean
union all
select 'block D skipped: not the dev database (no dev seed)', null where not coalesce(current_setting('verify.is_dev', true), 'false')::boolean
order by 1;
-- expect: 4 rows, all Subscriptions; the Invest "agent.one" is not visible. In prod: the one line "block D skipped",
--         and the people lines below answer no rows

select o.key as organisation, count(u.id) as users
from cma.organisation o
left join cma.app_user u on u.tenant_id = o.tenant_id and u.organisation_id = o.id
group by o.key
order by 1;
-- expect: newco 3, pulse4all 1 (clubdeal belongs to the other tenant and is not visible)

select key, is_synchronous from cma.channel order by 1;
-- expect: email false, phone true

select u.email, r.key as role, ur.scope_type
from cma.user_role ur
join cma.app_user u on u.tenant_id = ur.tenant_id and u.id = ur.user_id
join cma.app_role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
where coalesce(current_setting('verify.is_dev', true), 'false')::boolean
order by 1;
-- expect: 4 rows, scope_type NULL (whole tenant)

select r.key as role, count(rp.permission_key) as permissions
from cma.app_role r
left join cma.role_permission rp on rp.tenant_id = r.tenant_id and rp.role_id = r.id
group by r.key
order by 1;
-- expect: agent 4, analytics 4, manager 15, supervisor 8

-- a write as the application, then its audit row
update cma.app_user set display_name = 'Agent One (renamed)' where email = 'agent.one@example.com';

select table_name, action, actor_db_role, actor_label,
       actor_user_id = cma.current_user_id() as actor_is_manager,
       old_row ->> 'display_name' as before, new_row ->> 'display_name' as after
from cma.audit_log
where coalesce(current_setting('verify.is_dev', true), 'false')::boolean
order by changed_at desc
limit 1;
-- expect: app_user, update, cma_app, verify-script, true, Agent One, Agent One (renamed)
rollback;   -- the rename and its audit row are discarded

-- E. As the application with no tenant set: nothing (fail closed) ------------------------------------
begin;
set local role cma_app;
select count(*) as should_be_zero from cma.app_user;
select count(*) as should_be_zero from cma.audit_log;
rollback;

-- F. As the application, writing into another tenant: rejected -----------------------------------------
-- Expected result is an error:
--   new row violates row-level security policy for table "app_user"
-- If Studio stops at the error and leaves the transaction open, run "rollback;" on its own afterwards.
begin;
set local role cma_app;
select set_config('app.tenant_id',
                  (select id::text from cma.tenant where slug = 'pulse4all-subscriptions'),
                  true);
insert into cma.app_user (tenant_id, email, display_name)
values ((select id from cma.tenant where slug = 'pulse4all-invest'), 'intruder@example.com', 'Should fail');
rollback;

-- G. As the application, changing history: rejected ----------------------------------------------------
--   permission denied for table audit_log
begin;
set local role cma_app;
select set_config('app.tenant_id',
                  (select id::text from cma.tenant where slug = 'pulse4all-subscriptions'),
                  true);
delete from cma.audit_log;
rollback;

-- H. As yourself (reader), touching a base table: rejected --------------------------------------------
--   permission denied for schema cma
select count(*) from cma.app_user;
