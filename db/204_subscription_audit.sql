-- =============================================================================================
-- 204_subscription_audit.sql: addition 0009zb, the subscription audit and BACS direct debit as its own payment
-- instrument (brief B39 continued, Part B39a2)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics: the audit reads the CMA's own mirror of a subscription app (the
-- tables of 0008zl and 0009za) and says store, line, variant, billing event and payment instrument; the adapter maps the
-- source's words (docs/ingest/README.md, section Juo). Runs unchanged in every database, after
-- 202_subscription_lines.sql (0009za), and refuses to run before 0009za is recorded. Rerunnable, forward-only, in one
-- transaction with a lock timeout.
-- Run as your own IAM login: dev first, then 205_verify_subscription_audit.sql there (normal, then provoked), then the
-- verifies named below; then the audit itself in dev (docs/ingest/PROD_RUNBOOK.md, Phase 18); then prod before the merge,
-- and the audit in prod, whose output is the record records/0009zb-prod-<date>/audit.txt.
--
-- Why (Martin, 20 November 2026, brief B39 continued, Part B39a2; Decision log, 20 Nov 2026): Part A (0009za) mirrors the
-- subscription app's lines, catalog, billing events and 21 event types back to each store's first event. Before Parts B
-- to D compute churn rate, movements and payment states from that mirror, it is checked against the app: whether it is
-- complete, linked and clean per store, and how the app behaves where Part C's rules depend on it (a chargeback, an
-- invoice renewal, a migrated subscription's cycles). The prod run on 20 November 2026 also showed a store paying by BACS
-- direct debit, which 0009za stores as other.
--
-- What it adds
--   instrument         cma.payment_instrument_type_ok() takes an eighth code, bacs_direct_debit (a BACS direct debit);
--                      the checks on cma.subscription.payment_instrument_type and cma.billing_event.instrument_type call
--                      it, so both take the code with no change to a table (an immutable function widened: no row it
--                      held before fails it, nothing is revalidated and no table is locked). The ingest of this change
--                      maps the app's type to it; the subscriptions stored as other change at their next full read.
--                      Billing events are append-only, so those stored as other before this addition keep other
--   the audit          cma.subscription_audit_of(p_tenant): one row per check and store (the store's market, or
--                      market and handle when a market has several stores) of the tenant's active subscriptions
--                      connections: check_key, store, value (counts, shares, codes and months, never an id), expected
--                      and verdict (ok: the expectation holds; explain: it does not, and a cause in the source may
--                      explain it, which the record then names; fail: it does not, and a cause in the CMA is likely).
--                      Sixteen checks in this order: status_mix, no_lines, lines_histogram, line_currency,
--                      amount_vs_lines, variant_missing, events_by_month, orphan_events, status_chain, billing_kinds,
--                      billing_link, after_chargeback, migration_cycles, instruments, privacy, changes (the brief's
--                      table A2.1; each check's comment below says what it counts). Read only, in the caller's rights,
--                      executable by cma_owner only: run by hand in Studio, called by no page and no job. The owner
--                      is not held by row-level security, so every read names the tenant.
--                      cma.subscription_audit_stores_of(p_tenant), its helper (the same rights): the stores it reads
--
-- Not built here (the brief): no minimum term (the app holds none: minCyclesSet and maxCyclesSet 0 in every store on 20
-- November 2026). The audit's windows (30 days after a chargeback; 35 days around a migrated subscription's first order)
-- are the brief's definitions of those two checks, not tenant thresholds: no figure the CMA shows depends on them.
--
-- statement_timeout: the audit reads every row of the mirror once per check (about 300,000 rows in prod on 20 November
-- 2026). A function's own setting cannot lengthen the timer of the statement that calls it (checked on PostgreSQL 16), so
-- the caller sets statement_timeout to 120 s in the same session first (the runbook's Studio block); the audit is timed
-- once in 131 as information, without a budget. It reads through the existing indexes; no index is added.
--
-- Functions re-created and the verifies to run again afterwards (none edited by this change):
--   cma.payment_instrument_type_ok(text)  (base 202)  203 (reads it directly; its A4 probes seven codes and a refused
--                                                     one, which the widening keeps), 119 (through the subscription's
--                                                     check, by cma.ingest_upsert_subscriptions)
-- The message of CMA04 in cma.ingest_upsert_subscriptions (202) names the seven codes; the function is not re-created for
-- its message, which goes stale until the function is next made again. No table, view or column changes, so no reader
-- view, 131 row with a budget, round-trips.json or perf.json entry is needed; the column's comment is renewed.
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid, CMA06 not permitted.
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
  if not exists (select 1 from cma.schema_migration where version = '0009za') then
    raise exception 'addition 0009za (202_subscription_lines.sql) has not run in this database';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. BACS direct debit
-- ---------------------------------------------------------------------------------------------
-- A payment instrument's type in the CMA's codes: as 0009za (202), with bacs_direct_debit
-- based on: 202_subscription_lines.sql
create or replace function cma.payment_instrument_type_ok(p_value text)
returns boolean
language sql immutable
as $$
  select p_value in ('card', 'paypal', 'sepa_direct_debit', 'bacs_direct_debit', 'ideal', 'bancontact', 'invoice', 'other')
$$;
revoke execute on function cma.payment_instrument_type_ok(text) from public;
grant execute on function cma.payment_instrument_type_ok(text) to cma_app;

comment on column cma.subscription.payment_instrument_type is 'The type of the payment method''s instrument only: card, paypal, sepa_direct_debit, bacs_direct_debit, ideal, bancontact, invoice or other (null when unknown); nothing else of the payment method (0008zl; seven codes since 0009za, bacs_direct_debit since 0009zb)';
comment on column cma.billing_event.instrument_type is 'The type of the payment instrument the event was paid or returned on, as cma.subscription.payment_instrument_type (bacs_direct_debit since 0009zb; an event stored before as other keeps other: billing events are append-only)';

-- ---------------------------------------------------------------------------------------------
-- 2. The audit
-- ---------------------------------------------------------------------------------------------
-- The stores the audit reads: the tenant's active subscriptions connections with their commerce store (0008zn's
-- cma.flash_subscription_stores_of), labelled by the store's market, or by market and handle when a market has more than
-- one; unknown for a store without a market. A switched-off connection (a placeholder store) is left out, as every job
-- leaves it out
create or replace function cma.subscription_audit_stores_of(p_tenant uuid)
returns table (connection_id uuid, store_connection_id uuid, store text, time_zone text)
language sql stable
rows 20
as $$
  with s as (
    select f.connection_id, f.store_connection_id, f.handle, coalesce(f.market, 'unknown') as market,
           coalesce(cs.time_zone, t.timezone) as time_zone
    from cma.flash_subscription_stores_of(p_tenant) f
    join cma.integration_connection c on c.tenant_id = p_tenant and c.id = f.connection_id
    join cma.tenant t on t.id = p_tenant
    left join cma.commerce_store cs on cs.tenant_id = p_tenant and cs.connection_id = f.store_connection_id
    where c.status = 'active'
  )
  select s.connection_id, s.store_connection_id,
         case when count(*) over (partition by s.market) > 1 then s.market || ' ' || s.handle else s.market end,
         s.time_zone
  from s
