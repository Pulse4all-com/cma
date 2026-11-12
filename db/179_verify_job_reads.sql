-- =============================================================================================
-- 179_verify_job_reads.sql: verifies addition 0009o, the minute jobs' reads without per-row lookups, the follow-up's
-- change detection and the data-quality back-off (12 November 2026)
-- =============================================================================================
-- Universal: no seed is assumed. Block S checks structure, privileges, settings and the follow-up's list of input tables;
-- block E proves every rewritten read answers exactly what it did, on the database it runs in (the volume fixture
-- locally, the seeds, dev's and prod's own data): the previous definition of each function is kept here, as a temporary
-- function (pg_temp.old_ in place of cma., copied verbatim from 132, 40, 72, 160 and 154), and the two are compared row
-- for row, and in order where the function orders, for every tenant, as the application acting for the tenant
-- (row-level security); the business-time functions are compared with their _of originals on every market of every
-- tenant over a grid of instants. Block A works on a throwaway tenant inside a subtransaction that is always rolled back,
-- so nothing stays and the script runs in dev and in prod. Every check writes one row, ok or FAIL, and the last row is the
-- verdict, because Cloud SQL Studio shows no notices. Run as your own IAM login after 178_job_reads.sql, dev first, then
-- prod.
-- Expected verdict, in dev and in prod: "0009o verified | 179_verify_job_reads: <n> ok, 0 FAIL, <k> skip" (a tenant
-- without data reads ok on empty sets); provoked (verify.provoke true at the top): every E row reads FAIL (the previous
-- definition's first row is dropped before the comparison, or the row says the set was empty), every S and A row reads
-- FAIL, and the verdict PROVOKED, NOT A PASS.
--   S  S1 the addition row after 0009n; S2 cma.follow_up_marker's columns, row-level security, the policy, the
--      application's grants, no audit trigger; S3 the setting follow_up.recompute_minutes (60); S4 jit off on the three
--      functions that carried it, rows 20 on the calendar, custom plans on the two job entries; S5 the new and re-created functions executable by the
--      application and not by public; S6 the input tables: every tenant table the follow-up's functions read (derived
--      from their bodies, recursively) is in cma.follow_up_input_tables(), and each has its audit trigger enabled
--   E  per tenant: E1 open_tickets_of, E2 open_leads_of (in order), E3 speed_to_lead_of unbounded and E4 over the previous
--      month, E5 data_quality_of, E6 flash_findings_compute_of (as sets: it has no order by, so ties may fall either way);
--      each old copy calls the new functions below it, so equality is proved layer by layer; E7 business_seconds_in, business_days_in and
--      next_business_noon_in against their _of originals on every market; E8 the follow-up refresh: after the previous
--      definition's full rewrite the new one writes nothing and leaves the same items and snapshot; with items removed
--      and one changed it writes exactly those back
--   A  a throwaway tenant: A1 the business-time functions on a crafted calendar (a split day, a market's own hours and
--      '*', holidays of the market and of '*', both DST changes, an unknown market, to before from); A2 the setting's
--      range; A3 the job's entry: unchanged without an input change (a non-input table written meanwhile), computes after
--      an input change, after follow_up.recompute_minutes, when the next clock change is reached; A4 the next clock
--      change; A5 the data-quality back-off: a failed computation with no result since waits, a failure of another job
--      does not; A6 0009l to 0009n's settings still behave beside this change's: cma.tenant_setting keeps its triggers
--      (cma.check_tenant_setting as 172 made it, 0009l's take marker, this change's range check), active.present_source
--      takes live or take and refuses another word, customers.refresh_minutes takes a whole number and refuses a word,
--      customers.cohort_ages_months refuses a decreasing list, all with CMA04 (their own verifies, 173, 175 and 177,
--      rerun after 178, prove the rest)
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);                 -- 'true' to make every check fail

drop table if exists pg_temp.verify_0009o;
create temporary table verify_0009o (ord integer, check_name text, result text, detail text);
grant select, insert on pg_temp.verify_0009o to cma_app;

-- The previous definitions, verbatim, under pg_temp.old_
-- open_tickets_of as 132 defined it
create or replace function pg_temp.old_open_tickets_of(p_tenant_id uuid)
returns setof cma.open_ticket_row
language sql stable
as $$
  with s as (
    select greatest(1, cma.setting_of(p_tenant_id, 'tickets.sla_minutes')::integer) as sla_default,
           least(100, greatest(0, cma.setting_of(p_tenant_id, 'tickets.sla_warning_pct')::integer)) as warn_pct
  ),
  codes as materialized (
    select * from cma.market_codes_of(p_tenant_id)
  ),
  k as (
    select r.id, r.connection_id, r.source_system, r.source_id, r.pipeline_id, coalesce(p.label, r.pipeline_id) as pipeline_label,
           r.stage_id, coalesce(st.label, r.stage_id) as stage_label, r.owner_ref, r.source_created_at,
           coalesce(p.sla_minutes, (select s.sla_default from s)) as sla, (select s.warn_pct from s) as warn_pct, coalesce(cr.code, cc.code, 'unknown') as market,
           ow.user_id as owner_user_id
    from cma.crm_record r
    left join cma.connection_pipeline p
      on p.tenant_id = r.tenant_id and p.connection_id = r.connection_id and p.record_type = r.record_type and p.source_pipeline_id = r.pipeline_id
    left join cma.connection_stage st
      on st.tenant_id = r.tenant_id and st.connection_id = r.connection_id and st.record_type = r.record_type
     and st.source_pipeline_id = r.pipeline_id and st.source_stage_id = r.stage_id
    left join codes cr on cr.value = r.market
    left join cma.crm_contact kc on kc.tenant_id = r.tenant_id and kc.connection_id = r.connection_id and kc.source_id = r.contact_source_id
    left join codes cc on cc.value = kc.country
    left join cma.app_user_external_id ow
      on ow.tenant_id = r.tenant_id and ow.system = r.source_system || '_owner' and ow.external_id = r.owner_ref
    where r.tenant_id = p_tenant_id and r.record_type = 'ticket' and r.source_deleted_at is null
      and not coalesce(r.is_closed, false) and coalesce(p.is_counted, true)
  ),
  m as (
    select k.*, cma.business_seconds_of(p_tenant_id, nullif(k.market, 'unknown'), k.source_created_at, now()) as open_s from k
  )
  select p_tenant_id, m.id, m.connection_id, m.source_id, m.pipeline_id, m.pipeline_label, m.stage_id, m.stage_label,
         m.owner_user_id, m.owner_ref, m.market, m.source_created_at,
         m.open_s, m.sla,
         case when m.open_s is null then 'no_hours'
              when m.open_s >= m.sla * 60 then 'breached'
              when m.open_s * 100 >= m.sla * 60 * m.warn_pct then 'at_risk'
              else 'ok' end,
         case when m.open_s is null then null else m.sla - floor(m.open_s / 60.0)::integer end
  from m
  order by case when m.open_s is null then 1 else 0 end, (m.sla * 60 - m.open_s), m.source_created_at, m.source_id
$$;

