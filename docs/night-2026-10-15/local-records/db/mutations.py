import subprocess, re, sys
src = open('/home/user/cma/db/66_invitations.sql').read()
M = [
 ("audit keeps the hash", """  if tg_table_schema = 'cma' and tg_table_name = 'invitation' then
    v_old := v_old - 'token_hash';
    v_new := v_new - 'token_hash';
  end if;
""", ""),
 ("the application reads every column", "revoke select, update, delete on cma.invitation from cma_app;", "revoke update, delete on cma.invitation from cma_app;"),
 ("acceptance without the system-role check", """    if not exists (select 1 from cma.app_role r where r.tenant_id = inv.tenant_id and r.id = inv.role_id and r.is_assignable) then
      raise exception 'the role is not assignable' using errcode = 'CMA06';
    end if;
""", ""),
 ("acceptance without the address comparison", """  if v_email <> inv.email then
    return query select 'wrong_account'::text, null::uuid, null::uuid;
    return;
  end if;
""", ""),
 ("creation without the role ceiling", "  perform cma.assert_role_assignable(v_key);\n", ""),
 ("acceptance leaves the invitation's tenant set", """  perform set_config('app.tenant_id', coalesce(v_prev_t, ''), true);
  perform set_config('app.user_id', coalesce(v_prev_u, ''), true);
  perform set_config('app.actor_label', coalesce(v_prev_l, ''), true);
  return query select 'accepted'::text, inv.tenant_id, v_user;""", """  return query select 'accepted'::text, inv.tenant_id, v_user;"""),
 ("acceptance without the expiry", """  if inv.expires_at <= now() then
    return query select 'expired'::text, null::uuid, null::uuid;
    return;
  end if;
""", ""),
 ("valid days without the range", """  elsif new.key = 'auth.invitation_valid_days'
        and (case when length(new.value) > 3 then true else new.value::integer not between 1 and 30 end) then
    raise exception 'Setting % takes a whole number of days from 1 to 30', new.key using errcode = 'CMA04';
""", ""),
 ("acceptance matches an existing person by address", """    if exists (select 1 from cma.app_user u where u.tenant_id = inv.tenant_id and u.email = inv.email) then
      raise exception 'a person with this address exists' using errcode = 'CMA03';
    end if;
""", ""),
 ("a shorter token", "select translate(rtrim(encode(sha256(uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid())),\n                                'base64'), '='), '+/', '-_')",
   "select translate(rtrim(encode(uuid_send(gen_random_uuid()), 'base64'), '='), '+/', '-_')"),
 ("acceptance without the linked-id check", """  if exists (select 1 from cma.app_user_external_id x where x.tenant_id = inv.tenant_id and x.system = v_system and x.external_id = v_login) then
    return query select 'already_member'::text, inv.tenant_id, null::uuid;
    return;
  end if;
""", ""),
 ("acceptance twice", """  if inv.accepted_at is not null then
    return query select 'invalid'::text, null::uuid, null::uuid;
    return;
  end if;
""", ""),
 ("acceptance without a pinned search path", """language plpgsql security definer
set search_path = pg_catalog, cma, pg_temp
as $$
#variable_conflict use_column
declare
  v_system""", """language plpgsql security definer
as $$
#variable_conflict use_column
declare
  v_system"""),
 ("the list shows managing roles to a manager", "      and (v_all or not cma.role_is_managing(i.role_id))\n", "\n"),
 ("renew keeps the old token", "  set token_hash = cma.invitation_token_hash(v_token), expires_at = v_expires,", "  set expires_at = v_expires,"),
 ("revoke without the ceiling", "  perform cma.assert_role_assignable(inv.role_key);\n", ""),
 ("acceptance as the original inviter after a renewal by another", "coalesce(i.renewed_by, i.created_by) as inviter", "i.created_by as inviter"),
 ("acceptance without the other-tenant check", """  if cma.invitation_other_tenant(inv.tenant_id, v_system, v_login) then
    return query select 'other_tenant'::text, null::uuid, null::uuid;
    return;
  end if;
""", ""),
 ("domain check dropped", """  if not cma.invitation_domain_allowed(cma.current_tenant_id(), p_email) then
    raise exception 'the address is outside the email domains invitations may go to' using errcode = 'CMA04';
  end if;
""", ""),
]
out = open('mut/mutations.txt', 'w')
for i, (name, old, new) in enumerate(M, 1):
    assert src.count(old) == 1, (name, src.count(old))
    open('mut/66m.sql', 'w').write(src.replace(old, new))
    db = 'tmut'
    subprocess.run(['psql','-h','/tmp','-U','postgres','-d','postgres','-qc',f'drop database if exists {db}','-c',f'create database {db} template cma65'], check=True, capture_output=True)
    r = subprocess.run(['psql','-h','/tmp','-U','martin@pulse4all.com','-d',db,'-v','ON_ERROR_STOP=1','-qf','mut/66m.sql'], capture_output=True, text=True)
    if r.returncode != 0:
        line = f'{i:2} {name}: the mutated 66 does not run: {r.stderr.strip().splitlines()[-1][:150]}'
    else:
        v = subprocess.run(['psql','-h','/tmp','-U','martin@pulse4all.com','-d',db,'-At','-F','|','-f','/home/user/cma/db/67_verify_invitations.sql'], capture_output=True, text=True).stdout
        fails = [(l.split('|')[0].split(' ')[0] if not l.startswith('B the block') else 'B39 (the block stopped: ' + l.split('|')[2][:90] + ')')
                 for l in v.splitlines() if '|FAIL|' in l and not l.startswith('verdict')]
        verdict = [l for l in v.splitlines() if l.startswith('verdict')]
        line = f'{i:2} {name}: caught by {", ".join(fails) or "NOTHING"} ({verdict[0] if verdict else "no verdict"})'
    print(line); out.write(line + '\n')
