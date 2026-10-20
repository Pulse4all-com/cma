-- CMA drift check: the functions of schemas cma and cma_read, one line each (addition 0008z, 20 October 2026).
-- Read-only. Run with psql -X -qAt as yourself (it sets the owner role), once against dev and once against prod, and
-- diff the two outputs (docs/RUNBOOK.md, section 4, Drift between dev and prod): no line differs when both instances ran
-- the same scripts. Each line is the function's signature (regprocedure) and the md5 of its definition
-- (pg_get_functiondef), sorted bytewise, so the order never depends on the instance's collation. Signatures and hashes
-- only: no data. Aggregates and window functions have no pg_get_functiondef; the schemas define none.
set search_path = pg_catalog;
set role cma_owner;
select f.line
from (select p.oid::regprocedure::text || ' ' || md5(pg_get_functiondef(p.oid)) as line
      from pg_proc p
      where p.pronamespace in ('cma'::regnamespace, 'cma_read'::regnamespace)
        and p.prokind in ('f', 'p')) f
order by f.line collate "C";
reset role;