-- speed_to_lead_of as 40 defined it
create or replace function pg_temp.old_speed_to_lead_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns setof cma.speed_to_lead_row
language sql stable
as $$
  with s as (
    select greatest(0, cma.setting_of(p_tenant_id, 'speed_to_lead.pre_window_minutes')::integer) as pre_min,
           cma.setting_of(p_tenant_id, 'speed_to_lead.target_minutes')::integer * 60 as target_s
  ),
  d as materialized (
    select * from cma.lead_deals_of(p_tenant_id, p_from, p_to)
  ),
  c as materialized (
    select d.deal_id, lc.*
    from d cross join s
    cross join lateral cma.lead_calls_of(p_tenant_id, d.connection_id, d.record_type, d.source_id, d.contacts,
                                         d.created_at - make_interval(mins => s.pre_min)) lc
  ),
  fo as (select distinct on (c.deal_id) c.* from c where c.direction = 'outbound' order by c.deal_id, c.effective_at, c.call_id),
  fa as (select distinct on (c.deal_id) c.* from c order by c.deal_id, c.effective_at, c.call_id),
  fc as (select distinct on (c.deal_id) c.* from c where c.is_connected order by c.deal_id, c.effective_at, c.call_id),
  r as (
    select d.*, fo.call_id as fo_id, fo.call_source_id as fo_src, fo.effective_at as fo_at, fo.is_linked as fo_linked,
           fo.owner_ref as fo_owner, fo.source_system as fo_system,
           fa.effective_at as fa_at, fa.direction as fa_dir, fc.effective_at as fc_at,
           s.target_s,
           cma.next_business_noon_of(p_tenant_id, nullif(d.market, 'unknown'), d.created_at) as noon
    from d
    cross join s
    left join fo on fo.deal_id = d.deal_id
    left join fa on fa.deal_id = d.deal_id
    left join fc on fc.deal_id = d.deal_id
  ),
  m as (
    select r.*,
           case when r.fo_at is not null
                then cma.business_seconds_of(p_tenant_id, nullif(r.market, 'unknown'), r.created_at, r.fo_at) end as bs,
           case when r.fo_at is null
                then cma.business_seconds_of(p_tenant_id, nullif(r.market, 'unknown'), r.created_at, now()) end as bs_now,
           ag.user_id as ag_user, ag.ref as ag_ref, ag.src as ag_from
    from r
    left join lateral (
      select x.user_id, x.external_id as ref, x.src
      from (select xi.user_id, xi.external_id, 'call'::text as src, 1 as rank
            from cma.app_user_external_id xi
            where xi.tenant_id = p_tenant_id and xi.system = r.fo_system || '_owner' and xi.external_id = r.fo_owner
            union all
            select xi.user_id, xi.external_id, 'deal', 2
            from cma.app_user_external_id xi
            where xi.tenant_id = p_tenant_id and xi.system = r.source_system || '_owner' and xi.external_id = r.owner_ref) x
      order by x.rank limit 1) ag on true
  )
  select p_tenant_id, m.deal_id, m.connection_id, m.source_id, m.pipeline_id, m.pipeline_label, m.business_date,
         m.created_at, m.market, m.market_source, m.is_closed,
         case when m.fo_at is not null then 'called'
              when m.is_closed then 'not_called_closed' else 'not_called_open' end,
         m.fo_id, m.fo_src, m.fo_at, m.fo_linked, m.fa_at, m.fa_dir,
         coalesce(m.fa_dir = 'inbound', false), m.fc_at,
         m.ag_user, coalesce(m.ag_ref, case when m.fo_at is not null then m.fo_owner else m.owner_ref end),
         coalesce(m.ag_from, case when m.fo_owner is not null and m.fo_at is not null then 'call'
                                  when m.owner_ref is not null then 'deal' end),
         case when m.fo_at is not null then greatest(0, floor(extract(epoch from m.fo_at - m.created_at)))::integer end,
         m.bs, m.target_s,
         case when m.bs is not null then m.bs <= m.target_s
              when m.bs_now > m.target_s then false end,
         m.noon,
         case when m.fo_at is not null and m.noon is not null then m.fo_at < m.noon
              when m.fo_at is null and m.noon is not null and now() >= m.noon then false end,
         case when m.fo_at is null and not m.is_closed then m.bs_now end
  from m
$$;

-- open_leads_of as 72 defined it
create or replace function pg_temp.old_open_leads_of(p_tenant_id uuid)
returns setof cma.open_lead_row
language sql stable
as $$
  with s as (
    select cma.setting_of(p_tenant_id, 'leads.age_buckets_business_days') as edges,
           greatest(0, cma.setting_of(p_tenant_id, 'speed_to_lead.pre_window_minutes')::integer) as pre_min
  ),
  r as (
    select * from cma.speed_to_lead_of(p_tenant_id, null, null) x where x.status = 'not_called_open'
  )
  select p_tenant_id, r.deal_id, r.connection_id, r.deal_source_id, r.pipeline_id, r.pipeline_label,
         r.agent_user_id, r.agent_ref, r.market, r.created_at, r.waiting_business_seconds,
         a.days, b.bucket_from, b.bucket_to,
         case when r.within_target is false then true when r.waiting_business_seconds is null then null else false end,
         lc.last_at,
         case when lc.last_at is not null then floor(extract(epoch from now() - lc.last_at) / 86400)::integer end
  from r
  cross join s
  join cma.lead_deals_of(p_tenant_id, null, null) d on d.deal_id = r.deal_id
  cross join lateral (select cma.business_days_of(p_tenant_id, nullif(r.market, 'unknown'), r.created_at, now()) as days) a
  cross join lateral cma.age_bucket_of(a.days, s.edges) b
  left join lateral (
    select max(c.effective_at) as last_at
    from cma.lead_calls_of(p_tenant_id, d.connection_id, d.record_type, d.source_id, d.contacts, d.created_at - make_interval(mins => s.pre_min)) c) lc on true
  order by r.waiting_business_seconds desc nulls last, r.created_at
$$;

-- data_quality_of as 160 defined it
create or replace function pg_temp.old_data_quality_of(p_tenant_id uuid)
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

-- flash_findings_compute_of as 132 defined it
create or replace function pg_temp.old_flash_findings_compute_of(p_tenant_id uuid)
returns table (check_key text, connection_id uuid, object_type text, object_id text, value text, market text, fix_in text, fix_adapter text)
language sql stable
as $$
  with f as materialized (
    select q.* from cma.data_quality_of(p_tenant_id) q
  ), c as materialized (
    select ic.id, ic.adapter, coalesce(ic.kind, (cma.connection_held_kinds_of(ic.tenant_id, ic.id))[1]) as kind, ic.status
    from cma.integration_connection ic where ic.tenant_id = p_tenant_id
  ), ka as materialized (
    select distinct on (c.kind) c.kind, c.adapter from c where c.status = 'active' and c.kind is not null order by c.kind, c.id
  ), st as materialized (
    select x.connection_id, x.market from cma.commerce_store x where x.tenant_id = p_tenant_id
  ), sm as materialized (
    select * from cma.flash_subscription_stores_of(p_tenant_id)
  )
  select f.check_key, f.connection_id, f.object_type, f.object_id, f.value,
         coalesce(case f.object_type
                    when 'commerce_customer' then st.market
                    when 'subscription' then sm.market
                    when 'market' then f.object_id
                    when 'device' then (select d.market from cma.device d
                                        where d.tenant_id = p_tenant_id and d.connection_id = f.connection_id and d.source_id = f.object_id)
                    when 'contact' then (select cma.market_code_of(p_tenant_id, k.country) from cma.crm_contact k
                                         where k.tenant_id = p_tenant_id and k.connection_id = f.connection_id and k.source_id = f.object_id)
                    when 'form' then (select cf.market from cma.connection_form cf
                                      where cf.tenant_id = p_tenant_id and cf.connection_id = f.connection_id and cf.source_form_id = f.object_id)
                    when 'review_channel' then (select ch.market from cma.review_channel ch
                                                where ch.tenant_id = p_tenant_id and ch.connection_id = f.connection_id and ch.source_id = f.object_id)
                    when 'deal' then (select coalesce(cma.market_code_of(p_tenant_id, r.market), cma.market_code_of(p_tenant_id, rk.country))
                                      from cma.crm_record r
                                      left join cma.crm_contact rk
                                        on rk.tenant_id = r.tenant_id and rk.connection_id = r.connection_id and rk.source_id = r.contact_source_id
                                      where r.tenant_id = p_tenant_id and r.connection_id = f.connection_id and r.record_type = 'deal'
                                        and r.source_id = f.object_id)
                    when 'ticket' then (select coalesce(cma.market_code_of(p_tenant_id, r.market), cma.market_code_of(p_tenant_id, rk.country))
                                        from cma.crm_record r
                                        left join cma.crm_contact rk
                                          on rk.tenant_id = r.tenant_id and rk.connection_id = r.connection_id and rk.source_id = r.contact_source_id
                                        where r.tenant_id = p_tenant_id and r.connection_id = f.connection_id and r.record_type = 'ticket'
                                          and r.source_id = f.object_id) end, 'unknown'),
         x.fix_in,
         case when x.fix_in = 'cma' then null when c1.kind = x.fix_in then c1.adapter else ka.adapter end
  from f
  cross join lateral (select cma.data_quality_fix_in(f.check_key, f.value) as fix_in) x
  left join c c1 on c1.id = f.connection_id
  left join ka on ka.kind = x.fix_in
  left join st on f.object_type = 'commerce_customer' and st.connection_id = f.connection_id
  left join sm on f.object_type = 'subscription' and sm.connection_id = f.connection_id
