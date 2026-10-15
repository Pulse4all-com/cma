# Mutations of db/68_email_activity.sql: each one applied to a fresh copy of the local database at 67
# (template cma_at67), then db/69_verify_email_activity.sql run; a mutation is caught when a check fails.
import subprocess, sys, pathlib
S = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/mutations")
S.mkdir(parents=True, exist_ok=True)
src = pathlib.Path("/home/user/cma/db/68_email_activity.sql").read_text()
V69 = "/home/user/cma/db/69_verify_email_activity.sql"
def rep(old, new, text=None):
    t = src if text is None else text
    assert t.count(old) == 1, old
    return t.replace(old, new)
M = [
 ("an inbox refresh resets counted",
  rep("      do update set name = excluded.name, status = 'active', refreshed_at = now();\n  end loop;\n  update cma.connection_inbox b",
      "      do update set name = excluded.name, status = 'active', refreshed_at = now(), is_counted = true;\n  end loop;\n  update cma.connection_inbox b")),
 ("an inbox missing from the source stays active",
  rep("  update cma.connection_inbox b set status = 'archived'", "  update cma.connection_inbox b set status = 'active'")),
 ("a new channel counts whatever its kind",
  rep("            v_kind = 'email', 'active', now())", "            true, 'active', now())")),
 ("no stale guard on emails",
  rep("    if v_old.id is not null and v_old.source_updated_at is not null\n       and (v_updated is null or v_updated < v_old.source_updated_at) then\n      return query select v_kind, v_src, 'stale'::text;",
      "    if false then\n      return query select v_kind, v_src, 'stale'::text;")),
 ("no stale guard on threads",
  rep("    if v_old.id is not null and v_old.source_updated_at is not null\n       and (v_updated is null or v_updated < v_old.source_updated_at) then\n      return query select v_src, 'stale'::text;",
      "    if false then\n      return query select v_src, 'stale'::text;")),
 ("a deletion keeps the raw payload",
  rep("update cma.email_message em set source_deleted_at = v_deleted, raw = '{}'::jsonb, synced_at = now()",
      "update cma.email_message em set source_deleted_at = v_deleted, synced_at = now()")),
 ("a later closed read without a close time moves closed_at",
  rep("then coalesce(v_closed, case when et.status = 'closed' then et.closed_at end, now()) end,",
      "then coalesce(v_closed, now()) end,")),
 ("a known thread event answers inserted",
  rep("return query select v_src, case when v_id is null then 'known' else 'inserted' end;",
      "return query select v_src, 'inserted'::text;")),
 ("the deal before the ticket",
  rep("order by (a.to_type = 'ticket') desc, cr.source_created_at desc", "order by (a.to_type = 'ticket') asc, cr.source_created_at desc")),
 ("a removed association still gives the market",
  rep("and a.from_type = 'crm_email' and a.from_id = p_source_id and a.to_type in ('ticket', 'deal') and a.removed_at is null",
      "and a.from_type = 'crm_email' and a.from_id = p_source_id and a.to_type in ('ticket', 'deal')")),
 ("a deleted record still gives the market",
  rep("          and cr.source_deleted_at is null and cma.market_code_of(p_tenant_id, cr.market) is not null",
      "          and cma.market_code_of(p_tenant_id, cr.market) is not null")),
 ("the contact's country without the aliases",
  rep("        select cma.market_code_of(p_tenant_id, cc.country) into v_value",
      "        select (select m.code from cma.market m where m.tenant_id = p_tenant_id and m.code = upper(cc.country)) into v_value")),
 ("the market order setting ignored",
  rep("  v_order   text[] := string_to_array(cma.setting_of(p_tenant_id, 'email.market_order'), ',');",
      "  v_order   text[] := array['record', 'inbox', 'contact'];")),
 ("no unknown when no step finds a market",
  rep("  code := 'unknown';\n  source := null;", "  code := null;\n  source := null;")),
 ("rules by creation, not by their order",
  rep("  order by r.sort_order, r.created_at, r.id\n  limit 1", "  order by r.created_at, r.id\n  limit 1")),
 ("inactive rules applied",
  rep("  where r.tenant_id = p_tenant_id and r.connection_id = p_connection_id and r.status = 'active'\n",
      "  where r.tenant_id = p_tenant_id and r.connection_id = p_connection_id\n")),
 ("exclude words ignored",
  rep("     and not exists (select 1 from unnest(coalesce(p_exclude, '{}')) w where strpos(lower(p_value), w) > 0)",
      "     and true")),
 ("rule words matched with case",
  rep("     and exists (select 1 from unnest(p_words) w where strpos(lower(p_value), w) > 0)",
      "     and exists (select 1 from unnest(p_words) w where strpos(p_value, w) > 0)")),
 ("rule words kept in their case",
  rep("  from (select lower(btrim(x)) as w, min(ord) as first_at\n        from unnest(coalesce(p_words, '{}')) with ordinality as u(x, ord)\n        where nullif(btrim(x), '') is not null\n        group by lower(btrim(x))) t",
      "  from (select btrim(x) as w, min(ord) as first_at\n        from unnest(coalesce(p_words, '{}')) with ordinality as u(x, ord)\n        where nullif(btrim(x), '') is not null\n        group by btrim(x)) t")),
 ("the contact forget leaves threads",
  rep("  update cma.email_thread et set contact_source_id = null, synced_at = now()\n  where et.tenant_id = v_tenant and et.connection_id = p_connection_id and et.contact_source_id = p_contact_source_id;",
      "  update cma.email_thread et set synced_at = now()\n  where et.tenant_id = v_tenant and et.connection_id = p_connection_id and et.contact_source_id = p_contact_source_id;")),
 ("the contact forget answers the email keys always",
  rep("  if v_e > 0 then\n    v_res := v_res || jsonb_build_object('emails', v_e);\n  end if;",
      "  v_res := v_res || jsonb_build_object('emails', v_e);")),
 ("the thread forget does not mark the thread forgotten",
  rep("         forgotten_at = coalesce(et.forgotten_at, now()), synced_at = now()", "         synced_at = now()")),
 ("the thread forget clears email engagements too",
  rep("  where em.tenant_id = v_tenant and em.connection_id = p_connection_id and em.source_kind = 'inbox_message'\n    and em.thread_source_id = p_thread_source_id",
      "  where em.tenant_id = v_tenant and em.connection_id = p_connection_id\n    and em.thread_source_id = p_thread_source_id")),
 ("a message of a forgotten thread keeps its contact",
  rep("    v_forgotten := v_kind = 'inbox_message' and exists (", "    v_forgotten := false and exists (")),
 ("a forgotten thread read again",
  rep("    if v_old.id is not null and v_old.forgotten_at is not null then\n      return query select v_src, 'forgotten'::text;\n      continue;\n    end if;\n", "")),
 ("the email write without the permission check",
  rep("  perform cma.assert_permission('ingest.write');\n  v_system := cma.assert_email_connection(p_connection_id, true);\n  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then\n    raise exception 'emails must",
      "  v_system := cma.assert_email_connection(p_connection_id, true);\n  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then\n    raise exception 'emails must")),
 ("set_inbox without the permission check",
  rep("  perform cma.assert_permission('tenant.configure');\n  perform cma.assert_email_connection(p_connection_id, false);\n  if coalesce(p_inbox_id, '') = ''",
      "  perform cma.assert_email_connection(p_connection_id, false);\n  if coalesce(p_inbox_id, '') = ''")),
 ("the raw payload keeps strings with an @",
  rep("                     and strpos(e.value #>> '{}', '@') = 0\n", "")),
 ("the raw payload keeps a subject",
  rep("e.key !~* '(subject|body|text|", "e.key !~* '(body|text|")),
 ("an owner ref may hold an @",
  rep("  owner_ref           text check (owner_ref ~ '^[^@[:space:]]{1,100}$'),\n  category            text check (category ~ '^[a-z][a-z0-9_]{0,59}$'),\n  contact_source_id   text check (contact_source_id ~ '^[^@[:space:]]{1,100}$'),\n  source_created_at   timestamptz,",
      "  owner_ref           text check (length(owner_ref) between 1 and 100),\n  category            text check (category ~ '^[a-z][a-z0-9_]{0,59}$'),\n  contact_source_id   text check (contact_source_id ~ '^[^@[:space:]]{1,100}$'),\n  source_created_at   timestamptz,")),
 ("an owner ref for a customer",
  rep("  check (owner_ref is null or actor_kind = 'agent'),\n  check (source_kind <> 'inbox_message' or thread_source_id is not null),",
      "  check (source_kind <> 'inbox_message' or thread_source_id is not null),")),
 ("email activity on any kind of connection",
  rep("  if (v_kind is not null and v_kind <> 'crm')\n     or (v_kind is null and exists (select 1 from unnest(cma.connection_held_kinds_of(v_tenant, p_connection_id)) k where k <> 'crm')) then",
      "  if false then")),
 ("email rows imply no kind",
  rep("           or exists (select 1 from cma.connection_inbox x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)\n", "")),
 ("an association to an email not turned around",
  rep("    if v_ft = 'contact' or v_tt in ('crm_call', 'crm_email') then", "    if v_ft = 'contact' or v_tt = 'crm_call' then")),
 ("connection_config without the inboxes",
  rep("    'inboxes', coalesce(", "    'inboxes_x', coalesce(")),
 ("thread marks without the events",
  rep("         greatest(m.last_at, v.last_at),", "         m.last_at,")),
 ("no email_poll job",
  rep("check (job in ('backfill', 'reconcile', 'forms_poll', 'subscriptions_check', 'link_calls', 'email_poll'));",
      "check (job in ('backfill', 'reconcile', 'forms_poll', 'subscriptions_check', 'link_calls'));")),
 ("no row-level security on emails",
  rep("select cma.setup_tenant_table('cma.email_message');\n", "")),
 ("the application may delete threads",
  rep("revoke delete on cma.connection_inbox, cma.connection_inbox_channel, cma.connection_email_rule,\n                 cma.email_thread, cma.email_message,",
      "revoke delete on cma.connection_inbox, cma.connection_inbox_channel, cma.connection_email_rule,\n                 cma.email_message,")),
 ("the application may change thread events",
  rep("revoke update on cma.email_thread_event from cma_app;\n", "")),
 ("the message view shows raw",
  rep("         source_deleted_at, synced_at\n  from cma.email_message\n", "         source_deleted_at, synced_at, raw\n  from cma.email_message\n")),
 ("the category rule executable by the application",
  rep("  execute 'revoke execute on function cma.email_category_of(uuid,uuid,text,text) from public';",
      "  execute 'grant execute on function cma.email_category_of(uuid,uuid,text,text) to cma_app';")),
 ("the reply target's default 120",
  rep("  ('email.reply_target_minutes', 'integer', null, '240',", "  ('email.reply_target_minutes', 'integer', null, '120',")),
 ("the market order taken unchecked",
  rep("  elsif new.key = 'email.market_order' and not cma.is_email_market_order(new.value) then", "  elsif new.key = 'email.market_order' and false then")),
 ("the reply target unbounded",
  rep("        and (case when length(new.value) > 5 then true else new.value::integer not between 1 and 10080 end) then",
      "        and false then")),
 ("the start date without intake.start_date",
  rep("  select coalesce(nullif(cma.setting_of(p_tenant_id, 'email.start_date'), ''), cma.setting_of(p_tenant_id, 'intake.start_date'))::date",
      "  select coalesce(nullif(cma.setting_of(p_tenant_id, 'email.start_date'), ''), '2026-10-01')::date")),
 ("the actor kind ai refused",
  rep("  actor_kind            text not null default 'unknown'\n                          check (actor_kind in ('agent', 'customer', 'system', 'bot', 'ai', 'integration', 'unknown')),\n  owner_ref             text check",
      "  actor_kind            text not null default 'unknown'\n                          check (actor_kind in ('agent', 'customer', 'system', 'bot', 'integration', 'unknown')),\n  owner_ref             text check")),
 ("no record of the addition",
  rep("insert into cma.schema_migration (version, description)\nvalues ('0008m'", "insert into cma.schema_migration (version, description)\nselect * from (values ('0008m-x'")
    .replace("the privacy deletions, the reporting views')\non conflict", "the privacy deletions, the reporting views')) v where false\non conflict")),
]
P = ["psql", "-h", "/tmp", "-p", "54318", "-X", "-q"]
out = []
for i, (name, text) in enumerate(M, 1):
    f = S / f"m{i:02d}.sql"
    f.write_text(text)
    subprocess.run(P + ["-U", "postgres", "-d", "postgres", "-c", "drop database if exists cmamut", "-c", "create database cmamut template cma_at67"], check=True, capture_output=True)
    r = subprocess.run(P + ["-U", "martin@pulse4all.com", "-d", "cmamut", "-v", "ON_ERROR_STOP=1", "-f", str(f)], capture_output=True, text=True)
    if r.returncode != 0:
        out.append(f"M{i:02d} {name}: 68 itself failed: {r.stderr.strip()[-200:]}")
        continue
    r = subprocess.run(P + ["-U", "martin@pulse4all.com", "-d", "cmamut", "-f", V69], capture_output=True, text=True)
    fails = [l.split("|")[0].strip().split(" ")[0] for l in r.stdout.splitlines() if "| FAIL" in l and not l.strip().startswith("verdict")]
    verdict = [l for l in r.stdout.splitlines() if l.strip().startswith("verdict")]
    caught = "caught by " + ", ".join(fails) if fails else "NOT CAUGHT"
    out.append(f"M{i:02d} {name}: {caught}; {verdict[0].split('|',1)[1].strip() if verdict else 'no verdict'}")
print("\n".join(out))
