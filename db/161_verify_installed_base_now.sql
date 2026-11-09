-- =============================================================================================
-- 161_verify_installed_base_now.sql: verifies addition 0009f, Assets → Installed base as the "now" view (the list's own
-- filters, one rule for a field device without a subscription reference, the takes forgotten on a catalog change)
-- =============================================================================================
-- Blocks S check the addition, its functions and triggers (universal). Block A works on two throwaway tenants inside a
-- subtransaction that is always rolled back, so nothing stays; block D reads every active tenant's own data and writes
-- nothing. The script runs alike in dev and in prod. Every remade function is compared with its previous definition, kept
-- below word for word but for its name: pg_temp.v0009f_dq_0008zt (cma.data_quality_of as 136 defined it),
-- pg_temp.v0009f_rows_of_0008zz and pg_temp.v0009f_rows_0008zz (cma.flash_rows_of and cma.flash_rows as 148 defined them;
-- the kept wrapper calls the kept list), in the same transaction. Every comparison of two reads is made in one statement
-- (one snapshot), so a concurrent ingest cannot move one side (the lesson of 159's first prod run, #251). Every check
-- writes one row, ok or FAIL, and the last row is the verdict, because Cloud SQL Studio shows no notices: "0009f verified |
-- 161_verify_installed_base_now: 10 ok, 0 FAIL, 0 skip" (D1 reads skip for a database without a tenant whose asset
-- register is set up: 9 ok, 1 skip). Run as your own IAM login after 160_installed_base_now.sql, dev first, then prod;
-- then 41, 69, 73, 75, 101, 105, 113, 117, 123, 133, 137, 139, 149 and 159 again (160's header).
--   S1  the addition 0009f is recorded after 0009e
--   S2  the functions: the two new ones and the four remade ones the application's, in the caller's rights, nothing for
--       the readers; JIT off on cma.flash_rows_of; cma.flash_list_filters_of answers the installed base's two keys and
--       none for every other overview; the catalog triggers on the seven tables, both kinds, running cma.flash_current_forget
--       (definer, the owner's, pinned, nobody's to call)
--   S3  every function 160 remakes keeps exactly the settings (pg_proc.proconfig) it carried before 160:
--       cma.data_quality_of jit=off (122, 136), cma.flash_rows_of jit=off (122, 136, 138, 148), cma.flash_rows and
--       cma.flash_file_record none. Provoked: cma.data_quality_of's jit reset inside a subtransaction that is rolled back
--       (a deliberate difference the comparison must find). The check 160's first version lacked (dev, 9 November 2026:
--       it left cma.data_quality_of without jit=off, which 137's A5 found)
--   A1  D6: the devices of the data-quality check field_device_without_subscription_ref, the rule's function and the list
--       "In the field without a linked subscription" are the same devices, in one statement; 136's definition finds them
--       too; the list's count is theirs. Provoked: the list against the check less one device (a deliberate difference)
--   A2  D7: the serial search is an exact match trimmed and case-insensitive ("  sn-d-1 " finds SN-d-1), every device with
--       the serial (two share one), none for an unknown one, nothing of another tenant; its rows are the records list's
--   A3  the filters on every part (D3): for each market, operational status and model, and for a status with a model,
--       the list's total equals the sum of devices over the take's rows of the set [market, status, model, warehouse,
--       link] with that value (the tiles narrowed from the take are the list's figures); measure components_past_due
--       lists the devices with an item past due, a count of devices that differs from the items
--   A4  the remade functions answer as before for every call main makes: cma.flash_rows_of 148's over a grid of the old
--       filters, sorts, directions and pages and every other overview; cma.flash_rows 148's (as the reader);
--       cma.data_quality_of 136's for every check; the new keys taken by the list and the file record (one audit row),
--       refused where they must be: without_subscription_ref not "true", serial on another overview, an unknown key, the
--       keys on a month end's frozen list (CMA04)
--   A5  D9: a tenant's current take is forgotten by a catalog change its figures read (a device status flag, a status
--       inserted, a component kind's status, a maintenance rule inserted and one changed, a pipeline inserted, a stage's
--       is_closed, a task status's is_done, a task type's is_counted) and kept by a change it does not read (a status's
--       name and aliases, a rule written unchanged, a pipeline's label); the other tenant's take stays through all of it
--   D1  every active tenant with an asset register: the list without a subscription reference equals the check's devices,
--       in one statement; read only
--   D2  every active tenant: cma.data_quality_of equals 136's definition, check by check, in one statement; read only
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says PROVOKED, NOT A PASS.
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

drop table if exists pg_temp.verify_0009f;
create temp table verify_0009f (ord int, check_name text, result text, detail text);
grant select, insert on pg_temp.verify_0009f to cma_app;

-- ---------------------------------------------------------------------------------------------
-- The previous definitions, word for word but for their names and the call between them
-- ---------------------------------------------------------------------------------------------
-- cma.data_quality_of as 0008zt (136_flash_insights.sql) defined it
create or replace function pg_temp.v0009f_dq_0008zt(p_tenant_id uuid)
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
  -- devices in a status in the field without a subscription reference (0008zi)
  select 'field_device_without_subscription_ref', dv.connection_id, 'device', dv.source_id, null::text
  from cma.device dv
  join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_in_field
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.subscription_ref is null
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

-- cma.flash_rows_of as 0008zz (148_installed_base_list.sql) defined it, JIT off as there
create or replace function pg_temp.v0009f_rows_of_0008zz(p_tenant_id uuid, p_overview text, p_filters jsonb, p_sort text, p_descending boolean,
                                             p_limit integer, p_offset integer, p_from date, p_to date)
returns jsonb
language plpgsql stable
set jit = off
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
      -- page's subscriptions, since no filter or sort reads it (addition 0008zz)
      v_base := 'cma.flash_devices_of($2, $7)';
      v_extra := ', ps.payment_state as subscription_payment_state';
      v_page := 'p x left join cma.subscription_payment_state_of($2, array(select y.subscription_id from p y where y.subscription_id is not null)) ps
                   on ps.subscription_id = x.subscription_id';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''status'' is null or x.status = $1 ->> ''status'')
                  and ($1 ->> ''model'' is null or x.model = $1 ->> ''model'') and ($1 ->> ''warehouse'' is null or x.warehouse = $1 ->> ''warehouse'')
                  and ($1 ->> ''link'' is null or x.link = $1 ->> ''link'')
                  and ($1 ->> ''subscription_status'' is null or x.subscription_status = $1 ->> ''subscription_status'')
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

-- cma.flash_rows as 0008zz (148_installed_base_list.sql) defined it, calling the kept list
create or replace function pg_temp.v0009f_rows_0008zz(p_overview text, p_filters jsonb default '{}'::jsonb, p_sort text default null,
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
                where not (e.key = any (o.dims) or e.key = 'measure') or jsonb_typeof(e.value) <> 'string'
                   or length(e.value #>> '{}') not between 1 and 100)
     or (v_filters ? 'measure' and not ((v_filters ->> 'measure') = any (o.count_measures))) then
    raise exception 'filters are the overview''s dims (%) and measure (one of %), each a text', array_to_string(o.dims, ', '),
      array_to_string(o.count_measures, ', ') using errcode = 'CMA04';
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
    v_res := pg_temp.v0009f_rows_of_0008zz(v_tenant, p_overview, v_filters, v_sort, p_descending, p_limit, p_offset,
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

-- A statement's SQLSTATE, or ok
create or replace function pg_temp.v0009f_code(p_sql text)
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

-- A set of ids as one text (sorted), to compare two reads
create or replace function pg_temp.v0009f_ids(p_ids text[])
returns text
language sql immutable
as $$
  select coalesce((select string_agg(x, ',' order by x collate "C") from unnest(p_ids) x), '')
$$;

grant execute on function pg_temp.v0009f_dq_0008zt(uuid) to cma_app;
grant execute on function pg_temp.v0009f_rows_of_0008zz(uuid,text,jsonb,text,boolean,integer,integer,date,date) to cma_app;
grant execute on function pg_temp.v0009f_rows_0008zz(text,jsonb,text,boolean,integer,integer,date,date,date) to cma_app;
grant execute on function pg_temp.v0009f_code(text) to cma_app;
grant execute on function pg_temp.v0009f_ids(text[]) to cma_app;

-- S1. The addition
do $$
begin
  insert into verify_0009f values (1, 'S1 the addition 0009f is recorded after 0009e',
    case when exists (select 1 from cma.schema_migration where version = '0009f')
              and exists (select 1 from cma.schema_migration where version = '0009e')
              and not current_setting('verify.provoke')::boolean then 'ok' else 'FAIL' end,
    (select string_agg(version, ', ' order by version) from cma.schema_migration where version in ('0009e', '0009f')));
end
$$;

-- S2. The functions and the triggers
do $$
declare
  v_fn  text;
  v_tb  text;
  v_bad text := '';
  v_txt text;
begin
  foreach v_fn in array array['cma.flash_list_filters_of(text)', 'cma.field_devices_without_subscription_ref_of(uuid)', 'cma.data_quality_of(uuid)',
                              'cma.flash_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date,date)',
                              'cma.flash_rows(text,jsonb,text,boolean,integer,integer,date,date,date)',
                              'cma.flash_file_record(text,text,jsonb,text,date,date,date,integer)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  if not coalesce((select 'jit=off' = any (proconfig) from pg_proc where oid = 'cma.flash_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date,date)'::regprocedure), false) then
    v_bad := v_bad || 'flash_rows_of without jit=off; ';
  end if;
  if cma.flash_list_filters_of('installed_base') is distinct from array['serial', 'without_subscription_ref']
     or exists (select 1 from cma.flash_overviews() o where o.key <> 'installed_base' and cma.flash_list_filters_of(o.key) <> '{}'::text[])
     or cma.flash_list_filters_of('nope') <> '{}'::text[] then
    v_bad := v_bad || 'the list filters ' || coalesce(cma.flash_list_filters_of('installed_base')::text, 'none') || '; ';
  end if;
  -- the triggers: both kinds on each of the seven tables, running the definer function of 0009e
  foreach v_tb in array array['device_status', 'device_component_kind', 'maintenance_rule', 'connection_pipeline', 'connection_stage',
                              'connection_task_status', 'connection_task_type'] loop
    v_txt := (select string_agg(t.tgname || ':' || case when t.tgfoid = 'cma.flash_current_forget()'::regprocedure then 'forget' else 'other' end, ',' order by t.tgname)
              from pg_trigger t
              where t.tgrelid = ('cma.' || v_tb)::regclass and not t.tgisinternal and t.tgname like 'forget_flash_current_takes%');
    if v_txt is distinct from 'forget_flash_current_takes:forget,forget_flash_current_takes_change:forget' then
      v_bad := v_bad || v_tb || ' ' || coalesce(v_txt, 'no trigger') || '; ';
    end if;
  end loop;
  v_fn := 'cma.flash_current_forget()';
  if not (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
     or (select pg_get_userbyid(proowner) from pg_proc where oid = to_regprocedure(v_fn)) <> 'cma_owner'
     or not (select 'search_path=pg_catalog, cma, pg_temp' = any (proconfig) from pg_proc where oid = to_regprocedure(v_fn))
     or has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute') then
    v_bad := v_bad || 'the forget function; ';
  end if;
  insert into verify_0009f values (2, 'S2 the functions the application''s in the caller''s rights, nothing for the readers; JIT off on the list; the list filters; the catalog triggers, both kinds on seven tables, the definer function',
    case when v_bad = '' and not current_setting('verify.provoke')::boolean then 'ok' else 'FAIL' end, nullif(v_bad, ''));
end
$$;

-- S3. Every remade function keeps exactly the settings it carried before 160 (a create or replace drops them; 160's
-- section 5 sets them again). The list is taken from the scripts that set them: jit=off on cma.data_quality_of (122,
-- 136) and on cma.flash_rows_of (122, 136, 138, 148); no script set one on cma.flash_rows or cma.flash_file_record.
-- Provoked: one setting dropped for real, inside a subtransaction that is always rolled back, so nothing stays
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad text := '';
  v_txt text;
  r record;
begin
  begin
    if v_provoke then
      execute 'alter function cma.data_quality_of(uuid) reset jit';
    end if;
    for r in select x.fn, x.want from (values
               ('cma.data_quality_of(uuid)', array['jit=off']),
               ('cma.flash_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date,date)', array['jit=off']),
               ('cma.flash_rows(text,jsonb,text,boolean,integer,integer,date,date,date)', '{}'::text[]),
               ('cma.flash_file_record(text,text,jsonb,text,date,date,date,integer)', '{}'::text[])) x(fn, want) loop
      select coalesce(array_to_string(array(select c from unnest(p.proconfig) c order by c), ','), '') into v_txt
      from pg_proc p where p.oid = to_regprocedure(r.fn);
      if v_txt is distinct from array_to_string(r.want, ',') then
        v_bad := v_bad || r.fn || ' has {' || coalesce(v_txt, 'no such function') || '}, before 160 {' || array_to_string(r.want, ',') || '}; ';
      end if;
    end loop;
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then v_bad := v_bad || 'ended early: ' || sqlstate || ' ' || left(sqlerrm, 200);
  end;
  insert into verify_0009f values (3, 'S3 every function 160 remakes keeps exactly the settings it carried before: jit=off on cma.data_quality_of and cma.flash_rows_of, none on cma.flash_rows and cma.flash_file_record',
    case when v_bad = '' then 'ok' else 'FAIL' end, coalesce(nullif(v_bad, ''), '4 functions as before'));
end
$$;

-- A. Behaviour on two throwaway tenants, always rolled back
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  v_t1 uuid; v_t2 uuid; v_reader uuid; v_role uuid; v_sched1 uuid; v_sched2 uuid;
  v_crm uuid; v_gb uuid; v_nl uuid; v_sgb uuid; v_snl uuid; v_reg uuid; v_reg2 uuid; v_d1 uuid; v_d2 uuid;
  v_bad text; v_txt text; v_n integer; v_m integer; v_today date; v_before integer;
  v_check text; v_rule text; v_list text; v_old text; v_new jsonb; v_old_j jsonb; v_t2_at timestamptz;
  f jsonb; s text; d boolean; pg integer[]; k text; o record;
begin
  begin
    v_t1 := cma.create_tenant('verify-0009f-one', 'Verify 0009f one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0009f-two', 'Verify 0009f two', 'Europe/Amsterdam');
    select u.id into v_sched1 from cma.app_user u where u.tenant_id = v_t1 and u.email = 'scheduler@system.invalid';
    select u.id into v_sched2 from cma.app_user u where u.tenant_id = v_t2 and u.email = 'scheduler@system.invalid';
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-reader-0009f@example.invalid', 'reader') returning id into v_reader;
    insert into cma.app_role (tenant_id, key, name) values (v_t1, 'verify_reader', 'Verify reader') returning id into v_role;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_t1, v_role, 'reports.view');
    insert into cma.user_role (tenant_id, user_id, role_id) values (v_t1, v_reader, v_role);

    -- tenant one's sources (149's fixture): a CRM, two stores with a subscriptions connection each, a register
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency, sort_order) values
      (v_t1, 'GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', 10), (v_t1, 'NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', 20);
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifycrm', 'Verify CRM', 'portal-1', 'crm') returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyshop', 'Verify shop GB', 'shop-gb.shop.example', 'commerce') returning id into v_gb;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyshop', 'Verify shop NL', 'shop-nl.shop.example', 'commerce') returning id into v_nl;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t1, 'verifysubs', 'Verify subscriptions GB', 'shop-gb.shop.example', 'subscriptions', 'verify-subs-gb') returning id into v_sgb;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t1, 'verifysubs', 'Verify subscriptions NL', 'shop-nl.shop.example', 'subscriptions', 'verify-subs-nl') returning id into v_snl;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyregister', 'Verify register', 'base-1', 'assets') returning id into v_reg;
    insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone) values
      (v_t1, v_gb, 'shop-gb', 'Shop GB', 'GB', 'GBP', 'Europe/London'), (v_t1, v_nl, 'shop-nl', 'Shop NL', 'NL', 'EUR', 'Europe/Amsterdam');
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, amount_per_cycle, currency,
                                  billing_interval, billing_interval_count, paused_at, source_created_at) values
      (v_t1, v_sgb, 'verifysubs', 's-1', 'cu-1', 'active', 20.00, 'GBP', 'month', 1, null, '2025-10-30 09:00 Europe/Amsterdam'),
      (v_t1, v_sgb, 'verifysubs', 's-2', 'cu-2', 'active', 20.00, 'GBP', 'month', 1, null, '2025-10-31 00:30 Europe/Amsterdam'),
      (v_t1, v_sgb, 'verifysubs', 's-3', 'cu-3', 'active', 20.00, 'GBP', 'month', 1, null, null),
      (v_t1, v_sgb, 'verifysubs', 's-5', 'cu-4', 'paused', 20.00, 'GBP', 'month', 1, now(), '2024-01-01 12:00 Europe/Amsterdam'),
      (v_t1, v_sgb, 'verifysubs', 's-6', 'cu-5', 'canceled', 20.00, 'GBP', 'month', 1, null, '2024-01-01 12:00 Europe/Amsterdam'),
      (v_t1, v_sgb, 'verifysubs', 's-7', 'cu-1', 'failed', 20.00, 'GBP', 'month', 1, null, '2025-06-15 12:00 Europe/Amsterdam'),
      (v_t1, v_snl, 'verifysubs', 'n-1', 'ncu-1', 'active', 30.00, 'EUR', 'month', 1, null, '2024-04-30 12:00 Europe/Amsterdam');
    -- the register: two models, two tracked statuses and an untracked one in the field; devices on every subscription, one
    -- on an id no subscription has, three without a reference (one of them in stock, one in the untracked field status),
    -- two sharing a serial, one without a serial
    insert into cma.device_model (tenant_id, key, name, sort_order) values (v_t1, 'm1', 'M1', 10), (v_t1, 'm2', 'M2', 20);
    insert into cma.device_status (tenant_id, key, name, is_in_field, is_in_stock, is_tracked, aliases) values
      (v_t1, 'field', 'Field', true, false, true, array['field']), (v_t1, 'stock', 'Stock', false, true, true, array['stock']),
      (v_t1, 'loan', 'Loan', true, false, false, array['loan']);
    insert into cma.device_component_kind (tenant_id, key, name, sort_order) values (v_t1, 'pads', 'Pads', 10), (v_t1, 'battery', 'Battery', 20);
    insert into cma.maintenance_rule (tenant_id, model_key, component_key, interval_months, lead_days) values
      (v_t1, 'm1', 'pads', 24, 60), (v_t1, 'm1', 'battery', 54, 60), (v_t1, 'm2', 'pads', 24, 60), (v_t1, 'm2', 'battery', 54, 60);
    insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key, subscription_ref)
    select v_t1, v_reg, 'verifyregister', x.rec, x.sn, x.model, x.market, x.st, x.ref
    from (values ('d-1', 'SN-d-1', 'm1', 'GB', 'field', 's-1'), ('d-2', 'SN-d-2', 'm2', 'GB', 'field', 's-1'), ('d-3', 'SN-d-3', 'm1', 'GB', 'stock', 's-1'),
                 ('d-4', 'SN-d-4', 'm2', 'GB', 'field', 's-2'), ('d-5', 'SN-d-5', 'm1', 'GB', 'field', 's-3'), ('d-8', 'SN-d-8', 'm1', 'GB', 'field', 's-5'),
                 ('d-9', 'SN-d-9', 'm2', 'GB', 'field', 's-6'), ('d-10', 'SN-d-10', 'm1', 'GB', 'field', 'nope'), ('d-11', 'SN-d-11', 'm2', 'GB', 'field', null),
                 ('d-12', 'SN-d-12', 'm1', 'GB', 'stock', null), ('d-13', 'SN-d-13', 'm1', 'GB', 'field', 's-7'), ('d-14', 'SN-d-1', 'm2', 'NL', 'loan', null),
                 ('nd-1', 'SN-nd-1', 'm2', 'NL', 'field', 'n-1'), ('nd-2', null, 'm1', 'NL', 'field', 's-1')) as x(rec, sn, model, market, st, ref);
    -- past due: d-1's pads and battery both expired, d-2's pads: two devices past due, three items past due
    select x.id into v_d1 from cma.device x where x.tenant_id = v_t1 and x.source_id = 'd-1';
    select x.id into v_d2 from cma.device x where x.tenant_id = v_t1 and x.source_id = 'd-2';
    insert into cma.device_component (tenant_id, device_id, component_key, serial, expires_on) values
      (v_t1, v_d1, 'pads', 'P-1', '2020-01-01'), (v_t1, v_d1, 'battery', 'B-1', '2020-01-01'), (v_t1, v_d2, 'pads', 'P-2', '2020-01-01');
    -- the CRM's catalogs (D9)
    insert into cma.connection_pipeline (tenant_id, connection_id, record_type, source_pipeline_id, label, is_counted) values (v_t1, v_crm, 'deal', 'pl-1', 'Sales', true);
    insert into cma.connection_stage (tenant_id, connection_id, record_type, source_pipeline_id, source_stage_id, label, is_closed) values (v_t1, v_crm, 'deal', 'pl-1', 'st-1', 'New', false);
    insert into cma.connection_task_status (tenant_id, connection_id, status_ref, label, is_done) values (v_t1, v_crm, 'NOT_STARTED', 'Not started', false);
    insert into cma.connection_task_type (tenant_id, connection_id, type_ref, label, is_counted) values (v_t1, v_crm, 'CALL', 'Call', true);
    -- tenant two: a register of its own with a device that carries tenant one's serial, in the field without a reference
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency, sort_order) values (v_t2, 'GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', 10);
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t2, 'verifyregister', 'Verify register two', 'base-2', 'assets') returning id into v_reg2;
    insert into cma.device_model (tenant_id, key, name, sort_order) values (v_t2, 'm1', 'M1', 10);
    insert into cma.device_status (tenant_id, key, name, is_in_field, is_in_stock, is_tracked) values (v_t2, 'field', 'Field', true, false, true);
    insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key, subscription_ref)
    values (v_t2, v_reg2, 'verifyregister', 'd-1', 'SN-d-1', 'm1', 'GB', 'field', null);
    v_today := cma.tenant_today_of(v_t1);

    -- A1. D6: the check, the rule and the list are the same devices, in one statement; 136's definition finds them too
    select pg_temp.v0009f_ids(array(select q.object_id from cma.data_quality_of(v_t1) q where q.check_key = 'field_device_without_subscription_ref'
                                     order by q.object_id offset case when v_provoke then 1 else 0 end)),
           pg_temp.v0009f_ids(array(select u.source_id from cma.field_devices_without_subscription_ref_of(v_t1) u)),
           pg_temp.v0009f_ids(array(select x ->> 'device_id' from jsonb_array_elements(
             cma.flash_rows_of(v_t1, 'installed_base', '{"without_subscription_ref": "true"}', 'serial', false, 500, 0, null, null) -> 'rows') x)),
           pg_temp.v0009f_ids(array(select q.object_id from pg_temp.v0009f_dq_0008zt(v_t1) q where q.check_key = 'field_device_without_subscription_ref')),
           (cma.flash_rows_of(v_t1, 'installed_base', '{"without_subscription_ref": "true"}', 'serial', false, 500, 0, null, null) ->> 'total')::integer
    into v_check, v_rule, v_list, v_old, v_n;
    v_rows := v_rows || array['11', 'A1 D6: the check field_device_without_subscription_ref, the rule''s function and the list without a subscription reference are the same devices (in one statement); 136''s definition finds them; the list''s count is theirs',
      case when v_check = v_rule and v_rule = v_list and v_list = v_old and v_check = 'd-11,d-14' and v_n = 2 then 'ok' else 'FAIL' end,
      'check ' || v_check || ' | rule ' || v_rule || ' | list ' || v_list || ' | 136 ' || v_old || ' | total ' || v_n];

    -- A2. D7: the serial search
    v_bad := '';
    foreach k in array array['SN-d-1', '  sn-d-1 ', 'SN-D-2', 'SN-nd-1', 'SN-none', 'SN-d-1 x'] loop
      v_new := cma.flash_rows_of(v_t1, 'installed_base', jsonb_build_object('serial', k), 'serial', false, 500, 0, null, null);
      v_bad := v_bad || k || '=' || coalesce((select string_agg(x ->> 'device_id', '+' order by x ->> 'device_id' collate "C") from jsonb_array_elements(v_new -> 'rows') x), '-')
               || '/' || (v_new ->> 'total') || '; ';
    end loop;
    -- the search's rows are the records list's rows for those devices (the same object: every column)
    v_txt := case when (cma.flash_rows_of(v_t1, 'installed_base', '{"serial": "SN-d-2"}', 'serial', false, 500, 0, null, null) -> 'rows' -> 0)
                       = (select x from jsonb_array_elements(cma.flash_rows_of(v_t1, 'installed_base', '{}', 'serial', false, 500, 0, null, null) -> 'rows') x where x ->> 'device_id' = 'd-2')
                  then 'same row' else 'another row' end;
    v_rows := v_rows || array['12', 'A2 D7: the serial search is exact, trimmed and case-insensitive, finds every device with the serial (two share SN-d-1), none for an unknown one, nothing of another tenant; its rows are the records list''s',
      case when v_bad = 'SN-d-1=d-1+d-14/2;   sn-d-1 =d-1+d-14/2; SN-D-2=d-2/1; SN-nd-1=nd-1/1; SN-none=-/0; SN-d-1 x=-/0; ' and v_txt = 'same row' and not v_provoke
           then 'ok' else 'FAIL' end, v_bad || v_txt];

    -- A3. the filters on every part: the list's total per filter equals the take's rows summed (one statement each)
    v_bad := ''; v_n := 0;
    for o in select x.market, x.status, x.model from (
               select d.market, null::text as status, null::text as model from cma.device d where d.tenant_id = v_t1 group by 1
               union all select null, st.key, null from cma.device_status st where st.tenant_id = v_t1
               union all select null, null, m.key from cma.device_model m where m.tenant_id = v_t1
               union all select null, 'field', 'm2' union all select 'GB', 'field', 'm1' union all select null, 'unknown', null) x loop
      f := jsonb_strip_nulls(jsonb_build_object('market', o.market, 'status', o.status, 'model', o.model));
      select (cma.flash_rows_of(v_t1, 'installed_base', f, 'serial', false, 500, 0, null, null) ->> 'total')::integer,
             coalesce((select sum((c.measures ->> 'devices')::integer) from cma.flash_compute_of(v_t1, 'installed_base') c
                       where c.dims ? 'status' and (o.market is null or c.dims ->> 'market' = o.market)
                         and (o.status is null or c.dims ->> 'status' = o.status) and (o.model is null or c.dims ->> 'model' = o.model)), 0)
      into v_m, v_before;
      v_n := v_n + 1;
      if v_m <> v_before or (v_provoke and v_n = 1) then v_bad := v_bad || f::text || ' list ' || v_m || ' take ' || v_before || '; '; end if;
    end loop;
    -- the devices past due (a count of devices) against the items past due (the tile's count of items)
    select (cma.flash_rows_of(v_t1, 'installed_base', '{"measure": "components_past_due"}', 'serial', false, 500, 0, null, null) ->> 'total')::integer,
           (select (c.measures ->> 'components_past_due')::integer from cma.flash_compute_of(v_t1, 'installed_base') c where c.dims = '{}'::jsonb)
    into v_m, v_before;
    v_rows := v_rows || array['13', 'A3 every filter narrows the list as it narrows the take''s rows (market, status, model, two together, unknown; the list''s total is the rows'' devices summed); the devices past due (2) differ from the items past due (3)',
      case when v_bad = '' and v_n >= 8 and v_m = 2 and v_before = 3 and not v_provoke then 'ok' else 'FAIL' end,
      coalesce(nullif(left(v_bad, 500), ''), v_n || ' filters equal; devices past due ' || v_m || ', items ' || v_before)];

    -- A4. the remade functions as before; the new keys taken and refused where they must be
    v_bad := ''; v_n := 0;
    foreach f in array array['{}', '{"market": "GB"}', '{"model": "m2"}', '{"link": "linked"}', '{"status": "stock"}', '{"subscription_status": "active"}',
                             '{"measure": "in_field"}', '{"measure": "components_past_due", "market": "GB"}']::jsonb[] loop
      foreach s in array array['serial', 'next_due_on'] loop
        foreach d in array array[false, true] loop
          foreach pg slice 1 in array array[[500, 0], [3, 2]] loop
            select cma.flash_rows_of(v_t1, 'installed_base', f, s, d, pg[1], pg[2], null, null), pg_temp.v0009f_rows_of_0008zz(v_t1, 'installed_base', f, s, d, pg[1], pg[2], null, null)
            into v_new, v_old_j;
            v_n := v_n + 1;
            if v_new is distinct from v_old_j then v_bad := v_bad || f::text || ' ' || s || ' ' || d || ' ' || pg[1] || '/' || pg[2] || '; '; end if;
          end loop;
        end loop;
      end loop;
    end loop;
    for o in select x.key, x.kind from cma.flash_overviews() x where x.key <> 'installed_base' order by x.sort_order loop
      select cma.flash_rows_of(v_t1, o.key, '{}', (select x.sorts[1] from cma.flash_overviews() x where x.key = o.key), false, 500, 0,
                               case when o.kind = 'flow' then v_today - 40 end, case when o.kind = 'flow' then v_today end),
             pg_temp.v0009f_rows_of_0008zz(v_t1, o.key, '{}', (select x.sorts[1] from cma.flash_overviews() x where x.key = o.key), false, 500, 0,
                                           case when o.kind = 'flow' then v_today - 40 end, case when o.kind = 'flow' then v_today end)
      into v_new, v_old_j;
      if v_new is distinct from v_old_j then v_bad := v_bad || o.key || '; '; end if;
    end loop;
    -- data quality, check by check, in one statement
    select string_agg(x.check_key, ', ' order by x.check_key) into v_txt
    from (select coalesce(a.check_key, b.check_key) as check_key
          from (select q.check_key, pg_temp.v0009f_ids(array_agg(q.object_type || ':' || q.object_id || ':' || coalesce(q.value, ''))) as ids
                from cma.data_quality_of(v_t1) q group by q.check_key) a
          full join (select q.check_key, pg_temp.v0009f_ids(array_agg(q.object_type || ':' || q.object_id || ':' || coalesce(q.value, ''))) as ids
                     from pg_temp.v0009f_dq_0008zt(v_t1) q group by q.check_key) b on b.check_key = a.check_key
          where a.ids is distinct from b.ids) x;
    if v_txt is not null then v_bad := v_bad || 'data quality: ' || v_txt || '; '; end if;
    -- as the reader: the wrapper as 148's for the old calls; the new keys taken, and refused where they must be
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_reader::text, true);
    select cma.flash_rows('installed_base'), pg_temp.v0009f_rows_0008zz('installed_base') into v_new, v_old_j;
    if v_new is distinct from v_old_j then v_bad := v_bad || 'flash_rows; '; end if;
    select cma.flash_rows('installed_base', '{"market": "GB", "measure": "in_field"}', 'next_due_on', true, 4, 2),
           pg_temp.v0009f_rows_0008zz('installed_base', '{"market": "GB", "measure": "in_field"}', 'next_due_on', true, 4, 2) into v_new, v_old_j;
    if v_new is distinct from v_old_j then v_bad := v_bad || 'flash_rows GB; '; end if;
    v_txt := pg_temp.v0009f_code('select cma.flash_rows(''installed_base'', ''{"serial": "SN-d-1"}'')')
             || ' ' || pg_temp.v0009f_code('select cma.flash_rows(''installed_base'', ''{"without_subscription_ref": "true"}'')')
             || ' ' || pg_temp.v0009f_code('select cma.flash_rows(''installed_base'', ''{"without_subscription_ref": "yes"}'')')
             || ' ' || pg_temp.v0009f_code('select cma.flash_rows(''customers'', ''{"serial": "SN-d-1"}'')')
             || ' ' || pg_temp.v0009f_code('select cma.flash_rows(''installed_base'', ''{"nope": "x"}'')')
             || ' ' || pg_temp.v0009f_code(format('select cma.flash_rows(''installed_base'', ''{"serial": "SN-d-1"}'', null, false, 500, 0, %L)', (date_trunc('month', v_today) - interval '1 day')::date))
             || ' | ' || pg_temp.v0009f_code('select cma.flash_file_record(''installed_base'', ''rows'', ''{"serial": "SN-d-1", "without_subscription_ref": "true"}'', null, null, null, null, 2)')
             || ' ' || pg_temp.v0009f_code('select cma.flash_file_record(''installed_base'', ''rows'', ''{"without_subscription_ref": "yes"}'', null, null, null, null, 0)')
             || ' ' || pg_temp.v0009f_code('select cma.flash_file_record(''customers'', ''rows'', ''{"serial": "x"}'', null, null, null, null, 0)')
             || ' ' || pg_temp.v0009f_code('select cma.flash_file_record(''installed_base'', ''rows'', ''{"nope": "x"}'', null, null, null, null, 0)');
    select count(*) into v_m from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'flash_file' and a.new_row -> 'filters' ? 'serial';
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['14', 'A4 the remade functions answer as before: the list 148''s over a grid and every other overview, cma.flash_rows 148''s, data quality 136''s check by check; the new keys taken by the list and the file record, refused when not "true", on another overview, unknown or on a month end''s list',
      case when v_bad = '' and v_n = 64 and v_txt = 'ok ok CMA04 CMA04 CMA04 CMA04 | ok CMA04 CMA04 CMA04' and v_m = 1 and not v_provoke then 'ok' else 'FAIL' end,
      coalesce(nullif(left(v_bad, 400), ''), v_n || ' lists equal; ' || v_txt || '; ' || v_m || ' file record')];

    -- A5. D9: both tenants' takes refreshed (as their scheduler, the owner's writer), then catalog changes on tenant one
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t1, 'flash.current_overviews', 'installed_base,open_deals,open_tickets,open_tasks');
    -- the additions recorded in the last day (160 just before this script) moved a day back inside this rolled-back block,
    -- so a take is not older than the latest migration (159's rule)
    update cma.schema_migration set applied_at = applied_at - interval '1 day' where applied_at > now() - interval '1 day';
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_sched2::text, true);
    perform cma.flash_current_refresh_of(v_t2, 'installed_base', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_sched1::text, true);
    v_txt := '';
    -- each step: the take refreshed, the change, then whether tenant one's take is there (1) or gone (0), and tenant two's
    foreach k in array array[
      'update cma.device_status set name = $3, aliases = array[$4, $5] where tenant_id = $1 and key = $4',
      'update cma.device_status set is_in_field = false where tenant_id = $1 and key = $6',
      'insert into cma.device_status (tenant_id, key, name, is_in_field, is_in_stock, is_tracked, aliases, sort_order) values ($1, $7, $8, false, false, true, array[$9], 15)',
      'update cma.device_component_kind set status = $10 where tenant_id = $1 and key = $11',
      'insert into cma.maintenance_rule (tenant_id, model_key, component_key, interval_months, lead_days) values ($1, $12, $11, 48, 30) on conflict (tenant_id, model_key, component_key) do update set interval_months = 48',
      'update cma.maintenance_rule set lead_days = 90 where tenant_id = $1 and model_key = $13 and component_key = $14',
      'update cma.maintenance_rule set lead_days = lead_days where tenant_id = $1 and model_key = $13 and component_key = $14',
      'update cma.connection_pipeline set label = $15, refreshed_at = now() where tenant_id = $1 and source_pipeline_id = $16',
      'insert into cma.connection_pipeline (tenant_id, connection_id, record_type, source_pipeline_id, label, is_counted) values ($1, $2, $17, $18, $19, false)',
      'update cma.connection_stage set is_closed = true where tenant_id = $1 and source_stage_id = $20',
      'update cma.connection_task_status set is_done = true where tenant_id = $1 and status_ref = $21',
      'update cma.connection_task_type set is_counted = false where tenant_id = $1 and type_ref = $22'
    ] loop
      perform cma.flash_current_refresh_of(v_t1, 'installed_base', true);
      execute k using v_t1, v_crm, 'Field devices', 'field', 'at customer', 'loan', 'in_transit', 'In Transit', 'in transit', 'inactive', 'battery', 'm2',
                      'm1', 'pads', 'Sales pipeline', 'pl-1', 'deal', 'pl-2', 'Invest', 'st-1', 'NOT_STARTED', 'CALL';
      select count(distinct c.overview) filter (where c.tenant_id = v_t1), count(*) filter (where c.tenant_id = v_t2) into v_n, v_m from cma.flash_current_take c;
      v_txt := v_txt || v_n || '/' || case when v_m > 0 then 1 else 0 end || ' ';
    end loop;
    -- tenant two's take is the one it had: untouched by every change of tenant one
    select max(c.computed_at) into v_t2_at from cma.flash_current_take c where c.tenant_id = v_t2;
    v_rows := v_rows || array['15', 'A5 D9: a catalog change the take reads forgets the tenant''s takes (a status flag, a status inserted, a kind''s status, a rule inserted and changed, a pipeline inserted, a stage closed, a task status done, a task type uncounted); a change it does not read keeps them (a status''s name and aliases, a rule written unchanged, a pipeline''s label); the other tenant''s take stays',
      case when v_txt = '1/1 0/1 0/1 0/1 0/1 0/1 1/1 1/1 0/1 0/1 0/1 0/1 ' and v_t2_at is not null and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['29', 'A the block ran to the end', 'FAIL', sqlstate || ' ' || sqlerrm];
  end;
  perform set_config('role', 'cma_owner', true);
  insert into verify_0009f select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if not exists (select 1 from verify_0009f where ord between 11 and 29) then
    insert into verify_0009f values (29, 'A the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- D. Every active tenant, read only (as the owner, the tenant named on every read), each comparison in one statement
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  t record;
  v_check text; v_list text; v_txt text;
  v_bad1 text := ''; v_bad2 text := '';
  v_tenants integer := 0; v_assets integer := 0; v_devices bigint := 0;
begin
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
    v_tenants := v_tenants + 1;
    -- D1. the list without a subscription reference and the check, where the register is set up
    if coalesce(cma.flash_source_set_up_of(t.id, 'assets'), false) then
      v_assets := v_assets + 1;
      select pg_temp.v0009f_ids(array(select q.object_id from cma.data_quality_of(t.id) q where q.check_key = 'field_device_without_subscription_ref')),
             pg_temp.v0009f_ids(array(select x ->> 'device_id' from jsonb_array_elements(
               cma.flash_rows_of(t.id, 'installed_base', '{"without_subscription_ref": "true"}', 'serial', false, 50000, 0, null, null) -> 'rows') x))
      into v_check, v_list;
      v_devices := v_devices + coalesce(array_length(string_to_array(nullif(v_list, ''), ','), 1), 0);
      if v_check <> v_list then v_bad1 := v_bad1 || t.slug || ': check ' || left(v_check, 120) || ' list ' || left(v_list, 120) || '; '; end if;
    end if;
    -- D2. data quality as 136's, check by check
    select string_agg(x.check_key, ', ' order by x.check_key) into v_txt
    from (select coalesce(a.check_key, b.check_key) as check_key
          from (select q.check_key, pg_temp.v0009f_ids(array_agg(q.object_type || ':' || q.object_id || ':' || coalesce(q.value, ''))) as ids
                from cma.data_quality_of(t.id) q group by q.check_key) a
          full join (select q.check_key, pg_temp.v0009f_ids(array_agg(q.object_type || ':' || q.object_id || ':' || coalesce(q.value, ''))) as ids
                     from pg_temp.v0009f_dq_0008zt(t.id) q group by q.check_key) b on b.check_key = a.check_key
          where a.ids is distinct from b.ids) x;
    if v_txt is not null then v_bad2 := v_bad2 || t.slug || ': ' || v_txt || '; '; end if;
  end loop;
  insert into verify_0009f values
    (31, 'D1 every active tenant with an asset register: the list without a subscription reference equals the check''s devices, in one statement',
     case when v_provoke then 'FAIL' when v_assets = 0 then 'skip' when v_bad1 = '' then 'ok' else 'FAIL' end,
     case when v_assets = 0 then 'no tenant with an asset register set up' when v_bad1 = '' then v_assets || ' tenant(s), ' || v_devices || ' device(s) without a subscription reference' else left(v_bad1, 600) end),
    (32, 'D2 every active tenant: cma.data_quality_of equals 136''s definition, check by check, in one statement',
     case when v_bad2 = '' and not v_provoke then 'ok' else 'FAIL' end, case when v_bad2 = '' then v_tenants || ' tenant(s)' else left(v_bad2, 600) end);
end
$$;

-- The helpers are dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0009f_ids(text[]);
drop function if exists pg_temp.v0009f_code(text);
drop function if exists pg_temp.v0009f_rows_0008zz(text,jsonb,text,boolean,integer,integer,date,date,date);
drop function if exists pg_temp.v0009f_rows_of_0008zz(uuid,text,jsonb,text,boolean,integer,integer,date,date);
drop function if exists pg_temp.v0009f_dq_0008zt(uuid);

-- Verdict: one row per check, then the verdict: no FAIL, a skip only where the check says why
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0009f
      union all
      select 99, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from verify_0009f where result not in ('ok', 'skip')) then 'FAIL'
                  when (select count(*) from verify_0009f where result = 'ok') >= 9 then '0009f verified'
                  else 'FAIL' end,
             format('161_verify_installed_base_now: %s ok, %s FAIL, %s skip', (select count(*) from verify_0009f where result = 'ok'),
                    (select count(*) from verify_0009f where result not in ('ok', 'skip')),
                    (select count(*) from verify_0009f where result = 'skip'))) x
order by ord;
drop table if exists pg_temp.verify_0009f;
reset role;
