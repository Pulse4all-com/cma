-- Verify CMA migration 0003a (team_people). Run as yourself in Cloud SQL Studio, one block at a
-- time; every block ends in rollback and changes nothing. Your own login has no direct rights on
-- schema cma, so every block first switches role (cma_owner to read, cma_app to act as the app).
--   dev:  blocks A, B, C, D (B to D use the dev seed's mock identities)
--   prod: blocks A and E (E runs as you: replace the email)
-- Studio shows one result per statement: pick the last one in "All results". A block passes when
-- it shows PASS; a refusal that does not happen stops the block with an error starting with FAIL.
-- To provoke: in B demand count(*) >= 1000; in C expect 'CMA01'.
-- Verified 6 October 2026: dev A-D PASS (4 people), prod A and E PASS (2 people).

-- A. The function and the migration row exist ---------------------------------------------------
begin;
set local role cma_owner;
select 'A function and migration row' as check,
       case when to_regprocedure('cma.team_people()') is not null
             and exists (select 1 from cma.schema_migration where version = '0003a')
            then 'PASS' else 'FAIL' end as result;
rollback;

-- B. The test supervisor sees the people of the tenant, Agent Two included (dev) --------------------
begin;
set local role cma_app;
select set_config('app.tenant_id', (select tenant_id::text from cma.find_tenants_for_identity('mock', 'supervisor') limit 1), true);
select set_config('app.user_id', (select user_id::text from cma.app_user_external_id
                                   where tenant_id = cma.current_tenant_id() and system = 'mock' and external_id = 'supervisor'), true);
select 'B supervisor lists the people' as check,
       case when count(*) >= 2
             and bool_or(p.user_id = (select user_id from cma.app_user_external_id
                                      where tenant_id = cma.current_tenant_id() and system = 'mock' and external_id = 'agent-two'))
             and bool_and(u.status = 'active')
            then 'PASS' else 'FAIL' end as result,
       count(*) as people
from cma.team_people() p
join cma.app_user u on u.tenant_id = cma.current_tenant_id() and u.id = p.user_id;
rollback;

-- C. An agent is refused with CMA06 (dev) --------------------------------------------------------
begin;
set local role cma_app;
select set_config('app.tenant_id', (select tenant_id::text from cma.find_tenants_for_identity('mock', 'agent-two') limit 1), true);
select set_config('app.user_id', (select user_id::text from cma.app_user_external_id
                                   where tenant_id = cma.current_tenant_id() and system = 'mock' and external_id = 'agent-two'), true);
do $$
begin
  perform * from cma.team_people();
  raise exception 'FAIL C: an agent could list the people';
exception when sqlstate 'CMA06' then null;
end
$$;
select 'C agent refused with CMA06' as check, 'PASS' as result;
rollback;

-- D. Without an acting user: CMA01 (dev) ---------------------------------------------------------
begin;
set local role cma_app;
select set_config('app.tenant_id', (select tenant_id::text from cma.find_tenants_for_identity('mock', 'supervisor') limit 1), true);
do $$
begin
  perform * from cma.team_people();
  raise exception 'FAIL D: listed people without an acting user';
exception when sqlstate 'CMA01' then null;
end
$$;
select 'D no acting user refused with CMA01' as check, 'PASS' as result;
rollback;

-- E. You see the people of your tenant (prod; replace the email) ----------------------------------
begin;
set local role cma_owner;
select set_config('app.tenant_id', tenant_id::text, true),
       set_config('app.user_id', id::text, true)
from cma.app_user where email = 'martin@pulse4all.com';
set local role cma_app;
select 'E you list the people' as check,
       case when count(*) >= 1 and bool_and(timezone is not null) then 'PASS' else 'FAIL' end as result,
       count(*) as people
from cma.team_people();
rollback;
