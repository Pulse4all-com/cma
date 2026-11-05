-- =============================================================================================
-- 140_live_per_organisation.sql: addition 0008zv, a Live board per contact-center organisation
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics: which organisation is a contact center is tenant configuration
-- (Pulse4all's value is seed 02's: Newco of Pulse4all Subscriptions). Runs unchanged in every database, after
-- 138_flash_totals.sql (0008zu). Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own IAM
-- login: dev first, then 02_seed_pulse4all.sql again (it flags Newco), then 141_verify_live_per_organisation.sql there;
-- then prod in the same order, before the merge: the web of this change reads the column in the identity read of every
-- request (web/src/lib/data/postgres.ts, findPrincipal), so it must exist before that web is deployed. The web of main
-- runs unchanged on it: it reads no new column, and cma_read.organisation only gains one at its end.
--
-- Why (Martin, 5 November 2026; Decision log): the Live board showed every person of the tenant on one board. A tenant
-- can work with more than one contact center (Pulse4all Subscriptions today with Newco, a second one later), and a
-- supervisor watches one contact center's people. The rail's Live group gets one board per organisation flagged as a
-- contact center, labelled with the organisation's name (/live/<organisation key>), showing only that organisation's
-- people; a tenant with no flagged organisation has no Live group. The inbound and missed-call tiles stay tenant-wide
-- until a line maps to an organisation (Open decisions).
--
-- What it changes
--   cma.organisation.is_contact_center   boolean not null default false: the organisation is a contact center whose
--                      people have a Live board of their own. Every existing row reads false until a seed or Studio sets
--                      it; adding a column with a constant default rewrites no row (a catalog change only). The table's
--                      grants, row-level security and audit trigger (cma.setup_tenant_table, 01) cover the column as
--                      they cover the others: cma_app reads and updates its own tenant's rows only, and a change is
--                      audited. No screen writes it yet (configuration by seed or Studio, as the organisations themselves).
--   cma_read.organisation              the readers' view gains is_contact_center at its end (create or replace view
--                      only adds a column at the end; 05 added timezone the same way), so the flag is reachable for
--                      reporting like the organisation's other columns.
-- What it does not change
--   No function, no other table, no row: the flag starts false everywhere; seed 02 sets Newco's.
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
set local lock_timeout = '5s';
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0008zu') then
    raise exception 'addition 0008zu (138_flash_totals.sql) must run before 0008zv';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The flag, then the readers' view with it at its end (05's list, then is_contact_center)
-- ---------------------------------------------------------------------------------------------
-- cma.organisation is a small configuration table (a few rows per tenant), read by the identity read of every request:
-- the ACCESS EXCLUSIVE lock of the add is held until the commit, so only the view, the comment and the record follow it.
alter table cma.organisation add column if not exists is_contact_center boolean not null default false;
comment on column cma.organisation.is_contact_center is
  'The organisation is a contact center: its people get a Live board of their own (/live/<key>, the rail''s Live group, addition 0008zv). Tenant configuration, false by default';

create or replace view cma_read.organisation as
  select id, tenant_id, key, name, status, created_at, updated_at, timezone, is_contact_center
  from cma.organisation
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 2. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008zv', 'Live per contact-center organisation: cma.organisation.is_contact_center (boolean, not null, default false; the organisation''s people get a Live board of their own, /live/<key>, labelled with its name in the rail''s Live group), at the end of cma_read.organisation too; tenant configuration, set by seed 02 for Newco of Pulse4all Subscriptions')
on conflict (version) do nothing;

commit;
reset role;