$$;

-- One row per check and store (see the header); counts, codes and months only
create or replace function cma.subscription_audit_of(p_tenant uuid)
returns table (check_key text, store text, value text, expected text, verdict text)
language plpgsql stable
rows 200
as $$
#variable_conflict use_column
declare
  v_holding text[] := cma.flash_list_of(cma.setting_of(p_tenant, 'flash.device_holding_statuses'));
  -- a phone number's shape inside a row's JSON text, as a token of its own: +, 00 or a national 0 and digits, or digit
  -- groups split by single spaces; an id, a date, a time or an amount does not take it
  v_phone   text := '(^|[^0-9A-Za-z_.:+-])(\+[1-9][0-9]{7,14}|00[1-9][0-9]{7,13}|0[1-9][0-9]{8}|\+?[0-9]{2,4} [0-9]{2,4} [0-9]{2,4}( [0-9]{2,4})?)($|[^0-9A-Za-z_.:-])';
  -- a control character inside a row's JSON text, which escapes it
  v_cntrl   text := '\\(u00[01][0-9a-fA-F]|u007[fF]|[nrtbf])';
begin
  if not exists (select 1 from cma.tenant t where t.id = p_tenant) then
    raise exception 'Tenant % not found', p_tenant using errcode = 'CMA02';
  end if;

  -- status_mix: present subscriptions per status; those the latest full read no longer returned (missing). Compared by
  -- hand with the app's own count per status (Juo's subscriptions:count), so its verdict is always explain
  return query
  select 'status_mix'::text, st.store,
         coalesce((select string_agg(x.status || ' ' || x.n, ', ' order by x.status collate "C")
                   from (select s.status, count(*) as n from cma.subscription s
                         where s.tenant_id = p_tenant and s.connection_id = st.connection_id and s.source_deleted_at is null
                         group by s.status) x), 'none')
         || '; missing ' || (select count(*) from cma.subscription s
                             where s.tenant_id = p_tenant and s.connection_id = st.connection_id and s.source_deleted_at is not null),
         'the app''s own count per status, compared by hand'::text, 'explain'::text
  from cma.subscription_audit_stores_of(p_tenant) st
  order by st.store collate "C";

  -- no_lines and lines_histogram: present subscriptions in a device-holding status (flash.device_holding_statuses) by
  -- their lines not canceled (canceled_at null) that the latest read still held
  return query
  with h as (
    select st.store, s.source_id,
           (select count(*) from cma.subscription_line l
            where l.tenant_id = p_tenant and l.connection_id = s.connection_id and l.subscription_source_id = s.source_id
              and l.canceled_at is null and l.source_deleted_at is null) as n
    from cma.subscription_audit_stores_of(p_tenant) st
    join cma.subscription s on s.tenant_id = p_tenant and s.connection_id = st.connection_id
    where s.source_deleted_at is null and s.status = any (v_holding)
  ), k as (
    select 'no_lines'::text as check_key, 1 as ord, st.store,
           (select count(*) from h where h.store = st.store and h.n = 0)::text as value,
           '0'::text as expected
    from cma.subscription_audit_stores_of(p_tenant) st
    union all
    select 'lines_histogram', 2, st.store,
           format('1: %s, 2: %s, 3: %s, 4 to 5: %s, 6+: %s',
                  count(h.n) filter (where h.n = 1), count(h.n) filter (where h.n = 2), count(h.n) filter (where h.n = 3),
                  count(h.n) filter (where h.n between 4 and 5), count(h.n) filter (where h.n >= 6)),
           'shape only'
    from cma.subscription_audit_stores_of(p_tenant) st
    left join h on h.store = st.store
    group by st.store
  )
  select k.check_key, k.store, k.value, k.expected,
         case when k.check_key = 'no_lines' and k.value <> '0' then 'fail' else 'ok' end
  from k
  order by k.ord, k.store collate "C";

  -- line_currency: lines not canceled of present subscriptions whose currency is not their subscription's
  return query
  select 'line_currency'::text, st.store, x.n::text, '0'::text, case when x.n = 0 then 'ok' else 'fail' end
  from cma.subscription_audit_stores_of(p_tenant) st
  cross join lateral (
    select count(*) as n
    from cma.subscription s
    join cma.subscription_line l on l.tenant_id = p_tenant and l.connection_id = s.connection_id and l.subscription_source_id = s.source_id
    where s.tenant_id = p_tenant and s.connection_id = st.connection_id and s.source_deleted_at is null
      and l.canceled_at is null and l.source_deleted_at is null and l.currency is distinct from s.currency) x
  order by st.store collate "C";

  -- amount_vs_lines: present subscriptions with a line not canceled whose amount per cycle is not the sum of those
  -- lines', by their discounts (none, some, not stated)
  return query
  select 'amount_vs_lines'::text, st.store,
         format('no discount %s of %s; with a discount %s of %s; discounts not stated %s of %s',
                count(*) filter (where x.discount_count = 0 and x.differs), count(*) filter (where x.discount_count = 0),
                count(*) filter (where x.discount_count > 0 and x.differs), count(*) filter (where x.discount_count > 0),
                count(*) filter (where x.discount_count is null and x.differs), count(*) filter (where x.discount_count is null)),
         '0 where no discount'::text,
         case when count(*) filter (where x.discount_count = 0 and x.differs) = 0 then 'ok' else 'fail' end
  from cma.subscription_audit_stores_of(p_tenant) st
  left join lateral (
    select s.discount_count, s.amount_per_cycle is distinct from sum(l.amount_per_cycle) as differs
    from cma.subscription s
    join cma.subscription_line l on l.tenant_id = p_tenant and l.connection_id = s.connection_id and l.subscription_source_id = s.source_id
    where s.tenant_id = p_tenant and s.connection_id = st.connection_id and s.source_deleted_at is null
      and l.canceled_at is null and l.source_deleted_at is null
    group by s.id, s.discount_count, s.amount_per_cycle) x on true
  group by st.store
  order by st.store collate "C";

  -- variant_missing: lines not canceled of present subscriptions without a variant, with a variant the catalog does not
  -- hold, or with one the catalog's latest read no longer held (removed)
  return query
  select 'variant_missing'::text, st.store,
         format('no variant %s; not in the catalog %s; removed from the catalog %s', x.none_, x.absent, x.removed),
         '0'::text,
         case when x.none_ + x.absent > 0 then 'fail' when x.removed > 0 then 'explain' else 'ok' end
  from cma.subscription_audit_stores_of(p_tenant) st
  cross join lateral (
    select count(*) filter (where l.variant_source_id is null) as none_,
           count(*) filter (where l.variant_source_id is not null and v.id is null) as absent,
           count(*) filter (where v.source_deleted_at is not null) as removed
    from cma.subscription s
    join cma.subscription_line l on l.tenant_id = p_tenant and l.connection_id = s.connection_id and l.subscription_source_id = s.source_id
    left join cma.subscription_product_variant v
      on v.tenant_id = p_tenant and v.connection_id = l.connection_id and v.variant_source_id = l.variant_source_id
    where s.tenant_id = p_tenant and s.connection_id = st.connection_id and s.source_deleted_at is null
      and l.canceled_at is null and l.source_deleted_at is null) x
  order by st.store collate "C";

  -- events_by_month: events per month in the store's time zone from the month of its first event to the current one;
  -- a month without an event while the store had a subscription (created before the month ended and not canceled before
  -- it began) is a hole (fail); a month after the first renewal's without a renewal while it had one is explain
  return query
  with ev as (
    select st.store, date_trunc('month', e.occurred_at at time zone st.time_zone) as m, count(*) as n,
           count(*) filter (where e.event_type = 'renewed') as r
    from cma.subscription_audit_stores_of(p_tenant) st
    join cma.subscription_event e on e.tenant_id = p_tenant and e.connection_id = st.connection_id
    group by st.store, 2
  ), mo as (
    select st.store, st.connection_id, st.time_zone, g.m,
           coalesce(ev.n, 0) as n, coalesce(ev.r, 0) as r,
           g.m > (select min(e2.m) from ev e2 where e2.store = st.store and e2.r > 0) as after_first_renewal,
           exists (select 1 from cma.subscription s
                   where s.tenant_id = p_tenant and s.connection_id = st.connection_id
                     and s.source_created_at < (g.m + interval '1 month') at time zone st.time_zone
                     and (s.canceled_at is null or s.canceled_at >= g.m at time zone st.time_zone)) as held
    from cma.subscription_audit_stores_of(p_tenant) st
    cross join lateral generate_series((select min(e1.m) from ev e1 where e1.store = st.store),
                                       date_trunc('month', now() at time zone st.time_zone), interval '1 month') as g(m)
    left join ev on ev.store = st.store and ev.m = g.m
  ), agg as (
    select st.store,
           coalesce('from ' || to_char(min(mo.m), 'YYYY-MM') || ': '
                    || string_agg(to_char(mo.m, 'YYYY-MM') || ' ' || mo.n, ', ' order by mo.m), 'no event') as months,
           coalesce(string_agg(to_char(mo.m, 'YYYY-MM'), ', ' order by mo.m) filter (where mo.n = 0 and mo.held), 'none') as holes,
           coalesce(string_agg(to_char(mo.m, 'YYYY-MM'), ', ' order by mo.m)
                      filter (where mo.n > 0 and mo.r = 0 and mo.held and mo.after_first_renewal), 'none') as gaps,
           count(mo.m) = 0 and exists (select 1 from cma.subscription s where s.tenant_id = p_tenant and s.connection_id = st.connection_id
                                         and s.source_deleted_at is null) as none_with_subscriptions
    from cma.subscription_audit_stores_of(p_tenant) st
    left join mo on mo.store = st.store
    group by st.store, st.connection_id
  )
  select 'events_by_month'::text, agg.store,
         agg.months || '; no event: ' || agg.holes || '; no renewal: ' || agg.gaps,
         'no month without an event while the store had subscriptions'::text,
         case when agg.holes <> 'none' or agg.none_with_subscriptions then 'fail' when agg.gaps <> 'none' then 'explain' else 'ok' end
  from agg
  order by agg.store collate "C";

  -- orphan_events: events, lines and billing events naming a subscription the CMA does not hold (present or missing)
  return query
  select 'orphan_events'::text, st.store,
         format('events %s (subscriptions %s); lines %s; billing events %s', x.events, x.subs, y.lines, z.billing),
         '0, or explained (deleted in the app)'::text,
         case when x.events + y.lines + z.billing = 0 then 'ok' else 'explain' end
  from cma.subscription_audit_stores_of(p_tenant) st
  cross join lateral (
    select count(*) as events, count(distinct e.subscription_source_id) as subs
    from cma.subscription_event e
    where e.tenant_id = p_tenant and e.connection_id = st.connection_id
      and not exists (select 1 from cma.subscription s
                      where s.tenant_id = p_tenant and s.connection_id = e.connection_id and s.source_id = e.subscription_source_id)) x
  cross join lateral (
    select count(*) as lines
    from cma.subscription_line l
    where l.tenant_id = p_tenant and l.connection_id = st.connection_id
      and not exists (select 1 from cma.subscription s
                      where s.tenant_id = p_tenant and s.connection_id = l.connection_id and s.source_id = l.subscription_source_id)) y
  cross join lateral (
    select count(*) as billing
    from cma.billing_event b
    where b.tenant_id = p_tenant and b.connection_id = st.connection_id and b.subscription_source_id is not null
      and not exists (select 1 from cma.subscription s
                      where s.tenant_id = p_tenant and s.connection_id = b.connection_id and s.source_id = b.subscription_source_id)) z
  order by st.store collate "C";

  -- status_chain: present subscriptions whose latest event that moves a status (status_to stated) ends in another status
  -- than theirs, by that pair (the event's status > the subscription's); those without such an event
  return query
  with l as (
    select distinct on (e.connection_id, e.subscription_source_id) e.connection_id, e.subscription_source_id, e.status_to
    from cma.subscription_event e
    where e.tenant_id = p_tenant and e.status_to is not null
      and e.connection_id = any (select st.connection_id from cma.subscription_audit_stores_of(p_tenant) st)
    order by e.connection_id, e.subscription_source_id, e.occurred_at desc, e.source_id collate "C" desc
  ), c as (
    select s.connection_id, l.status_to, s.status
    from cma.subscription s
    left join l on l.connection_id = s.connection_id and l.subscription_source_id = s.source_id
    where s.tenant_id = p_tenant and s.source_deleted_at is null
  )
  select 'status_chain'::text, st.store,
         format('broken %s (%s); no status event %s',
                (select count(*) from c where c.connection_id = st.connection_id and c.status_to <> c.status),
                coalesce((select string_agg(p.pair || ' ' || p.n, ', ' order by p.pair collate "C")
                          from (select c.status_to || '>' || c.status as pair, count(*) as n from c
                                where c.connection_id = st.connection_id and c.status_to <> c.status group by 1) p), 'none'),
                (select count(*) from c where c.connection_id = st.connection_id and c.status_to is null)),
         '0, or explained'::text,
         case when exists (select 1 from c where c.connection_id = st.connection_id and c.status_to <> c.status) then 'explain' else 'ok' end
  from cma.subscription_audit_stores_of(p_tenant) st
  order by st.store collate "C";

  -- billing_kinds: billing events per kind (which stores renew by invoice: Awaiting payment)
  return query
  select 'billing_kinds'::text, st.store,
         coalesce((select string_agg(x.kind || ' ' || x.n, ', ' order by x.kind collate "C")
                   from (select b.kind, count(*) as n from cma.billing_event b
                         where b.tenant_id = p_tenant and b.connection_id = st.connection_id group by b.kind) x), 'none'),
         'shape only'::text, 'ok'::text
  from cma.subscription_audit_stores_of(p_tenant) st
  order by st.store collate "C";

  -- billing_link and after_chargeback: chargebacks and refunds linked to a subscription by its id, else through a
  -- renewal's store order (the renewal's order_source_id), else unlinked; after a linked chargeback, the first of a
  -- renewal, a failed renewal (retry failed), a move to failed, canceled or expired within 30 days, else nothing (or
  -- under 30 days while the 30 days have not passed)
  return query
  with ro as materialized (
    select distinct on (e.connection_id, e.order_source_id) e.connection_id, e.order_source_id, e.subscription_source_id
    from cma.subscription_event e
    where e.tenant_id = p_tenant and e.event_type = 'renewed' and e.order_source_id is not null
      and e.connection_id = any (select st.connection_id from cma.subscription_audit_stores_of(p_tenant) st)
    order by e.connection_id, e.order_source_id, e.occurred_at desc
  ), b as (
    select b.connection_id, case when b.kind = 'chargeback' then 'chargebacks' else 'refunds' end as family, b.kind, b.occurred_at,
           case when b.subscription_source_id is not null then 'subscription' when ro.subscription_source_id is not null then 'order'
                else 'unlinked' end as link,
           coalesce(b.subscription_source_id, ro.subscription_source_id) as subscription_source_id
    from cma.billing_event b
    left join ro on ro.connection_id = b.connection_id and ro.order_source_id = b.order_source_id
    where b.tenant_id = p_tenant and (b.kind = 'chargeback' or b.kind like 'refund\_%')
      and b.connection_id = any (select st.connection_id from cma.subscription_audit_stores_of(p_tenant) st)
  ), a as (
    select b.connection_id,
           coalesce(f.what, case when b.occurred_at > now() - interval '30 days' then 'under 30 days' else 'nothing' end) as what
    from b
    left join lateral (
      select case when e.event_type = 'renewed' then 'renewed' when e.status_to = 'failed' then 'failed'
                  when e.status_to = 'canceled' then 'canceled' when e.status_to = 'expired' then 'expired'
                  else 'retry failed' end as what
      from cma.subscription_event e
      where e.tenant_id = p_tenant and e.connection_id = b.connection_id and e.subscription_source_id = b.subscription_source_id
        and e.occurred_at > b.occurred_at and e.occurred_at <= b.occurred_at + interval '30 days'
        and (e.event_type in ('renewed', 'renew_failed') or e.status_to in ('failed', 'canceled', 'expired'))
      order by e.occurred_at, e.source_id collate "C"
      limit 1) f on true
    where b.kind = 'chargeback' and b.subscription_source_id is not null
  )
  select k.check_key, k.store, k.value, k.expected, k.verdict
  from (
    select 'billing_link'::text as check_key, 1 as ord, st.store,
           format('chargebacks: subscription %s, order %s, unlinked %s; refunds: subscription %s, order %s, unlinked %s',
                  count(*) filter (where b.family = 'chargebacks' and b.link = 'subscription'),
                  count(*) filter (where b.family = 'chargebacks' and b.link = 'order'),
                  count(*) filter (where b.family = 'chargebacks' and b.link = 'unlinked'),
                  count(*) filter (where b.family = 'refunds' and b.link = 'subscription'),
                  count(*) filter (where b.family = 'refunds' and b.link = 'order'),
                  count(*) filter (where b.family = 'refunds' and b.link = 'unlinked')) as value,
           'unlinked near 0'::text as expected,
           case when count(*) filter (where b.link = 'unlinked') = 0 then 'ok' else 'explain' end as verdict
    from cma.subscription_audit_stores_of(p_tenant) st
    left join b on b.connection_id = st.connection_id
    group by st.store
    union all
    select 'after_chargeback', 2, st.store,
           format('renewed %s, retry failed %s, failed %s, canceled %s, expired %s, nothing %s, under 30 days %s',
                  count(*) filter (where a.what = 'renewed'), count(*) filter (where a.what = 'retry failed'),
                  count(*) filter (where a.what = 'failed'), count(*) filter (where a.what = 'canceled'),
                  count(*) filter (where a.what = 'expired'), count(*) filter (where a.what = 'nothing'),
                  count(*) filter (where a.what = 'under 30 days')),
           'shape only', 'ok'
    from cma.subscription_audit_stores_of(p_tenant) st
    left join a on a.connection_id = st.connection_id
    group by st.store
  ) k
  order by k.ord, k.store collate "C";

  -- migration_cycles: subscriptions the app migrated (their latest migrated event) whose store customer has a store order
  -- at or before the app's created date, by the days from the earliest such order to the migration's next billing date
  -- less its cycle index times the billing interval; those without such an order; those without a cycle, a date or an
  -- interval
  return query
  with m as (
    select distinct on (e.connection_id, e.subscription_source_id) e.connection_id, e.subscription_source_id, e.cycle_index, e.billing_to_at
    from cma.subscription_event e
    where e.tenant_id = p_tenant and e.event_type = 'migrated'
      and e.connection_id = any (select st.connection_id from cma.subscription_audit_stores_of(p_tenant) st)
    order by e.connection_id, e.subscription_source_id, e.occurred_at desc, e.source_id collate "C" desc
  ), j as (
    select st.store, m.cycle_index, m.billing_to_at, s.billing_interval, st.time_zone,
           m.billing_to_at - (m.cycle_index * s.billing_interval_count)
             * case s.billing_interval when 'day' then interval '1 day' when 'week' then interval '1 week'
                                       when 'month' then interval '1 month' when 'year' then interval '1 year' end as est,
           (select min(o.source_created_at) from cma.commerce_order o
            where o.tenant_id = p_tenant and o.connection_id = st.store_connection_id and o.customer_source_id = s.customer_source_id
              and o.source_created_at <= coalesce(s.source_created_at, now()) and o.is_test is not true
              and o.source_deleted_at is null) as first_order
    from cma.subscription_audit_stores_of(p_tenant) st
    join m on m.connection_id = st.connection_id
    join cma.subscription s on s.tenant_id = p_tenant and s.connection_id = m.connection_id and s.source_id = m.subscription_source_id
  ), g as (
    select j.store, j.est is null as undated, j.first_order is null as no_order,
           (j.first_order at time zone j.time_zone)::date - (j.est at time zone j.time_zone)::date as gap
    from j
  ), c as (
    select st.store, count(g.store) as migrated,
           count(*) filter (where not g.undated and g.gap < -35) as b1,
           count(*) filter (where not g.undated and g.gap between -35 and -1) as b2,
           count(*) filter (where not g.undated and g.gap between 0 and 35) as b3,
           count(*) filter (where not g.undated and g.gap > 35) as b4,
           count(*) filter (where not g.undated and g.no_order) as no_order,
           count(*) filter (where g.undated) as undated
    from cma.subscription_audit_stores_of(p_tenant) st
    left join g on g.store = st.store
    group by st.store
  )
  select 'migration_cycles'::text, c.store,
         format('migrated %s; below -35: %s, -35 to -1: %s, 0 to 35: %s, above 35: %s; no store order %s; no cycle, date or interval %s',
                c.migrated, c.b1, c.b2, c.b3, c.b4, c.no_order, c.undated),
         'most in one bucket'::text,
         case when c.b1 + c.b2 + c.b3 + c.b4 = 0 or 2 * greatest(c.b1, c.b2, c.b3, c.b4) > c.b1 + c.b2 + c.b3 + c.b4 then 'ok'
              else 'explain' end
  from c
  order by c.store collate "C";

  -- instruments: present subscriptions per payment instrument type (none when not stated), billing events per instrument
  -- type, and the latest succeeded read's count of instrument types the mapping did not know (instrument_unknown; the
  -- names are in the dry run's instrumentTypes). A subscription stored as other fails; a billing event as other is
  -- explain, as one stored before 0009zb keeps other
  return query
  select 'instruments'::text, st.store,
         'subscriptions: ' || coalesce((select string_agg(x.t || ' ' || x.n, ', ' order by x.t collate "C")
                                         from (select coalesce(s.payment_instrument_type, 'none') as t, count(*) as n from cma.subscription s
                                               where s.tenant_id = p_tenant and s.connection_id = st.connection_id and s.source_deleted_at is null
                                               group by 1) x), 'none')
         || '; billing events: ' || coalesce((select string_agg(x.t || ' ' || x.n, ', ' order by x.t collate "C")
                                              from (select b.instrument_type as t, count(*) as n from cma.billing_event b
                                                    where b.tenant_id = p_tenant and b.connection_id = st.connection_id
                                                      and b.instrument_type is not null group by 1) x), 'none')
         || '; instrument_unknown of the latest read: '
         || coalesce((select r.counts ->> 'instrument_unknown' from cma.sync_run r
                      where r.tenant_id = p_tenant and r.connection_id = st.connection_id and r.status = 'succeeded'
                        and r.counts ? 'instrument_unknown'
                      order by r.finished_at desc limit 1), 'no read'),
         'other 0'::text,
         case when exists (select 1 from cma.subscription s where s.tenant_id = p_tenant and s.connection_id = st.connection_id
                             and s.source_deleted_at is null and s.payment_instrument_type = 'other') then 'fail'
              when exists (select 1 from cma.billing_event b where b.tenant_id = p_tenant and b.connection_id = st.connection_id
                             and b.instrument_type = 'other') then 'explain'
              else 'ok' end
  from cma.subscription_audit_stores_of(p_tenant) st
  order by st.store collate "C";

  -- privacy: rows of the four tables of 0009za and the two it widened whose JSON text (every column, raw included) holds an
  -- @, a control character or a phone number's shape; catalog texts over 100 characters
  return query
  with p as (
    select st.store, st.connection_id,
           (select count(*) from cma.subscription x where x.tenant_id = p_tenant and x.connection_id = st.connection_id
              and (strpos(to_jsonb(x)::text, '@') > 0 or to_jsonb(x)::text ~ v_cntrl or to_jsonb(x)::text ~ v_phone)) as subscription,
           (select count(*) from cma.subscription_event x where x.tenant_id = p_tenant and x.connection_id = st.connection_id
              and (strpos(to_jsonb(x)::text, '@') > 0 or to_jsonb(x)::text ~ v_cntrl or to_jsonb(x)::text ~ v_phone)) as subscription_event,
           (select count(*) from cma.subscription_line x where x.tenant_id = p_tenant and x.connection_id = st.connection_id
              and (strpos(to_jsonb(x)::text, '@') > 0 or to_jsonb(x)::text ~ v_cntrl or to_jsonb(x)::text ~ v_phone)) as subscription_line,
           (select count(*) from cma.subscription_product_variant x where x.tenant_id = p_tenant and x.connection_id = st.connection_id
              and (strpos(to_jsonb(x)::text, '@') > 0 or to_jsonb(x)::text ~ v_cntrl or to_jsonb(x)::text ~ v_phone)) as subscription_product_variant,
           (select count(*) from cma.billing_event x where x.tenant_id = p_tenant and x.connection_id = st.connection_id
              and (strpos(to_jsonb(x)::text, '@') > 0 or to_jsonb(x)::text ~ v_cntrl or to_jsonb(x)::text ~ v_phone)) as billing_event,
           (select count(*) from cma.subscription_change x where x.tenant_id = p_tenant and x.connection_id = st.connection_id
              and (strpos(to_jsonb(x)::text, '@') > 0 or to_jsonb(x)::text ~ v_cntrl or to_jsonb(x)::text ~ v_phone)) as subscription_change,
           (select count(*) from cma.subscription_product_variant x where x.tenant_id = p_tenant and x.connection_id = st.connection_id
              and (length(x.product_title) > 100 or length(x.variant_title) > 100 or length(x.sku) > 100)) as long_text
    from cma.subscription_audit_stores_of(p_tenant) st
  )
  select 'privacy'::text, p.store,
         format('subscription %s, subscription_event %s, subscription_line %s, subscription_product_variant %s, billing_event %s, subscription_change %s; catalog text over 100 characters %s',
                p.subscription, p.subscription_event, p.subscription_line, p.subscription_product_variant, p.billing_event,
                p.subscription_change, p.long_text),
         '0'::text,
         case when p.subscription + p.subscription_event + p.subscription_line + p.subscription_product_variant + p.billing_event
                   + p.subscription_change + p.long_text = 0 then 'ok' else 'fail' end
  from p
  order by p.store collate "C";

  -- changes: observed changes per field since the first load; those that changed nothing (the value found equal to the
  -- one stored, or the same change as the subscription's previous one of that field: a rerun that wrote it again)
  return query
  with c as (
    select x.connection_id, x.field,
           x.old_value is not distinct from x.new_value
           or (x.old_value = lag(x.old_value) over w and x.new_value is not distinct from lag(x.new_value) over w) as no_change
    from cma.subscription_change x
    where x.tenant_id = p_tenant
      and x.connection_id = any (select st.connection_id from cma.subscription_audit_stores_of(p_tenant) st)
    window w as (partition by x.connection_id, x.subscription_source_id, x.field order by x.observed_at, x.id)
  )
  select 'changes'::text, st.store,
         coalesce((select string_agg(f.field || ' ' || f.n, ', ' order by f.field collate "C")
                   from (select c.field, count(*) as n from c where c.connection_id = st.connection_id group by c.field) f), 'none')
         || '; without a change ' || (select count(*) from c where c.connection_id = st.connection_id and c.no_change),
         'without a change 0'::text,
         case when exists (select 1 from c where c.connection_id = st.connection_id and c.no_change) then 'fail' else 'ok' end
  from cma.subscription_audit_stores_of(p_tenant) st
  order by st.store collate "C";
end
$$;

-- Owner only: no grant to the application or a reader (an owner-only function is executed by cma_owner, its owner)
alter function cma.subscription_audit_stores_of(uuid) owner to cma_owner;
alter function cma.subscription_audit_of(uuid) owner to cma_owner;
revoke execute on function cma.subscription_audit_stores_of(uuid), cma.subscription_audit_of(uuid) from public;
comment on function cma.subscription_audit_of(uuid) is 'The subscription audit (0009zb): one row per check and store of the tenant''s active subscriptions connections, with value, expected and verdict (ok, explain, fail); counts, codes and months only. Read only, owner only, run by hand (set statement_timeout to 120 s first); called by no page and no job';

-- ---------------------------------------------------------------------------------------------
-- 3. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009zb', 'The subscription audit and BACS direct debit (brief B39 continued, Part B39a2): cma.payment_instrument_type_ok takes bacs_direct_debit (eight codes; the checks on cma.subscription and cma.billing_event take it with no table change); cma.subscription_audit_of(tenant), read only and owner only, one row per check and store of the active subscriptions connections (status_mix, no_lines, lines_histogram, line_currency, amount_vs_lines, variant_missing, events_by_month, orphan_events, status_chain, billing_kinds, billing_link, after_chargeback, migration_cycles, instruments, privacy, changes) with value, expected and verdict (ok, explain, fail), and its helper cma.subscription_audit_stores_of(tenant)')
on conflict (version) do nothing;

commit;
reset role;
