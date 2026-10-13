-- =============================================================================================
-- 54_uncounted_lines.sql: addition 0008f, a telephony connection stores calls on its counted
-- lines only
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 52_sources_configuration.sql (0008e). Rerunnable, forward-only, in one transaction. Run as your
-- own IAM login, dev first, then prod; then 55_verify_uncounted_lines.sql (dev), then
-- 35_verify_telephony.sql, 33_verify_intake_core.sql and 31_verify_ingest_crm_records.sql again
-- (unchanged).
--
-- Why (README Decision log, 13 October 2026): one telephony account can serve several business
-- lines, each a tenant with its own connection. A line that does not count (is_counted false) is
-- another business line's, so its calls are never stored in this tenant.
--
-- What it does
--   skip               cma.ingest_upsert_telephony_calls() as in 0007a, plus: a call whose numberRef
--                      is a line of this connection with is_counted false is not written, outcome
--                      skipped_uncounted_line (one row per call, like the other outcomes). A call
--                      on a line not yet in the catalog is stored as before. Webhook, reconcile and
--                      backfill all write through this function
--   switching off      when a line goes from counted to not counted (cma.set_telephony_number(), or
--                      any other update of is_counted), or is added as not counted, the connection's
--                      calls on that line are deleted in the same transaction, with their taggings
--                      (telephony_call_tag) and links (call_link, retired ones included). The CRM
--                      calls stay. A trigger on cma.telephony_number does it, so every path keeps
--                      the rule; set_telephony_number itself is unchanged (return type void).
--                      Switching a line back on deletes nothing: its calls return through the next
--                      backfill
--   the deletes        cma.remove_uncounted_line_calls(tenant, connection, line), owner only: the
--                      one place that deletes telephony calls. The application cannot delete from
--                      these tables (0007a), so the trigger's function is SECURITY DEFINER, owned by
--                      cma_owner with a pinned search path, and runs only as a trigger
--   the audit          cma.audit_row() as in 0001, plus one narrow exception: a delete made by
--                      remove_uncounted_line_calls() on telephony_call, telephony_call_tag or
--                      call_link keeps the row's ids only (id, tenant, connection, the source call
--                      id, the tag id, the linked call ids) and the reason uncounted_line, not the
--                      row image; table, time and actor as always. Every other change, deletes
--                      elsewhere included, keeps its full image. The earlier insert and update rows
--                      of those calls keep their images (see README, Open decisions)
--   lines already off  cma.remove_all_uncounted_line_calls(), owner only: applies the rule to every
--                      line already marked not counted, per connection; this script runs it once
--                      and shows the calls removed per connection (a rerun shows zeros)
--
-- Concurrency: the call write takes a shared advisory lock per line of its batch (in line order)
-- before it reads is_counted; removing a line's calls takes the exclusive one. A line switched off
-- while a batch on it is being written waits for that batch and then deletes what it stored; a
-- batch that arrives after the switch reads the line as not counted.
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
  if not exists (select 1 from cma.schema_migration where version = '0008e') then
    raise exception 'addition 0008e (52_sources_configuration.sql) must run before 0008f';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The audit trigger: ids only for the deletes of an uncounted line
