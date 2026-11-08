-- =============================================================================================
-- 160_installed_base_now.sql: addition 0009f, Assets → Installed base as the "now" view: the list's own filters, one rule
-- for a field device without a subscription reference, and the current takes forgotten on a catalog change
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics: which filters a list takes is the overviews' catalog
-- (cma.flash_list_filters_of), the device statuses are the tenant's catalog (a status such as In transit is a Studio
-- insert for the tenant, never a row of this script), and which catalogs a take reads is read from the computation.
-- Runs unchanged in every database, after 158_flash_current_take.sql (0009e). Rerunnable, forward-only, in one
-- transaction with a lock timeout. Run as your own IAM login: dev first, then 161_verify_installed_base_now.sql there,
-- then the verifies that read what this remakes (below); then the merge; then prod in the same order right after the
-- merge. main's web runs unchanged on it (every function keeps its name, arguments and answers for every call main makes;
-- two filters are added, which main never sends). This branch's web on a database without it: the records and the
-- breakdowns work; the serial search and the list without a subscription reference read "not available" (CMA04). No
-- table, view, column or setting changes: the data map's schema does not change.
--
-- Why (Martin, 8 November 2026; brief 0009f; Decision log, 8 Nov 2026, D1 to D9): Assets → Installed base becomes a
-- "now" view of its own that loads the stored current take's figures alone (the filters, the tiles, the model split as a
-- donut, In the field per market stacked per model) and reads its records, breakdowns, work lists and serial search on
-- demand, one panel at a time, as address state. Every load sent about 2.84 MB of HTML before (500 records and about
-- 1,700 breakdown filter links, #250). The database gives the page what the rows read could not express:
--   serial                   the serial search (D7): an exact match on the serial, trimmed and case-insensitive, within
--                            the tenant and the person's permissions; every device with it (a duplicate serial is a
--                            data-quality finding). It runs through the records read (cma.flash_rows_of over
--                            cma.flash_devices_of), so it costs a records page, not an index lookup: the per-device due
--                            items (cma.maintenance_items_of) are computed for the tenant as a whole, so an index on
--                            lower(serial) would not shorten it. No index is added
--   without_subscription_ref the list "In the field without a linked subscription" (D6): the devices the data-quality
--                            check field_device_without_subscription_ref finds, by the same rule in one implementation,
--                            cma.field_devices_without_subscription_ref_of, which cma.data_quality_of now reads too
--   the past-due list (D6)   needs nothing new: measure components_past_due already lists the devices with past_due_items
--                            above 0 (a count of devices, which differs from the Items past due tile, a count of items)
--   D9                       a tenant's current takes are forgotten when a catalog their figures read changes, as a
--                            setting change forgets them (0009e, cma.flash_current_forget): triggers on the catalogs the
--                            computations of the take-able overviews read (section 5), with the same SECURITY DEFINER
--                            function, firing on an insert or delete, and on an update only when a column the take
--                            reads changes (a sync that rewrites a catalog row unchanged forgets nothing)
--   In transit (D8)          a device status, so the register's first In transit device maps without a gap: the catalog
--                            has no write path of its own, so it is a Studio step of the PR for cma-dev-pg and
--                            cma-prod-pg (the tenant's row, never this script's); the trigger of D9 then forgets the
--                            tenant's takes and the next refresh counts under the new catalog
--
-- What it changes (functions and triggers only)
--   cma.flash_list_filters_of(overview)                 new: the filter keys a list takes beside the overview's dims and
--                                                        measure: serial and without_subscription_ref for installed_base,
--                                                        none else (the web mirrors it; verify:flash compares the two)
--   cma.field_devices_without_subscription_ref_of(tenant) new: the one rule: a device the register still holds, in a
--                                                        status flagged in the field, without a subscription reference
--   cma.data_quality_of                                  based on 136: that check reads the rule's function; every other
--                                                        check as before
--   cma.flash_rows_of                                    based on 148: the installed base's two filters; JIT off again
--   cma.flash_rows, cma.flash_file_record                based on 148 and 122: the list's own filters pass their checks
--                                                        (without_subscription_ref takes "true" alone; CMA04 else)
--   triggers forget_flash_current_takes (insert, delete) and forget_flash_current_takes_change (an update of a read column
--     that changes it) on cma.device_status, cma.device_component_kind, cma.maintenance_rule, cma.connection_pipeline,
--     cma.connection_stage, cma.connection_task_status and cma.connection_task_type (section 5)
-- Verifies that read what this remakes, rerun after it (grep -lw over db/*verify*.sql for cma.flash_rows_of,
-- cma.flash_rows, cma.flash_file_record and cma.data_quality_of, and for the functions that call them:
-- cma.refresh_data_quality_of, cma.data_quality_snapshot_of, cma.data_quality(), cma.data_quality_rows): 41, 69, 73, 75,
-- 101, 105, 113, 117, 123, 133, 137, 139 and 149; their answers are as before (161 compares the remade functions with
-- their previous definitions). 159 is edited by this addition (its D1 and A3 read both documents in one statement, so one
-- snapshot) and is rerun too.
--
-- SQLSTATEs as before: CMA04 invalid, CMA06 not permitted.
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
  if not exists (select 1 from cma.schema_migration where version = '0009e') then
    raise exception 'addition 0009e (158_flash_current_take.sql) must run before 0009f';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The list's own filters, and the one rule for a field device without a subscription reference
-- ---------------------------------------------------------------------------------------------
-- The filter keys a list takes beside its overview's dims and measure (cma.flash_rows, cma.flash_file_record): the
-- installed base's serial (an exact match, trimmed and case-insensitive) and without_subscription_ref ("true": the devices
-- of the data-quality check field_device_without_subscription_ref); none for another overview. The web's
-- FLASH_LIST_FILTERS mirrors it
create or replace function cma.flash_list_filters_of(p_overview text)
returns text[]
language sql immutable
as $$
  select case when p_overview = 'installed_base' then array['serial', 'without_subscription_ref'] else '{}'::text[] end
$$;

-- A device in the field without a subscription reference: the register still holds it (no source_deleted_at), its device
-- status is flagged in the field, and it carries no subscription reference. The data-quality check
-- field_device_without_subscription_ref and the Installed base's list "In the field without a linked subscription" both
-- read this function, so the two always agree (D6; 161 proves it)
create or replace function cma.field_devices_without_subscription_ref_of(p_tenant_id uuid)
returns table (device_id uuid, connection_id uuid, source_id text)
language sql stable
as $$
  select dv.id, dv.connection_id, dv.source_id
  from cma.device dv
  join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_in_field
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.subscription_ref is null
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. Data quality: the check from the rule's function
-- ---------------------------------------------------------------------------------------------
-- As 0008zt (136), word for word but for field_device_without_subscription_ref, which reads
-- cma.field_devices_without_subscription_ref_of (the same rows: the same rule, 161 compares every check with 136's
-- definition). The stored results (0008zr) take it at the next refresh, unchanged in what they hold
-- based on: 136_flash_insights.sql
create or replace function cma.data_quality_of(p_tenant_id uuid)
returns table (check_key text, connection_id uuid, object_type text, object_id text, value text)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_start timestamptz;
begin
  select cma.setting_of(t.id, 'intake.start_date')::date::timestamp at time zone t.timezone into v_start
  from cma.tenant t where t.id = p_tenant_id;

  return query
  -- lead deals without any contact
  select 'deal_without_contact'::text, d.connection_id, d.record_type, d.source_id, null::text
  from cma.lead_deals_of(p_tenant_id, null, null) d
  where cardinality(d.contacts) = 0
  union all
  -- primary contacts of lead deals without country or language
  select 'deal_contact_incomplete', k.connection_id, 'contact', k.source_id, null
  from cma.crm_contact k
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
    and (k.country is null or k.language is null)
    and exists (select 1 from cma.lead_deals_of(p_tenant_id, null, null) d
                where d.connection_id = k.connection_id and d.contact_source_id = k.source_id)
  union all
  -- markets and countries written by a source that are no catalog market
  select 'market_not_in_catalog', cr.connection_id, cr.record_type, cr.source_id, cr.market
  from cma.crm_record cr
  where cr.tenant_id = p_tenant_id and cr.source_deleted_at is null and cr.source_created_at >= v_start
    and nullif(btrim(cr.market), '') is not null and cma.market_code_of(p_tenant_id, cr.market) is null
  union all
  select 'market_not_in_catalog', k.connection_id, 'contact', k.source_id, k.country
  from cma.crm_contact k
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
    and nullif(btrim(k.country), '') is not null and cma.market_code_of(p_tenant_id, k.country) is null
  union all
  -- CRM owners (of records since the start and of calls since the start) without a person
  select 'owner_without_person', o.connection_id, 'owner', o.owner_ref, null
  from (select cr.connection_id, cr.source_system, cr.owner_ref
        from cma.crm_record cr
        where cr.tenant_id = p_tenant_id and cr.source_deleted_at is null and cr.source_created_at >= v_start
          and cr.owner_ref is not null
        union
        select c.connection_id, c.source_system, c.owner_ref
        from cma.crm_call c
        where c.tenant_id = p_tenant_id and c.source_deleted_at is null and c.occurred_at >= v_start
          and c.owner_ref is not null) o
  where not exists (select 1 from cma.app_user_external_id x
                    where x.tenant_id = p_tenant_id and x.system = o.source_system || '_owner' and x.external_id = o.owner_ref)
  union all
  -- telephony users without a person
  select 'telephony_user_without_person', u.connection_id, 'telephony_user', u.user_ref, null
  from (select distinct tc.connection_id, tc.source_system, tc.user_ref
        from cma.telephony_call tc
        where tc.tenant_id = p_tenant_id and tc.source_deleted_at is null and tc.started_at >= v_start
          and tc.user_ref is not null) u
  where not exists (select 1 from cma.app_user_external_id x
                    where x.tenant_id = p_tenant_id and x.system = u.source_system || '_user' and x.external_id = u.user_ref)
  union all
  -- CRM calls without a current contact association
  select 'crm_call_without_contact', c.connection_id, 'crm_call', c.source_id, null
  from cma.crm_call c
  where c.tenant_id = p_tenant_id and c.source_deleted_at is null and c.occurred_at >= v_start
    and not exists (select 1 from cma.crm_association a
                    where a.tenant_id = c.tenant_id and a.connection_id = c.connection_id and a.from_type = 'crm_call'
                      and a.from_id = c.source_id and a.to_type = 'contact' and a.removed_at is null)
  union all
  -- telephony calls older than 24 hours without a current link, once the tenant has CRM calls; an
  -- outbound call not connected (no answer) and without a current tag is skipped when the connection says so
  -- (dq_unlinked_skip = outbound_unanswered_untagged, the default for a telephony connection; 0008o; 0008zc)
  select 'telephony_call_unlinked', tc.connection_id, 'telephony_call', tc.source_id, null
  from cma.telephony_call tc
  join cma.integration_connection ic on ic.tenant_id = tc.tenant_id and ic.id = tc.connection_id
  where tc.tenant_id = p_tenant_id and tc.source_deleted_at is null
    and tc.started_at >= v_start and tc.started_at < now() - interval '24 hours'
    and exists (select 1 from cma.crm_call c where c.tenant_id = p_tenant_id and c.source_deleted_at is null)
    and not exists (select 1 from cma.call_link l
                    where l.tenant_id = tc.tenant_id and l.telephony_call_id = tc.id and l.unlinked_at is null)
    and not (coalesce(ic.settings ->> 'dq_unlinked_skip', case when ic.kind = 'telephony' then 'outbound_unanswered_untagged' end) = 'outbound_unanswered_untagged'
             and tc.direction = 'outbound'
             and tc.answered_at is null
             and not exists (select 1 from cma.telephony_call_tag g
                             where g.tenant_id = tc.tenant_id and g.connection_id = tc.connection_id
                               and g.call_source_id = tc.source_id and g.untagged_at is null))
  union all
  -- commerce customers whose id no contact holds, or several contacts hold
  -- (since 0008zn the contacts per id counted once by a join, no read per customer; the same rows)
  select case when coalesce(h.contacts, 0) = 0 then 'commerce_unmatched' else 'commerce_ambiguous' end,
         cu.connection_id, 'commerce_customer', cu.source_id, null
  from cma.commerce_customer cu
  left join (select r.system, r.external_id, count(distinct r.contact_id) as contacts
             from cma.crm_contact_ref r where r.tenant_id = p_tenant_id group by 1, 2) h
    on h.system = cu.source_system and h.external_id = cu.source_id
  where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null and coalesce(h.contacts, 0) <> 1
  union all
  -- contacts with both first slots of a ref system taken
  select 'contact_slots_full', k.connection_id, 'contact', k.source_id, r.system
  from cma.crm_contact k
  join cma.crm_contact_ref r on r.tenant_id = k.tenant_id and r.contact_id = k.id and r.slot in (1, 2)
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
  group by k.connection_id, k.source_id, r.system
  having count(distinct r.slot) = 2
  union all
  -- contacts whose country differs from the market of a store their commerce id belongs to
  select distinct 'contact_country_differs', k.connection_id, 'contact', k.source_id,
         cma.market_code_of(p_tenant_id, k.country) || '/' || st.market
  from cma.crm_contact k
  join cma.crm_contact_ref r on r.tenant_id = k.tenant_id and r.contact_id = k.id
  join cma.commerce_customer cu
    on cu.tenant_id = r.tenant_id and cu.source_system = r.system and cu.source_id = r.external_id and cu.source_deleted_at is null
  join cma.commerce_store st on st.tenant_id = cu.tenant_id and st.connection_id = cu.connection_id
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
    and cma.market_code_of(p_tenant_id, k.country) is distinct from st.market
    and nullif(btrim(k.country), '') is not null
  union all
  -- one commerce customer id in two or more stores
  select 'customer_in_two_stores', null::uuid, 'commerce_customer', cu.source_id, cu.source_system
  from cma.commerce_customer cu
  where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null
  group by cu.source_system, cu.source_id
  having count(distinct cu.connection_id) > 1
  union all
  -- active pipelines no person has ever written (only the source's refresh)
  select 'pipeline_unreviewed', p.connection_id, 'pipeline', p.source_pipeline_id, p.record_type
  from cma.connection_pipeline p
  where p.tenant_id = p_tenant_id and p.status = 'active'
    and not exists (select 1 from cma.audit_log al
                    join cma.app_user u on u.tenant_id = al.tenant_id and u.id = al.actor_user_id and u.kind = 'person'
                    where al.tenant_id = p.tenant_id and al.table_name = 'connection_pipeline' and al.row_id = p.id::text)
  union all
  -- counted active forms without a market
  select 'form_without_market', f.connection_id, 'form', f.source_form_id, null
  from cma.connection_form f
  where f.tenant_id = p_tenant_id and f.status = 'active' and f.is_counted and f.market is null
  union all
  -- held contacts whose country came from a fallback slot (0008m)
  select 'contact_country_fallback', k.connection_id, 'contact', k.source_id, k.country_source::text
  from cma.crm_contact k
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null and k.country_source > 1
  union all
  -- open tickets without an owner, and without a market, per pipeline, once ticket SLAs are configured (0008o)
  select 'ticket_no_owner', t.connection_id, 'ticket', t.ticket_source_id, t.pipeline_id
  from cma.open_tickets_of(p_tenant_id) t
  where t.owner_ref is null and cma.follow_up_configured_of(p_tenant_id)
  union all
  select 'ticket_no_market', t.connection_id, 'ticket', t.ticket_source_id, t.pipeline_id
  from cma.open_tickets_of(p_tenant_id) t
  where t.market = 'unknown' and cma.follow_up_configured_of(p_tenant_id)
  union all
  -- open tasks whose owner is not linked to a person (0008o)
  select 'crm_task_owner_unlinked', k.connection_id, 'task', k.task_source_id, k.owner_ref
  from cma.open_tasks_of(p_tenant_id) k
  where k.owner_ref is not null and k.owner_user_id is null
  union all
  -- kept form answers no option of their field accounts for, current or retired (0008p): one row per
  -- submission and field of a form the source has described, the field's name as the code
  select 'form_answer_not_in_options', fs.connection_id, 'form_submission', fs.source_id, e.key
  from cma.form_submission fs
  join cma.connection_form f
    on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
   and f.fields_refreshed_at is not null
  cross join lateral jsonb_each(fs.kept_values) e
  left join cma.connection_form_field ff
    on ff.tenant_id = fs.tenant_id and ff.connection_id = fs.connection_id and ff.source_form_id = fs.source_form_id
   and ff.name = e.key
  where fs.tenant_id = p_tenant_id and fs.kept_values <> '{}'::jsonb
    and (ff.name is null or not cma.form_choice_kind(ff.kind)
         or exists (select 1
                    from (select e.value #>> '{}' as v where jsonb_typeof(e.value) = 'string'
                          union all
                          select x from jsonb_array_elements_text(case when jsonb_typeof(e.value) = 'array' then e.value
                                                                       else '[]'::jsonb end) x) a
                    where not (a.v = any (ff.options || ff.retired_options))))
  union all
  -- review channels the source holds without a market (0008ze), with how many reviews the CMA holds of each
  select 'review_channel_unmapped', ch.connection_id, 'review_channel', ch.source_id,
         (select count(*) from cma.review r where r.tenant_id = ch.tenant_id and r.review_channel_id = ch.id)::text
  from cma.review_channel ch
  where ch.tenant_id = p_tenant_id and ch.source_deleted_at is null and ch.market is null
  union all
  -- active markets without a counted review channel, once the tenant has a reviews connection (0008ze)
  select 'market_without_review_channel', null::uuid, 'market', m.code, null::text
  from cma.market m
  where m.tenant_id = p_tenant_id and m.status = 'active' and cma.reviews_set_up_of(p_tenant_id)
    and not exists (select 1 from cma.review_channel ch
                    where ch.tenant_id = m.tenant_id and ch.market = m.code and ch.is_counted and ch.source_deleted_at is null)
  union all
  -- devices without a serial number (0008zi), of devices the register still holds
  select 'device_serial_missing', dv.connection_id, 'device', dv.source_id, null::text
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.serial is null
  union all
  -- devices whose serial number another device of the tenant holds too (0008zi); the value is the serial
  select 'device_serial_duplicate', dv.connection_id, 'device', dv.source_id, dv.serial
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.serial is not null
    and exists (select 1 from cma.device o
                where o.tenant_id = dv.tenant_id and o.serial = dv.serial and o.id <> dv.id and o.source_deleted_at is null)
  union all
  -- devices whose model, status or country maps to no catalog row (0008zi); the value is the register's label
  select 'device_model_unmapped', dv.connection_id, 'device', dv.source_id, dv.raw ->> 'model'
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.model_key is null
  union all
  select 'device_status_unmapped', dv.connection_id, 'device', dv.source_id, dv.raw ->> 'status'
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.device_status_key is null
  union all
  select 'device_market_unmapped', dv.connection_id, 'device', dv.source_id, dv.raw ->> 'country'
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.market is null
  union all
  -- devices whose register customer reference is no id (0008zi): the reference is never stored, so no value
  select 'device_customer_ref_invalid', dv.connection_id, 'device', dv.source_id, null::text
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.customer_ref_invalid
  union all
  -- due items of tracked devices without a due date (basis unknown, 0008zi); the value is the component kind
  select 'component_due_unknown', i.connection_id, 'device', i.source_id, i.component_key
  from cma.maintenance_items_of(p_tenant_id, cma.tenant_today_of(p_tenant_id)) i
  where i.basis = 'unknown'
  union all
  -- devices in a status in the field without a subscription reference (0008zi): the rule's one implementation, which
  -- the Installed base's list reads too (0009f)
  select 'field_device_without_subscription_ref', u.connection_id, 'device', u.source_id, null::text
  from cma.field_devices_without_subscription_ref_of(p_tenant_id) u
  union all
  -- store customers with an order linked to a CRM contact that lacks a reference of commerce.required_contact_refs in
  -- every slot (0008zn); the value the references missing, comma-separated; contact_deleted when the CRM deleted the
  -- contact the link names (fixed in the CRM: the link or the contact); contact_not_held while the CMA does not hold the
  -- contact (its references are unknown until the contact is read)
  select 'customer_required_ref_missing', cu.connection_id, 'commerce_customer', cu.source_id,
         case when k.id is null then 'contact_not_held'
              when k.source_deleted_at is not null then 'contact_deleted'
              else array_to_string(array(select x from unnest(rq.refs) x
                                         where not exists (select 1 from cma.crm_contact_ref cr
                                                           where cr.tenant_id = k.tenant_id and cr.contact_id = k.id and cr.system = x)), ',') end
  from cma.commerce_customer cu
  cross join (select cma.flash_list_of(cma.setting_of(p_tenant_id, 'commerce.required_contact_refs')) as refs offset 0) rq
  left join cma.crm_contact k
    on k.tenant_id = cu.tenant_id and k.connection_id = cu.crm_connection_id and k.source_id = cu.crm_contact_source_id
  where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null and cu.crm_contact_source_id is not null
    and coalesce(cu.orders_count, 0) >= 1 and cardinality(rq.refs) > 0
    and (k.id is null or k.source_deleted_at is not null
         or exists (select 1 from unnest(rq.refs) x
                    where not exists (select 1 from cma.crm_contact_ref cr
                                      where cr.tenant_id = k.tenant_id and cr.contact_id = k.id and cr.system = x)))
  union all
  -- devices the register still holds lacking a named id of assets.required_refs (0008zn); the value the ids missing
  select 'device_required_ref_missing', dv.connection_id, 'device', dv.source_id,
         array_to_string(array(select x from unnest(rq.refs) x where not (dv.external_refs ? x)), ',')
  from cma.device dv
  cross join (select cma.flash_list_of(cma.setting_of(p_tenant_id, 'assets.required_refs')) as refs offset 0) rq
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and cardinality(rq.refs) > 0
    and exists (select 1 from unnest(rq.refs) x where not (dv.external_refs ? x))
  union all
  -- subscriptions the latest full read still returns whose customer id no customer of their store holds (0008zn)
  select 'subscription_customer_unmatched', sb.connection_id, 'subscription', sb.source_id, null::text
  from cma.subscription sb
  -- the mapping fenced (offset 0): inlined, the planner guesses its few rows wrong and probes the customers per row
  join (select x.connection_id, x.store_connection_id from cma.flash_subscription_stores_of(p_tenant_id) x offset 0) sm
    on sm.connection_id = sb.connection_id
  left join (select cu.connection_id, cu.source_id from cma.commerce_customer cu
             where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null) cu
    on cu.connection_id = sm.store_connection_id and cu.source_id = sb.customer_source_id
  where sb.tenant_id = p_tenant_id and sb.source_deleted_at is null and sb.customer_source_id is not null and cu.source_id is null
  union all
  -- subscriptions in a device-holding status (flash.device_holding_statuses since 0008zt; the key keeps 0008zn's word) of
  -- a store whose market the register holds devices of, that no device of that market the register still holds names by
  -- its subscription reference, once the tenant has an asset register set up; the value the status. A market without any
  -- device in the register (one it does not cover yet) gives no finding
  select 'active_subscription_without_device', sb.connection_id, 'subscription', sb.source_id, sb.status
  from cma.subscription sb
  join (select x.connection_id, x.market from cma.flash_subscription_stores_of(p_tenant_id) x offset 0) sm on sm.connection_id = sb.connection_id
  left join (select distinct d.market, d.subscription_ref from cma.device d
             where d.tenant_id = p_tenant_id and d.source_deleted_at is null and d.subscription_ref is not null) dr
    on dr.subscription_ref = sb.source_id and dr.market = sm.market
  where sb.tenant_id = p_tenant_id and sb.source_deleted_at is null and dr.subscription_ref is null
    and sb.status = any (cma.flash_holding_statuses_of(p_tenant_id)) and cma.assets_set_up_of(p_tenant_id)
    -- the register's markets, once (a set, never a read per subscription)
    and sm.market in (select distinct d.market from cma.device d where d.tenant_id = p_tenant_id and d.source_deleted_at is null and d.market is not null)
  union all
  -- devices in a status in the field, of a market whose store's subscriptions the CMA reads, whose subscription
  -- reference names no subscription the CMA holds of that market (0008zn)
  select 'device_subscription_ref_unknown', dv.connection_id, 'device', dv.source_id, null::text
  from cma.device dv
  join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_in_field
  -- the subscriptions the CMA holds per market of their store, once (a set joined, never a read per device)
  left join (select distinct sm.market, sb.source_id
             from cma.subscription sb
             join (select y.connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y offset 0) sm on sm.connection_id = sb.connection_id
             where sb.tenant_id = p_tenant_id and sb.source_deleted_at is null) held
    on held.market = dv.market and held.source_id = dv.subscription_ref
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.subscription_ref is not null
    and dv.market in (select sm.market from cma.flash_subscription_stores_of(p_tenant_id) sm)
    and held.source_id is null
  union all
  -- devices in a status in the field linked to a subscription of their market in a status of
  -- flash.ended_subscription_statuses (0008zn); the value the subscription's status (the first by status when two
  -- subscriptions of the market share the id)
  select 'field_device_on_ended_subscription', dv.connection_id, 'device', dv.source_id, sb.status
  from cma.device dv
  join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_in_field
  join (select sm.market, x.source_id, min(x.status) as status
        from cma.subscription x
        join (select y.connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y offset 0) sm on sm.connection_id = x.connection_id
        where x.tenant_id = p_tenant_id and x.source_deleted_at is null and x.status = any (cma.flash_ended_statuses_of(p_tenant_id))
        group by 1, 2) sb on sb.source_id = dv.subscription_ref and sb.market = dv.market
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.subscription_ref is not null
  union all
  -- devices in a status in the field linked to a subscription of their market whose status is neither a device-holding
  -- one nor an ended one (0008zt: for Pulse4all paused, merged and never-subscribed; an ended one is the check above, so
  -- no device is listed twice); the value the subscription's status (the device's own subscription, as the installed base
  -- links it: the first by id when two subscriptions of the market share the id)
  select 'field_device_on_non_holding_subscription', dv.connection_id, 'device', dv.source_id, sb.status
  from cma.device dv
  join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_in_field
  join (select distinct on (sm.market, x.source_id) sm.market, x.source_id, x.status
        from cma.subscription x
        join (select y.connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y offset 0) sm on sm.connection_id = x.connection_id
        where x.tenant_id = p_tenant_id and x.source_deleted_at is null
        order by sm.market, x.source_id, x.id) sb on sb.source_id = dv.subscription_ref and sb.market = dv.market
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.subscription_ref is not null
    and not (sb.status = any (cma.flash_holding_statuses_of(p_tenant_id))) and not (sb.status = any (cma.flash_ended_statuses_of(p_tenant_id)));

  -- parked write-backs: the outbox arrives with migration 0007c (DESIGN §4.3a); until then the check
  -- finds nothing. Only the columns every outbox row has by design are read: id, connection, status
  if to_regclass('cma.outbox_action') is not null then
    return query execute
      'select ''writeback_parked''::text, o.connection_id, ''outbox_action''::text, o.id::text, null::text
       from cma.outbox_action o
       where o.tenant_id = $1 and o.status = ''needs_review'''
      using p_tenant_id;
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. A list: the installed base's own filters
-- ---------------------------------------------------------------------------------------------
-- As 0008zz (148), with the installed base's two list filters in its where clause (serial, without_subscription_ref);
-- every other overview's statement is unchanged
-- based on: 148_installed_base_list.sql
create or replace function cma.flash_rows_of(p_tenant_id uuid, p_overview text, p_filters jsonb, p_sort text, p_descending boolean,
                                             p_limit integer, p_offset integer, p_from date, p_to date)
returns jsonb
language plpgsql stable
as $$
declare
  v_order text := cma.flash_order_by(p_overview, p_sort, p_descending);
  v_today date := cma.tenant_today_of(p_tenant_id);
  v_from  date := coalesce(p_from, v_today);
  v_to    date := coalesce(p_to, p_from, v_today);
  v_src   text := (select o.source from cma.flash_overviews() o where o.key = p_overview);
  v_base  text;
  v_where text;
  v_obj   text;
  v_res   jsonb;
  v_extra text := '';      -- columns the page adds after the filter and the paging (0008zz)
  v_page  text := 'p x';   -- the page and what it joins (0008zz)
begin
  if v_order is null then
    raise exception 'sort % is not a sort key of %', p_sort, p_overview using errcode = 'CMA04';
  end if;
  if v_src is not null and not coalesce(cma.flash_source_set_up_of(p_tenant_id, v_src), false) then
    return jsonb_build_object('total', 0, 'rows', '[]'::jsonb);
  end if;
  case p_overview
    when 'customers' then
      v_base := 'cma.flash_customer_figures_of($2)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''store'' is null or x.store = $1 ->> ''store'')
                  and ($1 ->> ''segment'' is null or x.segment = $1 ->> ''segment'')
                  and case $1 ->> ''measure'' when ''active_customers'' then x.holding_subscriptions > 0
                                              when ''paused_customers'' then x.holding_subscriptions = 0 and x.paused_subscriptions > 0
                                              when ''linked_to_contact'' then x.contact_source_id is not null
                                              when ''with_required_refs'' then x.contact_source_id is not null and x.contact_held and cardinality(x.missing_refs) = 0
                                              else true end';
      v_obj := 'jsonb_build_object(''customer_id'', x.source_id, ''connection_id'', x.connection_id, ''store'', x.store, ''market'', x.market,
                  ''contact_id'', x.contact_source_id, ''contact_url'', cma.record_url(x.crm_connection_id, ''contact'', x.contact_source_id),
                  ''contact_held'', x.contact_held, ''refs'', x.refs, ''missing_refs'', to_jsonb(x.missing_refs),
                  ''lifetime_orders'', x.lifetime_orders, ''total_spent'', x.total_spent, ''currency'', x.currency,
                  ''active_subscriptions'', x.active_subscriptions, ''paused_subscriptions'', x.paused_subscriptions, ''devices'', x.devices,
                  ''holding_subscriptions'', x.holding_subscriptions,
                  ''order_ids'', (select coalesce(jsonb_agg(q.n order by q.at desc, q.n), ''[]''::jsonb)
                                 from (select coalesce(o.order_name, o.source_id) as n, o.source_created_at as at from cma.commerce_order o
                                       where o.tenant_id = $2 and o.connection_id = x.connection_id and o.customer_source_id = x.source_id
                                         and o.source_deleted_at is null order by o.source_created_at desc, o.source_id limit 20) q),
                  ''orders_held'', (select count(*) from cma.commerce_order o where o.tenant_id = $2 and o.connection_id = x.connection_id
                                     and o.customer_source_id = x.source_id and o.source_deleted_at is null),
                  ''subscription_ids'', (select coalesce(jsonb_agg(q.source_id order by q.source_id), ''[]''::jsonb)
                                        from (select sb.source_id from cma.subscription sb join sm on sm.connection_id = sb.connection_id
                                              where sb.tenant_id = $2 and sm.store_connection_id = x.connection_id and sb.customer_source_id = x.source_id
                                                and sb.source_deleted_at is null order by sb.source_id limit 20) q))';
    when 'subscriptions' then
      -- measured against the tenant's today (the age bands); devices_on_holding's records are the device-holding
      -- subscriptions with a device in the field, each with its devices_in_field (they add up to the figure)
      v_base := 'cma.flash_subscriptions_of($2, $7)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''store'' is null or x.store = $1 ->> ''store'')
                  and ($1 ->> ''status'' is null or x.status = $1 ->> ''status'') and ($1 ->> ''payment_state'' is null or x.payment_state = $1 ->> ''payment_state'')
                  and ($1 ->> ''device_band'' is null or x.device_band = $1 ->> ''device_band'')
                  and ($1 ->> ''age_band'' is null or x.age_band = $1 ->> ''age_band'')
                  and case $1 ->> ''measure'' when ''active_subscriptions'' then x.is_active when ''paused_subscriptions'' then x.status = ''paused''
                                              when ''holding_subscriptions'' then x.is_holding
                                              when ''devices_on_holding'' then x.is_holding and x.devices_in_field > 0 else true end';
      v_obj := 'jsonb_build_object(''subscription_id'', x.source_id, ''connection_id'', x.connection_id, ''store'', x.store, ''market'', x.market,
                  ''customer_id'', x.customer_source_id, ''contact_id'', x.contact_source_id,
                  ''contact_url'', cma.record_url(x.crm_connection_id, ''contact'', x.contact_source_id), ''status'', x.status,
                  ''payment_state'', x.payment_state, ''amount_per_cycle'', x.amount_per_cycle, ''currency'', x.currency,
                  ''billing_interval'', x.billing_interval, ''billing_interval_count'', x.billing_interval_count, ''next_billing_at'', x.next_billing_at,
                  ''retry_since'', x.retry_since, ''last_attempt'', x.last_attempt, ''devices'', x.devices, ''devices_in_field'', x.devices_in_field)';
    when 'installed_base' then
      -- the devices, filtered and paged first; the linked subscription's payment state (0008zl's derivation) only for the
      -- page's subscriptions, since no filter or sort reads it (addition 0008zz). The list's own filters (0009f,
      -- cma.flash_list_filters_of): serial, an exact match trimmed and case-insensitive (every device with it: a duplicate
      -- serial is a data-quality finding), and without_subscription_ref, the devices the data-quality check
      -- field_device_without_subscription_ref finds (one implementation, cma.field_devices_without_subscription_ref_of)
      v_base := 'cma.flash_devices_of($2, $7)';
      v_extra := ', ps.payment_state as subscription_payment_state';
      v_page := 'p x left join cma.subscription_payment_state_of($2, array(select y.subscription_id from p y where y.subscription_id is not null)) ps
                   on ps.subscription_id = x.subscription_id';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''status'' is null or x.status = $1 ->> ''status'')
                  and ($1 ->> ''model'' is null or x.model = $1 ->> ''model'') and ($1 ->> ''warehouse'' is null or x.warehouse = $1 ->> ''warehouse'')
                  and ($1 ->> ''link'' is null or x.link = $1 ->> ''link'')
                  and ($1 ->> ''subscription_status'' is null or x.subscription_status = $1 ->> ''subscription_status'')
                  and ($1 ->> ''serial'' is null or lower(x.serial) = lower(btrim($1 ->> ''serial'')))
                  and ($1 ->> ''without_subscription_ref'' is null
                       or x.device_id in (select u.device_id from cma.field_devices_without_subscription_ref_of($2) u))
                  and case $1 ->> ''measure'' when ''in_field'' then x.is_in_field when ''in_stock'' then x.is_in_stock
                                              when ''in_field_on_holding'' then x.is_in_field and x.subscription_status = any ($8)
                                              when ''components_past_due'' then x.past_due_items > 0 when ''items_due_3m'' then x.items_due_3m > 0
                                              else true end';
      v_obj := 'jsonb_build_object(''serial'', x.serial, ''device_id'', x.source_id, ''connection_id'', x.connection_id, ''model'', x.model,
                  ''market'', x.market, ''status'', x.status, ''in_field'', x.is_in_field, ''in_stock'', x.is_in_stock, ''warehouse'', x.warehouse,
                  ''refs'', x.refs, ''missing_refs'', to_jsonb(x.missing_refs), ''customer_id'', x.customer_ref, ''subscription_id'', x.subscription_ref,
                  ''link'', x.link, ''subscription_status'', x.subscription_status, ''subscription_payment_state'', x.subscription_payment_state,
                  ''past_due_items'', x.past_due_items, ''items_due_3m'', x.items_due_3m, ''next_due_on'', x.next_due_on,
                  ''record_url'', cma.record_url(x.connection_id, ''device'', x.source_id))';
    when 'churn' then
      v_base := 'cma.flash_churn_of($2, $5, $6)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''store'' is null or x.store = $1 ->> ''store'')
                  and ($1 ->> ''reason'' is null or x.reason = $1 ->> ''reason'')';
      v_obj := 'jsonb_build_object(''subscription_id'', x.source_id, ''connection_id'', x.connection_id, ''store'', x.store, ''market'', x.market,
                  ''customer_id'', x.customer_source_id, ''churned_at'', x.churned_at, ''business_date'', x.business_date, ''reason'', x.reason,
                  ''cycles'', x.cycles)';
    when 'orders' then
      v_base := 'cma.flash_orders_of($2, $5, $6)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''store'' is null or x.store = $1 ->> ''store'')
                  and ($1 ->> ''kind'' is null or x.kind = $1 ->> ''kind'') and ($1 ->> ''sku'' is null or ($1 ->> ''sku'') = any (x.skus))';
      v_obj := 'jsonb_build_object(''order_number'', x.order_number, ''order_id'', x.source_id, ''connection_id'', x.connection_id, ''store'', x.store,
                  ''market'', x.market, ''created_at'', x.created_at, ''business_date'', x.business_date, ''kind'', x.kind,
                  ''financial_status'', x.financial_status, ''fulfillment_status'', x.fulfillment_status, ''skus'', to_jsonb(x.skus),
                  ''units'', x.units, ''total'', x.total, ''currency'', x.currency, ''customer_id'', x.customer_source_id)';
    when 'payments' then
      v_base := 'cma.flash_payments_of($2, $5, $6)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''store'' is null or x.store = $1 ->> ''store'')
                  and ($1 ->> ''kind'' is null or x.kind = $1 ->> ''kind'') and ($1 ->> ''status'' is null or x.status = $1 ->> ''status'')
                  and case $1 ->> ''measure'' when ''orders'' then x.kind = ''order''
                                              when ''renewals'' then x.kind = ''renewal'' and x.status = ''renewed''
                                              when ''failed_renewals'' then x.kind = ''renewal'' and x.status = ''renew_failed'' else true end';
      v_obj := 'jsonb_build_object(''kind'', x.kind, ''status'', x.status, ''record_ref'', x.record_ref, ''cycle'', x.cycle, ''source_id'', x.source_id,
                  ''connection_id'', x.connection_id, ''store'', x.store, ''market'', x.market, ''at'', x.at, ''business_date'', x.business_date,
                  ''amount'', x.amount, ''currency'', x.currency)';
    when 'open_deals' then
      v_base := 'cma.flash_deals_of($2)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''pipeline'' is null or x.pipeline = $1 ->> ''pipeline'')
                  and ($1 ->> ''stage'' is null or x.stage = $1 ->> ''stage'')';
      v_obj := 'jsonb_build_object(''record_id'', x.source_id, ''record_url'', cma.record_url(x.connection_id, ''deal'', x.source_id),
                  ''connection_id'', x.connection_id, ''pipeline'', x.pipeline, ''stage'', x.stage, ''market'', x.market, ''owner_ref'', x.owner_ref,
                  ''owner_linked'', x.owner_user_id is not null, ''created_at'', x.created_at, ''age_days'', x.age_days)';
    when 'open_tickets' then
      v_base := 'cma.flash_tickets_of($2)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''queue'' is null or x.queue = $1 ->> ''queue'')
                  and ($1 ->> ''stage'' is null or x.stage = $1 ->> ''stage'')';
      v_obj := 'jsonb_build_object(''record_id'', x.source_id, ''record_url'', cma.record_url(x.connection_id, ''ticket'', x.source_id),
                  ''connection_id'', x.connection_id, ''queue'', x.queue, ''stage'', x.stage, ''market'', x.market, ''owner_ref'', x.owner_ref,
                  ''owner_linked'', x.owner_user_id is not null, ''created_at'', x.created_at, ''age_days'', x.age_days)';
    when 'open_tasks' then
      v_base := 'cma.flash_tasks_of($2)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''type'' is null or x.type = $1 ->> ''type'')
                  and ($1 ->> ''status'' is null or x.status = $1 ->> ''status'')
                  and case $1 ->> ''measure'' when ''overdue'' then x.overdue else true end';
      v_obj := 'jsonb_build_object(''task_id'', x.source_id, ''task_url'', cma.record_url(x.connection_id, ''task'', x.source_id),
                  ''connection_id'', x.connection_id, ''type'', x.type, ''status'', x.status, ''market'', x.market, ''owner_ref'', x.owner_ref,
                  ''owner_linked'', x.owner_user_id is not null, ''due_at'', x.due_at, ''overdue'', x.overdue, ''record_type'', x.record_type,
                  ''record_id'', x.record_source_id,
                  ''record_url'', case when x.record_type is not null then cma.record_url(x.connection_id, x.record_type, x.record_source_id) end)';
    when 'reviews' then
      v_base := 'cma.flash_reviews_of($2, $5, $6)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''rating'' is null or x.stars::text = $1 ->> ''rating'')
                  and case $1 ->> ''measure'' when ''negative'' then x.is_negative else true end';
      v_obj := 'jsonb_build_object(''review_id'', x.source_id, ''review_url'', cma.record_url(x.connection_id, ''review'', x.source_id),
                  ''connection_id'', x.connection_id, ''channel'', x.channel, ''market'', x.market, ''rating'', x.rating, ''stars'', x.stars,
                  ''negative'', x.is_negative, ''submitted_at'', x.submitted_at, ''business_date'', x.business_date, ''link_level'', x.link_level)';
    when 'data_quality' then
      v_base := 'cma.flash_findings_of($2)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''check'' is null or x.check_key = $1 ->> ''check'')';
      v_obj := 'jsonb_build_object(''check'', x.check_key, ''object_type'', x.object_type, ''object_id'', x.object_id, ''connection_id'', x.connection_id,
                  ''value'', x.value, ''market'', x.market, ''fix_in'', x.fix_in, ''fix_adapter'', x.fix_adapter)
                  || cma.flash_finding_links_of($2, x.connection_id, x.object_type, x.object_id)';
  end case;
  execute format(
    'with sm as materialized (select * from cma.flash_subscription_stores_of($2)),
          f as materialized (select x.* from %s x where %s),
          p as materialized (select x.* from f x order by %s limit $3 offset $4),
          n as (select x.*%s, row_number() over (order by %s) as ord from %s)
     select jsonb_build_object(''total'', (select count(*) from f),
                               ''rows'', coalesce((select jsonb_agg(%s order by x.ord) from n x), ''[]''::jsonb))',
    v_base, v_where, v_order, v_extra, v_order, v_page, v_obj)
    into v_res
    using p_filters, p_tenant_id, p_limit, p_offset, v_from, v_to, v_today, cma.flash_holding_statuses_of(p_tenant_id);
  return v_res;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. The list's read and the file record: the list's own filters pass their checks
-- ---------------------------------------------------------------------------------------------
-- As 0008zz (148), with the filter keys of cma.flash_list_filters_of accepted beside the dims and measure, each a text of 1
-- to 100 characters, without_subscription_ref "true" alone (CMA04 else); a past month end's frozen list (p_as_of) refuses
-- them as it refuses every filter it cannot apply (cma.flash_id_rows_of, CMA04)
-- based on: 148_installed_base_list.sql
create or replace function cma.flash_rows(p_overview text, p_filters jsonb default '{}'::jsonb, p_sort text default null,
                                          p_descending boolean default false, p_limit integer default 500, p_offset integer default 0,
                                          p_as_of date default null, p_from date default null, p_to date default null)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_today   date;
  v_filters jsonb := coalesce(p_filters, '{}'::jsonb);
  o         record;
  v_sort    text;
  v_res     jsonb;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.assert_flash_overview(p_overview);
  v_today := cma.tenant_today_of(v_tenant);
  perform cma.assert_flash_params(null, p_as_of, p_from, p_to, v_today);
  select * into o from cma.flash_overviews() x where x.key = p_overview;
  if jsonb_typeof(v_filters) <> 'object'
     or exists (select 1 from jsonb_each(v_filters) e
                where not (e.key = any (o.dims) or e.key = 'measure' or e.key = any (cma.flash_list_filters_of(p_overview)))
                   or jsonb_typeof(e.value) <> 'string' or length(e.value #>> '{}') not between 1 and 100
                   or (e.key = 'without_subscription_ref' and (e.value #>> '{}') <> 'true'))
     or (v_filters ? 'measure' and not ((v_filters ->> 'measure') = any (o.count_measures))) then
    raise exception 'filters are the overview''s dims (%), measure (one of %) and the list''s own filters (%), each a text', array_to_string(o.dims, ', '),
      array_to_string(o.count_measures, ', '), array_to_string(cma.flash_list_filters_of(p_overview), ', ') using errcode = 'CMA04';
  end if;
  -- a measure that does not apply has no records: with_required_refs while no contact reference is required
  if p_overview = 'customers' and (v_filters ->> 'measure') = 'with_required_refs'
     and cardinality(cma.flash_list_of(cma.setting_of(v_tenant, 'commerce.required_contact_refs'))) = 0 then
    raise exception 'with_required_refs does not apply: commerce.required_contact_refs is empty' using errcode = 'CMA04';
  end if;
  perform cma.assert_flash_params(v_filters ->> 'market', null, null, null, v_today);
  if p_limit is null or p_limit not between 1 and cma.setting_of(v_tenant, 'flash.file_max_rows')::integer
     or p_offset is null or p_offset not between 0 and 100000000 then
    raise exception 'a list reads 1 to % rows from an offset of 0 or more', cma.setting_of(v_tenant, 'flash.file_max_rows') using errcode = 'CMA04';
  end if;
  if p_as_of is null then
    v_sort := coalesce(p_sort, o.sorts[1]);
    v_res := cma.flash_rows_of(v_tenant, p_overview, v_filters, v_sort, p_descending, p_limit, p_offset,
                               case when o.kind = 'flow' then coalesce(p_from, v_today) end, case when o.kind = 'flow' then coalesce(p_to, v_today) end);
  else
    v_sort := p_sort;
    v_res := cma.flash_id_rows_of(v_tenant, p_overview, v_filters, p_sort, p_descending, p_limit, p_offset, p_as_of);
  end if;
  return jsonb_build_object('overview', p_overview, 'mode', case when p_as_of is null then 'live' else 'snapshot' end,
                            'as_of', case when p_as_of is null then to_jsonb(now()) else to_jsonb(p_as_of) end,
                            'from', case when o.kind = 'flow' and p_as_of is null then coalesce(p_from, v_today) end,
                            'to', case when o.kind = 'flow' and p_as_of is null then coalesce(p_to, v_today) end,
                            'filters', v_filters, 'sort', v_sort, 'descending', coalesce(p_descending, false), 'limit', p_limit, 'offset', p_offset,
                            'set_up', case when o.source is null then true
                                           else coalesce(cma.flash_source_set_up_of(v_tenant, o.source), false) end,
                            'time_zone', (select t.timezone from cma.tenant t where t.id = v_tenant))
         || v_res;
end
$$;

-- As 0008zn (122), with the same filter keys accepted in a file record (the audit row of a file or a rows read)
-- based on: 122_flash.sql
create or replace function cma.flash_file_record(p_overview text, p_part text, p_filters jsonb, p_market text, p_as_of date, p_from date,
                                                 p_to date, p_rows integer)
returns void
language plpgsql
as $$
declare
  o record;
begin
  perform cma.assert_any_permission(case when p_overview = 'data_quality' then array['reports.view', 'performance.team', 'tenant.configure']
                                         else array['reports.view', 'performance.team'] end);
  perform cma.assert_flash_overview(p_overview);
  select * into o from cma.flash_overviews() x where x.key = p_overview;
  if p_part is null or p_part not in ('rows', 'breakdown') or p_rows is null or p_rows < 0
     or (p_filters is not null
         and (jsonb_typeof(p_filters) <> 'object' or strpos(p_filters::text, '@') > 0
              or exists (select 1 from jsonb_each(p_filters) e
                         where not (e.key = any (o.dims) or e.key = 'measure' or e.key = any (cma.flash_list_filters_of(p_overview)))
                            or jsonb_typeof(e.value) <> 'string' or length(e.value #>> '{}') not between 1 and 100
                            or (e.key = 'without_subscription_ref' and (e.value #>> '{}') <> 'true'))
              or (p_filters ? 'measure' and not ((p_filters ->> 'measure') = any (o.count_measures))))) then
    raise exception 'a file record names its part (rows or breakdown), its filters (the overview''s dims, measure and the list''s own filters, each a text) and its rows'
      using errcode = 'CMA04';
  end if;
  perform cma.assert_flash_params(p_market, p_as_of, p_from, p_to, cma.tenant_today_of(cma.current_tenant_id()));
  perform cma.assert_flash_params(p_filters ->> 'market', null, null, null, cma.tenant_today_of(cma.current_tenant_id()));
  insert into cma.audit_log (tenant_id, table_name, action, old_row, new_row, actor_user_id, actor_label)
  values (cma.current_tenant_id(), 'flash_file', 'insert', null,
          jsonb_strip_nulls(jsonb_build_object('overview', p_overview, 'part', p_part, 'filters', coalesce(p_filters, '{}'::jsonb),
                                               'market', p_market, 'as_of', p_as_of, 'from', p_from, 'to', p_to, 'rows', p_rows)),
          cma.current_user_id(), cma.current_actor_label());
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Grants and JIT; the catalog triggers, last; the addition
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  -- the application's, in the caller's rights (a function made again keeps its grants)
  foreach f in array array[
    'cma.flash_list_filters_of(text)', 'cma.field_devices_without_subscription_ref_of(uuid)', 'cma.data_quality_of(uuid)',
    'cma.flash_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date,date)', 'cma.flash_rows(text,jsonb,text,boolean,integer,integer,date,date,date)',
    'cma.flash_file_record(text,text,jsonb,text,date,date,date,integer)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
  -- JIT off again for the large read (a create or replace drops a function's settings), as 148 set it
  execute 'alter function cma.flash_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date,date) set jit = off';
end
$$;

-- D9: a tenant's current takes are forgotten when a catalog their figures read changes, with 0009e's definer function
-- (cma.flash_current_forget: the writer of a catalog row holds no write on the takes). The catalogs the take-able
-- overviews' computations read, and the columns they read, from the code: the installed base (cma.flash_devices_of,
-- cma.maintenance_items_of) the device statuses' key and flags, the component kinds' key and status, the maintenance
-- rules' model, kind, interval and lead days; the subscriptions' take the device statuses too; open deals, tickets and
-- tasks (cma.counted_deals_of, cma.open_tickets_of, cma.open_tasks_of) the pipelines' is_counted, is_lead and is_order, the
-- stages' is_closed, the task statuses' is_done and the task types' is_counted. Not read by a take: the models' and
-- markets' catalogs and the market aliases (the device row stores the mapped keys at the register's read: a change reaches
-- the take through the next read of the source), the stores (a source's configuration) and every label (read live by the
-- document). An insert or a delete forgets (forget_flash_current_takes); an update only when a read column changes
-- (forget_flash_current_takes_change, its when clause: a trigger on insert or delete cannot read old and new), so a sync
-- that rewrites a catalog row unchanged (the CRM catalogs' refreshed_at, a status's updated_at) forgets nothing. Each
-- trigger takes a lock on its table that is held to the commit, so they come last, directly before the addition
drop trigger if exists forget_flash_current_takes on cma.device_status;
create trigger forget_flash_current_takes after insert or delete on cma.device_status
  for each row execute function cma.flash_current_forget();
drop trigger if exists forget_flash_current_takes_change on cma.device_status;
create trigger forget_flash_current_takes_change after update of key, is_in_field, is_in_stock, is_tracked on cma.device_status
  for each row when ((old.key, old.is_in_field, old.is_in_stock, old.is_tracked) is distinct from (new.key, new.is_in_field, new.is_in_stock, new.is_tracked)) execute function cma.flash_current_forget();

drop trigger if exists forget_flash_current_takes on cma.device_component_kind;
create trigger forget_flash_current_takes after insert or delete on cma.device_component_kind
  for each row execute function cma.flash_current_forget();
drop trigger if exists forget_flash_current_takes_change on cma.device_component_kind;
create trigger forget_flash_current_takes_change after update of key, status on cma.device_component_kind
  for each row when ((old.key, old.status) is distinct from (new.key, new.status)) execute function cma.flash_current_forget();

drop trigger if exists forget_flash_current_takes on cma.maintenance_rule;
create trigger forget_flash_current_takes after insert or delete on cma.maintenance_rule
  for each row execute function cma.flash_current_forget();
drop trigger if exists forget_flash_current_takes_change on cma.maintenance_rule;
create trigger forget_flash_current_takes_change after update of model_key, component_key, interval_months, lead_days on cma.maintenance_rule
  for each row when ((old.model_key, old.component_key, old.interval_months, old.lead_days) is distinct from (new.model_key, new.component_key, new.interval_months, new.lead_days)) execute function cma.flash_current_forget();

drop trigger if exists forget_flash_current_takes on cma.connection_pipeline;
create trigger forget_flash_current_takes after insert or delete on cma.connection_pipeline
  for each row execute function cma.flash_current_forget();
drop trigger if exists forget_flash_current_takes_change on cma.connection_pipeline;
create trigger forget_flash_current_takes_change after update of is_counted, is_lead, is_order on cma.connection_pipeline
  for each row when ((old.is_counted, old.is_lead, old.is_order) is distinct from (new.is_counted, new.is_lead, new.is_order)) execute function cma.flash_current_forget();

drop trigger if exists forget_flash_current_takes on cma.connection_stage;
create trigger forget_flash_current_takes after insert or delete on cma.connection_stage
  for each row execute function cma.flash_current_forget();
drop trigger if exists forget_flash_current_takes_change on cma.connection_stage;
create trigger forget_flash_current_takes_change after update of is_closed on cma.connection_stage
  for each row when ((old.is_closed) is distinct from (new.is_closed)) execute function cma.flash_current_forget();

drop trigger if exists forget_flash_current_takes on cma.connection_task_status;
create trigger forget_flash_current_takes after insert or delete on cma.connection_task_status
  for each row execute function cma.flash_current_forget();
drop trigger if exists forget_flash_current_takes_change on cma.connection_task_status;
create trigger forget_flash_current_takes_change after update of is_done on cma.connection_task_status
  for each row when ((old.is_done) is distinct from (new.is_done)) execute function cma.flash_current_forget();

drop trigger if exists forget_flash_current_takes on cma.connection_task_type;
create trigger forget_flash_current_takes after insert or delete on cma.connection_task_type
  for each row execute function cma.flash_current_forget();
drop trigger if exists forget_flash_current_takes_change on cma.connection_task_type;
create trigger forget_flash_current_takes_change after update of is_counted on cma.connection_task_type
  for each row when ((old.is_counted) is distinct from (new.is_counted)) execute function cma.flash_current_forget();

insert into cma.schema_migration (version, description)
values ('0009f', 'Assets → Installed base as the "now" view: the list''s own filters (cma.flash_list_filters_of: installed_base''s serial, an exact match trimmed and case-insensitive, and without_subscription_ref), taken by cma.flash_rows_of (from 148), cma.flash_rows (148) and cma.flash_file_record (122); one rule for a field device without a subscription reference (cma.field_devices_without_subscription_ref_of), read by cma.data_quality_of (from 136) and the list alike; a tenant''s current takes forgotten when a catalog their figures read changes (triggers forget_flash_current_takes on cma.device_status, device_component_kind, maintenance_rule, connection_pipeline, connection_stage, connection_task_status and connection_task_type, with 0009e''s cma.flash_current_forget); the web''s now view, panels, 50-row lists, donut and stacked bars are web only; 159''s D1 and A3 compare in one statement')
on conflict (version) do nothing;

commit;
reset role;