$$;

-- refresh_follow_up_of as 154 defined it
create or replace function pg_temp.old_refresh_follow_up_of(p_tenant_id uuid, p_wait boolean default false)
returns jsonb
language plpgsql
as $$
declare
  v_t0      timestamptz := clock_timestamp();
  v_leads   integer;
  v_tickets integer;
  v_tasks   integer;
  v_ms      integer;
  v_summary jsonb;
  v_owners  jsonb;
  v_courtesy integer;
begin
  if p_tenant_id is null or p_tenant_id is distinct from cma.current_tenant_id() then
    raise exception 'the follow-up snapshot is refreshed for the current tenant only' using errcode = 'CMA06';
  end if;
  if coalesce(p_wait, false) then
    perform pg_advisory_xact_lock(cma.follow_up_lock_key(p_tenant_id));
    if exists (select 1 from cma.follow_up_snapshot s where s.tenant_id = p_tenant_id) then
      return jsonb_build_object('refreshed', false, 'reason', 'present');
    end if;
  elsif not pg_try_advisory_xact_lock(cma.follow_up_lock_key(p_tenant_id)) then
    return jsonb_build_object('refreshed', false, 'reason', 'running');
  end if;

  delete from cma.follow_up_item i where i.tenant_id = p_tenant_id;
  insert into cma.follow_up_item (tenant_id, kind, sort_key, item_id, market, owner_user_id, state, row)
  select p_tenant_id, 'lead', o.ordinality, o.deal_id, coalesce(nullif(o.market, ''), 'unknown'), o.owner_user_id,
         case when o.past_target then 'past_target' when o.past_target is false then 'within_target' else 'no_hours' end,
         to_jsonb(o) - 'tenant_id' - 'ordinality'
  from cma.open_leads_of(p_tenant_id) with ordinality o;
  get diagnostics v_leads = row_count;
  insert into cma.follow_up_item (tenant_id, kind, sort_key, item_id, market, owner_user_id, state, row)
  select p_tenant_id, 'ticket', o.ordinality, o.ticket_id, coalesce(nullif(o.market, ''), 'unknown'), o.owner_user_id, o.sla_state,
         to_jsonb(o) - 'tenant_id' - 'ordinality'
  from cma.open_tickets_of(p_tenant_id) with ordinality o;
  get diagnostics v_tickets = row_count;
  insert into cma.follow_up_item (tenant_id, kind, sort_key, item_id, market, owner_user_id, state, row)
  select p_tenant_id, 'task', o.ordinality, o.task_id, coalesce(nullif(o.market, ''), 'unknown'), o.owner_user_id, o.due_state,
         to_jsonb(o) - 'tenant_id' - 'ordinality'
  from cma.open_tasks_of(p_tenant_id) with ordinality o;
  get diagnostics v_tasks = row_count;

  -- The counts and the figures per person from the items just written, as follow_up_summary_of and
  -- follow_up_by_owner_of compute them from the live sets (a person with only later tasks has a row of zeros)
  select jsonb_build_object(
           'leads_open_not_called', count(*) filter (where i.kind = 'lead'),
           'leads_past_target', count(*) filter (where i.kind = 'lead' and i.state = 'past_target'),
           'tickets_at_risk', count(*) filter (where i.kind = 'ticket' and i.state = 'at_risk'),
           'tickets_breached', count(*) filter (where i.kind = 'ticket' and i.state = 'breached'),
           'tickets_without_owner', count(*) filter (where i.kind = 'ticket' and i.row ->> 'owner_ref' is null),
           'tasks_overdue', count(*) filter (where i.kind = 'task' and i.state = 'overdue'),
           'tasks_due_today', count(*) filter (where i.kind = 'task' and i.state = 'today'),
           'tasks_unmapped_owner', count(*) filter (where i.kind = 'task' and i.row ->> 'owner_ref' is not null and i.owner_user_id is null))
    into v_summary
  from cma.follow_up_item i where i.tenant_id = p_tenant_id;
  -- the courtesy flag (0009a, renamed in 0009c): the courtesy orders Unreachable now and the attempts since due that flag one, both null while
  -- courtesy.start_date is unset, so Welcome's Needs attention reads them with the summary
  v_courtesy := cma.courtesy_unreachable_of(p_tenant_id, now());
  v_summary := v_summary || jsonb_build_object(
    'courtesy_unreachable', v_courtesy,
    'courtesy_alert_attempts', case when v_courtesy is not null then cma.setting_of(p_tenant_id, 'courtesy.alert_attempts')::integer end);
  select coalesce(jsonb_agg(jsonb_build_object(
           'owner_user_id', g.uid, 'open_leads', g.leads, 'leads_past_target', g.past, 'open_tickets', g.tickets,
           'tickets_at_risk_or_breached', g.risk, 'tasks_overdue', g.overdue, 'tasks_due_today', g.today) order by g.uid nulls last), '[]'::jsonb)
    into v_owners
  from (select i.owner_user_id as uid,
               count(*) filter (where i.kind = 'lead') as leads,
               count(*) filter (where i.kind = 'lead' and i.state = 'past_target') as past,
               count(*) filter (where i.kind = 'ticket') as tickets,
               count(*) filter (where i.kind = 'ticket' and i.state in ('at_risk', 'breached')) as risk,
               count(*) filter (where i.kind = 'task' and i.state = 'overdue') as overdue,
               count(*) filter (where i.kind = 'task' and i.state = 'today') as today
        from cma.follow_up_item i where i.tenant_id = p_tenant_id
        group by i.owner_user_id) g;

  v_ms := floor(extract(epoch from clock_timestamp() - v_t0) * 1000)::integer;
  insert into cma.follow_up_snapshot (tenant_id, computed_at, duration_ms, summary, by_owner)
  values (p_tenant_id, now(), v_ms, v_summary, v_owners)
  on conflict (tenant_id) do update
    set computed_at = excluded.computed_at, duration_ms = excluded.duration_ms, summary = excluded.summary, by_owner = excluded.by_owner;
  return jsonb_build_object('refreshed', true, 'leads', v_leads, 'tickets', v_tickets, 'tasks', v_tasks,
                            'rows', v_leads + v_tickets + v_tasks, 'duration_ms', v_ms, 'computed_at', now());
