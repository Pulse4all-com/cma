-- CMA migration 0003a: team people
-- Run as yourself (IAM login), after 09. Safe to rerun. Universal: no customer, tenant or vendor
-- specifics; runs unchanged in every customer database.
--
-- Adds (README: Data model: corrections; Roadmap step 2, increment c2)
--   cma.team_people()  the people whose time is kept (active, holding workday.own), with employer
--                      and zone, for people holding workday.team. The Hours screen needs it for
--                      Add day and the person filter: team_hours only knows people who have a day,
--                      and Add day exists for someone who never clocked in.
--
-- Numbered 0003a so the planned migrations keep 0004 to 0009. Tenant-wide until teams exist
-- (migration 0004); then scoped to the grant, like team_hours.

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;

set role cma_owner;

create or replace function cma.team_people()
returns table (
  user_id           uuid,
  display_name      text,
  organisation_name text,
  timezone          text
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('workday.team');
  return query
    select u.id, u.display_name::text, coalesce(o.name, '')::text, cma.user_timezone(u.id)::text
    from cma.app_user u
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    where u.tenant_id = cma.current_tenant_id()
      and u.status = 'active'
      and cma.has_permission(u.id, 'workday.own')
    order by u.display_name, u.id;
end
$$;

insert into cma.schema_migration (version, description)
values ('0003a', 'Team people: team_people for Add day and the person filter')
on conflict (version) do nothing;

reset role;