-- ---------------------------------------------------------------------------------------------
-- As in 0001, plus the exception. The switch cma.audit_keys_only is set, for the length of its own
-- deletes, by cma.remove_uncounted_line_calls() only, and narrows only a DELETE on the three
-- tables below. The application cannot delete from them (0007a), so nothing else reaches it.
create or replace function cma.audit_row()
returns trigger
language plpgsql
as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
begin
  if tg_op = 'DELETE' and tg_table_schema = 'cma'
     and tg_table_name in ('telephony_call', 'telephony_call_tag', 'call_link')
     and coalesce(current_setting('cma.audit_keys_only', true), '') = 'uncounted_line' then
    v_old := jsonb_strip_nulls(jsonb_build_object(
      'id', v_old -> 'id', 'tenant_id', v_old -> 'tenant_id', 'connection_id', v_old -> 'connection_id',
      'source_id', v_old -> 'source_id', 'call_source_id', v_old -> 'call_source_id', 'tag_ref', v_old -> 'tag_ref',
      'telephony_call_id', v_old -> 'telephony_call_id', 'crm_call_id', v_old -> 'crm_call_id',
      'reason', 'uncounted_line'));
  end if;
  insert into cma.audit_log (tenant_id, table_name, action, old_row, new_row, actor_user_id, actor_label)
  values (
    (coalesce(v_new, v_old) ->> 'tenant_id')::uuid,
    tg_table_name,
    lower(tg_op),
    v_old,
    v_new,
    cma.current_user_id(),
    cma.current_actor_label()
  );
  return null;   -- after trigger, return value is ignored
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. Removing the calls of a line that does not count (owner only)
-- ---------------------------------------------------------------------------------------------
-- Deletes the connection's telephony calls on the line, with their taggings and their links
-- (current and retired); the CRM calls stay. Refuses a line that is missing (CMA02) or counted
-- (CMA03). Takes the line's exclusive advisory lock first, so a call write on the line in flight
-- finishes before the delete reads. Answers what it removed. Runs in the caller's rights: the
-- owner, here and from the trigger's function of section 4; the application may not execute it.
create or replace function cma.remove_uncounted_line_calls(p_tenant_id uuid, p_connection_id uuid, p_number_ref text)
returns table (calls integer, taggings integer, links integer)
language plpgsql
as $$
declare
  v_counted boolean;
  v_ids     uuid[];
  v_srcs    text[];
begin
  if p_tenant_id is null or p_connection_id is null or coalesce(p_number_ref, '') = '' then
    raise exception 'a tenant, a connection and a line are needed' using errcode = 'CMA04';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_tenant_id::text || '/telephony_line/' || p_connection_id::text || '/' || p_number_ref, 0));
  select n.is_counted into v_counted from cma.telephony_number n
  where n.tenant_id = p_tenant_id and n.connection_id = p_connection_id and n.number_ref = p_number_ref;
  if v_counted is null then
    raise exception 'no line % on connection % of tenant %', p_number_ref, p_connection_id, p_tenant_id using errcode = 'CMA02';
  end if;
  if v_counted then
    raise exception 'line % counts; its calls stay', p_number_ref using errcode = 'CMA03';
  end if;

  select coalesce(array_agg(t.id), '{}'), coalesce(array_agg(t.source_id), '{}') into v_ids, v_srcs
  from cma.telephony_call t
  where t.tenant_id = p_tenant_id and t.connection_id = p_connection_id and t.number_ref = p_number_ref;
  calls := cardinality(v_ids);
  taggings := 0;
  links := 0;
  if calls = 0 then
    return next;
    return;
  end if;

  perform set_config('cma.audit_keys_only', 'uncounted_line', true);
  delete from cma.call_link l where l.tenant_id = p_tenant_id and l.telephony_call_id = any (v_ids);
  get diagnostics links = row_count;
  delete from cma.telephony_call_tag ct
  where ct.tenant_id = p_tenant_id and ct.connection_id = p_connection_id and ct.call_source_id = any (v_srcs);
  get diagnostics taggings = row_count;
  delete from cma.telephony_call t where t.tenant_id = p_tenant_id and t.id = any (v_ids);
  get diagnostics calls = row_count;
  perform set_config('cma.audit_keys_only', '', true);
  return next;
end
$$;
alter function cma.remove_uncounted_line_calls(uuid, uuid, text) owner to cma_owner;
revoke execute on function cma.remove_uncounted_line_calls(uuid, uuid, text) from public;

-- Applies the rule to every line already marked not counted, in every tenant: one row per
-- connection with lines, in tenant and connection order, with the lines not counted and what was
-- removed. Owner only; a rerun removes nothing and answers zeros.
create or replace function cma.remove_all_uncounted_line_calls()
returns table (tenant text, connection text, connection_id uuid, lines_not_counted integer,
               calls_removed integer, taggings_removed integer, links_removed integer)
language plpgsql
as $$
#variable_conflict use_column
declare
  c record;
  n record;
  r record;