end
$$;

-- refresh_data_quality_of as 132 defined it
create or replace function pg_temp.old_refresh_data_quality_of(p_tenant_id uuid, p_wait boolean default false)
returns jsonb
language plpgsql
as $$
declare
  v_t0   timestamptz := clock_timestamp();
  v_rows integer;
  v_ms   integer;
  v_age  interval;
begin
  if p_tenant_id is null or p_tenant_id is distinct from cma.current_tenant_id() then
    raise exception 'the data-quality result is refreshed for the current tenant only' using errcode = 'CMA06';
  end if;
  if coalesce(p_wait, false) then
    perform pg_advisory_xact_lock(cma.data_quality_lock_key(p_tenant_id));
    if exists (select 1 from cma.data_quality_snapshot s where s.tenant_id = p_tenant_id) then
      return jsonb_build_object('refreshed', false, 'reason', 'present');
    end if;
  else
    select now() - s.computed_at into v_age from cma.data_quality_snapshot s where s.tenant_id = p_tenant_id;
    if v_age is not null and v_age < make_interval(mins => cma.setting_of(p_tenant_id, 'data_quality.refresh_minutes')::integer) then
      return jsonb_build_object('refreshed', false, 'reason', 'fresh', 'age_seconds', floor(extract(epoch from v_age))::integer);
    end if;
    if not pg_try_advisory_xact_lock(cma.data_quality_lock_key(p_tenant_id)) then
      return jsonb_build_object('refreshed', false, 'reason', 'running');
    end if;
  end if;

  delete from cma.data_quality_finding f where f.tenant_id = p_tenant_id;
  insert into cma.data_quality_finding (tenant_id, ord, check_key, connection_id, object_type, object_id, value, market, fix_in, fix_adapter)
  select p_tenant_id, x.ordinality, x.check_key, x.connection_id, x.object_type, x.object_id, x.value, x.market, x.fix_in, x.fix_adapter
  from cma.flash_findings_compute_of(p_tenant_id) with ordinality x;
  get diagnostics v_rows = row_count;
  v_ms := floor(extract(epoch from clock_timestamp() - v_t0) * 1000)::integer;
  insert into cma.data_quality_snapshot (tenant_id, computed_at, duration_ms, findings)
  values (p_tenant_id, now(), v_ms, v_rows)
  on conflict (tenant_id) do update set computed_at = excluded.computed_at, duration_ms = excluded.duration_ms, findings = excluded.findings;
  return jsonb_build_object('refreshed', true, 'rows', v_rows, 'duration_ms', v_ms);
end
$$;


