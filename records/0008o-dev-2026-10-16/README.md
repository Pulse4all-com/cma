# Addition 0008o in dev, 16 October 2026

Night run N16-B (the follow-up layer; `Pulse4all-com/cma#142`), step 3 of
`docs/night-2026-10-16/MORNING_RUNBOOK.md`, run by Martin on 16 October 2026 in p4a-cma-dev (cma-dev-pg),
after 0008n (`records/0008n-dev-2026-10-16`). Written down by Claude Code on 17 October 2026 at Martin's
request from his report and the outputs he pushed to this folder; the values are his. Ids, counts, dates
and times only: no key, no secret and no personal data.

## Database (step 3)

| Script | File | Result |
|---|---|---|
| `72_follow_up.sql` | `72.txt` | ends `INSERT 0 1`, `COMMIT`, `RESET`; one notice: the check `connection_pipeline_sla_minutes_check` did not exist yet |
| `02_seed_pulse4all.sql` again | `02-rerun.txt` | no error: the two tenants' ids, `INSERT 0 0` twice, its blocks `DO` |
| `73_verify_follow_up.sql` | `73.txt` | 21 rows `PASS`; verdict `PASS`, `21 PASS, 0 FAIL`, `(22 rows)` |
| `73_verify_follow_up.sql` with `verify.provoke` true | `73-provoked.txt` | every row `FAIL`; verdict `PROVOKED, NOT A PASS`, `0 PASS, 21 FAIL` |
| `41_verify_lead_metrics.sql` again | `41-rerun.txt` | six tenant rows, each `PASS`: `pulse4all-subscriptions` (2 lead deals, 1 called, 5 data-quality findings), `pulse4all-invest`, and the four `email-…` tenants of the note below |
| `53_verify_sources_configuration.sql` again | `53-rerun.txt` | 15 `PASS`, 1 `FAIL`: A4 `2 connection(s) without the kind their rows imply`; verdict `FAIL`, `15 PASS, 1 FAIL` (note below) |
| `69_verify_email_activity.sql` again | `69-rerun.txt` | 29 rows `PASS`; verdict `PASS`, `29 PASS, 0 FAIL` |
| `71_verify_crm_tasks.sql` again | `71-rerun.txt` | 20 rows `PASS`; verdict `PASS`, `20 PASS, 0 FAIL` |

`41`, `69` and `71` are unchanged by 0008o. The runbook expected `53` at `16 PASS, 0 FAIL`; its one FAIL
does not come from 0008o (note below).

## Not in the report

- The times of the runs.

## Note: two leftover throwaway tenants in dev (one-off)

This note is not a result of the run. Claude Code wrote it on 17 October 2026, at Martin's request.

`41` lists four tenants that are not Pulse4all's: `email-69af3e5a-one`, `email-69af3e5a-two`,
`email-9990fdc0-one` and `email-9990fdc0-two`. They are the throwaway tenants of two earlier runs of
`ingest/verify/email-flow.mjs` in dev (briefs B17b and B17b.1), and they hold invented rows only. That
verifier did not remove its tenants, and it gave their HubSpot connections no kind. Each `-one` connection
holds email rows, which imply `crm`, so `53`'s A4 counts two connections without the kind their rows imply.

Since the pull request that added this note, the verifier sets kind `crm` on its connections and removes its
two tenants when done (README, Decision log, 17 October 2026), so a new run leaves nothing behind. The two
leftovers are cleared once, by hand, in dev only. The three steps below run one at a time.

**1. Studio (cma-dev-pg)**: the connections A4 counts (read only).

```sql
set role cma_owner;
select t.slug, c.adapter, c.kind, cma.connection_held_kinds_of(c.tenant_id, c.id) as held
from cma.integration_connection c join cma.tenant t on t.id = c.tenant_id
where c.kind is null and cardinality(cma.connection_held_kinds_of(c.tenant_id, c.id)) = 1
order by 1;
reset role;
```

