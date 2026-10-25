-- =============================================================================================
-- 102_tag_meaning_incorrect_data.sql: addition 0008zd, a seventh tag meaning: incorrect data
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 100_definitions_calls.sql (0008zc). Rerunnable, forward-only, in one transaction. Run as your own IAM login: dev
-- first, then 103_verify_tag_meaning_incorrect_data.sql and 101 again (dev); then prod, before or after the web deploy:
-- nothing is renamed and no read changes its columns, so the web of main runs unchanged on it
-- (docs/definitions-2026-10/RUNBOOK-0008zd.md).
--
-- docs/definitions.md (Tag, Conversation; Decision log, 25 October 2026, "Definitions: incorrect data as its own tag
-- meaning"): a tag can mean incorrect data, the contact data is wrong (a wrong number, incorrect data). Like not
-- reached, a call carrying a current tag of that meaning is never a Conversation. It is its own meaning, not folded
-- into not reached, so it can be reported apart later (a data-quality figure, definitions step 2). A tag keeps one
-- meaning. Connected is unaffected.
--
-- What it changes
--   tags           cma.telephony_tag.meaning: the check holds seven keys, incorrect_data added to not_reached, call_type,
--                  courtesy_attempt, courtesy_completed_positive, courtesy_completed_neutral and
--                  courtesy_completed_negative; cma.set_telephony_tag_meaning() accepts it
--   Conversation   cma.tag_meaning_excludes_conversation(meaning), new: the meanings that keep a call from being a
--                  Conversation (not_reached and incorrect_data), written once. cma.call_not_reached_of() reads it, so
--                  its not_reached is true for a current tag (untagged_at empty) of either meaning, whatever the tag's
--                  is_counted. cma.is_conversation() takes that flag as before and is not made again; every read that
--                  joins cma.call_not_reached_of (Calls, Calls per agent, a CRM call's conversation, Email's not
--                  responding, first orders, Attempts per deal and per agent) follows without a change
--   settings       the description of calls.conversation_min_talk_seconds names both meanings
--
-- Nothing is renamed: cma.call_not_reached_of keeps its name and its column not_reached, and cma.is_conversation its
-- argument p_not_reached, so every caller and the web of main keep working. No table, no column, no index, no view.
-- Everything is SECURITY INVOKER and executable by the application only, as before.
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA04 invalid, CMA06 not permitted.
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
  if not exists (select 1 from cma.schema_migration where version = '0008zc') then
    raise exception 'addition 0008zc (100_definitions_calls.sql) must run before 0008zd';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The seventh key
-- ---------------------------------------------------------------------------------------------
-- The check is replaced only while it lacks incorrect_data, so a rerun leaves it as it is. Every stored meaning is one
-- of the six keys or null, so the new check validates at once
do $$
begin
  if not exists (select 1 from pg_constraint
                 where conrelid = 'cma.telephony_tag'::regclass and conname = 'telephony_tag_meaning_check'
                   and pg_get_constraintdef(oid) ~ '''incorrect_data''') then
    alter table cma.telephony_tag drop constraint if exists telephony_tag_meaning_check;
    alter table cma.telephony_tag add constraint telephony_tag_meaning_check
      check (meaning in ('not_reached', 'incorrect_data', 'call_type', 'courtesy_attempt', 'courtesy_completed_positive',
                         'courtesy_completed_neutral', 'courtesy_completed_negative'));
  end if;
end
$$;
comment on column cma.telephony_tag.meaning is 'What the tag means (configuration, 0008zc; incorrect_data 0008zd): not_reached, incorrect_data, call_type, courtesy_attempt, courtesy_completed_positive, courtesy_completed_neutral or courtesy_completed_negative; null for none. A current tag meaning not_reached or incorrect_data keeps a call from being a conversation';

-- As 0008zc (100), with incorrect_data: sets or clears a tag's meaning (tenant.configure); a tag the catalog does not
-- hold yet is added with its ref as its name. p_meaning null clears it; a key outside the set is CMA04
create or replace function cma.set_telephony_tag_meaning(p_connection_id uuid, p_tag_ref text, p_meaning text)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if p_meaning is not null and p_meaning not in ('not_reached', 'incorrect_data', 'call_type', 'courtesy_attempt',
                                                 'courtesy_completed_positive', 'courtesy_completed_neutral',
                                                 'courtesy_completed_negative') then
    raise exception 'a tag''s meaning is not_reached, incorrect_data, call_type, courtesy_attempt, courtesy_completed_positive, courtesy_completed_neutral, courtesy_completed_negative or none, not %', p_meaning
      using errcode = 'CMA04';
  end if;
  insert into cma.telephony_tag (tenant_id, connection_id, tag_ref, name, meaning)
  values (cma.current_tenant_id(), p_connection_id, btrim(p_tag_ref), left(btrim(p_tag_ref), 100), p_meaning)
  on conflict (tenant_id, connection_id, tag_ref) do update set meaning = excluded.meaning;
exception when check_violation or not_null_violation then
  raise exception 'invalid tag: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. The meanings that exclude a call from Conversation, written once
-- ---------------------------------------------------------------------------------------------
-- Whether a tag's meaning keeps a call carrying it (as a current tag) from being a Conversation: not reached (a
-- voicemail box, a gatekeeper) or incorrect data (the contact data is wrong). The only place that names these keys
-- for Conversation; an immutable expression the planner inlines. Never null
create or replace function cma.tag_meaning_excludes_conversation(p_meaning text)
returns boolean
language sql immutable
as $$
  select coalesce(p_meaning in ('not_reached', 'incorrect_data'), false)
