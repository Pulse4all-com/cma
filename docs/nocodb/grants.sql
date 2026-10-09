-- NocoDB's own metadata database: grants for the IAM database user cma-nocodb@__PROJECT__.iam.
-- Run in Cloud SQL Studio as postgres, connected to the database nocodb (not cma), once per project.
-- Replace __PROJECT__ with p4a-cma-dev or p4a-cma-prod. Never committed filled in.

grant connect, create, temporary on database nocodb to "cma-nocodb@__PROJECT__.iam";
grant usage, create on schema public to "cma-nocodb@__PROJECT__.iam";

-- The read-only surface NocoDB shows: the cma_read views through cma_readonly (see db/00_roles.sql).
grant cma_readonly to "cma-nocodb@__PROJECT__.iam";

-- Verdict: nocodb_create, public_create, cma_connect and reads_cma_read true; is_owner and is_app false.
select
  has_database_privilege('cma-nocodb@__PROJECT__.iam', 'nocodb', 'CREATE')   as nocodb_create,
  has_schema_privilege('cma-nocodb@__PROJECT__.iam', 'public', 'CREATE')     as public_create,
  has_database_privilege('cma-nocodb@__PROJECT__.iam', 'cma', 'CONNECT')     as cma_connect,
  has_schema_privilege('cma-nocodb@__PROJECT__.iam', 'cma_read', 'USAGE')    as reads_cma_read,
  pg_has_role('cma-nocodb@__PROJECT__.iam', 'cma_owner', 'MEMBER')           as is_owner,
  pg_has_role('cma-nocodb@__PROJECT__.iam', 'cma_app', 'MEMBER')             as is_app;