Expected: two rows, `email-69af3e5a-one` and `email-9990fdc0-one`, each with adapter `hubspot`, kind null and
held `{crm}`. If any other tenant shows, stop here and tell Claude Code: step 2 removes the four `email-…`
tenants and nothing else.

**2. Studio (cma-dev-pg)**: remove the four tenants with every row they hold.

The block refuses unless the database is dev (the dev seed's active `agent.two@example.com`) and all four
tenants exist. It deletes their rows from every tenant table, children before the tables they point to (the
catalog's foreign keys), then their audit rows, then the four tenants. It runs as one transaction, so a
refusal or an error changes nothing. It does the same as `removeTenants` in `ingest/verify/lib.mjs`.

```sql
set role cma_owner;
do $$
declare
  v_slugs text[] := array['email-69af3e5a-one', 'email-69af3e5a-two', 'email-9990fdc0-one', 'email-9990fdc0-two'];
  v_ids   uuid[];
  v_left  text[];
  v_free  text[];
  v_t     text;
begin
  if not exists (select 1 from cma.app_user where email = 'agent.two@example.com' and status = 'active') then
    raise exception 'refused: not dev (no active agent.two@example.com)';
  end if;
  v_ids := array(select id from cma.tenant where slug = any (v_slugs));
  if cardinality(v_ids) <> cardinality(v_slugs) then
    raise exception 'refused: % of the % tenants found', cardinality(v_ids), cardinality(v_slugs);
  end if;
  -- every tenant table but the audit log, each after the tables that point to it
  v_left := array(select c.relname::text from pg_class c
                    join pg_attribute a on a.attrelid = c.oid and a.attname = 'tenant_id' and not a.attisdropped
                   where c.relnamespace = 'cma'::regnamespace and c.relkind in ('r', 'p') and not c.relispartition
                     and c.relname <> 'audit_log');
  while cardinality(v_left) > 0 loop
    v_free := array(select t from unnest(v_left) t where not exists (
                select 1 from pg_constraint k join pg_class ch on ch.oid = k.conrelid join pg_class pa on pa.oid = k.confrelid
                 where k.contype = 'f' and k.connamespace = 'cma'::regnamespace and k.conrelid <> k.confrelid
                   and pa.relname = t and ch.relname = any (v_left)));
    if cardinality(v_free) = 0 then
      raise exception 'refused: the foreign keys among % form a cycle', v_left;
    end if;
    foreach v_t in array v_free loop
      execute format('delete from cma.%I where tenant_id = any ($1)', v_t) using v_ids;
      v_left := array_remove(v_left, v_t);
    end loop;
  end loop;
  delete from cma.audit_log where tenant_id = any (v_ids);
  delete from cma.tenant where id = any (v_ids);
  raise notice 'removed % tenants', cardinality(v_ids);
end
$$;
select slug from cma.tenant order by 1;
reset role;
```

Expected: the notice `removed 4 tenants` and two tenants left, `pulse4all-invest` and
`pulse4all-subscriptions`. A message starting with `refused:` means nothing was changed.

**3. Studio (cma-dev-pg)**: `db/53_verify_sources_configuration.sql`, then `db/41_verify_lead_metrics.sql`.

Expected: `53` gives A4 `PASS` with `0 connection(s) without the kind their rows imply`, and the verdict
`PASS | 16 PASS, 0 FAIL`. `41` gives two tenant rows, `pulse4all-invest` and `pulse4all-subscriptions`,
each `PASS`.

Claude Code tested the block on PostgreSQL 16 in its container on 17 October 2026. The test database was built
from `db/` with the dev seed and had a leftover tenant pair from one run of the old verifier. It refused the
four dev names, which do not exist locally (`refused: 0 of the 4 tenants found`). With the local pair's
names it removed both tenants, and `53` went back to `16 PASS, 0 FAIL`. No value from dev was used.