$$;

-- As 0008zc (100), by the helper above: whether a telephony call carries a current tag (untagged_at empty) whose
-- meaning excludes it from Conversation, not_reached or incorrect_data, whatever the tag's is_counted; false for a call
-- without one, or without a call (a null connection). The name and the column stay (nothing is renamed, so every
-- caller keeps working); not_reached reads "a current tag keeps it from being a conversation". One row, so a read joins
-- it laterally and the planner inlines it
create or replace function cma.call_not_reached_of(p_tenant_id uuid, p_connection_id uuid, p_call_source_id text)
returns table (not_reached boolean)
language sql stable
as $$
  select exists (select 1
                 from cma.telephony_call_tag ct
                 join cma.telephony_tag tg
                   on tg.tenant_id = ct.tenant_id and tg.connection_id = ct.connection_id and tg.tag_ref = ct.tag_ref
                 where ct.tenant_id = p_tenant_id and ct.connection_id = p_connection_id and ct.call_source_id = p_call_source_id
                   and ct.untagged_at is null and cma.tag_meaning_excludes_conversation(tg.meaning))
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The setting's description
-- ---------------------------------------------------------------------------------------------
update cma.setting
set description = 'A connected outbound or an answered inbound call is a conversation at this many seconds of talk time or more (0 to 600), unless a current tag means not reached or incorrect data'
where key = 'calls.conversation_min_talk_seconds';

-- ---------------------------------------------------------------------------------------------
-- 4. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.set_telephony_tag_meaning(uuid,text,text)',
    'cma.tag_meaning_excludes_conversation(text)',
    'cma.call_not_reached_of(uuid,uuid,text)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008zd', 'A seventh tag meaning (docs/definitions.md, Tag): incorrect_data, the contact data is wrong; cma.telephony_tag''s check and cma.set_telephony_tag_meaning accept it. Like not_reached it keeps a call from being a Conversation: cma.tag_meaning_excludes_conversation names the two meanings once and cma.call_not_reached_of reads it. Nothing renamed; the description of calls.conversation_min_talk_seconds names both meanings')
on conflict (version) do nothing;

commit;
reset role;