begin
  for c in
    select t.slug, x.tenant_id as tid, x.id as cid, x.name as cname
    from cma.integration_connection x
    join cma.tenant t on t.id = x.tenant_id
    where exists (select 1 from cma.telephony_number l where l.tenant_id = x.tenant_id and l.connection_id = x.id)
    order by t.slug, x.name, x.id
  loop
    tenant := c.slug;
    connection := c.cname;
    connection_id := c.cid;
    lines_not_counted := 0;
    calls_removed := 0;
    taggings_removed := 0;
    links_removed := 0;
    for n in
      select l.number_ref from cma.telephony_number l
      where l.tenant_id = c.tid and l.connection_id = c.cid and not l.is_counted
      order by l.number_ref
    loop
      select * into r from cma.remove_uncounted_line_calls(c.tid, c.cid, n.number_ref);
      lines_not_counted := lines_not_counted + 1;
      calls_removed := calls_removed + r.calls;
      taggings_removed := taggings_removed + r.taggings;
      links_removed := links_removed + r.links;
    end loop;
    return next;
  end loop;
end
$$;
alter function cma.remove_all_uncounted_line_calls() owner to cma_owner;
revoke execute on function cma.remove_all_uncounted_line_calls() from public;

-- ---------------------------------------------------------------------------------------------
-- 3. The call write: calls on a line that does not count are skipped
-- ---------------------------------------------------------------------------------------------
-- As in 0007a (34_telephony.sql), plus: the batch's lines are locked shared first (in line order),
-- and a call whose numberRef is a line of this connection with is_counted false is not written:
-- outcome skipped_uncounted_line. A call on a line not yet in the catalog is stored as before.
-- Upserts telephony calls as the source answered them, at most 500:
--   [{sourceId, direction, status, missedReason, startedAt, answeredAt, endedAt, durationSeconds,
--     userRef, numberRef, counterpartHash, isArchived, versionAt, deletedAt?, tags?, raw?}]
-- versionAt (the event's or the read's time) is the stale guard: a call older than the stored
-- version is stale and changes nothing. tags, when present, is the call's whole current tag set
-- (tag refs, or {tagRef, name}): tags no longer in it are closed and new ones opened, both at
-- versionAt; an absent tags key leaves the tags as they are, an empty list closes them all. A tag
-- not yet in the catalog joins it, counted, with its name or its ref. A deleted call keeps its id,
-- times and tags and loses its hash and raw payload. Outcomes: inserted, updated, stale, deleted,
-- unknown (a deletion of a call never seen), skipped_uncounted_line.
create or replace function cma.ingest_upsert_telephony_calls(p_connection_id uuid, p_calls jsonb)
returns table (source_id text, outcome text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_system   text;
  c          jsonb;
  v_src      text;
  v_version  timestamptz;
  v_deleted  timestamptz;
  v_old      cma.telephony_call;
  v_dir      text;
  v_tags     text[];
  t          jsonb;
  v_ref      text;
  v_line     text;
begin
  perform cma.assert_permission('ingest.write');
  v_system := cma.active_connection_adapter(p_connection_id);
  if p_calls is null or jsonb_typeof(p_calls) <> 'array' or jsonb_array_length(p_calls) > 500 then
    raise exception 'calls must be an array of at most 500' using errcode = 'CMA04';
  end if;
  -- the batch's lines, shared, in line order: a line being switched off waits for this batch
  for v_line in
    select distinct nullif(btrim(e ->> 'numberRef'), '') as ref
    from jsonb_array_elements(p_calls) e
    where jsonb_typeof(e) = 'object' and nullif(btrim(e ->> 'numberRef'), '') is not null
    order by 1
  loop
    perform pg_advisory_xact_lock_shared(hashtextextended(v_tenant::text || '/telephony_line/' || p_connection_id::text || '/' || v_line, 0));
  end loop;
  for c in select value from jsonb_array_elements(p_calls) loop
    v_src := btrim(c ->> 'sourceId');
    if coalesce(v_src, '') = '' then
      raise exception 'every call needs a sourceId' using errcode = 'CMA04';
    end if;
    v_version := cma.json_time(c -> 'versionAt', 'versionAt');
    v_deleted := cma.json_time(c -> 'deletedAt', 'deletedAt');

    -- a line of this connection that does not count: the call is not stored
    v_line := nullif(btrim(c ->> 'numberRef'), '');
    if v_line is not null and exists (select 1 from cma.telephony_number n
                                      where n.tenant_id = v_tenant and n.connection_id = p_connection_id
                                        and n.number_ref = v_line and not n.is_counted) then
      return query select v_src, 'skipped_uncounted_line'::text;
      continue;
    end if;

    select * into v_old from cma.telephony_call tc
    where tc.tenant_id = v_tenant and tc.connection_id = p_connection_id and tc.source_id = v_src
    for update;

    if v_deleted is not null then
      if v_old.id is null then
        return query select v_src, 'unknown'::text;
      else
        update cma.telephony_call tc
           set source_deleted_at = v_deleted, counterpart_hash = null, raw = '{}'::jsonb, synced_at = now(),
               source_version_at = greatest(tc.source_version_at, coalesce(v_version, tc.source_version_at))
         where tc.tenant_id = v_tenant and tc.id = v_old.id;
        return query select v_src, 'deleted'::text;
      end if;
      continue;
    end if;

    if v_version is null then
      raise exception 'every call needs a versionAt (the time of its event or read)' using errcode = 'CMA04';
    end if;
    if v_old.id is not null and v_version < v_old.source_version_at then
      return query select v_src, 'stale'::text;
      continue;
    end if;

    v_dir := lower(btrim(c ->> 'direction'));
    if v_dir is null or v_dir not in ('inbound', 'outbound') then
      raise exception 'direction must be inbound or outbound, got %', c ->> 'direction' using errcode = 'CMA04';
    end if;
    if c ? 'isArchived' and jsonb_typeof(c -> 'isArchived') not in ('boolean', 'null') then
      raise exception 'isArchived must be true or false' using errcode = 'CMA04';
    end if;
    if c ? 'tags' and jsonb_typeof(c -> 'tags') not in ('array', 'null') then
      raise exception 'tags must be a list of tag refs' using errcode = 'CMA04';
    end if;

    if v_old.id is null then
      insert into cma.telephony_call (tenant_id, connection_id, source_system, source_id, direction, status, missed_reason,
                                      started_at, answered_at, ended_at, duration_seconds, user_ref, number_ref,
                                      counterpart_hash, is_archived, source_version_at, raw)
      values (v_tenant, p_connection_id, v_system, v_src, v_dir, nullif(btrim(c ->> 'status'), ''),
              nullif(btrim(c ->> 'missedReason'), ''),
              cma.json_time(c -> 'startedAt', 'startedAt'), cma.json_time(c -> 'answeredAt', 'answeredAt'),
              cma.json_time(c -> 'endedAt', 'endedAt'), (c ->> 'durationSeconds')::integer,
              nullif(btrim(c ->> 'userRef'), ''), nullif(btrim(c ->> 'numberRef'), ''),
              nullif(lower(btrim(c ->> 'counterpartHash')), ''), coalesce((c ->> 'isArchived')::boolean, false),
              v_version, cma.telephony_raw(c -> 'raw'));
    else
      update cma.telephony_call tc
         set direction = v_dir,
             status = nullif(btrim(c ->> 'status'), ''),
             missed_reason = nullif(btrim(c ->> 'missedReason'), ''),
             started_at = cma.json_time(c -> 'startedAt', 'startedAt'),
             answered_at = cma.json_time(c -> 'answeredAt', 'answeredAt'),
             ended_at = cma.json_time(c -> 'endedAt', 'endedAt'),
             duration_seconds = (c ->> 'durationSeconds')::integer,
             user_ref = nullif(btrim(c ->> 'userRef'), ''),
             number_ref = nullif(btrim(c ->> 'numberRef'), ''),
             counterpart_hash = nullif(lower(btrim(c ->> 'counterpartHash')), ''),
             is_archived = coalesce((c ->> 'isArchived')::boolean, false),
             source_version_at = v_version,
             source_deleted_at = null,
             synced_at = now(),
             raw = cma.telephony_raw(c -> 'raw')
       where tc.tenant_id = v_tenant and tc.id = v_old.id;
    end if;

    -- the tag set, by difference at versionAt
    if jsonb_typeof(c -> 'tags') = 'array' then
      if jsonb_array_length(c -> 'tags') > 50 then
        raise exception 'at most 50 tags per call' using errcode = 'CMA04';
      end if;
      v_tags := '{}';
      for t in select value from jsonb_array_elements(c -> 'tags') loop
        v_ref := cma.telephony_tag_ref(t);
        if v_ref is null or length(v_ref) > 100 then
          raise exception 'every tag needs a tagRef of 1 to 100 characters' using errcode = 'CMA04';
        end if;
        insert into cma.telephony_tag (tenant_id, connection_id, tag_ref, name)
        values (v_tenant, p_connection_id, v_ref,
                left(coalesce(nullif(btrim(case when jsonb_typeof(t) = 'object' then t ->> 'name' end), ''), v_ref), 100))
        on conflict (tenant_id, connection_id, tag_ref) do nothing;
        v_tags := array_append(v_tags, v_ref);
      end loop;
      update cma.telephony_call_tag ct set untagged_at = v_version
      where ct.tenant_id = v_tenant and ct.connection_id = p_connection_id and ct.call_source_id = v_src
        and ct.untagged_at is null and not (ct.tag_ref = any (v_tags));
      insert into cma.telephony_call_tag (tenant_id, connection_id, call_source_id, tag_ref, tagged_at)
      select distinct v_tenant, p_connection_id, v_src, x.ref, v_version
      from unnest(v_tags) x(ref)
      where not exists (select 1 from cma.telephony_call_tag ct
                        where ct.tenant_id = v_tenant and ct.connection_id = p_connection_id and ct.call_source_id = v_src
                          and ct.tag_ref = x.ref and ct.untagged_at is null);
    end if;
    return query select v_src, case when v_old.id is null then 'inserted' else 'updated' end;
  end loop;
exception
  when check_violation or not_null_violation or invalid_text_representation or numeric_value_out_of_range or unique_violation then
    raise exception 'invalid telephony call: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Switching a line off removes its calls
-- ---------------------------------------------------------------------------------------------
-- After an insert of a line that does not count, or an update of is_counted from true to false,
-- the line's calls go (section 2). SECURITY DEFINER, owned by cma_owner, search path pinned: the
-- application cannot delete from the telephony tables, and a trigger function cannot be called
-- directly. The row is the tenant's own (row-level security on cma.telephony_number), and the
-- deletes name its tenant, connection and line. The catalog refresh never writes is_counted, so it
-- never fires this.
create or replace function cma.remove_calls_of_uncounted_line()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, cma, pg_temp
as $$
begin
  if not new.is_counted then
    if tg_op = 'INSERT' then
      perform cma.remove_uncounted_line_calls(new.tenant_id, new.connection_id, new.number_ref);
    elsif old.is_counted then
      perform cma.remove_uncounted_line_calls(new.tenant_id, new.connection_id, new.number_ref);
    end if;
  end if;
  return null;
end
$$;
alter function cma.remove_calls_of_uncounted_line() owner to cma_owner;
revoke execute on function cma.remove_calls_of_uncounted_line() from public;

create or replace trigger remove_uncounted_calls after insert or update of is_counted on cma.telephony_number
  for each row execute function cma.remove_calls_of_uncounted_line();

-- ---------------------------------------------------------------------------------------------
-- 5. Grants: the call write stays the application's; the removals are the owner's
-- ---------------------------------------------------------------------------------------------
revoke execute on function cma.ingest_upsert_telephony_calls(uuid, jsonb) from public;
grant execute on function cma.ingest_upsert_telephony_calls(uuid, jsonb) to cma_app;

insert into cma.schema_migration (version, description)
values ('0008f', 'Uncounted lines: a telephony connection stores calls on its counted lines only; a call on a line that does not count is skipped, switching a line off removes its calls, taggings and links (ids only in the audit for those deletes)')
on conflict (version) do nothing;

-- ---------------------------------------------------------------------------------------------
-- 6. Lines already marked not counted: their calls go now. One row per connection with lines;
--    the last result of this script. A rerun answers zeros.
-- ---------------------------------------------------------------------------------------------
select * from cma.remove_all_uncounted_line_calls();

commit;
reset role;
