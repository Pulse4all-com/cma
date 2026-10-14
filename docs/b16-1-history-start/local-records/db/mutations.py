import subprocess, re, sys, pathlib
S = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/mutations")
S.mkdir(parents=True, exist_ok=True)
src = pathlib.Path("/home/user/cma/db/64_calls_history_start.sql").read_text()
V65 = "/home/user/cma/db/65_verify_calls_history_start.sql"
def rep(old, new):
    assert src.count(old) == 1, old
    return src.replace(old, new)
M = [
 ("the tenant's zone instead of the line's",
  rep("      return (select min(c.business_date)\n", "      return (select min((c.started_at at time zone (select timezone from cma.tenant where id = p_tenant_id))::date)\n")),
 ("the first call's date by instant, no two-day window",
  rep("      v_to := v_first + interval '2 days';", "      v_to := v_first + interval '1 second';")),
 ("a window of one day after the earliest call instead of two",
  rep("      v_to := v_first + interval '2 days';", "      v_to := v_first + interval '1 day';")),
 ("no step past a window without a call: null",
  rep("    select min(tc.started_at) into v_at\n    from cma.telephony_call tc\n    where tc.tenant_id = p_tenant_id and tc.started_at >= v_to;", "    v_at := null;")),
 ("the earliest stored row, deleted or not, on any line",
  rep("  while v_at is not null loop", "  return (v_at at time zone 'Europe/Amsterdam')::date;\n  while v_at is not null loop")),
 ("the application's read without the permission check",
  rep("  perform cma.assert_any_permission(array['reports.view', 'performance.team']);\n  return cma.telephony_history_start_of(v_tenant);", "  return cma.telephony_history_start_of(v_tenant);")),
 ("performance.team only",
  rep("  perform cma.assert_any_permission(array['reports.view', 'performance.team']);\n  return cma.telephony_history_start_of(v_tenant);", "  perform cma.assert_permission('performance.team');\n  return cma.telephony_history_start_of(v_tenant);")),
 ("the application's read in the owner's rights",
  rep("returns date\nlanguage plpgsql stable\nas $$\ndeclare\n  v_tenant", "returns date\nlanguage plpgsql stable security definer\nas $$\ndeclare\n  v_tenant")),
 ("executable by everyone",
  rep("    execute format('revoke execute on function %s from public', f);\n", "")),
 ("the start-index probe over every tenant's rows (equivalent: cma.calls_of still reads the tenant's calls only, so it walks more windows to the same answer)",
  src.replace("where tc.tenant_id = p_tenant_id and tc.started_at is not null;", "where tc.started_at is not null;").replace("where tc.tenant_id = p_tenant_id and tc.started_at >= v_to;", "where tc.started_at >= v_to;")),
 ("the application's read for no tenant",
  rep("  return cma.telephony_history_start_of(v_tenant);", "  return cma.telephony_history_start_of(null);")),
 ("the earliest business date within the window the earliest call was found in, not up to two days after it",
  rep("      v_to := v_first + interval '2 days';\n", "      v_to := v_at + interval '7 days';\n")),
 ("the history start one day early",
  rep("      return (select min(c.business_date)\n", "      return (select min(c.business_date) - 1\n")),
 ("no record of the addition",
  rep("insert into cma.schema_migration (version, description)\nvalues ('0008k'", "insert into cma.schema_migration (version, description)\nselect * from (values ('0008k-x'")
    .replace("so the Calls report shows no change against a period before it')\non conflict", "so the Calls report shows no change against a period before it')) v where false\non conflict")),
]
P = ["psql", "-h", "/tmp", "-p", "54318", "-X", "-q"]
out = []
for i, (name, text) in enumerate(M, 1):
    f = S / f"m{i:02d}.sql"
    f.write_text(text)
    subprocess.run(P + ["-U", "postgres", "-d", "postgres", "-c", "drop database if exists cmamut", "-c", "create database cmamut template cma_at63"], check=True, capture_output=True)
    r = subprocess.run(P + ["-U", "martin@pulse4all.com", "-d", "cmamut", "-v", "ON_ERROR_STOP=1", "-f", str(f)], capture_output=True, text=True)
    if r.returncode != 0:
        out.append(f"M{i:02d} {name}: 64 itself failed: {r.stderr.strip()[-200:]}")
        continue
    r = subprocess.run(P + ["-U", "martin@pulse4all.com", "-d", "cmamut", "-f", V65], capture_output=True, text=True)
    fails = [l.split("|")[0].strip().split(" ")[0] for l in r.stdout.splitlines() if "| FAIL" in l]
    verdict = [l for l in r.stdout.splitlines() if l.strip().startswith("verdict")]
    caught = "caught by " + ", ".join(fails) if fails else "NOT CAUGHT"
    out.append(f"M{i:02d} {name}: {caught}; {verdict[0].split('|',1)[1].strip() if verdict else 'no verdict'}")
print("\n".join(out))
