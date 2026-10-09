-- CMA foundation, step 0: database roles
-- Run once per database server, as the built-in postgres user (Cloud SQL's admin role, not a
-- superuser), connected to the CMA database. This is the only step that needs postgres;
-- everything after it runs under personal IAM logins. Safe to rerun.
-- Roles are server-wide in Postgres: a second customer database on the same server would share
-- them, one reason a separate server or project per customer is the stronger boundary (README,
-- Open decisions).
--
-- Three NOLOGIN group roles. People and services never get rights directly, only membership:
--   cma_owner     owns the cma and cma_read schemas and every object in them; migrations via SET ROLE
--   cma_app       read and write on schema cma for the ingest API and the CMA; row-level security
--   cma_readonly  SELECT on the reporting views in schema cma_read only, never on base tables;
--                 for BigQuery, NocoDB and analytics. Sees all tenants unless the login user
--                 carries a tenant setting (see bq_reader below)
-- One LOGIN user for a service that cannot use IAM:
--   bq_reader     BigQuery federated connection (username and password, password in Secret Manager)

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'cma_owner') then
    create role cma_owner nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'cma_app') then
    create role cma_app nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'cma_readonly') then
    create role cma_readonly nologin;
  end if;
  -- login user without a password: cannot connect until the password is set (see below)
  if not exists (select 1 from pg_roles where rolname = 'bq_reader') then
    create role bq_reader login;
  end if;
end
$$;

-- cma_owner creates the cma and cma_read schemas (and any later schema) in this database, and
-- unqualified table names resolve to cma in new sessions (Studio, psql). Uses the database you
-- are connected to, so the script is the same for every customer database.
do $$
begin
  execute format('grant create on database %I to cma_owner', current_database());
  execute format('alter database %I set search_path = cma, public', current_database());
end
$$;

-- BigQuery login: reporting views only, unqualified names resolve to cma_read
grant cma_readonly to bq_reader;
alter role bq_reader set search_path = cma_read;
-- Password (Roadmap step 2, when the BigQuery connection is created), from Cloud Shell, never
-- pasted here:
--   gcloud sql users set-password bq_reader --instance=<instance> --prompt-for-password
-- then store it in Secret Manager as cma-<env>-bq-reader-password (europe-west4),
-- for example cma-dev-bq-reader-password on cma-dev-pg.
-- To limit a reader to one tenant, give that login user a tenant setting (optional):
--   alter role bq_reader set app.tenant_id = '<tenant uuid>';

-- Team logins
--   default session: the reporting surface in cma_read, exactly what BigQuery and NocoDB get
--   SET ROLE cma_owner   to run migrations and to read or fix base tables
--   SET ROLE cma_app     to test exactly what the application can see
--   ADMIN lets Martin and Joshua grant these roles to Finn and to service accounts without postgres
grant cma_readonly to "martin@pulse4all.com", "joshua@pulse4all.com" with admin true;
grant cma_owner    to "martin@pulse4all.com", "joshua@pulse4all.com" with admin true, inherit false, set true;
grant cma_app      to "martin@pulse4all.com", "joshua@pulse4all.com" with admin true, inherit false, set true;

-- Emergency path for postgres: SET ROLE cma_owner when nobody from the team is available
grant cma_owner to postgres with inherit false, set true;

-- Later, as Martin or Joshua (no postgres needed):
--
-- Finn, once his IAM database user exists (see handover open items):
--   grant cma_readonly to "finn@pulse4all.com";
--   grant cma_owner    to "finn@pulse4all.com" with inherit false, set true;
--   grant cma_app      to "finn@pulse4all.com" with inherit false, set true;
--
-- Ingest API service account (Roadmap step 2). The database user is the service account email
-- without .gserviceaccount.com, so per project: cma-ingest@p4a-cma-dev.iam, cma-ingest@p4a-cma-prod.iam
--   gcloud sql users create cma-ingest@<project>.iam --instance=<instance> --type=cloud_iam_service_account
--   grant cma_app to "cma-ingest@<project>.iam";
--
-- NocoDB (read-only table browser). No password login: NocoDB runs as the Cloud Run service cma-nocodb under
-- its own service account, through a Cloud SQL Auth Proxy sidecar with automatic IAM authentication. The
-- database user is cma-nocodb@<project>.iam, granted cma_readonly (and, on database nocodb, rights for its
-- own metadata) by docs/nocodb/grants.sql. Setup order and commands: docs/nocodb/README.md.
