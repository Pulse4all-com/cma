# Note on this folder

31.txt is the run of db/31 from main directly after db/76 on cma-prod-pg: it stopped at check A4, because 31 still pinned the earlier search path of ingest_connection (the catalog holds the intended pg_catalog, cma, pg_temp, confirmed on dev and prod). db/76 was not changed.
31-after-fix.txt is the run of the amended 31 (PR #162) on the same database: verdict PASS for both tenants.

Written down from Martin's own runs on 18 October 2026.
