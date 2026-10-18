# 5.3 Database and tenancy (`db/`): findings

**Summary.** Examined db/00..75 statically and live on the local PostgreSQL 16 copy (database `cma`, built from the scripts with the dev seeds; a faithful copy `cma_perf` loaded with about a year of synthetic volume for the Subscriptions tenant, see section "Synthetic volume"). Checked RLS and its fail-closed behaviour as the real `cma-web@local.iam` login, every SECURITY DEFINER function, all grants and default privileges, the `cma_read` views, foreign keys and indexes, function volatility, migration hygiene, error codes, timeouts and locks, and ran EXPLAIN (ANALYZE, BUFFERS) on every page function as the web login with the manager's or an agent's context. Time: about four hours. Most important: (1) CMA-037 item 2 is confirmed as observed: the real Ingest login, with a tenant context and no acting user, deletes a line's calls through a direct `UPDATE ... set is_counted = false` (DB-01, with the 0008q draft); (2) the audit log writes about 3.4 rows and five copies of each webhook payload per `ingest_event`, which makes `cma.audit_log` the growth driver (DB-02); (3) no statement or lock timeout exists anywhere while the connection budget is 83 of 93 (DB-03); (4) the `(p is null or col >= p)` bound pattern keeps the time indexes out of use in the report cores, so Reports → Calls and the lead reads scan the tenant's history for any period (DB-04, measured below). The foundation itself is sound: 73 tenant tables, one policy shape, fail-closed verified, owner cores without grants, no `cma_read` view exposing raw, hashes, tokens or secret names.

Severity counts: Critical 0, High 0, Medium 5 (DB-01, DB-02, DB-03, DB-04, DB-05), Low 4 (DB-06, DB-07, DB-08, DB-09), Info 4 (DB-10, DB-11, DB-12, DB-13).

Evidence files in `local-records/5.3-database/`: `rls-tables.tsv`, `policies.tsv`, `rls-fail-closed-test.txt`, `secdef-functions.txt`, `table-grants.tsv`, `column-grants.tsv`, `cma-views.tsv`, `cma_read-sensitive-columns.tsv`, `fk-without-index.tsv`, `indexes-hot-tables.tsv`, `read-functions-volatility.tsv`, `schema_migration.tsv`, `audit-amplification-local.tsv`, `cma-037-item2-test.txt`, `plans/*.txt`, `plans-summary.txt`. Scratch (queries, generator, bodies) under `/var/tmp/5.3/`.

---

### DB-01: A direct UPDATE of `telephony_number.is_counted` by the Ingest login deletes a line's calls with no acting user and no permission check (CMA-037 item 2, confirmed)
- Severity: Medium   Confidence: High   Effort: S
- Component: `db/54_uncounted_lines.sql` (trigger `remove_uncounted_calls`, function `cma.remove_calls_of_uncounted_line()`, SECURITY DEFINER), grants of 0007a on `cma.telephony_number`
- Evidence (observed, `local-records/5.3-database/cma-037-item2-test.txt`): on a throwaway tenant in `cma_perf` (a telephony connection, one counted line with 3 stored calls and 1 tagging, built through `upsert_connection`, `set_telephony_number` and `ingest_upsert_telephony_calls` as the verify scripts do), as the real login `cma-ingest@local.iam` (member of `cma_app`), `set_config('app.tenant_id', <tenant>, true)`, `app.user_id` empty, `app.actor_label = 'ingest-api:audit'`:
  - `has_table_privilege(current_user, 'cma.telephony_call', 'delete')` = f; `has_column_privilege(current_user, 'cma.telephony_number', 'is_counted', 'update')` = t (the full-table UPDATE grant of 0007a, `local-records/5.3-database/column-grants.tsv`).
  - `update cma.telephony_number set is_counted = false where number_ref = 'line-1'` → `UPDATE 1`; calls 3 → 0, taggings 1 → 0, inside the same statement.
  - The audit rows: `telephony_call delete ×3` and `telephony_call_tag delete ×1` with `actor_db_role = cma_owner`, `actor_user_id = (none)`, `actor_login = cma-ingest@local.iam`; the line's update row with `actor_db_role = cma-ingest@local.iam`. Rolled back.
  - The trigger function (`\sf cma.remove_calls_of_uncounted_line`) has no `assert_permission` and no check on the acting user; `tenant.configure` is asserted only inside `cma.set_telephony_number()` (`db/34_telephony.sql:552`). `55_verify_uncounted_lines.sql` B9 tests the Ingest user through `set_telephony_number` only (CMA06), never a direct UPDATE.