-- Two set-returning calls compared: null when they answer the same rows (the same multiset; the same sequence when
-- p_ordered), else what differs; in provoke mode the old side loses its first row, so the comparison must fail (133's)
create or replace function pg_temp.v0009o_diff(p_new text, p_old text, p_ordered boolean)
returns text
language plpgsql
as $$
declare
  v_old text := p_old;
  v_n_new bigint; v_n_old bigint; v_only_new bigint; v_only_old bigint; v_same boolean;
begin
  if current_setting('verify.provoke')::boolean then
    v_old := format('select * from (%s) z offset 1', p_old);
  end if;
  execute format('select count(*) from (%s) a', p_new) into v_n_new;
  execute format('select count(*) from (%s) a', v_old) into v_n_old;
  if current_setting('verify.provoke')::boolean and v_n_new = 0 then
    return 'provoked, but the set is empty: nothing to differ (FAIL by the switch)';
  end if;
  if p_ordered then
    execute format('select (select string_agg(a::text, ''|'' order by a.o) from (select row_number() over () as o, t from (%s) t) a) is not distinct from
                           (select string_agg(b::text, ''|'' order by b.o) from (select row_number() over () as o, t from (%s) t) b)', p_new, v_old) into v_same;
  else
    v_same := true;
  end if;
  execute format('select count(*) from ((%s) except all (%s)) a', p_new, v_old) into v_only_new;
  execute format('select count(*) from ((%s) except all (%s)) a', v_old, p_new) into v_only_old;
  if v_only_new = 0 and v_only_old = 0 and v_same then
    return null;
  end if;
  return format('%s rows now against %s before: %s only now, %s only before%s', v_n_new, v_n_old, v_only_new, v_only_old,
                case when not v_same and v_only_new = 0 and v_only_old = 0 then ', the same rows in another order' else '' end);
end
$$;

-- A check row kept as four texts, for the blocks whose subtransaction is rolled back (their rows must outlive it)
create or replace function pg_temp.v0009o_row(p_ord integer, p_name text, p_result text, p_detail text)
returns text[] language sql immutable as $$ select array[p_ord::text, p_name, p_result, p_detail] $$;

-- The business-time functions against their originals for one tenant and market over a grid of instants: the pairs
-- where they differ, counted, and the first such pair; p_market null or a code without a market gives the null cases
create or replace function pg_temp.v0009o_hours(p_tenant uuid, p_market text, p_from timestamptz[], p_to timestamptz[])
returns text
language plpgsql
as $$
declare
  c record; n_s integer := 0; n_d integer := 0; n_n integer := 0; v_pairs integer := 0; v_first text;
  a timestamptz; b timestamptz;
begin
  select * into c from cma.business_calendar_of(p_tenant) x where x.market = p_market;
  foreach a in array p_from loop
    if cma.next_business_noon_in(c.time_zone, c.weekdays, c.holidays, a) is distinct from cma.next_business_noon_of(p_tenant, p_market, a) then
      n_n := n_n + 1; v_first := coalesce(v_first, format('noon at %s', a));
    end if;
    foreach b in array p_to loop
      v_pairs := v_pairs + 1;
      if cma.business_seconds_in(c.time_zone, c.weekdays, c.opens, c.closes, c.holidays, a, b) is distinct from cma.business_seconds_of(p_tenant, p_market, a, b) then
        n_s := n_s + 1; v_first := coalesce(v_first, format('seconds %s to %s', a, b));
      end if;
      if cma.business_days_in(c.time_zone, c.weekdays, c.holidays, a, b) is distinct from cma.business_days_of(p_tenant, p_market, a, b) then
        n_d := n_d + 1; v_first := coalesce(v_first, format('days %s to %s', a, b));
      end if;
    end loop;
  end loop;
  if current_setting('verify.provoke')::boolean then
    return format('provoked: %s pairs compared (FAIL by the switch)', v_pairs);
  end if;
  if n_s + n_d + n_n = 0 then
    return null;
  end if;
  return format('%s of %s pairs differ in seconds, %s in days, %s instants in noon; first: %s', n_s, v_pairs, n_d, n_n, v_first);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- S. Structure, privileges, settings, the input tables
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_ok boolean; v_txt text; v_missing text; v_unaudited text;
  f text;
begin
  v_ok := exists (select 1 from cma.schema_migration where version = '0009o')
          and (select applied_at from cma.schema_migration where version = '0009o') >= (select applied_at from cma.schema_migration where version = '0009n');
  insert into verify_0009o values (1, 'S1 addition 0009o recorded after 0009n', case when v_ok and not v_provoke then 'ok' else 'FAIL' end,
    case when v_ok then 'cma.schema_migration holds 0009o' else 'no 0009o row, or before 0009n' end);

  select string_agg(column_name, ',' order by ordinal_position) into v_txt from information_schema.columns
  where table_schema = 'cma' and table_name = 'follow_up_marker';
  v_ok := v_txt = 'tenant_id,computed_at,inputs_checked_at,next_change_at,migrations'
          and (select c.relrowsecurity from pg_class c where c.oid = 'cma.follow_up_marker'::regclass)
          and exists (select 1 from pg_policies where schemaname = 'cma' and tablename = 'follow_up_marker' and policyname = 'tenant_app')
          and (select count(*) from information_schema.role_table_grants where table_schema = 'cma' and table_name = 'follow_up_marker'
               and grantee = 'cma_app' and privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')) = 4
          and not exists (select 1 from pg_trigger t where t.tgrelid = 'cma.follow_up_marker'::regclass and t.tgname = 'audit')
          and not exists (select 1 from information_schema.role_table_grants where table_schema = 'cma' and table_name = 'follow_up_marker' and grantee = 'cma_readonly');
  insert into verify_0009o values (2, 'S2 cma.follow_up_marker: columns, row-level security, policy, the application''s grants, no audit trigger',
    case when v_ok and not v_provoke then 'ok' else 'FAIL' end, coalesce(v_txt, 'no table'));

  v_ok := (select s.default_value = '60' and s.value_type = 'integer' from cma.setting s where s.key = 'follow_up.recompute_minutes');
  insert into verify_0009o values (3, 'S3 the setting follow_up.recompute_minutes, 60 by default', case when coalesce(v_ok, false) and not v_provoke then 'ok' else 'FAIL' end,
    coalesce((select s.default_value from cma.setting s where s.key = 'follow_up.recompute_minutes'), 'no setting'));

  v_ok := (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'cma' and p.proname in ('open_tickets_of', 'data_quality_of', 'flash_findings_compute_of') and 'jit=off' = any (p.proconfig)) = 3
          and (select p.prorows = 20 from pg_proc p where p.oid = 'cma.business_calendar_of(uuid)'::regprocedure)
          and (select count(*) from pg_proc p where p.oid in ('cma.refresh_follow_up()'::regprocedure, 'cma.refresh_data_quality_of(uuid,boolean)'::regprocedure)
               and 'plan_cache_mode=force_custom_plan' = any (p.proconfig)) = 2;
  insert into verify_0009o values (4, 'S4 jit off on open_tickets_of, data_quality_of and flash_findings_compute_of; rows 20 on the calendar; custom plans on the two job entries',
    case when v_ok and not v_provoke then 'ok' else 'FAIL' end, 'pg_proc.proconfig and prorows');

  v_ok := true; v_txt := null;
  foreach f in array array[
    'cma.business_calendar_of(uuid)', 'cma.business_seconds_in(text,integer[],time[],time[],date[],timestamptz,timestamptz)',
    'cma.business_days_in(text,integer[],date[],timestamptz,timestamptz)', 'cma.next_business_noon_in(text,integer[],date[],timestamptz)',
    'cma.open_tickets_of(uuid)', 'cma.speed_to_lead_of(uuid,timestamptz,timestamptz)', 'cma.open_leads_of(uuid)', 'cma.data_quality_of(uuid)',
    'cma.flash_findings_compute_of(uuid)', 'cma.follow_up_item_print(integer,text,uuid,text,jsonb)', 'cma.follow_up_input_tables()',
    'cma.follow_up_next_change_of(uuid,timestamptz)', 'cma.refresh_follow_up_of(uuid,boolean)', 'cma.refresh_follow_up()',
    'cma.refresh_data_quality_of(uuid,boolean)'] loop
    if not has_function_privilege('cma_app', f, 'execute') or has_function_privilege('public', f, 'execute') then
      v_ok := false; v_txt := coalesce(v_txt || ', ', '') || f;
    end if;
  end loop;
  insert into verify_0009o values (5, 'S5 the fifteen functions: the application may execute them, public may not',
    case when v_ok and not v_provoke then 'ok' else 'FAIL' end, coalesce('wrong: ' || v_txt, 'as designed'));

  -- S6 every tenant table the follow-up's functions read, followed through the functions they call (their bodies'
  -- cma.<name> references), is in the input list, and is audited
  with recursive fn(name) as (
    select x::text collate "C" from unnest(array['open_leads_of', 'open_tickets_of', 'open_tasks_of', 'courtesy_unreachable_of', 'refresh_follow_up_of']) x
    union
    select m[1] collate "C" from fn
    join pg_proc p on p.proname::text = fn.name and p.pronamespace = 'cma'::regnamespace
    cross join lateral regexp_matches(p.prosrc, 'cma\.([a-z_0-9]+)\s*\(', 'g') m
  ),
  refs as (
    select distinct m[1] as name
    from fn join pg_proc p on p.proname::text = fn.name and p.pronamespace = 'cma'::regnamespace
    cross join lateral regexp_matches(p.prosrc, 'cma\.([a-z_0-9]+)', 'g') m
  ),
  tabs as (
    select r.name from refs r join pg_class c on c.relname::text = r.name and c.relnamespace = 'cma'::regnamespace and c.relkind = 'r'
    where exists (select 1 from information_schema.columns k where k.table_schema = 'cma' and k.table_name = r.name and k.column_name = 'tenant_id')
      and r.name not in ('follow_up_item', 'follow_up_snapshot', 'follow_up_marker')
  )
  select string_agg(t.name, ', ' order by t.name) filter (where not (t.name = any (cma.follow_up_input_tables()))),
         string_agg(t.name, ', ' order by t.name) filter (where not exists (select 1 from pg_trigger g where g.tgrelid = ('cma.' || t.name)::regclass and g.tgname = 'audit'
                                                                           and g.tgenabled <> 'D'))
    into v_missing, v_unaudited
  from tabs t;
  v_ok := v_missing is null and v_unaudited is null;
  insert into verify_0009o values (6, 'S6 the follow-up''s input tables: each table its functions read is listed and its audit trigger enabled',
    case when v_ok and not v_provoke then 'ok' else 'FAIL' end,
    coalesce('not listed: ' || v_missing, '') || coalesce(' not audited: ' || v_unaudited, '') || case when v_ok then cardinality(cma.follow_up_input_tables()) || ' tables listed' else '' end);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- E. The rewritten reads answer what they did, per tenant
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  t record; i integer; v_ord integer := 100; v_diff text; v_err text; v_note text;
  v_checks text[]; v_sql_new text[]; v_sql_old text[]; v_ordered boolean[];
  v_from timestamptz[]; v_to timestamptz[]; m record; v_bad text;
  r jsonb; v_n_old bigint; v_only bigint; v_snap boolean;
begin
  for t in select te.id, te.slug from cma.tenant te order by te.slug loop
    perform set_config('app.tenant_id', t.id::text, true);
    -- the tenant's Scheduler user, matched on its external id (never an email)
    perform set_config('app.user_id', coalesce((select u.id::text from cma.app_user_external_id x
                                                join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
                                                where x.tenant_id = t.id and x.system = 'scheduler' and x.external_id = 'scheduler'
                                                  and u.status = 'active' limit 1), ''), true);
    v_checks := array['E1 open_tickets_of', 'E2 open_leads_of', 'E3 speed_to_lead_of, unbounded', 'E4 speed_to_lead_of, the previous month',
                      'E5 data_quality_of', 'E6 flash_findings_compute_of'];
    v_sql_new := array[format('select * from cma.open_tickets_of(%L)', t.id), format('select * from cma.open_leads_of(%L)', t.id),
                       format('select * from cma.speed_to_lead_of(%L, null, null)', t.id),
                       format('select * from cma.speed_to_lead_of(%L, date_trunc(''month'', now()) - interval ''1 month'', date_trunc(''month'', now()))', t.id),
                       format('select * from cma.data_quality_of(%L)', t.id), format('select * from cma.flash_findings_compute_of(%L)', t.id)];
    v_sql_old := array[format('select * from pg_temp.old_open_tickets_of(%L)', t.id), format('select * from pg_temp.old_open_leads_of(%L)', t.id),
                       format('select * from pg_temp.old_speed_to_lead_of(%L, null, null)', t.id),
                       format('select * from pg_temp.old_speed_to_lead_of(%L, date_trunc(''month'', now()) - interval ''1 month'', date_trunc(''month'', now()))', t.id),
                       format('select * from pg_temp.old_data_quality_of(%L)', t.id), format('select * from pg_temp.old_flash_findings_compute_of(%L)', t.id)];
    v_ordered := array[true, true, false, false, false, false];
    for i in 1 .. cardinality(v_checks) loop
      v_ord := v_ord + 1; v_diff := null; v_err := null;
      begin
        perform set_config('role', 'cma_app', true);
        v_diff := pg_temp.v0009o_diff(v_sql_new[i], v_sql_old[i], v_ordered[i]);
        perform set_config('role', 'cma_owner', true);
      exception when others then
        perform set_config('role', 'cma_owner', true);
        v_err := 'error ' || sqlstate;
      end;
      insert into verify_0009o values (v_ord, v_checks[i] || ' (' || t.slug || ')',
        case when v_err is null and v_diff is null then 'ok' else 'FAIL' end,
        coalesce(v_err, v_diff, 'the same rows as the previous definition' || case when v_ordered[i] then ', in the same order' else '' end));
    end loop;

    -- E7 the business-time functions on every market of the tenant, over a grid of instants: a year of them around the
    -- DST changes, the year's turn and the tenant's holidays, at odd times of day, and an unknown market
    v_from := array(select x from (select generate_series(timestamptz '2025-12-29 06:17+00', timestamptz '2026-12-31 06:17+00', interval '9 days 7 hours 13 minutes') x
                                   union select (h.day + time '11:30')::timestamptz from cma.business_holiday h where h.tenant_id = t.id
                                   union select timestamptz '2026-03-29 00:30+00' union select timestamptz '2026-10-25 00:30+00') y order by 1);
    v_to := array(select x from (select generate_series(timestamptz '2026-01-02 15:41+00', timestamptz '2027-01-05 15:41+00', interval '23 days 5 hours 7 minutes') x
                                 union select timestamptz '2026-03-30 08:00+00' union select timestamptz '2026-10-26 17:59+00') y order by 1);
    v_bad := null; v_err := null;
    begin
      for m in select mk.code from cma.market mk where mk.tenant_id = t.id union all select 'XX' order by 1 loop
        v_diff := pg_temp.v0009o_hours(t.id, m.code, v_from, v_to);
        if v_diff is not null then v_bad := coalesce(v_bad || '; ', '') || m.code || ': ' || v_diff; end if;
      end loop;
    exception when others then v_err := 'error ' || sqlstate;
    end;
    v_ord := v_ord + 1;
    insert into verify_0009o values (v_ord, 'E7 business_seconds_in, business_days_in and next_business_noon_in against the _of functions (' || t.slug || ')',
      case when v_err is null and v_bad is null then 'ok' else 'FAIL' end,
      coalesce(v_err, v_bad, format('every market and an unknown one, %s by %s instants: the same answers', cardinality(v_from), cardinality(v_to))));

    -- E8 the follow-up refresh, in a subtransaction that is rolled back: the previous definition's full rewrite, then the
    -- new one writes nothing and leaves the same items and snapshot; with ten items removed and one changed it writes
    -- exactly those (eleven deleted or inserted rows: ten inserts, one delete and one insert)
    v_ord := v_ord + 1; v_err := null; v_note := null; v_diff := null;
    begin
      -- the tenant's refresh lock first, waiting for a job's run to end (released with the subtransaction)
      perform pg_advisory_xact_lock(cma.follow_up_lock_key(t.id));
      perform set_config('role', 'cma_app', true);
      perform pg_temp.old_refresh_follow_up_of(t.id, false);
      perform set_config('role', 'cma_owner', true);
      create temporary table v0009o_items on commit drop as select * from cma.follow_up_item where tenant_id = t.id;
      create temporary table v0009o_snap on commit drop as select summary, by_owner from cma.follow_up_snapshot where tenant_id = t.id;
      perform set_config('role', 'cma_app', true);
      r := cma.refresh_follow_up_of(t.id, false);
      perform set_config('role', 'cma_owner', true);
      select count(*) into v_only from ((select * from cma.follow_up_item where tenant_id = t.id) except all (select * from v0009o_items)) a;
      select count(*) into v_n_old from ((select * from v0009o_items) except all (select * from cma.follow_up_item where tenant_id = t.id)) a;
      select s.summary = o.summary and s.by_owner = o.by_owner into v_snap from cma.follow_up_snapshot s, v0009o_snap o where s.tenant_id = t.id;
      if (r ->> 'written')::integer <> 0 or v_only <> 0 or v_n_old <> 0 or not coalesce(v_snap, false) then
        v_diff := format('after the full rewrite: written %s, %s items only now, %s only before, snapshot the same: %s', r ->> 'written', v_only, v_n_old, v_snap);
      end if;
      if v_diff is null and (select count(*) from v0009o_items) >= 11 then
        delete from cma.follow_up_item i where i.tenant_id = t.id and (i.kind, i.sort_key) in (select x.kind, x.sort_key from v0009o_items x order by x.kind, x.sort_key limit 10);
        update cma.follow_up_item i set row = i.row || '{"v0009o": 1}'::jsonb
        where i.tenant_id = t.id and (i.kind, i.sort_key) = (select x.kind, x.sort_key from v0009o_items x order by x.kind desc, x.sort_key desc limit 1);
        perform set_config('role', 'cma_app', true);
        r := cma.refresh_follow_up_of(t.id, false);
        perform set_config('role', 'cma_owner', true);
        select count(*) into v_only from ((select * from cma.follow_up_item where tenant_id = t.id) except all (select * from v0009o_items)) a;
        select count(*) into v_n_old from ((select * from v0009o_items) except all (select * from cma.follow_up_item where tenant_id = t.id)) a;
        if (r ->> 'written')::integer <> 12 or v_only <> 0 or v_n_old <> 0 then
          v_diff := format('ten removed and one changed: written %s (12 expected), %s items only now, %s only before', r ->> 'written', v_only, v_n_old);
        end if;
        v_note := format('%s items: the same as the full rewrite, 0 written; with ten removed and one changed, 12 rows written back', r ->> 'rows');
      else
        v_note := coalesce(v_note, format('%s items: the same as the full rewrite, 0 written', r ->> 'rows'));
      end if;
      if v_provoke then v_diff := coalesce(v_diff, 'provoked'); end if;
      raise exception using errcode = 'CMAOK';
    exception
      when sqlstate 'CMAOK' then perform set_config('role', 'cma_owner', true);
      when others then perform set_config('role', 'cma_owner', true); v_err := 'error ' || sqlstate;
    end;
    insert into verify_0009o values (v_ord, 'E8 the follow-up refresh writes only what changed, to the same items and snapshot (' || t.slug || ')',
      case when v_err is null and v_diff is null then 'ok' else 'FAIL' end, coalesce(v_err, v_diff, v_note || ' (rolled back)'));
    v_ord := (v_ord / 100 + 1) * 100;
  end loop;
  perform set_config('role', 'cma_owner', true);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- A. Behaviour on a throwaway tenant, rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_t uuid; v_sched uuid; r jsonb; v_ok boolean; v_state text; v_diff text; v_run uuid; v_at timestamptz; v_next timestamptz;
  v_from timestamptz[]; v_to timestamptz[];
  rows_ text[] := '{}';
begin
  begin
    v_t := cma.create_tenant('verify-0009o', 'Verify 0009o', 'Europe/Amsterdam');
    perform set_config('app.tenant_id', v_t::text, true);
    v_sched := (select x.user_id from cma.app_user_external_id x
                where x.tenant_id = v_t and x.system = 'scheduler' and x.external_id = 'scheduler');
    perform set_config('app.user_id', v_sched::text, true);
    -- two markets: NL with its own hours (a split Monday) and holidays, GB on '*' hours; '*' holidays for both
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency) values
      (v_t, 'NL', 'Verify NL', 'Europe/Amsterdam', 'nl', 'EUR'), (v_t, 'GB', 'Verify GB', 'Europe/London', 'en', 'GBP');
    insert into cma.business_hours (tenant_id, market, weekday, opens_at, closes_at) values
      (v_t, 'NL', 1, '09:00', '12:00'), (v_t, 'NL', 1, '13:00', '17:30'), (v_t, 'NL', 2, '09:00', '17:00'), (v_t, 'NL', 3, '09:00', '17:00'),
      (v_t, 'NL', 4, '09:00', '17:00'), (v_t, 'NL', 5, '08:30', '16:00'), (v_t, 'NL', 6, '10:00', '13:00'),
      (v_t, '*', 1, '08:00', '18:00'), (v_t, '*', 2, '08:00', '18:00'), (v_t, '*', 3, '08:00', '18:00'), (v_t, '*', 4, '08:00', '18:00'),
      (v_t, '*', 5, '08:00', '18:00');
    insert into cma.business_holiday (tenant_id, market, day, name) values
      (v_t, 'NL', '2026-04-27', 'Verify holiday'), (v_t, 'NL', '2026-12-28', 'Verify holiday'), (v_t, '*', '2026-12-25', 'Verify holiday'),
      (v_t, '*', '2026-03-30', 'Verify holiday'), (v_t, 'GB', '2026-08-31', 'Verify holiday');

    -- A1 the business-time functions on the crafted calendar: odd times across a year, both DST weekends, the holidays,
    -- to before from, and an unknown market
    v_from := array(select x from (select generate_series(timestamptz '2025-12-27 05:47+00', timestamptz '2026-12-31 23:11+00', interval '3 days 4 hours 37 minutes') x
                                   union select unnest(array[timestamptz '2026-03-28 23:30+00', '2026-03-29 01:30+00', '2026-10-24 23:30+00', '2026-10-25 01:30+00',
                                                             '2026-04-26 22:00+00', '2026-12-24 12:00+00', '2026-12-28 11:00+00'])) y order by 1);
    v_to := array(select x from (select generate_series(timestamptz '2026-01-01 12:00+00', timestamptz '2027-01-03 12:00+00', interval '17 days 2 hours 3 minutes') x
                                 union select unnest(array[timestamptz '2026-03-30 07:15+00', '2026-10-26 16:45+00', '2025-12-01 00:00+00'])) y order by 1);
    v_diff := coalesce(pg_temp.v0009o_hours(v_t, 'NL', v_from, v_to), '') || coalesce(pg_temp.v0009o_hours(v_t, 'GB', v_from, v_to), '')
              || coalesce(pg_temp.v0009o_hours(v_t, 'XX', v_from, v_to), '');
    v_ok := v_diff = '' and cma.business_seconds_in(null, '{1}', '{09:00}', '{17:00}', '{}', now(), now() + interval '1 day') is null
            and cma.business_days_in('Europe/Amsterdam', '{1}', '{}', null, now()) is null;
    rows_ := rows_ || pg_temp.v0009o_row(301, 'A1 the business-time functions equal the _of functions on a crafted calendar (split day, own and * hours, holidays, DST)',
      case when v_ok and not v_provoke then 'ok' else 'FAIL' end, coalesce(nullif(v_diff, ''), format('NL, GB and XX, %s by %s instants', cardinality(v_from), cardinality(v_to))));

    -- A2 the setting's range
    perform set_config('role', 'cma_owner', true);
    v_state := 'none';
    begin
      insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'follow_up.recompute_minutes', '0');
    exception when others then v_state := sqlstate;
    end;
    v_ok := v_state = 'CMA04';
    v_state := 'none';
    begin
      insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'follow_up.recompute_minutes', '1441');
    exception when others then v_state := sqlstate;
    end;
    v_ok := v_ok and v_state = 'CMA04' and cma.setting_of(v_t, 'follow_up.recompute_minutes') = '60';
    rows_ := rows_ || pg_temp.v0009o_row(302, 'A2 follow_up.recompute_minutes takes 1 to 1440 (0 and 1441 refused with CMA04), 60 by default',
      case when v_ok and not v_provoke then 'ok' else 'FAIL' end, '60 for the tenant');

    -- A3 the job's entry. The first run computes. Before each later run the marker is set as a quiet hour leaves it: the
    -- next clock change an hour ahead and the inputs read up to two minutes from now (past the overlap, so the tenant's own
    -- set-up rows above, written a moment ago, count as read). Then a run with nothing changed confirms the figures
    -- (computed false, unchanged, the snapshot's computed_at now) and so does one after a run row (sync_run, no input);
    -- follow_up.recompute_minutes passed, the next clock change reached and an input change (a ticket setting) each make
    -- it compute
    perform set_config('role', 'cma_app', true);
    r := cma.refresh_follow_up();
    v_ok := (r ->> 'computed')::boolean;
    v_diff := 'first ' || (r ->> 'computed');
    perform set_config('role', 'cma_owner', true);
    update cma.follow_up_marker x set next_change_at = now() + interval '1 hour', inputs_checked_at = clock_timestamp() + interval '2 minutes' where x.tenant_id = v_t;
    perform set_config('role', 'cma_app', true);
    r := cma.refresh_follow_up();
    v_ok := v_ok and not (r ->> 'computed')::boolean and r ->> 'reason' = 'unchanged'
            and (select s.computed_at = now() from cma.follow_up_snapshot s where s.tenant_id = v_t);
    v_diff := v_diff || ', nothing changed ' || (r ->> 'computed');
    perform set_config('role', 'cma_owner', true);
    update cma.follow_up_marker x set next_change_at = now() + interval '1 hour', inputs_checked_at = clock_timestamp() + interval '2 minutes' where x.tenant_id = v_t;
    perform set_config('role', 'cma_app', true);
    v_run := cma.job_run_start('refresh_follow_up');
    r := cma.refresh_follow_up();
    v_ok := v_ok and not (r ->> 'computed')::boolean;
    v_diff := v_diff || ', a run row ' || (r ->> 'computed');
    perform set_config('role', 'cma_owner', true);
    update cma.follow_up_marker x set next_change_at = now() + interval '1 hour', inputs_checked_at = clock_timestamp() + interval '2 minutes',
                                      computed_at = now() - interval '61 minutes' where x.tenant_id = v_t;
    perform set_config('role', 'cma_app', true);
    r := cma.refresh_follow_up();
    v_ok := v_ok and (r ->> 'computed')::boolean;
    v_diff := v_diff || ', 61 minutes ' || (r ->> 'computed');
    perform set_config('role', 'cma_owner', true);
    update cma.follow_up_marker x set next_change_at = now(), inputs_checked_at = clock_timestamp() + interval '2 minutes' where x.tenant_id = v_t;
    perform set_config('role', 'cma_app', true);
    r := cma.refresh_follow_up();
    v_ok := v_ok and (r ->> 'computed')::boolean;
    v_diff := v_diff || ', clock change reached ' || (r ->> 'computed');
    perform set_config('role', 'cma_owner', true);
    update cma.follow_up_marker x set next_change_at = now() + interval '1 hour', inputs_checked_at = clock_timestamp() - interval '1 second' where x.tenant_id = v_t;
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'tickets.sla_minutes', '240');
    perform set_config('role', 'cma_app', true);
    r := cma.refresh_follow_up();
    v_ok := v_ok and (r ->> 'computed')::boolean;
    v_diff := v_diff || ', an input changed ' || (r ->> 'computed');
    rows_ := rows_ || pg_temp.v0009o_row(303, 'A3 the job computes only when an input changed, the backstop passed or the clock moves a figure',
      case when v_ok and not v_provoke then 'ok' else 'FAIL' end, 'computed: ' || v_diff);

    -- A4 the next clock change: now while NL is open (a Monday 10:00 there), the next opening when both are closed
    -- (Saturday 14:00 Amsterdam: GB on '*' hours is closed at weekends, NL opens Monday 09:00 Amsterdam)
    v_next := cma.follow_up_next_change_of(v_t, timestamptz '2026-11-16 10:00 Europe/Amsterdam');
    v_ok := v_next = timestamptz '2026-11-16 10:00 Europe/Amsterdam';
    v_at := cma.follow_up_next_change_of(v_t, timestamptz '2026-11-14 14:00 Europe/Amsterdam');
    v_ok := v_ok and v_at = timestamptz '2026-11-15 00:00 Europe/Amsterdam';
    v_diff := format('open: %s; Saturday 14:00: %s (the next midnight before Monday''s opening)', v_next, v_at);
    rows_ := rows_ || pg_temp.v0009o_row(304, 'A4 the next clock change: now in office hours, else the next opening or midnight',
      case when v_ok and not v_provoke then 'ok' else 'FAIL' end, v_diff);

    -- A5 the data-quality back-off: with a stored result older than data_quality.refresh_minutes and a failed run since,
    -- the refresh waits (backoff); a failed run of another job does not; without the failed run it computes
    perform set_config('role', 'cma_app', true);
    r := cma.refresh_data_quality();
    perform set_config('role', 'cma_owner', true);
    update cma.data_quality_snapshot s set computed_at = now() - interval '10 minutes' where s.tenant_id = v_t;
    perform set_config('role', 'cma_app', true);
    v_run := cma.job_run_start('refresh_follow_up');
    perform cma.job_run_finish(v_run, 'failed', '{}'::jsonb, '57014');
    r := cma.refresh_data_quality();
    v_ok := (r ->> 'refreshed')::boolean;
    v_diff := 'another job failed: ' || coalesce(r ->> 'reason', 'refreshed');
    perform set_config('role', 'cma_owner', true);
    update cma.data_quality_snapshot s set computed_at = now() - interval '10 minutes' where s.tenant_id = v_t;
    perform set_config('role', 'cma_app', true);
    v_run := cma.job_run_start('refresh_data_quality');
    perform cma.job_run_finish(v_run, 'failed', '{}'::jsonb, '57014');
    r := cma.refresh_data_quality();
    v_ok := v_ok and not (r ->> 'refreshed')::boolean and r ->> 'reason' = 'backoff';
    v_diff := v_diff || '; its own failure: ' || coalesce(r ->> 'reason', 'refreshed');
    rows_ := rows_ || pg_temp.v0009o_row(305, 'A5 a failed data-quality computation waits data_quality.refresh_minutes (backoff)',
      case when v_ok and not v_provoke then 'ok' else 'FAIL' end, v_diff);

    -- A6 0009l to 0009n's settings beside this change's: the triggers on cma.tenant_setting, enabled; the Active settings
    -- accepted and refused by cma.check_tenant_setting (172) as before
    perform set_config('role', 'cma_owner', true);
    v_ok := (select count(*) from pg_trigger g where g.tgrelid = 'cma.tenant_setting'::regclass and g.tgenabled <> 'D'
             and g.tgname in ('check_data_quality_setting', 'mark_active_take_stale')) = 2
            and exists (select 1 from pg_trigger g join pg_proc p on p.oid = g.tgfoid
                        where g.tgrelid = 'cma.tenant_setting'::regclass and g.tgenabled <> 'D' and p.proname = 'check_tenant_setting');
    v_diff := 'triggers ' || case when v_ok then 'present' else 'missing' end;
    if to_regclass('cma.active_take') is not null then
      insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'active.present_source', 'take');
      insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'customers.refresh_minutes', '7');
      v_ok := v_ok and cma.setting_of(v_t, 'active.present_source') = 'take' and cma.setting_of(v_t, 'customers.refresh_minutes') = '7';
      foreach v_state in array array['active.present_source=nowhere', 'customers.refresh_minutes=seven', 'customers.cohort_ages_months=12,6'] loop
        begin
          update cma.tenant_setting ts set value = split_part(v_state, '=', 2) where ts.tenant_id = v_t and ts.key = split_part(v_state, '=', 1);
          if not found then
            insert into cma.tenant_setting (tenant_id, key, value) values (v_t, split_part(v_state, '=', 1), split_part(v_state, '=', 2));
          end if;
          v_ok := false; v_diff := v_diff || ', ' || v_state || ' accepted';
        exception when others then
          if sqlstate <> 'CMA04' then v_ok := false; v_diff := v_diff || ', ' || v_state || ' ' || sqlstate; end if;
        end;
      end loop;
      v_diff := v_diff || '; the Active settings accepted and refused as 172 and 176 set them';
    else
      v_diff := v_diff || '; no Active tables (0009l not run): only the triggers checked';
    end if;
    rows_ := rows_ || pg_temp.v0009o_row(306, 'A6 0009l to 0009n''s settings still behave beside this change''s (triggers, accepted and refused values)',
      case when v_ok and not v_provoke then 'ok' else 'FAIL' end, v_diff);

    raise exception using errcode = 'CMAOK';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      rows_ := rows_ || pg_temp.v0009o_row(399, 'A block ended early', 'FAIL', 'error ' || sqlstate);
  end;
  perform set_config('role', 'cma_owner', true);
  insert into verify_0009o (ord, check_name, result, detail)
  select rows_[4 * i - 3]::integer, rows_[4 * i - 2], rows_[4 * i - 1], rows_[4 * i] from generate_series(1, cardinality(rows_) / 4) i;
end
$$;

drop function if exists pg_temp.v0009o_diff(text, text, boolean);
drop function if exists pg_temp.v0009o_row(integer, text, text, text);
drop function if exists pg_temp.v0009o_hours(uuid, text, timestamptz[], timestamptz[]);
drop function if exists pg_temp.old_open_tickets_of;
drop function if exists pg_temp.old_speed_to_lead_of;
drop function if exists pg_temp.old_open_leads_of;
drop function if exists pg_temp.old_data_quality_of;
drop function if exists pg_temp.old_flash_findings_compute_of;
drop function if exists pg_temp.old_refresh_follow_up_of;
drop function if exists pg_temp.old_refresh_data_quality_of;

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009o
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009o where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009o where result = 'ok') then 'FAIL'
                  else '0009o verified' end,
             format('179_verify_job_reads: %s ok, %s FAIL, %s skip', (select count(*) from pg_temp.verify_0009o where result = 'ok'),
                    (select count(*) from pg_temp.verify_0009o where result = 'FAIL'), (select count(*) from pg_temp.verify_0009o where result = 'skip'))) x
order by ord;
drop table if exists pg_temp.verify_0009o;
reset role;
