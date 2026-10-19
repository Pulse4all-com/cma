-- =============================================================================================
-- 86_journeys.sql: addition 0008v, journeys as placeholders (Campaign monitoring)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 84_first_orders.sql (0008u). Rerunnable, forward-only, in one transaction. Run as your own IAM login,
-- dev first, then prod; then rerun 02_seed_<customer>.sql (the customer's journeys), then
-- 87_verify_journeys.sql (dev).
--
-- Brief N19-A, part 3 (Martin, 18 October 2026; README Decision log): a place for campaign and compliance
-- monitoring that becomes the journey engine of the FCA compliance monitor concept (a population, ordered
-- steps with proof events, due rules, evidence and escalation, all as configuration). This addition holds
-- only the journeys themselves, as named placeholders with their prerequisites: no step, population or
-- per-customer table yet. The model word is journey; campaign is reserved for the queue engine (0011), and
-- "Campaign monitoring" is a screen's copy only. Every journey's code, name, summary, market and
-- prerequisites are configuration: a customer's seed (02 for Pulse4all) or Configuration, never this script.
--
-- What it adds
--   journeys           cma.journey: per tenant a code (^[a-z][a-z0-9-]{1,40}$, unique), a name (1 to 80
--                      characters), a summary (at most 500), a market (catalog, or none), a status
--                      (placeholder, building, live or archived; placeholder by default; never deleted:
--                      archived hides it), a design link (https, or none), the prerequisites (at most 20
--                      lines of 1 to 200 characters, in their order) and a sort order
--   reads              cma.journeys() (reports.view or performance.team): every journey of the tenant but
--                      the archived ones, in their order
--   configuration      cma.set_journey(code, name, summary, market, design_url, prerequisites, sort_order)
--                      adds or changes a journey (its status kept; placeholder for a new one) and
--                      cma.set_journey_status(code, status) (tenant.configure both)
--   reporting view     cma_read.journey
--
-- Everything is SECURITY INVOKER and executable by the application only, and checks its permission again
-- inside. A journey holds no customer data: codes, a name and texts a person configures, a market code and
-- a link.
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid,
-- CMA06 not permitted.
--
-- Guard: scripts run under a personal IAM login so the audit trail names a person. postgres is
-- for emergencies only; to use it deliberately, run first:  set cma.emergency = 'on';
do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;

begin;
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0008u') then
    raise exception 'addition 0008u (84_first_orders.sql) must run before 0008v';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Journeys
-- ---------------------------------------------------------------------------------------------
-- A journey's prerequisites: at most 20 lines, each 1 to 200 characters, none empty or padded
create or replace function cma.is_journey_prerequisites(p_lines text[])
returns boolean
language sql immutable
as $$
  select p_lines is not null and coalesce(array_ndims(p_lines), 1) = 1 and coalesce(cardinality(p_lines), 0) <= 20
     and not exists (select 1 from unnest(p_lines) l where l is null or length(l) not between 1 and 200 or l <> btrim(l))
$$;

create table if not exists cma.journey (
  id             uuid primary key default uuidv7(),
  tenant_id      uuid not null default cma.current_tenant_id() references cma.tenant (id),
  code           text not null check (code ~ '^[a-z][a-z0-9-]{1,40}$'),
  name           text not null check (length(name) between 1 and 80 and name = btrim(name)),
  summary        text check (length(summary) between 1 and 500 and summary = btrim(summary)),
  market         text,
  status         text not null default 'placeholder' check (status in ('placeholder', 'building', 'live', 'archived')),
  design_url     text check (design_url ~ '^https://[^[:space:]]+$' and length(design_url) <= 500),
  prerequisites  text[] not null default '{}' check (cma.is_journey_prerequisites(prerequisites)),
  sort_order     integer not null default 100 check (sort_order between 0 and 10000),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (tenant_id, code),
  unique (tenant_id, id),
  foreign key (tenant_id, market) references cma.market (tenant_id, code)
);
comment on table cma.journey is 'Journeys (Campaign monitoring): placeholders for compliance and campaign monitors. Code, name, summary, market, status, design link and prerequisites as configuration; never deleted, archived hides one';
create or replace trigger set_updated_at before update on cma.journey
  for each row execute function cma.set_updated_at();
select cma.setup_tenant_table('cma.journey');
revoke delete on cma.journey from cma_app;

-- ---------------------------------------------------------------------------------------------
-- 2. The read: every journey but the archived ones (reports.view or performance.team)
-- ---------------------------------------------------------------------------------------------
create or replace function cma.journeys()
returns table (code text, name text, summary text, market text, status text, design_url text, prerequisites text[],
               sort_order integer, updated_at timestamptz)
language plpgsql stable
as $$
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  return query
    select j.code, j.name, j.summary, j.market, j.status, j.design_url, j.prerequisites, j.sort_order, j.updated_at
    from cma.journey j
    where j.tenant_id = cma.current_tenant_id() and j.status <> 'archived'
    order by j.sort_order, j.name, j.code;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. Configuration (tenant.configure)
-- ---------------------------------------------------------------------------------------------
-- Adds a journey (as a placeholder) or changes one: name, summary (null or empty for none), market (a
-- catalog market or null), design link (https, or null or empty for none), prerequisites (null for none)
-- and sort order (null keeps 100 for a new journey, the stored one otherwise). The status is kept.
create or replace function cma.set_journey(p_code text, p_name text, p_summary text, p_market text, p_design_url text,
                                           p_prerequisites text[], p_sort_order integer)
returns void
language plpgsql
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_summary text := nullif(btrim(p_summary), '');
  v_url     text := nullif(btrim(p_design_url), '');
  v_lines   text[] := coalesce(p_prerequisites, '{}');
begin
  perform cma.assert_permission('tenant.configure');
  if p_code is null or p_code !~ '^[a-z][a-z0-9-]{1,40}$' then
    raise exception 'a journey code is 2 to 41 characters: a lower-case letter, then lower-case letters, digits or hyphens'
      using errcode = 'CMA04';
  end if;
  if p_name is null or length(btrim(p_name)) not between 1 and 80 then
    raise exception 'a journey name has 1 to 80 characters' using errcode = 'CMA04';
  end if;
  if v_summary is not null and length(v_summary) > 500 then
    raise exception 'a journey summary has at most 500 characters' using errcode = 'CMA04';
  end if;
  if v_url is not null and (v_url !~ '^https://[^[:space:]]+$' or length(v_url) > 500) then
    raise exception 'a design link is an https address without spaces, at most 500 characters' using errcode = 'CMA04';
  end if;
  if not cma.is_journey_prerequisites(v_lines) then
    raise exception 'a journey has at most 20 prerequisites, each 1 to 200 characters' using errcode = 'CMA04';
  end if;
  if p_sort_order is not null and p_sort_order not between 0 and 10000 then
    raise exception 'a sort order is 0 to 10000' using errcode = 'CMA04';
  end if;
  if p_market is not null then
    perform cma.assert_market(p_market, false);
  end if;
  insert into cma.journey as j (tenant_id, code, name, summary, market, design_url, prerequisites, sort_order)
  values (v_tenant, p_code, btrim(p_name), v_summary, p_market, v_url, v_lines, coalesce(p_sort_order, 100))
  on conflict (tenant_id, code) do update
    set name = excluded.name, summary = excluded.summary, market = excluded.market, design_url = excluded.design_url,
        prerequisites = excluded.prerequisites, sort_order = coalesce(p_sort_order, j.sort_order);
exception when check_violation or not_null_violation then
  raise exception 'invalid journey: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- A journey's status: placeholder, building, live or archived (archived hides it; nothing is deleted)
create or replace function cma.set_journey_status(p_code text, p_status text)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  if p_status is null or p_status not in ('placeholder', 'building', 'live', 'archived') then
    raise exception 'a journey''s status is placeholder, building, live or archived' using errcode = 'CMA04';
  end if;
  update cma.journey j set status = p_status
  where j.tenant_id = cma.current_tenant_id() and j.code = p_code;
  if not found then
    raise exception 'no journey % in the current tenant', p_code using errcode = 'CMA02';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.is_journey_prerequisites(text[])',
    'cma.journeys()',
    'cma.set_journey(text,text,text,text,text,text[],integer)',
    'cma.set_journey_status(text,text)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Reporting view
-- ---------------------------------------------------------------------------------------------
create or replace view cma_read.journey as
  select id, tenant_id, code, name, summary, market, status, design_url, prerequisites, sort_order, created_at, updated_at
  from cma.journey
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 6. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008v', 'Journeys (Campaign monitoring): placeholders with code, name, summary, market, status (placeholder, building, live, archived; never deleted), design link, prerequisites and sort order as configuration; the read cma.journeys() without the archived ones, cma.set_journey and cma.set_journey_status, the reporting view')
on conflict (version) do nothing;

commit;
reset role;