- Impact (in this system's context): the ingest service never writes `is_counted` (the catalog refresh of 0007a writes `name`, `digits`, `status`, `refreshed_at` only, `db/34_telephony.sql:466-470`), so no shipped code path takes this route. The exposure is defence in depth: a bug or an injected payload in the ingest service, or anyone with the `cma_app` rights (a team member testing with `set role cma_app`), can remove every stored call of a line in milliseconds with an audit trail that names no person, against README's statement for 0008f that "the audit names the person (`actor_user_id`)". The deleted calls come back only through a backfill that treats them as new. Data loss class, bounded to one tenant and one line per statement.
- Recommendation: option A below (assert the right inside the trigger, keep the grants), drafted as addition 0008q (`db/76_uncounted_lines_guard.sql` and `db/77_verify_uncounted_lines_guard.sql`). Option B (revoke `update (is_counted)` from `cma_app` and route through `set_telephony_number`) is rejected here because `set_telephony_number` runs in the caller's rights by design (`55` A4 asserts it is not SECURITY DEFINER and the application's only), so it would have to become SECURITY DEFINER itself, widening that surface and changing a verified contract. Option A keeps `55` A2's exact assertions about the trigger function (SECURITY DEFINER, owner `cma_owner`, `search_path=pg_catalog, cma, pg_temp`, executable by nobody) and adds nothing to the application's rights.
- README check: already open (CMA-037 item 2). README (Data model: uncounted lines) says the trigger fires on "any other update" and that "the audit names the person"; the second sentence does not hold for a direct update without an acting user. The Decision log of 13 October 2026 (FIND-01 rejected: "the accident risk is closed by B9a.1") concerns the Sources screen's confirmation, not the database path; new information does not reopen it, the fix is additive.
- Disproof attempt: checked whether RLS or a column grant stops the write (no: `cma_app` holds UPDATE on all ten columns of `telephony_number`, the policy allows the tenant's own rows); checked whether `assert_permission` runs anywhere on the path (`\sf` of the trigger function and of `remove_uncounted_line_calls`: neither asserts); checked whether the ingest's own code writes `is_counted` (grep of `ingest/src` for `is_counted`/`set_telephony_number`: no writer; only the web app's Sources page calls `set_telephony_number`). The finding stands as a defence-in-depth gap with a demonstrated path, not as an exploited one.

**Draft 0008q, `db/76_uncounted_lines_guard.sql`** (complete; follows README, Conventions for every migration; one transaction; rerunnable; no new table, so no `setup_tenant_table`, no catalog change; the datamap is untouched because no table, view or column changes):

```sql
-- =============================================================================================
-- 76_uncounted_lines_guard.sql: addition 0008q, switching a line off asserts the acting person's
-- right inside the trigger
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 54_uncounted_lines.sql (0008f). Rerunnable, forward-only, in one transaction. Run as your own IAM
-- login, dev first, then prod; then 77_verify_uncounted_lines_guard.sql (dev) and 55 (dev, unchanged).
--
-- Why (IT audit of 17 October 2026, finding DB-01, backlog CMA-037 item 2): the trigger of 0008f runs
-- as the owner on any update that sets is_counted to false, and the application holds UPDATE on the
-- column, so a direct update by the Ingest service account (a tenant context, no acting user) removed
-- a line's calls with an audit trail naming no person. The right (tenant.configure) was asserted only
-- in cma.set_telephony_number(), the screen's path.
--
-- What it does: cma.remove_calls_of_uncounted_line() replaced. Before it removes anything it asserts
-- the acting person's tenant.configure for the line's tenant (CMA01 without an active acting user,
-- CMA06 without the right), exactly as set_telephony_number does, so the screen's path is unchanged.
-- Without an acting user the removal is allowed only when the acting database role is the owner: a
-- migration or one-off under a personal login that set role cma_owner (the role GUC keeps the outer
-- SET ROLE inside a SECURITY DEFINER function; a login without SET ROLE counts as itself, so the
-- service accounts, members of cma_app only, are refused). The trigger, its event, its owner, its
-- search path and its rights are unchanged (55 A2 still holds). The one-off
-- cma.remove_all_uncounted_line_calls() does not pass through the trigger and is unchanged.
--
-- SQLSTATEs: CMA01 no acting user, CMA06 not permitted (both from cma.assert_permission).
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
set role cma_owner;

begin;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0008f') then
    raise exception 'addition 0008f (54_uncounted_lines.sql) must run before 0008q';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The trigger's function: who may switch a line off
-- ---------------------------------------------------------------------------------------------
create or replace function cma.remove_calls_of_uncounted_line()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, cma, pg_temp
as $$
declare
  v_user  uuid := cma.current_user_id();
  -- the database role that issued the statement: the outer SET ROLE when there is one (the role GUC
  -- is not changed by SECURITY DEFINER), otherwise the login itself
  v_role  text := coalesce(nullif(current_setting('role', true), 'none'), session_user::text);
begin
  if new.is_counted or (tg_op = 'UPDATE' and not old.is_counted) then
    return null;                                        -- nothing switches off
  end if;
  if v_user is not null then
    -- an acting person: the line's tenant must be the current one, and the person must hold the
    -- right that set_telephony_number asks for (CMA01 when not active, CMA06 without the right)
    if new.tenant_id is distinct from cma.current_tenant_id() then
      raise exception 'line % belongs to another tenant than the acting person', new.number_ref using errcode = 'CMA06';
    end if;
    perform cma.assert_permission('tenant.configure');
  elsif not pg_has_role(v_role, 'cma_owner', 'member') then
    -- no acting person: only the owner (a migration or a one-off under a personal login) may
    raise exception 'switching line % off needs an acting person with tenant.configure (app.user_id is not set)', new.number_ref
      using errcode = 'CMA01';
  end if;
  perform cma.remove_uncounted_line_calls(new.tenant_id, new.connection_id, new.number_ref);
  return null;
end
$$;
alter function cma.remove_calls_of_uncounted_line() owner to cma_owner;
revoke execute on function cma.remove_calls_of_uncounted_line() from public;
-- the trigger itself is unchanged: after insert or update of is_counted, for each row (0008f)

-- ---------------------------------------------------------------------------------------------
-- 2. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008q', 'Uncounted lines guard: switching a line off asserts the acting person''s tenant.configure inside the trigger (CMA01 without an acting user unless the owner runs it, CMA06 without the right); the trigger, its owner, search path and rights unchanged')
on conflict (version) do nothing;

commit;
reset role;
```

**Draft verify, `db/77_verify_uncounted_lines_guard.sql`** (dev only, as `55`; block A structure, block B behaviour on a throwaway tenant inside a rolled-back subtransaction; the `verify.provoke` switch fails every check; one PASS or FAIL row per check and a verdict row). The block that answers the audit question, written in `55`'s style:

```sql
-- 77_verify_uncounted_lines_guard.sql: verifies addition 0008q (header, guard, set role cma_owner,
-- verify.provoke and verify.is_dev exactly as in 75; temp table verify_0008q (ord, check_name, result, detail))

-- A. structure and privileges
do $$
declare v_provoke boolean := current_setting('verify.provoke')::boolean; v_detail text;
begin
  if not current_setting('verify.is_dev')::boolean then return; end if;
  insert into verify_0008q values (1, 'A1 addition 0008q recorded after 0008f',
    case when exists (select 1 from cma.schema_migration where version = '0008q')
          and exists (select 1 from cma.schema_migration where version = '0008f') and not v_provoke then 'PASS' else 'FAIL' end, '');
  -- A2 as 55 A2: the trigger and its function unchanged in event, owner, search path and rights
  select format('tgtype %s, enabled %s, secdef %s, owner %s, config %s, app %s, readers %s, public %s',
                t.tgtype, t.tgenabled, p.prosecdef, pg_get_userbyid(p.proowner), array_to_string(p.proconfig, ','),
                has_function_privilege('cma_app', p.oid, 'execute'), has_function_privilege('cma_readonly', p.oid, 'execute'),
                exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
    into v_detail
  from pg_trigger t join pg_proc p on p.oid = t.tgfoid
  where t.tgrelid = 'cma.telephony_number'::regclass and t.tgname = 'remove_uncounted_calls';
  insert into verify_0008q values (2, 'A2 the trigger and its owner''s function unchanged in rights',
    case when v_detail = 'tgtype 21, enabled O, secdef t, owner cma_owner, config search_path=pg_catalog, cma, pg_temp, app f, readers f, public f'
          and (select prosrc from pg_proc where oid = 'cma.remove_calls_of_uncounted_line()'::regprocedure) ~ 'assert_permission\(''tenant\.configure''\)'
          and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_detail, 'no trigger'));
end $$;

-- B. behaviour on a throwaway tenant (rolled back): the setup as 55 B (a tenant, an admin, an agent, the
--    Ingest user, a telephony connection with line-1 counted and two calls with a tagging), then:
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_t1 uuid; v_admin uuid; v_agent uuid; v_ing1 uuid; v_tel uuid; v_n integer; v_calls integer; v_s timestamptz := timestamptz '2026-10-12 10:00:00+00';
begin
  if not current_setting('verify.is_dev')::boolean then return; end if;
  begin
    v_t1 := cma.create_tenant('verify-0008q-one', 'Verify 0008q one', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent@example.invalid', 'agent') returning id into v_agent;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id from (values (v_t1, v_admin, 'admin'), (v_t1, v_agent, 'agent')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    select c.connection_id into v_tel from cma.upsert_connection('verifytel', 'Verify phones', 'company-1', null, null) c;
    perform cma.set_telephony_number(v_tel, 'line-1', null, true);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      jsonb_build_object('sourceId', 'q-1', 'direction', 'outbound', 'startedAt', v_s, 'numberRef', 'line-1', 'versionAt', v_s, 'tags', jsonb_build_array('tag-a')),
      jsonb_build_object('sourceId', 'q-2', 'direction', 'inbound', 'startedAt', v_s + interval '5 minutes', 'numberRef', 'line-1', 'versionAt', v_s)));

    -- B1. the Ingest service account's path: cma_app rights, the tenant set, no acting user, an actor
    --     label as the ingest service sends it: a direct update of is_counted is refused with CMA01
    --     and the calls, the tagging and the line stay as they were
    perform set_config('app.user_id', '', true);
    perform set_config('app.actor_label', 'ingest-api:verify', true);
    v_n := 0;
    begin
      update cma.telephony_number set is_counted = false where connection_id = v_tel and number_ref = 'line-1';
    exception when sqlstate 'CMA01' then v_n := v_n + 1;
    end;
    select count(*) into v_calls from cma.telephony_call where tenant_id = v_t1 and connection_id = v_tel;
    insert into verify_0008q values (3, 'B1 a direct update without an acting user is refused (CMA01) and the calls stay',
      case when v_n = 1 and v_calls = 2
            and (select is_counted from cma.telephony_number where tenant_id = v_t1 and connection_id = v_tel and number_ref = 'line-1')
            and (select count(*) from cma.telephony_call_tag where tenant_id = v_t1 and connection_id = v_tel) = 1
            and not v_provoke then 'PASS' else 'FAIL' end, format('%s refusal, %s calls', v_n, v_calls));

    -- B2. an agent (an acting person without tenant.configure): CMA06, nothing removed
    perform set_config('app.user_id', v_agent::text, true);
    v_n := 0;
    begin
      update cma.telephony_number set is_counted = false where connection_id = v_tel and number_ref = 'line-1';
    exception when sqlstate 'CMA06' then v_n := v_n + 1;
    end;
    select count(*) into v_calls from cma.telephony_call where tenant_id = v_t1 and connection_id = v_tel;
    insert into verify_0008q values (4, 'B2 an agent''s direct update is refused (CMA06) and the calls stay',
      case when v_n = 1 and v_calls = 2 and not v_provoke then 'PASS' else 'FAIL' end, format('%s refusal, %s calls', v_n, v_calls));

    -- B3. the admin through the screen's function: the rule of 0008f unchanged, the calls removed, the
    --     audit of the deletes naming the person
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_telephony_number(v_tel, 'line-1', null, false);
    select count(*) into v_calls from cma.telephony_call where tenant_id = v_t1 and connection_id = v_tel;
    insert into verify_0008q values (5, 'B3 the admin switching the line off through set_telephony_number removes the calls, audited with the person',
      case when v_calls = 0
            and (select count(*) from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'telephony_call' and a.action = 'delete' and a.actor_user_id = v_admin) = 2
            and not v_provoke then 'PASS' else 'FAIL' end, format('%s calls left', v_calls));

    -- B4. the owner without an acting user (a migration or one-off under a personal login): allowed
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.user_id', '', true);
    perform cma.ingest_upsert_telephony_calls(v_tel, '[]'::jsonb) ; -- no-op; the calls below are written as the Ingest user
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_telephony_number(v_tel, 'line-2', null, true);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      jsonb_build_object('sourceId', 'q-3', 'direction', 'outbound', 'startedAt', v_s, 'numberRef', 'line-2', 'versionAt', v_s)));
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.user_id', '', true);
    update cma.telephony_number set is_counted = false where tenant_id = v_t1 and connection_id = v_tel and number_ref = 'line-2';
    select count(*) into v_calls from cma.telephony_call where tenant_id = v_t1 and connection_id = v_tel and number_ref = 'line-2';
    insert into verify_0008q values (6, 'B4 the owner without an acting user (a one-off) may switch a line off',
      case when v_calls = 0 and not v_provoke then 'PASS' else 'FAIL' end, format('%s calls left on line-2', v_calls));

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end $$;
-- Verdict as in 75 (6 PASS expected; PROVOKED under the switch), then reset role.
```

Notes for Martin on the draft (to be checked in dev before prod): B4's `ingest_upsert_telephony_calls(v_tel, '[]')` no-op line can be dropped; it is there only to keep the four roles' order visible. The verify needs the `verify_0008q` temp table and the verdict select copied from `75`. `55` must still pass afterwards (its B9 refusals go through `set_telephony_number`, where the CMA06 of `assert_permission` is raised before the trigger).

### DB-02: The audit log writes about 3.4 rows and five copies of each webhook payload per `ingest_event`; `cma.audit_log` is the growth driver, with no retention or aggregation yet
- Severity: Medium   Confidence: High (amplification observed; prod volume estimated)   Effort: M
- Component: `cma.audit_row()` (0001, replaced in 0008f and 0008l), `cma.setup_tenant_table` on `cma.ingest_event` (0006), `cma.ingest_claim_events` / `cma.ingest_finish_events`
- Evidence (observed, local `cma`, all tenants, `local-records/5.3-database/audit-amplification-local.tsv`): `ingest_event` 2,934 base rows, 10,022 audit rows (ratio 3.4: one insert, the claim's update of `attempts`/`next_attempt_at`, the finish's update of `status`/`processed_at`), average `pg_column_size(old_row) + pg_column_size(new_row)` 1,542 bytes per audit row with the ingest verifiers' payloads; every update row carries the full `raw` payload twice (old and new image), so the audit holds five copies of each payload next to the one in `ingest_event`. Locally `cma.audit_log` is 27 MB for 16,210 rows against 3.2 MB for `ingest_event`. Both tables are unpartitioned heaps, append-only by privilege (`audit_log`: `cma_app` INSERT and SELECT only).
- Impact (estimated): README records for prod 1,359 deals, 1,520 tickets and 2,784 calls in the 12 days of the first backfill and 14,689 tasks in about 45 days (Decision log 12 and 16 October 2026), so roughly 800 object changes a day reach the ingest as webhooks, each as one or more property-change events: 2,000 to 3,000 `ingest_event` rows a day, 60,000 to 90,000 a month. At about 5 to 7 KB of audit per event (3.4 rows × 1.5 to 2 KB) that is 300 to 600 MB a month of `audit_log` from `ingest_event` alone, before the mirror tables' own audit rows (one 1.6 KB image per upsert of a record, contact, call or task) and the reconcile's updates. Order of magnitude 0.5 to 1 GB a month, 6 to 12 GB a year, on an instance with 3.75 GB of memory whose `audit_log (tenant_id, changed_at)` and `(tenant_id, table_name, row_id, changed_at)` indexes grow with it. The audit of a technical log (`ingest_event` is itself the record of each webhook, with its payload) adds little evidence: the status transitions are deterministic and the payload is already stored once.
- Recommendation: (1) stop auditing the payload of `ingest_event`: in `cma.audit_row()` strip `raw` from the images when `tg_table_name = 'ingest_event'` (as it strips `token_hash` for `invitation`), or audit `ingest_event` inserts and the `needs_review`/`ignored` outcomes only; a one-line addition to the existing exception list, verified by a check that no `audit_log.new_row ? 'raw'` row exists for `ingest_event` after the change. (2) Fold the retention of `audit_log` into CMA-003/CMA-026: `ingest_event` rows older than N days (processed, ignored) and their audit rows can go first; the 1-year rule for call data (Decision log 15 October 2026) sets the ceiling. (3) When the retention job exists, consider partitioning `audit_log` by month (`changed_at`) so retention is a `DROP PARTITION`, not a delete of millions of rows; this is a new table and a data move, so it is a planned migration, not this one.
- README check: already open (CMA-003 retention, CMA-026 aggregation; Open decisions "Retention of staff data, the audit log and the customer-field mirror"). The amplification by `ingest_event`'s audit (five payload copies) is new.
- Disproof attempt: checked whether the ingest's updates skip the audit (no: `ingest_event` went through `setup_tenant_table`, trigger `audit` present, `local-records/5.3-database/rls-tables.tsv`); checked whether `audit_row()` already strips `raw` (no: only `token_hash` of `invitation` and the keys-only exception of 0008f); checked the local ratio against the per-event lifecycle in `ingest_claim_events` (one update) and `ingest_finish_events` (one update): 3 rows per event plus retries, matching the observed 3.4.

### DB-03: No statement timeout, lock timeout or idle-in-transaction timeout anywhere: role, pool, migrations
- Severity: Medium   Confidence: High   Effort: S
- Component: `web/src/lib/db/client.ts` (pool and `transaction()`), `ingest/src/core/db.mjs`, `db/*.sql`, role settings
- Evidence (observed): `pg_db_role_setting` holds only `search_path` for the database and for `bq_reader`; `pg_roles.rolconfig` is null for `cma_app`, `cma_owner`, `cma_readonly` and the service-account logins. `client.ts:119-121` and `141-143` set `max`, `idleTimeoutMillis` and `connectionTimeoutMillis` only; `transaction()` runs `begin` / `set_config` / `fn` / `commit` with no `set local statement_timeout`; `db.mjs:48-60` the same. `grep -n -i 'lock_timeout\|statement_timeout\|idle_in_transaction' db/*.sql` finds nothing; the migrations since `48` run `alter table ... add column` and `create or replace function` inside one transaction without a `lock_timeout`.
- Impact: a report call that scans the tenant's history (DB-04: measured at hundreds of milliseconds locally, seconds at prod scale per README's own 1.6 s figure) holds one of the 5 pooled connections per Cloud Run instance for its whole duration; a slow or stuck query is never cut, and a dozen concurrent manager page loads exhaust the pool (4 instances × 5 = 20 of the budget's 83 of 93 usable connections, README Database connection budget), after which every request waits 10 s on `connectionTimeoutMillis` and fails as `DB_UNAVAILABLE`. A migration run in Cloud SQL Studio during the day that needs an `ACCESS EXCLUSIVE` lock on `cma.telephony_call` or `cma.crm_record` queues behind any such read and, while it waits, blocks every other reader and writer of that table (lock queue), with no timeout to release it.
- Recommendation: (1) `alter role cma_app set statement_timeout = '30s'` (and `idle_in_transaction_session_timeout = '60s'`) in a new script run by Martin as a personal login with ADMIN on the role (Terminal/Studio step, no code), or per transaction in `client.ts`'s `transaction()`: `set local statement_timeout = '30s'` right after `begin` (the web's own ceiling; the ingest keeps a longer one for backfills, e.g. 5 minutes, set in `db.mjs`). The jobs that legitimately run long (`load_import_batch`, the backfill) set their own `set local statement_timeout = 0` inside their transaction. (2) Every migration from 0008q on starts its transaction with `set local lock_timeout = '5s'`, so a blocked DDL fails fast and is rerun instead of queueing the application; add it to README's Conventions for every migration.
- README check: new. Related: Database connection budget (15 October 2026) counts connections, not their duration; the Decision log rejects raising `max_connections`, which makes bounding the duration the remaining lever.
- Disproof attempt: looked for a timeout set elsewhere: Cloud SQL flags are console-only and not in the repository (`grep -rn statement_timeout docs/ cloudbuild.yaml` empty); pg's defaults are 0 (none). The pg driver's `query_timeout`/`statement_timeout` client options are not passed (`client.ts:113-124`, `141-147`).

### DB-04: The optional-bound pattern `(p_from is null or col >= p_from)` keeps the time indexes out of use in the report cores, so Reports → Calls, Inbound and the lead reads scan the tenant's history for any period
- Severity: Medium   Confidence: Medium (expected from the code and from README's own recorded figure; not re-measured here, see the volume section)   Effort: S
- Component: `cma.calls_of` (0008j/0008k), `cma.inbound_calls_of` (0008i), `cma.lead_deals_of` (0007d), `cma.my_messages` (`p_since`), and the same shape on `business_date` in `team_hours`, `team_status_time`, `crm_records_per_day`, `message_stats`, `export_hours`, `export_status_changes` (`local-records/5.3-database/nonsargable-bounds.tsv`)
- Evidence: `\sf cma.calls_of` lines 26-27: `and (p_from is null or tc.started_at >= p_from) and (p_to is null or tc.started_at < p_to)`; the same in `inbound_calls_of` (lines 26-27) and `lead_deals_of` (lines 31-32). An `OR` with a parameter test is not an index condition, so the `(tenant_id, started_at)`, `(tenant_id, occurred_at)` and `(tenant_id, source_created_at)` indexes (`indexes-hot-tables.tsv`) are not used for the period; the scan is the tenant's whole table (or, for `lead_deals_of`, everything since the tenant's `start_date`, line 30, which is sargable) and the period is applied as a filter. README itself records the consequence (Data model: telephony history start, 0008k): "read without bounds it scans every call of the tenant, because its optional bounds (`p is null or started_at < p`) keep the index on the tenant and the start out of use (0008j's overview reads that way: 1.6 seconds for a month over 300,000 calls locally)" and "420 to 470 ms for one unbounded read of `cma.calls_of`". The web layer bounds a range to 92 days (`postgres.ts:105`), which bounds the output, not the scan. The EXPLAIN on `cma` as `cma-web@local.iam` (`rls-fail-closed-test.txt`, last two plans) shows the RLS predicate itself folded to a single stable expression, so the policy is not the cause.
- Impact: every Reports → Calls, Inbound and Speed to lead page load costs time proportional to the tenant's history, not to the month asked: at 300,000 calls (about two years of Pulse4all's 2,784 calls per 12 days, README) 1.6 s per overview as README measured; it grows with every month stored until the retention job (CMA-003) exists. Combined with DB-03 (no statement timeout) each such read also holds a pooled connection for its duration.
- Recommendation: replace the pattern by sargable bounds with the same semantics, in the three cores and the `business_date` readers: `tc.started_at >= coalesce(p_from, '-infinity'::timestamptz) and tc.started_at < coalesce(p_to, 'infinity'::timestamptz)` (a parameter inside `coalesce` is a stable expression the planner uses as an index condition; `NULL` keeps today's meaning). One addition, no signature or result change; verified by `55`-style checks that the result of `calls_of` with and without bounds is unchanged on a throwaway tenant, plus an `EXPLAIN` row in the verify's detail showing `Index Cond` on `started_at`. `telephony_history_start_of` (0008k) already works around the pattern with constant windows and would become simpler afterwards.
- README check: the symptom is documented (0008k, 16 October 2026) and worked around for the history start only; the cause in `calls_of` and the two other cores is new as a finding. Not in the Decision log as a decision.
- Disproof attempt: checked that the indexes exist (they do); checked whether the planner can use an OR-with-parameter as an index condition on PostgreSQL 16 or 18 (it cannot; a `coalesce`-bound or two function variants can); checked whether the pages pass bounds (they do, `calls_overview(p_from, p_to, ...)`), so the scan is not asked for.

### DB-05: `cma.sources()` runs four correlated scans of `ingest_event` per connection without a time index; the Sources page grows with the ingest history
- Severity: Medium   Confidence: Medium (expected from the code; not measured at volume here)   Effort: S
- Component: `cma.sources()` and `cma.connections_all()` (0008e), indexes of `cma.ingest_event` (0006)
- Evidence: `\sf cma.sources` lines 13-16: per connection `count(*) ... where recorded_at > now() - interval '24 hours'`, `count(*) ... where status in ('received', 'failed')`, `count(*) ... where status = 'needs_review'`, `max(recorded_at)`. The indexes on `ingest_event` (`indexes-hot-tables.tsv`) are the partial `(tenant_id, connection_id, next_attempt_at) where status in ('received','failed')` (serves the second count only), `(tenant_id, connection_id, object_type, object_id)`, `(tenant_id, connection_id, event_key)` and the keys; there is no index on `recorded_at` and none covering `status = 'needs_review'`, so the first, third and fourth subqueries scan the connection's whole event history (a bitmap or index scan on `(tenant_id, connection_id, ...)` then a heap filter over all of its rows), per connection, on every Sources page load and every `connections_all()` reader call.
- Impact: at the estimated 60,000 to 90,000 events a month (DB-02) the Sources page reads several hundred thousand `ingest_event` rows (with their 1 KB payloads in the heap) after a few months, three times per connection, for four small numbers. Configuration pages are not the daily path, but Sources is where an operator looks when the ingest misbehaves, which is when the table is busiest.
- Recommendation: one index `create index concurrently if not exists ingest_event_recorded_idx on cma.ingest_event (tenant_id, connection_id, recorded_at desc)` (serves the 24-hour count and the `max`), and either a partial index `... (tenant_id, connection_id) where status = 'needs_review'` or widen the existing partial index's predicate to `status in ('received', 'failed', 'needs_review')`; `create index concurrently` cannot run inside the migration's transaction, so it is its own statement before the `begin;`, as README's convention allows for an index (to be stated in the PR). The datamap catalog's `how` for `ingest_event` is unchanged.
- README check: new.
- Disproof attempt: looked for an index on `recorded_at` under any name (none); checked whether `sources()` is called only once per page (it is, but it is the page's main query) and whether the counts could come from `sync_run` instead (no: they are webhook counts).

### DB-06: `cma_app` keeps DELETE on 16 tables, 14 of them master data, 4 with no delete path at all (CMA-060 parts 1 and 3)
- Severity: Low   Confidence: High   Effort: S
- Component: `cma.setup_tenant_table()` (grants `select, insert, update, delete` by default), the `revoke delete` lines of each migration
- Evidence (observed, `local-records/5.3-database/table-grants.tsv`): `cma_app` holds DELETE on `app_role`, `app_user`, `app_user_external_id`, `business_holiday`, `business_hours`, `channel`, `commerce_order_line`, `connection_field`, `coverage_target` (re-granted in `db/23_roster.sql:184`), `crm_contact_ref`, `market_alias`, `organisation`, `role_permission`, `skill_level`, `tenant_setting`, `user_role`. Every other table (57) had DELETE revoked by its migration. README says `app_user` is "never hard-deleted" (Tables) and "status columns instead of hard deletes" (Conventions).
  Delete paths in functions (grep of `delete from` by enclosing function, migrations only): `set_tenant_setting` → `tenant_setting` (a reset to the default); `set_person_role` → `user_role` (replace); `set_skill_levels` → `skill_level` (replace the dimension's ladder); `set_coverage_target` → `coverage_target`; `set_connection_field` → `connection_field` (replace a slot); `remove_market_alias` → `market_alias`; `set_business_hours` → `business_hours` (replace a weekday); `remove_business_holiday` → `business_holiday`; `remove_user_external_id` → `app_user_external_id`; `ingest_upsert_contacts` / `ingest_contact_forget` → `crm_contact_ref` (refs replaced as a set); `ingest_upsert_commerce_orders` → `commerce_order_line` (lines replaced as a set); `remove_uncounted_line_calls` → `call_link`, `telephony_call_tag`, `telephony_call` (owner only); `seed_default_roles` → `role_permission`, `permission` (owner only: `create_tenant` and `seed_default_roles` are executable by `cma_owner` alone). Routes (`web/src/lib/data/postgres.ts`, `web/src/lib/sources.ts`, `web/src/app/api/v1/configuration/settings/route.ts`) call `set_tenant_setting`, `set_person_role`, `set_skill_levels`, `set_coverage_target`, `set_business_hours`, `remove_business_holiday`, `remove_market_alias`, `remove_user_external_id`; the ingest calls `ingest_upsert_contacts`, `ingest_contact_forget`, `ingest_upsert_commerce_orders`.
  No path at all for `app_user`, `app_role`, `organisation`, `channel`, `role_permission` (as `cma_app`): five unused DELETE grants on master data.
- Impact: least privilege only; nothing in the code uses the five grants, and RLS bounds a delete to the tenant. A `DELETE` on `app_user` by the application role would cascade or fail on foreign keys, but a careless script under `set role cma_app` could remove a person's row and with it the "never hard-deleted" promise.
- Recommendation (part 1): revoke now, in 0008q or its own addition, with no code change: `revoke delete on cma.app_user, cma.app_role, cma.organisation, cma.channel, cma.role_permission from cma_app;`. Keep the set-replace deletes for now (`user_role`, `skill_level`, `coverage_target`, `connection_field`, `business_hours`, `market_alias`, `business_holiday`, `app_user_external_id`, `tenant_setting`, `crm_contact_ref`, `commerce_order_line`): the audit log keeps the removed rows, and a change to `valid_to`/status columns is a function-by-function migration. Of these, `user_role`, `skill_level` and `coverage_target` are the ones README's convention names ("team membership, skills, rates, targets carry `valid_from` and `valid_to` and are never overwritten"): schedule them first.
  (Part 3) The verify block for `db/77_...` (block A, structure), failing on any DELETE grant to `cma_app` on a master-data table; the list is the proposal, to be settled by Martin:
```sql
  -- A3. the application never deletes master data: no DELETE grant to cma_app on any configuration or people table
  select string_agg(t, ', ' order by t) into v_bad
  from unnest(array[
    'app_user', 'app_user_external_id', 'organisation', 'team', 'team_member', 'skill', 'skill_level', 'user_skill',
    'app_role', 'role_permission', 'user_role', 'channel', 'work_status', 'absence_type', 'app_link',
    'roster_week', 'roster_publication', 'roster_entry', 'coverage_target',
    'telephony_number', 'telephony_tag', 'telephony_missed_reason', 'market', 'market_alias', 'business_hours', 'business_holiday',
    'integration_connection', 'connection_pipeline', 'connection_stage', 'connection_field', 'connection_form', 'connection_form_field',
    'connection_call_outcome', 'connection_task_status', 'connection_task_type', 'connection_inbox', 'connection_inbox_channel',
    'connection_email_rule', 'form_category', 'writeback_field', 'message_rule', 'tenant_setting', 'invitation', 'commerce_store']) t
  where to_regclass('cma.' || t) is not null and has_table_privilege('cma_app', 'cma.' || t, 'delete');
  insert into verify_0008q values (7, 'A3 no DELETE grant to cma_app on a master-data table',
    case when v_bad is null and not v_provoke then 'PASS' else 'FAIL' end, coalesce('cma_app may delete from: ' || v_bad, ''));
```
  On today's database this block reads FAIL with `app_role, app_user, app_user_external_id, business_holiday, business_hours, channel, connection_field, coverage_target, market_alias, organisation, role_permission, skill_level, tenant_setting, user_role` (observed by running the query as `postgres`), so it is the measure of CMA-060's progress: the five revokes above take it to nine, each later function migration one further.
- README check: already open (CMA-060). Decision log 5 October 2026 ("facts are append-only by privilege") and 9 October 2026 ("retired, never deleted") settle the direction.
- Disproof attempt: checked whether a default privilege re-grants DELETE (no: `pg_default_acl` gives `cma_app` SELECT on new tables only); checked whether any route issues a raw `delete from` (grep of `web/src` and `ingest/src` for `delete from`: none outside tests).

### DB-07: 22 functions of migrations 0001 to 0003a are executable by PUBLIC (no `revoke ... from public`), among them `open_workday`, `end_workday`, `set_status`, `correct_workday`, `correct_time_event`
- Severity: Low   Confidence: High   Effort: S
- Component: `db/01_foundation.sql`, `05_time_model.sql`, `09_corrections.sql`, `11_team_people.sql`
- Evidence (observed): `select proname from pg_proc where pronamespace = 'cma'::regnamespace and proacl is null` → 22 functions (`assert_permission`, `assert_time_kept`, `audit_row`, `business_date`, `business_day_time`, `correct_time_event`, `correct_workday`, `current_actor_label`, `current_tenant_id`, `current_user_id`, `end_workday`, `has_permission`, `is_timezone`, `open_workday`, `refresh_workday`, `set_status`, `set_updated_at`, `team_hours`, `team_people`, `time_is_kept`, `user_permissions`, `user_timezone`); every function from `13` on carries `{cma_owner=X,cma_app=X}`. Not exploitable today: as `bq_reader` (member of `cma_readonly`) `select cma.user_permissions(...)` fails with `permission denied for schema cma` (schema USAGE is granted to `cma_owner` and `cma_app` only), and `has_schema_privilege('bq_reader', 'cma', 'usage')` is false.
- Impact: the schema grant is the only thing between a reader login and the time-model write functions (which run in the caller's rights and would then fail on table privileges and RLS, so a reader still could not write). Hygiene against the convention every later migration follows; a future `grant usage on schema cma to cma_readonly` for a reporting need would silently open the execute path.
- Recommendation: one rerunnable statement set in the next addition: `revoke execute on function cma.open_workday(timestamptz), cma.end_workday(uuid, timestamptz, text), cma.set_status(...), cma.correct_workday(...), cma.correct_time_event(...), cma.refresh_workday(uuid), cma.team_hours(date, date, uuid), cma.team_people(), cma.user_permissions(uuid) from public; grant execute on ... to cma_app;` (the helpers `current_tenant_id`, `current_user_id`, `business_date`, `is_timezone`, `set_updated_at`, `audit_row` may stay public: they are used by defaults, checks and triggers in every role), with a verify check that no function in `cma` other than that helper list has a PUBLIC EXECUTE entry (`aclexplode(proacl)` grantee 0, or `proacl is null`).
- README check: new (hygiene). The convention "executable by the application only" appears from 0003b on.
- Disproof attempt: tried the call as a reader (refused at the schema); confirmed `cma_readonly` has no USAGE on `cma` (`pg_namespace.nspacl`).

### DB-08: Two SECURITY DEFINER functions pin `search_path` without `pg_temp` last (`find_tenants_for_identity`, `ingest_connection`)
- Severity: Low   Confidence: High   Effort: S
- Component: `db/05_time_model.sql` / `52_sources_configuration.sql` (`cma.find_tenants_for_identity`), `db/30_ingest_crm_records.sql` (`cma.ingest_connection`)
- Evidence (observed, `local-records/5.3-database/secdef-functions.txt`): `proconfig = {search_path=pg_catalog, cma}` for both; the twelve other SECURITY DEFINER functions (0007d, 0008f, 0008l, 0008o) use `pg_catalog, cma, pg_temp`. Both bodies are single SQL statements with every relation schema-qualified (`cma.app_user_external_id`, `cma.app_user`, `cma.tenant`, `cma.integration_connection`), no dynamic SQL, input validation (`p_system !~ '_(owner|user)$'`, equality on `key`), owner `cma_owner`, `REVOKE FROM PUBLIC` done (`{cma_owner=X,cma_app=X}`). `ingest_connection` returns `signing_secret_name` and `token_secret_name` (names, not values) to `cma_app`, which is the ingest's design (README, 0006).
- Impact: none today: with `pg_temp` absent from the path PostgreSQL searches the temporary schema first for relation names, but the bodies name no unqualified relation and the temp schema is never searched for functions or operators. The README (0008l) describes "search path pinned" as the standard; these two pin it incompletely.
- Recommendation: `alter function cma.find_tenants_for_identity(text, text) set search_path = pg_catalog, cma, pg_temp; alter function cma.ingest_connection(text) set search_path = pg_catalog, cma, pg_temp;` in the next addition, and a verify check that every `prosecdef` function in `cma` and `cma_read` has `pg_temp` as the last entry of its `search_path`.
- README check: new (hygiene against the stated convention).
- Disproof attempt: read both bodies for unqualified names and dynamic SQL (none); confirmed that the temporary schema is not searched for functions (PostgreSQL documentation, `search_path`), so a temp-function shadowing attack is not possible either.

### DB-09: Migrations 0001 to 0008b (`01` to `46`) run without a transaction; `12_verify_team_people.sql` has no `postgres` guard
- Severity: Low   Confidence: High   Effort: S (documentation) 
- Component: `db/01..46` (even scripts), `db/12_verify_team_people.sql`
- Evidence (observed): `grep -c '^begin;'` and `'^commit;'` is 0/0 for every migration up to `46_workday_window.sql` and 1/1 from `48` on; every script except `00_roles.sql` and `12_verify_team_people.sql` carries the `session_user = 'postgres'` guard; `04_verify.sql` uses `set local role` inside its blocks instead of a top-level `set role cma_owner` (fine).
- Impact: a failure in the middle of `01`..`46` leaves a half-applied migration; they are rerunnable (`if not exists`, `create or replace`, `on conflict`), so a rerun completes it, and all of them have run in dev and prod, so the point is historical except as a convention: the "one transaction" rule appears in the headers from `48` on and is not in README's Conventions for every migration. `12`'s missing guard matters little (it only reads), but it is the one exception to "every script except 00".
- Recommendation: add "one transaction (`begin;` ... `commit;`), with `set local lock_timeout` (DB-03)" to README's Conventions for every migration; leave `01`..`46` as they are (never edit a script that has run). `12` stays as it is or gets the guard in its next edit, if any.
- README check: new (documentation of an existing practice).
- Disproof attempt: checked whether Cloud SQL Studio wraps a script in a transaction (it does not; each statement autocommits), so the observation is real but mitigated by rerunnability.

### DB-10: README says "four security definer functions in `cma_read`"; there are nine (0008o added five)
- Severity: Info   Confidence: High   Effort: S
- Component: README (Data model: foundation table row for `40_lead_metrics.sql`; Decision log 11 October 2026)
- Evidence (observed): `cma_read.data_quality_rows`, `follow_up_by_owner_rows`, `follow_up_summary_rows`, `intake_per_day_rows`, `lead_to_order_rows`, `open_leads_rows`, `open_tasks_rows`, `open_tickets_rows`, `speed_to_lead_rows` are SECURITY DEFINER, owned by `cma_owner`, `search_path=pg_catalog, cma, pg_temp`, executable by `cma_readonly` only, each `cross join lateral cma.<x>_of(t.id, ...)` filtered by `cma_read.reader_sees(t.id)`; their return types (`local-records/5.3-database/secdef-functions.txt`) hold ids, refs, counts, dates and seconds, no hash, raw, token or secret. All fine; the count in the README is stale. For the doc-drift area (5.11).
- README check: new (doc drift).
- Disproof attempt: counted twice (`pg_proc.prosecdef` in `cma_read`): nine.

### DB-11: Foreign keys without a covering index: 46 of 179, all on low-traffic paths
- Severity: Info   Confidence: High   Effort: S
- Evidence (observed, `local-records/5.3-database/fk-without-index.tsv`, set-based: no index whose leading columns are the FK's columns): 24 point at `app_user` (`created_by`, `approved_by`, `granted_by`, `published_by`, `recorded_by`, `linked_by`, `resolved_by`, `sender_user_id`, ...), 4 at `permission`, 1 at `setting`, the rest at catalogs (`skill`, `market`, `channel`, `work_status`, `absence_type`, `form_category`, `app_role`, `organisation`) and two at `workday`/`time_event` from `import_day`. `time_event (tenant_id, workday_id, user_id)` is covered in practice by `(tenant_id, workday_id, occurred_at)` (the first two columns), `form_submission (tenant_id, connection_id, source_form_id)` by `(tenant_id, connection_id, source_id)` only partially. None of the referenced tables is deleted from in normal running (people, catalogs), so the missing indexes cost nothing on deletes, and the lookups the pages make (`indexes-hot-tables.tsv`) have their own indexes: `time_event (tenant, user, occurred_at)`, `workday (tenant, user, business_date)`, `telephony_call (tenant, started_at)`, `crm_call (tenant, occurred_at)`, `audit_log (tenant, changed_at)`, `sync_run (tenant, connection, started_at)`, `outbox_action` partial on due actions, `message_delivery (tenant, user, read_at)`. Clean except the one gap named in DB-05 (`ingest_event` has no time index).
- README check: new (observation).

### DB-12: The four verify anomalies of the local build are sandbox artefacts, not defects
- Severity: Info   Confidence: High
- Evidence (observed, `local-records/db/07-verify.txt`, `12-verify.txt`, `25-verify.txt`, `39-verify.txt` and the scripts):
  - `07` (exit 3): the local runner used `ON_ERROR_STOP`, and the script's block C ends with an *expected* error (`db/07_verify_time_model.sql:119`, "expected error: workday ... is already ended; resuming is a correction (SQLSTATE CMA03)"); psql stopped there, so blocks D to K, H among them, never ran locally. The script is written for Cloud SQL Studio, which carries on after an error. Not a defect; the README already documents H's dependence on the fixture's open day.
  - `12` (exit 3): block E looks up the admin's own login ("the prod people", README table row for `12`); the dev seed has no such person, `set_config` returned no row and `team_people()` raised CMA01 (`this needs app.user_id`). Blocks A to D passed (B listed 5 people). Expected in a database without the prod people.
  - `25` B3 (`FAIL B3: the entries read [2026-10-19 shift 10:00:00-18:00:00 desk 4; 2026-10-19 shift 09:00:00-17:30:00; ...]`): the check orders entries by `(business_date, user_id)` and expects the agent created first (`v_a1`) to sort first; the sandbox `uuidv7()` shim (`pg_catalog.uuidv7`, millisecond prefix + random bits) gave `v_a2` a smaller id in the same millisecond. PostgreSQL 18's native `uuidv7()` is monotonic within a backend (sub-millisecond counter), so the assumption holds in prod (`records/0005-prod-2026-10-08`).
  - `39` D1 (`claimed {...169a-7608, ...169b-77f5, ...169b-7dfb} (3 at one attempt), or claimed again at once`): three actions enqueued in one millisecond (`169b`) got ids whose random part inverted the creation order; the check compares `array_agg(action_id order by action_id)` with `array[v_a, v_b, v_c]`. Same cause as B3; the claim itself took exactly the three due actions once (count 3 at one attempt).
  - The time of day (18:46 Europe/Amsterdam, inside the 07:00 to 22:00 window) and the collation (C.UTF-8) played no part in these four.
- Recommendation: none for prod. For local builds, run the verifiers without `ON_ERROR_STOP` (as Studio does) and read the PASS/FAIL rows; a shim with a per-session counter would remove the ordering noise.
- README check: settled (README rows for `07` and `12` describe both dependencies).

### DB-13: Observations without a finding (for the lead)
- Severity: Info
- `cma_read.app_user` and `cma_read.invitation` expose staff `email` and `display_name`, `cma_read.message.body` the CMA's own alert text, `cma_read.app_link.address` a URL, `roster_entry.note` the planner's note: all by design (people and configuration data, no customer data); the grep for `raw|hash|token|secret|phone|subject|address` over the 104 view definitions and their column names finds nothing else (`cma_read-sensitive-columns.tsv`).
- `cma.setting` is a fourth global table without RLS, with `tenant`, `permission` and `schema_migration`; justified (Decision log 6 October 2026: the settings catalog is global, the tenant's values in `tenant_setting` under RLS).
- The dev `docs/datamap/schema.json` (generated 2026-10-17T09:58Z at 0008p) matches the local build column for column (2,015 columns; the only differences are the type spelling of array columns between `udt_name` and `data_type`).
- The local `cma` database holds 18 throwaway tenants left by other agents' ingest verifiers next to the two seeded ones; irrelevant for the checks here (each has its own tenant id), noted so nobody reads the 20 as a defect.

---

## Synthetic volume and the page functions (EXPLAIN ANALYZE as `cma-web@local.iam`)

**Set-up (observed).** `cma_perf` was created as postgres by dump and restore of `cma` after recreating the `pg_catalog.uuidv7()` shim (a template copy was refused: six other sessions on `cma`); 77 tables, 35 migrations, 73 policies, 345 functions, no restore errors. The generator `local-records/5.3-database/synthetic-volume-generator.sql` (fictional values only; run as `auditor@local`, `set role cma_owner`, one transaction, through the configuration functions as the tenant's admin for connections, markets, lines and tags, then direct inserts with the audit triggers on) loads the Subscriptions tenant with: 11 more agents (13 in all, each with a CRM owner id and a telephony user id, team `nl`), 3,388 ended workdays with about 130,000 time events (one start, up to 38 status changes 13 minutes apart, one end) plus 8 open days today, 60,000 telephony calls over 365 days on two counted lines (55 % inbound, 80 % answered, keyed hashes as random hex), 18,000 taggings, 30,000 CRM calls linked to half of the telephony calls (`call_link`, `hash_time`) with associations, 40,000 contacts, 40,000 deals and 45,000 tickets, 100,000 tasks, 50,000 emails, 10,000 form submissions, 100,000 processed ingest events with a 1 KB payload each, 20,000 alerts delivered to three agents each and the manager's urgent ones, 53 published roster weeks with Monday-to-Friday shifts for the 13 agents, and the two audit update rows per ingest event the claim and finish would have written. Then `analyze`.

**Status at hand-back (observed).** The generator's third run was in section 4 (CRM records; `ERROR` count 0) when this run had to end: two earlier runs were lost to generator mistakes (a generated column, a check constraint on `call_link.method`, a `NOT NULL` on `crm_association.source_changed_at`) and one to a cached referential-integrity plan (the FK checks of `telephony_call_tag` were planned while `telephony_call` statistics said 26 rows and seq-scanned 60,000 rows per check; fixed by `analyze` steps between parent and child loads, itself a note for anyone bulk-loading these tables). It runs on in the background under `nohup` and leaves `cma_perf` loaded when it commits. **The EXPLAIN (ANALYZE, BUFFERS) pass over the page functions was therefore not completed in this run; no plan under `plans/` is claimed and no timing is reported as observed.** The runner is ready: `bash local-records/5.3-database/run-plans.sh` (as `postgres`, loads `auto_explain` with nested statements, `set role "cma-web@local.iam"`, the manager's or agent's context per call, a warm and a measured pass per function, one file per function under `plans/`) followed by `python3 -I local-records/5.3-database/summarise-plans.py` (writes `plans-summary.txt`: top-level ms, rows, buffers, big-table seq scans, heaviest nested statement). The route was proven on `cma` (`auto_explain` LOG lines reach the client after `SET ROLE`, RLS applied: `rolbypassrls = f`, nested plans show `tenant_id = (NULLIF(current_setting(...)))::uuid` as a filter).

**What the plans would decide (expected, to confirm with the runner):** DB-04's history-proportional scans in `calls_overview`, `inbound_service`, `speed_to_lead_summary` and `telephony_history_start` (the latter already windowed by 0008k), DB-05's scans in `sources()`, the open-item reads (`open_leads`, `open_tickets`, `open_tasks`, `follow_up_*`) which are proportional to open records rather than to history, and the own-day, roster and messages reads which have exact indexes (`workday (tenant, user, business_date)`, `time_event (tenant, workday, occurred_at)`, `roster_entry (tenant, roster_week_id, business_date)`, `message_delivery (tenant, user, read_at)`) and should stay in the low milliseconds. The 50 ms sandbox threshold and the "three slowest plans" are left to that run.

---

## Checked and found clean
- RLS: all 73 tenant tables have `relrowsecurity = t`, exactly one policy `tenant_app` for `cma_app`, `FOR ALL`, `USING (tenant_id = current_tenant_id()) WITH CHECK (tenant_id = current_tenant_id())` (`policies.tsv`: one shape, 73 tables); every one carries the `audit` trigger except `audit_log` itself (insert-only by grant); `relforcerowsecurity = f` everywhere by design (the owner's cores bypass RLS, Decision log 5 October 2026). The four tables without RLS are the global ones (`tenant`, `permission`, `schema_migration`, `setting`).
- Fail-closed (observed as the real `cma-web@local.iam`, `rls-fail-closed-test.txt`): no context → 0 rows from `app_user`, `time_event`, `telephony_call`, `audit_log`, `tenant_setting`; `app.tenant_id = ''` → 0 rows and an insert into `organisation` refused (`new row violates row-level security policy`); a non-uuid context errors; `cma.workday_summary` (a tenant face) → 0 rows; `cma_read` refused (`permission denied for schema cma_read`); the global tables readable (by design).
- Policy shape and planning: `cma.current_tenant_id()` is `LANGUAGE sql STABLE PARALLEL SAFE` and is inlined, so the predicate reaches the planner as `tenant_id = (NULLIF(current_setting('app.tenant_id', true), ''))::uuid`, a stable expression evaluated once per scan and usable as an index condition (seen as `Index Cond: (tenant_id = ...)` in the plans under `plans/`); not evaluated per row. Not `LEAKPROOF`, which is right (it needs no leakproof status: it reads a GUC, and the policy is the filter). No `security_barrier` views (none needed: the `_all` cores have no grant to `cma_app`, the faces filter on the tenant, `cma-views.tsv`).
- SECURITY DEFINER inventory (`secdef-functions.txt`): 5 in `cma` (`accept_invitation`, `find_tenants_for_identity`, `ingest_connection`, `invitation_preview`, `remove_calls_of_uncounted_line`), 9 in `cma_read`; all owned by `cma_owner`, all with `REVOKE FROM PUBLIC` (`proacl` lists `cma_owner` and either `cma_app` or `cma_readonly`), none builds SQL from input, `accept_invitation` validates the sign-in system and id (`^[a-z0-9_]+$`, not `_(owner|user)$`, length ≤ 200, no whitespace), hashes the token (`cma.invitation_token_hash`) and restores the caller's context after switching it; the trigger function is executable by nobody.
- Grants: `cma_readonly` holds nothing on `cma` (schema USAGE included) and SELECT on the 104 `cma_read` views; `PUBLIC` holds nothing on either schema; default privileges give `cma_app` SELECT on new tables and `rU` on sequences in `cma`, `cma_readonly` SELECT on new `cma_read` relations; column-level grants restrict `cma_app`'s UPDATE on `absence_type`, `call_link`, `coverage_target`, `invitation` (no SELECT: the token hash is unreadable by the application), `outbox_action`, `time_event` (none), among others (`column-grants.tsv`).
- `02_seed_pulse4all.sql`: every insert is `on conflict (...) do nothing` (14 clauses, `tenant_setting` included), so a rerun never overwrites a tenant's own values.
- `schema_migration`: 35 rows, 0001 to 0008p, one per migration file, descriptions match; `applied_by` is the login (`auditor@local` here).
- Drops: only `drop constraint if exists` before re-adding, `drop policy/trigger if exists` inside `setup_tenant_table`, `drop function` before a `create or replace` with a changed signature (`46:529`, `50:695`), one `drop index` replaced by a better one (`44:76`), and `pg_temp` objects in verifiers. No `drop table` or `drop column` of a shipped object.
- Error codes: every user-facing `raise exception` in the functions carries `using errcode` CMA01..CMA06 (the few without are the `postgres` guard, the migration-order checks and `refresh_workday`'s internal invariants, which are not reachable from the API); `CMAOK` is used only inside verifiers to roll back a subtransaction; the API maps on the SQLSTATE (`web/src/lib/api/respond.ts:36-42`, `translateDbError` in `client.ts` on `e.code`), never on text; `postgres.ts` raises its own `CmaDbError` with the same codes.
- Volatility: every page read function is `STABLE` (`read-functions-volatility.tsv`), `my_messages` is rightly `VOLATILE` (it marks deliveries delivered), `calls_filters_check`, `data_quality_*_checks`, `email_words*` are `IMMUTABLE`.
- Locks: advisory locks are transaction-scoped (`pg_advisory_xact_lock` per outbox target in 0007c, per telephony line in 0008f, shared for the call write and exclusive for the removal); `for update skip locked` in the claims; no long transactions in the jobs beyond one batch.
- Indexes on the hot paths (`indexes-hot-tables.tsv`): `time_event (tenant, user, occurred_at)` and `(tenant, workday, occurred_at)`; `workday (tenant, user, business_date)` and the partial `(tenant, business_date) where status = 'open'`; `telephony_call (tenant, started_at)`, `(tenant, connection, source_id)`, partial on `counterpart_hash`; `crm_call (tenant, occurred_at)`; `crm_record (tenant, source_created_at)`; `ingest_event` partial on due events and `(tenant, connection, object_type, object_id)`; `outbox_action` partial on due actions and `(tenant, dedupe_key)`; `message_delivery (tenant, user, read_at)`; `audit_log (tenant, changed_at)`; `sync_run (tenant, connection, started_at)`; `email_message (tenant, occurred_at)`; `crm_task (tenant, due_at)`.
- The 0008q numbering: `main` ends at `75_verify_forms_reporting.sql` (0008p), so `76`/`77` and the letter `q` are free.

## Not checked / could not check
- Prod or dev row counts and sizes (no access by the audit's rules); the growth figures are estimates from README's recorded counts.
- `pg_stat_statements` or real plan statistics from Cloud SQL (console only).
- PostgreSQL 18 behaviour (`uuidv7()` monotonicity, planner differences) is reasoned from documentation; the sandbox runs 16.
- The ingest's own transactions (long batches in `load_import_batch` or the backfill) were reviewed statically only.

## Commands run
- `psql -h 127.0.0.1 -U postgres -d cma` catalog queries for RLS, policies, triggers, grants, column grants, default ACLs, role settings, SECURITY DEFINER inventory and bodies, view definitions, FK/index coverage, volatility, `schema_migration` (outputs in `local-records/5.3-database/*.tsv|*.txt`).
- `psql -U cma-web@local.iam -d cma -f rls-fail-closed-test.sql`: fail-closed and plan-shape test (passed as expected: 0 rows without context, insert refused, plans show the inlined predicate).
- `psql -U auditor@local -d cma_perf -f cma-037-item2-setup.sql` then `psql -U cma-ingest@local.iam -d cma_perf -f cma-037-item2-test.sql`: the CMA-037 item 2 test (direct update deleted 3 calls and 1 tagging; rolled back).
- `psql -U bq_reader -d cma`: a reader calling `cma.user_permissions` (refused at the schema), reading `cma_read.app_user` (allowed, 69 rows across tenants, by design without a tenant setting on the login).
- `psql -U auditor@local -d cma -f roletest.sql` (scratch): proof that `current_setting('role')` keeps the outer `SET ROLE` inside a SECURITY DEFINER function and that the service account is not an owner member (basis of the 0008q draft; rolled back).
- `dropdb/createdb cma_perf`, `pg_dump cma | psql cma_perf` after creating the `uuidv7()` shim; `psql -U auditor@local -d cma_perf -f synthetic-volume-generator.sql` (three runs, see the volume section; running at hand-back).
- Static: `grep` over `db/*.sql` for the guard, `set role`, `begin;/commit;`, `drop`, `delete from` by enclosing function (awk), `raise exception` without `errcode` (line and next-line), `errcode` values, `revoke ... delete`, `advisory`, `lock_timeout|statement_timeout`; over `web/src` and `ingest/src` for `cma.<name>` references, pool settings and the SQLSTATE mapping; `python3 -I` diff of `docs/datamap/schema.json` against the local columns.
