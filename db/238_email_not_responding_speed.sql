-- =============================================================================================
-- 238_email_not_responding_speed.sql: addition 0009zs, Reports → Email's deals not responding in one read per branch
-- (brief N07, WP7; PR N07c)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 236_jobs_off_the_vcpu.sql
-- (0009zr). Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own IAM login: dev first, then
-- 239_verify_email_not_responding_speed.sql there (normal and provoked), then the verifies that read what this re-creates,
-- each still PASS and none edited: 83 (Email's reports), 91 (the report speed copies) and 101 (the definitions of the
-- calls), which read cma.email_not_responding_of, then 131_time_all.sql part b (its email rows). Prod the same after the merge.
--
-- Why (Martin, 24 November 2026; brief N07, D8: Email first; prod's request log of 24 November: /reports/email p95
-- 1,716 ms, p99 11,349 ms, max 12,897 ms; /reports/email-per-agent max 14,251 ms): measured at three times prod's volume
-- with the CRM's email in the volume fixture (12,000 threads, 51,000 messages, 27,000 thread events), Postgres held to one
-- CPU, the page's five reads took 10.3 s, of which cma.email_not_responding 7.0 s. Its check "no conversation call
-- since the last email" joined the call associations to the deal by "a contact of the deal or the deal itself": an or
-- across two columns of crm_association, which no index serves, so every call association of the connection (111,258
-- rows) was read once per deal (240 deals: 15 s of buffer reads under load).
--
-- What it changes
--   cma.email_not_responding_of (based on 100) that check as two: no conversation call since on a contact of the deal,
--                and none on the deal itself; each reads crm_association_to_idx (tenant, connection, to_type, to_id).
--                not (a or b) is (not a) and (not b): the same deals, the same rows (239's E1 to E3 against 100's
--                definition, kept there). Everything else word for word. 7.0 s → about 0.4 s at the fixture's volume
-- =============================================================================================

begin;
set local lock_timeout = '5s';
set role cma_owner;

-- based on: 100_definitions_calls.sql
create or replace function cma.email_not_responding_of(p_tenant_id uuid, p_now timestamptz default now())
returns table (
  connection_id     uuid,
  deal_source_id    text,
  pipeline_label    text,
  market            text,
  owner_ref         text,
  source_system     text,
  last_email_at     timestamptz,
  days_since        integer
)
language sql stable
as $$
  with s as (
    select cma.setting_of(t.id, 'email.no_response_days')::integer as days from cma.tenant t where t.id = p_tenant_id
  ),
  d as (
    select l.* from cma.lead_deals_of(p_tenant_id, null, null) l where not l.is_closed and cardinality(l.contacts) > 0
  ),
  last_out as (
    select d.deal_id, max(m.occurred_at) as at
    from d
    join cma.email_message m
      on m.tenant_id = p_tenant_id and m.connection_id = d.connection_id and m.contact_source_id = any (d.contacts)
    join cma.integration_connection c on c.tenant_id = m.tenant_id and c.id = m.connection_id
    left join cma.email_thread th
      on m.source_kind = 'inbox_message' and th.tenant_id = m.tenant_id and th.connection_id = m.connection_id
     and th.source_id = m.thread_source_id
    where m.direction = 'out' and m.status = 'sent' and m.source_deleted_at is null
      and case when m.source_kind = 'crm_email'
               then not (lower(coalesce(m.origin, '')) = any (cma.setting_codes(c.settings, 'email_inbox_copy_origins')))
                    and not (lower(coalesce(m.origin, '')) = any (cma.setting_codes(c.settings, 'email_automated_origins')))
               else m.actor_kind = 'agent' and not coalesce(th.is_spam, false) end
    group by d.deal_id
  )
  select d.connection_id, d.source_id, d.pipeline_label, d.market, d.owner_ref, d.source_system, lo.at,
         floor(extract(epoch from p_now - lo.at) / 86400)::integer
  from d
  join last_out lo on lo.deal_id = d.deal_id
  cross join s
  where lo.at <= p_now - make_interval(days => s.days)
    and not exists (
      select 1 from cma.email_message m
      where m.tenant_id = p_tenant_id and m.connection_id = d.connection_id and m.contact_source_id = any (d.contacts)
        and m.direction in ('in', 'forwarded') and m.source_deleted_at is null and m.occurred_at > lo.at)
    -- 0009zs: a conversation since, on a contact's call or on the deal's, as two reads that each take crm_association_to_idx
    -- (one read with the two joined by or scanned every call association of the connection, once per deal)
    and not exists (
      select 1
      from cma.crm_association a
      join cma.crm_call cc on cc.tenant_id = a.tenant_id and cc.connection_id = a.connection_id and cc.source_id = a.from_id
      cross join lateral cma.crm_call_conversation_of(p_tenant_id, cc.id) k
      where a.tenant_id = p_tenant_id and a.connection_id = d.connection_id and a.from_type = 'crm_call' and a.removed_at is null
        and a.to_type = 'contact' and a.to_id = any (d.contacts)
        and cc.source_deleted_at is null and k.is_conversation and k.effective_at > lo.at)
    and not exists (
      select 1
      from cma.crm_association a
      join cma.crm_call cc on cc.tenant_id = a.tenant_id and cc.connection_id = a.connection_id and cc.source_id = a.from_id
      cross join lateral cma.crm_call_conversation_of(p_tenant_id, cc.id) k
      where a.tenant_id = p_tenant_id and a.connection_id = d.connection_id and a.from_type = 'crm_call' and a.removed_at is null
        and a.to_type = 'deal' and a.to_id = d.source_id
        and cc.source_deleted_at is null and k.is_conversation and k.effective_at > lo.at)
  order by lo.at, d.source_id
$$;

revoke execute on function cma.email_not_responding_of(uuid, timestamptz) from public;
grant execute on function cma.email_not_responding_of(uuid, timestamptz) to cma_app;

insert into cma.schema_migration (version, description)
values ('0009zs', 'Reports → Email''s deals not responding (brief N07, WP7, D8): cma.email_not_responding_of checks a conversation call since the last email on a contact of the deal and on the deal itself as two reads over crm_association_to_idx instead of one read joined by or (every call association of the connection read once per deal); the same rows')
on conflict (version) do nothing;

commit;
reset role;
