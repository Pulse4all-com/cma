-- =============================================================================================
-- 28_my_profile.sql: addition 0005b, my profile (the My account page's read)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database.
-- Rerunnable. Run as your own IAM login, dev first, then prod; then 29_verify_my_profile.sql.
--
--   cma.my_profile()   exactly one row: the acting person's own details as the Workspace holds
--                      them (name, email, employer, time zone, role, whether their time is kept,
--                      current teams, current skills with level). No permission beyond being an
--                      active person of the current tenant: everyone may read their own row and
--                      nobody else's, so the function takes no user id. A system user (the
--                      scheduler) is refused. Runs with the caller's rights; the application only.
--
-- Slice 4(a) of the night build's handover (CMA_handover_Step5_g_night_build.md): My account.
-- Teams and skills follow cma.directory()'s definition exactly (current rows, the team still in
-- force, the skills in dimension and catalog order with the level's name), so the person sees what
-- their manager sees. Ids in other systems (app_user_external_id) are left out on purpose: the
-- sign-in id is stored once and never shown again (the People screen's rule), and the CRM and
-- telephony ids arrive with Sync (Roadmap step 3). Numbered 0005b so the planned migrations keep
-- 0006 to 0009.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;

-- ---------------------------------------------------------------------------------------------
-- 1. My profile
-- ---------------------------------------------------------------------------------------------
create or replace function cma.my_profile()
returns table (
  user_id            uuid,
  email              text,
  display_name       text,
  organisation_key   text,
  organisation_name  text,
  timezone           text,
  role_key           text,          -- null for a person without a role
  role_name          text,
  time_kept          boolean,
  teams              jsonb,         -- [{key, name}] in team order
  skills             jsonb          -- [{dimension, key, name, level, levelName}] as in directory()
)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_user uuid := cma.current_user_id();
begin
  if v_user is null then
    raise exception 'my_profile needs app.user_id, the acting user' using errcode = 'CMA01';
  end if;
  if not exists (select 1 from cma.app_user
                 where tenant_id = cma.current_tenant_id() and id = v_user and status = 'active' and kind = 'person') then
    raise exception 'user % is not an active person of the current tenant', v_user using errcode = 'CMA01';
  end if;
  return query
    select u.id, u.email::text, u.display_name::text,
           o.key::text, coalesce(o.name, '')::text, cma.user_timezone(u.id)::text,
           r.key::text, r.name::text,
           cma.time_is_kept(u.id),
           coalesce((select jsonb_agg(jsonb_build_object('key', t.key, 'name', t.name) order by t.sort_order, t.key)
                     from cma.team_member m
                     join cma.team t on t.tenant_id = m.tenant_id and t.id = m.team_id
                     where m.tenant_id = u.tenant_id and m.user_id = u.id and m.valid_to is null and t.valid_to is null), '[]'::jsonb),
           coalesce((select jsonb_agg(jsonb_build_object('dimension', s.dimension, 'key', s.key, 'name', s.name,
                                                         'level', us.level, 'levelName', l.name)
                                      order by case s.dimension when 'language' then 1 when 'work_type' then 2 else 3 end, s.sort_order, s.key)
                     from cma.user_skill us
                     join cma.skill s on s.tenant_id = us.tenant_id and s.id = us.skill_id
                     left join cma.skill_level l on l.tenant_id = s.tenant_id and l.dimension = s.dimension and l.level = us.level
                     where us.tenant_id = u.tenant_id and us.user_id = u.id and us.valid_to is null), '[]'::jsonb)
    from cma.app_user u
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    left join lateral (
      select ar.key, ar.name
      from cma.user_role ur
      join cma.app_role ar on ar.tenant_id = ur.tenant_id and ar.id = ur.role_id
      where ur.tenant_id = u.tenant_id and ur.user_id = u.id
      order by ur.granted_at, ar.key
      limit 1
    ) r on true
    where u.tenant_id = cma.current_tenant_id() and u.id = v_user;
end
$$;

revoke execute on function cma.my_profile() from public;
grant execute on function cma.my_profile() to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 2. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0005b', 'My profile: cma.my_profile(), the acting person''s own details, role, teams and skills for the My account page')
on conflict (version) do nothing;

reset role;
